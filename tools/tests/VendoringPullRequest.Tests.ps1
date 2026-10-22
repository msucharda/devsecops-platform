BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $publisher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Publish-VendoringPullRequest.ps1'
    $gitExecutable = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $remoteUrl = 'https://example.ghe.com/customer-actions/upstream-action.git'
    function git {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
        & $gitExecutable @Arguments
    }
    # Pull request stub of GET/POST /repos/{owner}/{repo}/pulls and PATCH /repos/{owner}/{repo}/pulls/{pull_number}
    # (API version 2026-03-10). Responses use the shared documented fixtures; $cloud.pulls holds the repository state.
    $newPullFixture = {
        param([string] $Name, [hashtable] $Pull, [string] $Prefix)
        $set = @{}
        $fields = @{
            number = $Pull.number; html_url = "https://example.ghe.com/customer-actions/upstream-action/pull/$($Pull.number)"
            state = $Pull.state; title = $Pull.title; body = $Pull.body; 'head.ref' = $Pull.head; 'head.label' = "$($Pull.headOwner):$($Pull.head)"
            'head.repo.full_name' = $Pull.headRepository; 'base.ref' = $Pull.base
        }
        foreach ($key in $fields.Keys) { $set["$Prefix$key"] = $fields[$key] }
        $body = Get-GitHubApiFixture -Name $Name -Set $set
        if ($null -eq $Pull.headRepository) { if ($Prefix) { $body[0].head.repo = $null } else { $body.head.repo = $null } }
        return , $body
    }
    $apiTransport = {
        param([uri] $Uri, [string] $Method, $Body)
        $Method = if ($Method) { $Method.ToUpperInvariant() } else { 'GET' }
        if ($Uri.AbsolutePath -like '*/installation/repositories') {
            return Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{
                total_count = 1; 'repositories.0.full_name' = 'customer-actions/upstream-action'
            }
        }
        if ($Uri.AbsolutePath -ceq '/repos/customer-actions/upstream-action/pulls' -and $Method -eq 'GET') {
            $query = [Web.HttpUtility]::ParseQueryString($Uri.Query)
            $items = [Collections.Generic.List[object]]::new()
            foreach ($pull in $cloud.pulls) {
                # The documented head filter selects by owner and branch; the stub matches like GitHub without case.
                if ($query['head'] -and "$($pull.headOwner):$($pull.head)" -ne $query['head']) { continue }
                if (-not $cloud.listAllStates -and $query['state'] -cne 'all' -and $pull.state -cne $query['state']) { continue }
                $items.Add((& $newPullFixture 'pulls/list' $pull '0.')[0])
            }
            return , $items.ToArray()
        }
        if ($Uri.AbsolutePath -ceq '/repos/customer-actions/upstream-action/pulls' -and $Method -eq 'POST') {
            $request = $Body | ConvertFrom-Json -AsHashtable
            $number = $cloud.nextNumber
            $cloud.nextNumber = $number + 1
            $pull = @{
                number = $number; state = 'open'; title = $request.title; body = $request.body; head = $request.head
                headOwner = 'customer-actions'; headRepository = 'customer-actions/upstream-action'; base = $request.base
            }
            $cloud.pulls.Add($pull)
            return & $newPullFixture 'pulls/create' $pull ''
        }
        if ($Uri.AbsolutePath -cmatch '^/repos/customer-actions/upstream-action/pulls/(?<number>[0-9]+)$' -and $Method -eq 'PATCH') {
            $number = [int] $Matches['number']
            $request = $Body | ConvertFrom-Json -AsHashtable
            $pull = @($cloud.pulls | Where-Object { $_.number -eq $number })[0]
            foreach ($key in $request.Keys) { $pull[$key] = $request[$key] }
            return & $newPullFixture 'pulls/update' $pull ''
        }
        throw "Unexpected publishing API: $Method $Uri"
    }
    # Replaces the HTTPS remote of the target with a local bare repository, so that ls-remote, fetch and push run offline.
    $gitTransport = {
        param([string[]] $Arguments)
        $mapped = @(foreach ($argument in $Arguments) { if ($argument -ceq $remoteUrl) { $bare } else { $argument } })
        & $gitExecutable @mapped
    }
}

