BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $publisher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Publish-VendoringPullRequest.ps1'
    $gitExecutable = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    function git {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
        & $gitExecutable @Arguments
    }
}

Describe 'Vendoring diff and pull request publication' {
    BeforeEach {
        $target = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $prepared = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $target, $prepared
        & $gitExecutable -C $target init --quiet --initial-branch=main
        & $gitExecutable -C $target config user.name fixture
        & $gitExecutable -C $target config user.email fixture@example.test
        'original' | Set-Content -LiteralPath (Join-Path $target 'action.yml')
        'obsolete' | Set-Content -LiteralPath (Join-Path $target 'old.js')
        '{"version":1,"kind":"action","files":["action.yml","old.js"]}' |
            Set-Content -LiteralPath (Join-Path $target '.vendoring.json')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m fixture
        'updated' | Set-Content -LiteralPath (Join-Path $prepared 'action.yml')
        $receipt = Join-Path $TestDrive 'receipt.json'
        '{"Repository":"upstream/action","Tag":"v1","Commit":"3333333333333333333333333333333333333333","Sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Attestation":"not-present","Asset":""}' |
            Set-Content -LiteralPath $receipt
        $savedToken = $env:GH_TOKEN
        $savedMap = $env:PLATFORM_GITHUB_TOKENS
        $env:GH_TOKEN = 'ghs_fixture'
        $env:PLATFORM_GITHUB_TOKENS = '{"customer-actions":"ghs_fixture"}'
        $remotePath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.git')
        & $gitExecutable init --quiet --bare $remotePath
        $cloud = @{ pulls = [Collections.Generic.List[object]]::new(); attempt = 0 }
        $gitTransport = {
            param([string[]] $Arguments)
            $localArguments = @($Arguments | ForEach-Object {
                if ($_ -ceq 'https://example.ghe.com/customer-actions/upstream-action.git') { $remotePath } else { $_ }
            })
            & $gitExecutable @localArguments
        }
        Mock git { & $gitTransport -Arguments $Arguments }
        $cloudTransport = {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            if ($Uri -like '*/installation/repositories*') {
                return Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{
                    total_count = 1; 'repositories.0.full_name' = 'customer-actions/upstream-action'
                }
            }
            if ($Uri.AbsolutePath -like '*/pulls' -and $Method -eq 'GET') {
                $filter = [Web.HttpUtility]::ParseQueryString($Uri.Query)
                $items = @(foreach ($pull in @($cloud.pulls | Where-Object { "customer-actions:$($_.head.ref)" -ceq $filter['head'] })) {
                    $fixture = Get-GitHubApiFixture -Name pulls/list -Set @{
                        '0.number' = $pull.number; '0.html_url' = $pull.html_url
                        '0.head.ref' = $pull.head.ref; '0.head.sha' = $pull.head.sha
                        '0.head.repo.full_name' = $pull.head.repo.full_name
                        '0.base.ref' = $pull.base.ref; '0.base.repo.full_name' = $pull.base.repo.full_name
                        '0.state' = $pull.state; '0.merged_at' = $pull.merged_at
                    }
                    $fixture[0]
                })
                if ($cloud.ContainsKey('lookupTransform')) { return & $cloud.lookupTransform $items }
                return ,$items
            }
            if ($Uri.AbsolutePath -like '*/pulls' -and $Method -eq 'POST') {
                $request = $Body | ConvertFrom-Json -AsHashtable
                $sha = & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($request.head)"
                $number = $cloud.pulls.Count + 1
                $pull = Get-GitHubApiFixture -Name pulls/create -Set @{
                    number = $number; html_url = "https://example.ghe.com/customer-actions/upstream-action/pull/$number"
                    'head.ref' = $request.head; 'head.sha' = $sha; 'head.repo.full_name' = 'customer-actions/upstream-action'
                    'base.ref' = 'main'; 'base.repo.full_name' = 'customer-actions/upstream-action'
                    state = 'open'; merged_at = $null
                }
                $cloud.pulls.Add($pull)
                return $pull
            }
            throw "Unexpected publishing API: $Method $Uri"
        }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            & $cloudTransport -Uri $Uri -Method $Method -Body $Body
        }
    }

    AfterEach {
        $env:GH_TOKEN = $savedToken
        $env:PLATFORM_GITHUB_TOKENS = $savedMap
    }

    It 'opens an App PR containing updated files and deletion of obsolete vendored files' {
        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture

        $result.PullRequest | Should -Be 'https://example.ghe.com/customer-actions/upstream-action/pull/1'
        Get-Content -LiteralPath (Join-Path $target 'action.yml') -Raw | Should -Match 'updated'
        Test-Path -LiteralPath (Join-Path $target 'old.js') | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and ($Body | ConvertFrom-Json).base -ceq 'main' -and
            ($Body | ConvertFrom-Json).body -like '*NOT PERFORMED*'
        }
    }

    It 'does not open another PR when the vendored source and provenance are unchanged' {
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture
        & $gitExecutable -C $target branch -f main HEAD
        & $gitExecutable -C $target switch --quiet main
        $cloud.pulls[0].state = 'closed'
        $cloud.pulls[0].merged_at = '2026-10-22T12:00:00Z'

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier second
        $result.HasChanges | Should -BeFalse
        $result.PullRequest | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'uses the same import branch across different workflow attempts' {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier first
        & $gitExecutable -C $target switch --quiet main

        $second = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier second

        $second.Branch | Should -BeExactly $first.Branch
        $second.Branch | Should -Match '^vendor/action/[a-f0-9]{64}$'
    }

    It 'recovers the same source repository identity with different casing' {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        $data = Get-Content $receipt -Raw | ConvertFrom-Json -AsHashtable
        $data.Repository = 'UPSTREAM/ACTION'
        $data | ConvertTo-Json | Set-Content $receipt
        $second = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $second.PullRequest | Should -BeExactly $first.PullRequest
    }

    It 'separates imports by source and exact tag even when their archive digest is identical' {
        $branches = @(
            foreach ($source in @(
                @{ Repository = 'upstream/action'; Tag = 'v1' },
                @{ Repository = 'another/action'; Tag = 'v1' },
                @{ Repository = 'upstream/action'; Tag = 'v2' },
                @{ Repository = 'upstream/action'; Tag = 'V1' }
            )) {
                & $gitExecutable -C $target switch --quiet main
                $data = Get-Content $receipt -Raw | ConvertFrom-Json -AsHashtable
                $data.Repository = $source.Repository
                $data.Tag = $source.Tag
                $data | ConvertTo-Json | Set-Content $receipt
                $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
                    -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
                $result.Branch
            }
        )
        @($branches | Sort-Object -Unique -CaseSensitive).Count | Should -Be 4
        $cloud.pulls.Count | Should -Be 4
    }

    It 'recovers the published branch and PR without duplicating either' {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier first
        $firstSha = & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($first.Branch)"
        & $gitExecutable -C $target switch --quiet main

        $second = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier second

        $second.Branch | Should -BeExactly $first.Branch
        $second.PullRequest | Should -BeExactly $first.PullRequest
        @(& $gitExecutable --git-dir=$remotePath for-each-ref refs/heads).Count | Should -Be 1
        & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($first.Branch)" | Should -BeExactly $firstSha
        $cloud.pulls.Count | Should -Be 1
    }

    It 'recovers the original import after target main advances' {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        $null = New-Item -ItemType Directory -Path (Join-Path $target '.github')
        'new governance' | Set-Content (Join-Path $target '.github/CODEOWNERS')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m governance

        $second = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com

        $second.PullRequest | Should -BeExactly $first.PullRequest
        $cloud.pulls.Count | Should -Be 1
    }

    It 'resumes an orphaned <ImportKind> import with main changes <Change>' -ForEach @(
        @{ ImportKind = 'action'; Change = 'inside (added file)'; Inside = $true; Mode = $false }
        @{ ImportKind = 'release'; Change = 'inside (added file)'; Inside = $true; Mode = $false }
        @{ ImportKind = 'action'; Change = 'inside (executable bit)'; Inside = $true; Mode = $true }
        @{ ImportKind = 'release'; Change = 'inside (executable bit)'; Inside = $true; Mode = $true }
        @{ ImportKind = 'action'; Change = 'outside'; Inside = $false; Mode = $false }
        @{ ImportKind = 'release'; Change = 'outside'; Inside = $false; Mode = $false }
    ) {
        $modePath = 'old.js'
        if ($ImportKind -ceq 'release') {
            Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
            $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform'), (Join-Path $target 'platform')
            'release content' | Set-Content (Join-Path $prepared 'platform/README.md')
            $modePath = 'platform/old.sh'
            'original release' | Set-Content (Join-Path $target $modePath)
            & $gitExecutable -C $target add .
            & $gitExecutable -C $target commit --quiet -m release-base
        }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            if ($Method -eq 'POST') { throw 'Injected PR creation interruption.' }
            & $cloudTransport -Uri $Uri -Method $Method -Body $Body
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Injected PR creation interruption*'
        $refs = @(& $gitExecutable --git-dir=$remotePath for-each-ref '--format=%(refname)' refs/heads)
        $refs.Count | Should -Be 1
        $remoteSha = & $gitExecutable --git-dir=$remotePath rev-parse $refs[0]
        & $gitExecutable -C $target switch --quiet main
        if ($Mode) {
            if (-not $IsWindows) { [IO.File]::SetUnixFileMode((Join-Path $target $modePath), [IO.UnixFileMode]493) }
            & $gitExecutable -C $target update-index --chmod=+x -- $modePath
        }
        else {
            $changedPath = if ($Inside) {
                if ($ImportKind -ceq 'release') { 'platform/extra.yml' } else { 'extra.js' }
            }
            else {
                if ($ImportKind -ceq 'release') { 'instance.yaml' } else { '.github/CODEOWNERS' }
            }
            $destination = Join-Path $target $changedPath
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            'main advanced' | Set-Content -LiteralPath $destination
            & $gitExecutable -C $target add .
        }
        & $gitExecutable -C $target commit --quiet -m main-advance
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            & $cloudTransport -Uri $Uri -Method $Method -Body $Body
        }

        if ($Inside) {
            { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
                Should -Throw '*main changed inside the vendoring boundary*delete the orphaned import branch*run the import again*'
            $cloud.pulls.Count | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }
        else {
            $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
            $result.Branch | Should -BeExactly $refs[0].Substring('refs/heads/'.Length)
            $result.PullRequest | Should -BeExactly 'https://example.ghe.com/customer-actions/upstream-action/pull/1'
            $cloud.pulls.Count | Should -Be 1
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }
        & $gitExecutable --git-dir=$remotePath rev-parse $refs[0] | Should -BeExactly $remoteSha
        @(& $gitExecutable --git-dir=$remotePath for-each-ref refs/heads).Count | Should -Be 1
    }

    It 'rejects changed content or provenance for an existing import identity' -ForEach @(
        @{ Case = 'content'; Change = { 'different bytes' | Set-Content (Join-Path $prepared 'action.yml') } }
        @{ Case = 'digest'; Change = {
            $data = Get-Content $receipt -Raw | ConvertFrom-Json -AsHashtable
            $data.Sha256 = 'b' * 64
            $data | ConvertTo-Json | Set-Content $receipt
        } }
    ) {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $firstSha = & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($first.Branch)"
        & $gitExecutable -C $target switch --quiet main
        . $Change

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*different content or provenance*'
        & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($first.Branch)" | Should -BeExactly $firstSha
        $cloud.pulls.Count | Should -Be 1
    }

    It 'rejects an invalid resumed PR: <Case>' -ForEach @(
        @{ Case = 'missing response'; Change = { return ,@($null) }; Message = '*Invalid vendoring PR response*' }
        @{ Case = 'missing head'; Change = { param($items) $items[0].Remove('head'); return ,$items }; Message = '*head repository*' }
        @{ Case = 'null head repository'; Change = { param($items) $items[0].head.repo = $null; return ,$items }; Message = '*head repository*' }
        @{ Case = 'other head repository'; Change = { param($items) $items[0].head.repo.full_name = 'another/repo'; return ,$items }; Message = '*head repository*' }
        @{ Case = 'missing base'; Change = { param($items) $items[0].Remove('base'); return ,$items }; Message = '*base repository*' }
        @{ Case = 'null base repository'; Change = { param($items) $items[0].base.repo = $null; return ,$items }; Message = '*base repository*' }
        @{ Case = 'other base repository'; Change = { param($items) $items[0].base.repo.full_name = 'another/repo'; return ,$items }; Message = '*base repository*' }
        @{ Case = 'other head ref'; Change = { param($items) $items[0].head.ref = 'other'; return ,$items }; Message = '*head does not match*' }
        @{ Case = 'head ref case'; Change = { param($items) $items[0].head.ref = $items[0].head.ref.ToUpperInvariant(); return ,$items }; Message = '*head does not match*' }
        @{ Case = 'other base ref'; Change = { param($items) $items[0].base.ref = 'other'; return ,$items }; Message = '*base is not main*' }
        @{ Case = 'base ref case'; Change = { param($items) $items[0].base.ref = 'MAIN'; return ,$items }; Message = '*base is not main*' }
        @{ Case = 'other SHA'; Change = { param($items) $items[0].head.sha = 'f' * 40; return ,$items }; Message = '*head SHA changed*' }
        @{ Case = 'SHA case'; Change = { param($items) $items[0].head.sha = $items[0].head.sha.ToUpperInvariant(); return ,$items }; Message = '*head SHA changed*' }
        @{ Case = 'missing state'; Change = { param($items) $items[0].Remove('state'); return ,$items }; Message = '*state is unknown*' }
        @{ Case = 'state case'; Change = { param($items) $items[0].state = 'OPEN'; return ,$items }; Message = '*state is unknown*' }
        @{ Case = 'empty state'; Change = { param($items) $items[0].state = ''; return ,$items }; Message = '*state is unknown*' }
        @{ Case = 'missing number'; Change = { param($items) $items[0].Remove('number'); return ,$items }; Message = '*URL does not match*' }
        @{ Case = 'invalid numeric URL'; Change = { param($items) $items[0].number = 0; $items[0].html_url = 'https://example.ghe.com/customer-actions/upstream-action/pull/0'; return ,$items }; Message = '*URL does not match*' }
        @{ Case = 'other URL'; Change = { param($items) $items[0].html_url = 'https://other.test/pull/1'; return ,$items }; Message = '*URL does not match*' }
        @{ Case = 'empty URL'; Change = { param($items) $items[0].html_url = ''; return ,$items }; Message = '*URL does not match*' }
        @{ Case = 'closed unmerged'; Change = { param($items) $items[0].state = 'closed'; return ,$items }; Message = '*closed without merging*' }
    ) {
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        # Deliberately invalid API responses and a closed-unmerged PR exercise the rejection policy.
        $cloud.lookupTransform = $Change
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } | Should -Throw $Message
        $cloud.pulls.Count | Should -Be 1
    }

    It 'rejects a malformed merge timestamp instead of reporting a completed import' {
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        # Deliberately invalid date-time value in an otherwise documented PR response.
        $cloud.lookupTransform = {
            param($items)
            $items[0].state = 'closed'
            $items[0].merged_at = 'unknown'
            return ,$items
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*closed without merging*'
    }

    It 'rejects a merged import that main no longer contains: <Case>' -ForEach @(
        @{ Case = 'newer content'; Change = {
            'newer version' | Set-Content (Join-Path $target 'action.yml')
            & $gitExecutable -C $target add .
            & $gitExecutable -C $target commit --quiet -m newer-version
        } }
        @{ Case = 'reverted import'; Change = {
            & $gitExecutable -C $target revert --no-edit HEAD | Out-Null
        } }
        @{ Case = 'missing provenance'; Change = {
            & $gitExecutable -C $target rm --quiet .vendoring.json
            & $gitExecutable -C $target commit --quiet -m remove-provenance
        } }
    ) {
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target branch -f main HEAD
        & $gitExecutable -C $target switch --quiet main
        $cloud.pulls[0].state = 'closed'
        $cloud.pulls[0].merged_at = '2026-10-22T12:00:00Z'
        . $Change

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*main no longer contains*'
        $cloud.pulls.Count | Should -Be 1
    }

    It 'checks a merged import after changes outside and inside the <ImportKind> boundary' -ForEach @(
        @{ ImportKind = 'action'; Owned = 'action.yml'; Outside = '.github/CODEOWNERS' }
        @{ ImportKind = 'release'; Owned = 'platform/README.md'; Outside = 'instance.yaml' }
    ) {
        if ($ImportKind -ceq 'release') {
            Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
            $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
            'release' | Set-Content (Join-Path $prepared $Owned)
        }
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target branch -f main HEAD
        & $gitExecutable -C $target switch --quiet main
        $cloud.pulls[0].state = 'closed'
        $cloud.pulls[0].merged_at = '2026-10-22T12:00:00Z'
        $null = New-Item -ItemType Directory -Path (Split-Path (Join-Path $target $Outside) -Parent) -Force
        'outside import' | Set-Content (Join-Path $target $Outside)
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m outside-boundary

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $result.HasChanges | Should -BeFalse
        $result.PullRequest | Should -BeNullOrEmpty

        & $gitExecutable -C $target switch --quiet main
        'inside import changed' | Set-Content (Join-Path $target $Owned)
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m inside-boundary
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*main no longer contains*'
    }

    It 'accepts documented nullable PR fields and case-insensitive repository names on resume' {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        $cloud.lookupTransform = {
            param($items)
            $items[0].user = $null
            $items[0].head.user = $null
            $items[0].head.repo.full_name = 'CUSTOMER-ACTIONS/UPSTREAM-ACTION'
            $items[0].base.repo.full_name = 'CUSTOMER-ACTIONS/UPSTREAM-ACTION'
            return ,$items
        }
        $second = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $second.PullRequest | Should -BeExactly $first.PullRequest
    }

    It 'fails closed on a malformed or ambiguous PR lookup: <Case>' -ForEach @(
        @{ Case = 'null'; Change = { param($items) $null = $items; return $null } }
        @{ Case = 'object'; Change = { param($items) return $items[0] } }
        @{ Case = 'duplicates'; Change = { param($items) return ,@($items[0], $items[0]) } }
    ) {
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        # Deliberately malformed/ambiguous collection, not a documented successful response.
        $cloud.lookupTransform = $Change
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*array with at most one import PR*'
    }

    It 'fails closed when an existing PR has lost its branch' {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        & $gitExecutable --git-dir=$remotePath update-ref -d "refs/heads/$($first.Branch)"
        $cloud.lookupTransform = { param($items) $null = $items; return ,@($cloud.pulls[0]) }

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*no import branch*'
        @(& $gitExecutable --git-dir=$remotePath for-each-ref refs/heads).Count | Should -Be 0
        $cloud.pulls.Count | Should -Be 1
    }

    It 'rejects an invalid resume ref: <Case>' -ForEach @(
        @{ Case = 'multiple refs'; Operation = 'ls-remote'; Response = { @($refLine, $refLine) }; Message = '*resolve*one commit*' }
        @{ Case = 'invalid SHA'; Operation = 'ls-remote'; Response = { $refLine -replace '^[a-f0-9]{40}', ('z' * 40) }; Message = '*resolve*one commit*' }
        @{ Case = 'SHA case'; Operation = 'ls-remote'; Response = { $firstSha.ToUpperInvariant() + "`trefs/heads/$($first.Branch)" }; Message = '*resolve*one commit*' }
        @{ Case = 'other branch'; Operation = 'ls-remote'; Response = { "$firstSha`trefs/heads/other" }; Message = '*resolve*one commit*' }
        @{ Case = 'branch case'; Operation = 'ls-remote'; Response = { $refLine.Replace('vendor/', 'VENDOR/') }; Message = '*resolve*one commit*' }
        @{ Case = 'missing parent'; Operation = 'rev-list'; Response = { $firstSha }; Message = '*single-parent*' }
        @{ Case = 'merge commit'; Operation = 'rev-list'; Response = { "$firstSha $firstSha $firstSha" }; Message = '*single-parent*' }
        @{ Case = 'other main ancestry'; Operation = 'merge-base'; Response = { 'f' * 40 }; Message = '*main history*' }
        @{ Case = 'ancestry case'; Operation = 'merge-base'; Response = { (& $gitExecutable -C $target rev-parse main).ToUpperInvariant() }; Message = '*main history*' }
    ) {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        $firstSha = & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($first.Branch)"
        $refLine = "$firstSha`trefs/heads/$($first.Branch)"
        # Deliberately malformed/foreign git responses isolate the resume guards.
        Mock git {
            if ($Arguments -contains $Operation) { return & $Response }
            & $gitTransport -Arguments $Arguments
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } | Should -Throw $Message
    }

    It 'rejects a changed import branch before PR creation: <Case>' -ForEach @(
        @{ Case = 'missing'; Response = { param($line) $null = $line; return @() } }
        @{ Case = 'multiple'; Response = { param($line) @($line, $line) } }
        @{ Case = 'other SHA'; Response = { param($line) $line -replace '^[a-f0-9]{40}', ('f' * 40) } }
        @{ Case = 'SHA case'; Response = { param($line) $line.Substring(0, 40).ToUpperInvariant() + $line.Substring(40) } }
        @{ Case = 'branch case'; Response = { param($line) $line.Replace('vendor/', 'VENDOR/') } }
    ) {
        $cloud.reads = 0
        Mock git {
            if ($Arguments -contains 'ls-remote') {
                $cloud.reads++
                if ($cloud.reads -gt 1) {
                    $line = & $gitTransport -Arguments $Arguments
                    return & $Response $line
                }
            }
            & $gitTransport -Arguments $Arguments
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*branch changed before PR creation*'
        $cloud.pulls.Count | Should -Be 0
    }

    It 'rejects changed content or provenance returned by git with different tree casing' {
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        # Deliberately noncanonical git output tests an invalid object identity.
        Mock git {
            if ($Arguments -contains 'rev-parse' -and $Arguments[-1] -like '*^{tree}') {
                return (& $gitTransport -Arguments $Arguments).ToUpperInvariant()
            }
            & $gitTransport -Arguments $Arguments
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*different content or provenance*'
    }

    It 'rejects target workflows as prepared action content before creating any PR' {
        $workflow = Join-Path $prepared '.github/workflows/unsafe.yml'
        $null = New-Item -ItemType Directory -Path (Split-Path $workflow -Parent) -Force
        'name: unsafe' | Set-Content -LiteralPath $workflow
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture } |
            Should -Throw '*outside the action vendoring boundary*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'preserves instance configuration and live workflows while replacing only the release tree' {
        $null = New-Item -ItemType Directory -Path (Join-Path $target 'platform'), (Join-Path $target '.github/workflows')
        'configured instance' | Set-Content -LiteralPath (Join-Path $target 'instance.yaml')
        'trusted deployment' | Set-Content -LiteralPath (Join-Path $target '.github/workflows/deploy.yml')
        'old release' | Set-Content -LiteralPath (Join-Path $target 'platform/obsolete.txt')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m instance
        Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'new release' | Set-Content -LiteralPath (Join-Path $prepared 'platform/README.md')

        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture
        Get-Content -LiteralPath (Join-Path $target 'instance.yaml') -Raw | Should -Match 'configured instance'
        Get-Content -LiteralPath (Join-Path $target '.github/workflows/deploy.yml') -Raw | Should -Match 'trusted deployment'
        Test-Path -LiteralPath (Join-Path $target 'platform/obsolete.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'platform/README.md') | Should -BeTrue
    }

    It 'restores executable bits from the prepared manifest after artifact transfer has flattened permissions' {
        'entrypoint' | Set-Content -LiteralPath (Join-Path $prepared 'entrypoint.sh')
        $modeManifest = Join-Path $TestDrive 'modes.json'
        '{"version":1,"files":{"action.yml":false,"entrypoint.sh":true}}' | Set-Content -LiteralPath $modeManifest
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture -ModeManifestPath $modeManifest

        & $gitExecutable -C $target ls-files --stage entrypoint.sh | Should -Match '^100755 '
        & $gitExecutable -C $target ls-files --stage action.yml | Should -Match '^100644 '
    }

    It 'rejects an executable manifest containing paths outside the prepared inventory' {
        $modeManifest = Join-Path $TestDrive 'invalid-modes.json'
        '{"version":1,"files":{"../escape.sh":true}}' | Set-Content -LiteralPath $modeManifest
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture -ModeManifestPath $modeManifest } |
            Should -Throw '*Mode manifest has no boolean executable flag*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
    }
}