Describe 'Vendoring diff and pull request publication' {
    BeforeEach {
        $target = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $prepared = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $bare = Join-Path $TestDrive ([guid]::NewGuid().ToString())
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
        & $gitExecutable clone --quiet --bare $target $bare
        'updated' | Set-Content -LiteralPath (Join-Path $prepared 'action.yml')
        $receipt = Join-Path $TestDrive 'receipt.json'
        '{"Repository":"upstream/action","Tag":"v1","Commit":"3333333333333333333333333333333333333333","Sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Attestation":"not-present","Asset":""}' |
            Set-Content -LiteralPath $receipt
        $savedToken = $env:GH_TOKEN
        $savedMap = $env:PLATFORM_GITHUB_TOKENS
        $env:GH_TOKEN = 'ghs_fixture'
        $env:PLATFORM_GITHUB_TOKENS = '{"customer-actions":"ghs_fixture"}'
        $cloud = @{ pulls = [Collections.Generic.List[hashtable]]::new(); nextNumber = 1; listAllStates = $false }
        Mock git { & $gitTransport $Arguments }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method, $Body)
            & $apiTransport -Uri $Uri -Method $Method -Body $Body
        }
    }

    AfterEach {
        $env:GH_TOKEN = $savedToken
        $env:PLATFORM_GITHUB_TOKENS = $savedMap
    }

    It 'opens an App PR containing updated files and deletion of obsolete vendored files' {
        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com

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
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target branch -f main HEAD
        & $gitExecutable -C $target switch --quiet main

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $result.HasChanges | Should -BeFalse
        $result.PullRequest | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects target workflows as prepared action content before creating any PR' {
        $workflow = Join-Path $prepared '.github/workflows/unsafe.yml'
        $null = New-Item -ItemType Directory -Path (Split-Path $workflow -Parent) -Force
        'name: unsafe' | Set-Content -LiteralPath $workflow
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
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
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
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
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -ModeManifestPath $modeManifest

        & $gitExecutable -C $target ls-files --stage entrypoint.sh | Should -Match '^100755 '
        & $gitExecutable -C $target ls-files --stage action.yml | Should -Match '^100644 '
    }

    It 'rejects an executable manifest containing paths outside the prepared inventory' {
        $modeManifest = Join-Path $TestDrive 'invalid-modes.json'
        '{"version":1,"files":{"../escape.sh":true}}' | Set-Content -LiteralPath $modeManifest
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -ModeManifestPath $modeManifest } |
            Should -Throw '*Mode manifest has no boolean executable flag*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
    }

    Context 'stable import identity and recovery' {
        BeforeEach {
            $arguments = @{
                PreparedPath = $prepared; TargetPath = $target; ReceiptPath = $receipt; Kind = 'action'
                Repository = 'customer-actions/upstream-action'; ApiUrl = 'https://api.example.ghe.com'
            }
            # A new workflow run starts from a fresh checkout of the target main.
            $restart = {
                & $gitExecutable -C $target switch --quiet --force main
                & $gitExecutable -C $target branch --quiet -D @(& $gitExecutable -C $target for-each-ref --format='%(refname:short)' refs/heads/vendor)
            }
            $remoteBranches = { @(& $gitExecutable --git-dir=$bare for-each-ref --format='%(refname:short)' refs/heads/vendor) }
            $rewriteRemote = {
                param([string] $Branch, [string] $Email, [string[]] $Parents)
                $tree = & $gitExecutable --git-dir=$bare rev-parse "refs/heads/$Branch^{tree}"
                $env:GIT_COMMITTER_NAME = 'someone'; $env:GIT_COMMITTER_EMAIL = $Email
                $env:GIT_AUTHOR_NAME = 'someone'; $env:GIT_AUTHOR_EMAIL = $Email
                try {
                    $parentArguments = @(foreach ($parent in $Parents) { '-p'; $parent })
                    $commit = & $gitExecutable --git-dir=$bare commit-tree $tree @parentArguments -m rewritten
                }
                finally {
                    Remove-Item Env:GIT_COMMITTER_NAME, Env:GIT_COMMITTER_EMAIL, Env:GIT_AUTHOR_NAME, Env:GIT_AUTHOR_EMAIL
                }
                & $gitExecutable --git-dir=$bare update-ref "refs/heads/$Branch" $commit
            }
        }

        It 'derives the branch from kind, source and tag and reuses the pushed branch and open PR on a rerun' {
            $first = & $publisher @arguments
            & $restart
            $second = & $publisher @arguments

            $first.Branch | Should -Match '^vendor/action/upstream-action-v1-[0-9a-f]{16}$'
            $second.Branch | Should -BeExactly $first.Branch
            $second.PullRequest | Should -BeExactly $first.PullRequest
            & $remoteBranches | Should -Be @($first.Branch)
            $cloud.pulls.Count | Should -Be 1
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'push' }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'gives different tags and import kinds different branches' {
            $action = & $publisher @arguments
            & $restart
            '{"Repository":"upstream/action","Tag":"v2","Commit":"3333333333333333333333333333333333333333","Sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Attestation":"not-present","Asset":""}' |
                Set-Content -LiteralPath $receipt
            $tag = & $publisher @arguments

            $tag.Branch | Should -Match '^vendor/action/upstream-action-v2-[0-9a-f]{16}$'
            $tag.Branch.Substring($tag.Branch.Length - 16) | Should -Not -Be $action.Branch.Substring($action.Branch.Length - 16)
            $cloud.pulls.Count | Should -Be 2
        }

        It 'replaces a stale vendoring commit and updates the PR when the same tag has new content' {
            $first = & $publisher @arguments
            & $restart
            'retagged' | Set-Content -LiteralPath (Join-Path $prepared 'action.yml')
            '{"Repository":"upstream/action","Tag":"v1","Commit":"4444444444444444444444444444444444444444","Sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","Attestation":"not-present","Asset":""}' |
                Set-Content -LiteralPath $receipt
            $second = & $publisher @arguments

            $second.Branch | Should -BeExactly $first.Branch
            $second.PullRequest | Should -BeExactly $first.PullRequest
            & $gitExecutable --git-dir=$bare show "refs/heads/$($first.Branch):action.yml" | Should -Be 'retagged'
            $cloud.pulls.Count | Should -Be 1
            $cloud.pulls[0].body | Should -Match 'bbbbbbbbbbbb'
            Should -Invoke git -Times 2 -Exactly -ParameterFilter { $Arguments -contains 'push' }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'replaces a vendoring commit whose parent is an older main commit' {
            $first = & $publisher @arguments
            & $restart
            'instance change' | Set-Content -LiteralPath (Join-Path $target 'NOTES.md')
            & $gitExecutable -C $target add NOTES.md
            & $gitExecutable -C $target commit --quiet -m 'main moved'
            & $gitExecutable -C $target push --quiet $bare main

            $null = & $publisher @arguments
            & $gitExecutable --git-dir=$bare rev-parse "refs/heads/$($first.Branch)~1" | Should -Be (& $gitExecutable --git-dir=$bare rev-parse main)
            Should -Invoke git -Times 2 -Exactly -ParameterFilter { $Arguments -contains 'push' }
            $cloud.pulls.Count | Should -Be 1
        }

        It 'refuses to replace an import branch whose head <Case>' -ForEach @(
            @{ Case = 'has another committer'; Email = 'reviewer@example.test'; Parents = 'main' }
            @{ Case = 'has the vendoring committer in another case'; Email = 'Platform-Vendoring@users.noreply.github.com'; Parents = 'main' }
            @{ Case = 'is a merge commit'; Email = 'platform-vendoring@users.noreply.github.com'; Parents = 'main', 'branch' }
            @{ Case = 'has a parent outside main'; Email = 'platform-vendoring@users.noreply.github.com'; Parents = 'orphan' }
        ) {
            $first = & $publisher @arguments
            & $restart
            $parents = @(foreach ($name in $Parents) {
                    switch ($name) {
                        'main' { & $gitExecutable --git-dir=$bare rev-parse main }
                        'branch' { & $gitExecutable --git-dir=$bare rev-parse "refs/heads/$($first.Branch)" }
                        'orphan' { & $gitExecutable --git-dir=$bare commit-tree (& $gitExecutable --git-dir=$bare rev-parse 'main^{tree}') -m orphan }
                    }
                })
            & $rewriteRemote $first.Branch $Email $parents
            $before = & $gitExecutable --git-dir=$bare rev-parse "refs/heads/$($first.Branch)"

            { & $publisher @arguments } | Should -Throw '*did not create on top of main*'
            & $gitExecutable --git-dir=$bare rev-parse "refs/heads/$($first.Branch)" | Should -Be $before
            Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'push' }
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }

        It 'opens its own PR and ignores a listed PR whose head <Case>' -ForEach @(
            @{ Case = 'branch differs in case'; Field = 'head'; Value = 'upper' }
            @{ Case = 'is in a fork'; Field = 'headRepository'; Value = 'fork-owner/upstream-action' }
            @{ Case = 'repository was deleted'; Field = 'headRepository'; Value = $null }
        ) {
            $first = & $publisher @arguments
            & $restart
            $cloud.pulls[0][$Field] = if ($Value -ceq 'upper') { $first.Branch.ToUpperInvariant() } else { $Value }

            $second = & $publisher @arguments
            $second.PullRequest | Should -Not -Be $first.PullRequest
            $cloud.pulls.Count | Should -Be 2
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }

        It 'stops before changing a listed PR that <Case>' -ForEach @(
            @{ Case = 'targets another base'; Field = 'base'; Value = 'develop'; Message = '*not an open PR into main*' }
            @{ Case = 'is closed'; Field = 'state'; Value = 'closed'; Message = '*not an open PR into main*' }
            @{ Case = 'has an invalid number'; Field = 'number'; Value = 0; Message = '*not an open PR into main*' }
            @{ Case = 'has a non-HTTPS URL'; Field = 'html_url'; Value = 'http://example.ghe.com/pull/1'; Message = '*not an open PR into main*' }
            @{ Case = 'has a duplicate'; Field = 'duplicate'; Value = $null; Message = '*has 2 pull requests*' }
        ) {
            $null = & $publisher @arguments
            & $restart
            $cloud.listAllStates = $true
            'retagged' | Set-Content -LiteralPath (Join-Path $prepared 'action.yml')
            if ($Field -ceq 'duplicate') { $cloud.pulls.Add($cloud.pulls[0].Clone()) }
            elseif ($Field -ceq 'html_url') {
                Mock Invoke-RestMethod -ParameterFilter { $Method -ne 'POST' -and $Method -ne 'PATCH' -and ([string] $Uri) -like '*/pulls?*' } {
                    $items = & $apiTransport -Uri $Uri -Method GET
                    foreach ($item in $items) { $item.html_url = 'http://example.ghe.com/pull/1' }
                    return , $items
                }
            }
            else { $cloud.pulls[0][$Field] = $Value }

            { & $publisher @arguments } | Should -Throw $Message
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        }
    }
}
