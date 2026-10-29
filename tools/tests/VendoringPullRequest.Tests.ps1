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
        if ((Get-Variable ImportKind -ErrorAction SilentlyContinue) -and $ImportKind -ceq 'release') {
            '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
                Set-Content -LiteralPath (Join-Path $prepared '.platform-bootstrap.json')
        }
        $receipt = Join-Path $TestDrive 'receipt.json'
        '{"Repository":"upstream/action","Tag":"v1","Commit":"3333333333333333333333333333333333333333","Sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Attestation":"not-present","Asset":""}' |
            Set-Content -LiteralPath $receipt
        $releaseCatalogArgs = @{
            CatalogPath = Join-Path $PSScriptRoot 'fixtures/vendoring/catalog.json'
            ActionsOrganization = 'customer-actions'
        }
        $savedToken = $env:GH_TOKEN
        $savedMap = $env:PLATFORM_GITHUB_TOKENS
        $env:GH_TOKEN = 'ghs_fixture'
        $env:PLATFORM_GITHUB_TOKENS = '{"customer-actions":"ghs_fixture"}'
        $remotePath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '.git')
        & $gitExecutable init --quiet --bare $remotePath
        & $gitExecutable -C $target push --quiet $remotePath main
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
                $state = if ($filter['state']) { $filter['state'] } else { 'open' }
                $perPage = if ($filter['per_page']) { [int] $filter['per_page'] } else { 30 }
                $page = if ($filter['page']) { [int] $filter['page'] } else { 1 }
                $matchingPulls = @($cloud.pulls | Where-Object {
                    ($state -eq 'all' -or $_.state -ceq $state) -and
                    (-not $filter['head'] -or "$($_.head.repo.full_name.Split('/')[0]):$($_.head.ref)" -ceq $filter['head']) -and
                    (-not $filter['base'] -or $_.base.ref -ceq $filter['base'])
                } | Sort-Object number -Descending | Select-Object -Skip (($page - 1) * $perPage) -First $perPage)
                $items = @(foreach ($pull in $matchingPulls) {
                    $fixture = Get-GitHubApiFixture -Name pulls/list -Set @{
                        '0.number' = $pull.number; '0.html_url' = $pull.html_url
                        '0.head.ref' = $pull.head.ref; '0.head.sha' = $pull.head.sha
                        '0.head.repo.full_name' = $pull.head.repo.full_name
                        '0.base.ref' = $pull.base.ref; '0.base.repo.full_name' = $pull.base.repo.full_name
                        '0.state' = $pull.state; '0.merged_at' = $pull.merged_at; '0.user' = $pull.user
                    }
                    $fixture[0]
                })
                if ($cloud.ContainsKey('lookupTransform')) { return & $cloud.lookupTransform $items }
                return ,$items
            }
            if ($Uri.AbsolutePath -like '*/pulls' -and $Method -eq 'POST') {
                $request = $Body | ConvertFrom-Json -AsHashtable
                if (@($cloud.pulls | Where-Object {
                    $_.head.ref -ceq $request.head -and $_.base.ref -ceq $request.base -and $_.state -ceq 'open'
                }).Count -gt 0) {
                    # The documented POST validation failure is surfaced as an HTTP error, not a success response.
                    throw 'HTTP 422: a pull request already exists for this head and base.'
                }
                $sha = & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($request.head)"
                $number = $cloud.pulls.Count + 1
                $pull = Get-GitHubApiFixture -Name pulls/create -Set @{
                    number = $number; html_url = "https://example.ghe.com/customer-actions/upstream-action/pull/$number"
                    'head.ref' = $request.head; 'head.sha' = $sha; 'head.repo.full_name' = 'customer-actions/upstream-action'
                    'base.ref' = $request.base; 'base.repo.full_name' = 'customer-actions/upstream-action'
                    state = 'open'; merged_at = $null
                    'user.type' = 'Bot'; 'user.login' = 'platform-vendoring[bot]'
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

    It 'commits the root release marker and platform together without changing instance configuration' -Tag 'DeploymentRelease' {
        Remove-Item (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'new release' | Set-Content (Join-Path $prepared 'platform/README.md')
        '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
            Set-Content (Join-Path $prepared '.platform-bootstrap.json')
        'instance configuration' | Set-Content (Join-Path $target 'instance.yaml')
        '{"instance":"demo","releaseVersion":"1.0.0","files":{}}' | Set-Content (Join-Path $target '.platform-bootstrap.json')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m initial-marker
        & $gitExecutable -C $target push --quiet $remotePath main
        $before = & $gitExecutable -C $target rev-parse HEAD

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com

        $result.HasChanges | Should -BeTrue
        @(& $gitExecutable -C $target diff --name-only $before HEAD) |
            Should -Be @('.platform-bootstrap.json', 'platform/.vendoring.json', 'platform/README.md')
        & $gitExecutable -C $target rev-list --count "$before..HEAD" | Should -Be 1
        Get-Content (Join-Path $target 'instance.yaml') | Should -Be 'instance configuration'
    }

    It 'commits the exact import-time action catalog as a version 2 release receipt' -Tag 'CatalogSnapshot' {
        Remove-Item (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'new release' | Set-Content (Join-Path $prepared 'platform/README.md')
        '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
            Set-Content (Join-Path $prepared '.platform-bootstrap.json')
        $catalogPath = Join-Path $TestDrive 'release-catalog.json'
        '{"version":2,"actions":{"actions/checkout":{"repository":"customer-actions/actions-checkout","sha":"1111111111111111111111111111111111111111","upstreamCommit":"3d3c42e5aac5ba805825da76410c181273ba90b1","tag":"v7.0.1"}}}' |
            Set-Content $catalogPath

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com `
            -CatalogPath $catalogPath -ActionsOrganization customer-actions

        $result.HasChanges | Should -BeTrue
        $saved = (& $gitExecutable -C $target show HEAD:platform/.vendoring.json | Out-String) |
            ConvertFrom-Json -AsHashtable
        $saved.version | Should -Be 2
        $saved.kind | Should -BeExactly 'release'
        $saved.catalog.version | Should -Be 2
        $saved.catalog.actions['actions/checkout'].repository | Should -BeExactly 'customer-actions/actions-checkout'
        $saved.catalog.actions['actions/checkout'].upstreamCommit |
            Should -BeExactly '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $saved.catalog.actions['actions/checkout'].sha | Should -BeExactly '1111111111111111111111111111111111111111'
    }

    It 'rejects <Case> rather than publishing a release without a valid import-time catalog' -Tag 'CatalogSnapshot' -ForEach @(
        @{ Case = 'missing catalog'; Content = $null; Error = '*Import-time catalog snapshot file is missing for release publication*' }
        @{ Case = 'malformed catalog'; Content = '{'; Error = '*Invalid import-time catalog snapshot*' }
        @{ Case = 'catalog outside the actions organization'; Content = '{"version":2,"actions":{"actions/checkout":{"repository":"other-actions/actions-checkout","sha":"1111111111111111111111111111111111111111","upstreamCommit":"3d3c42e5aac5ba805825da76410c181273ba90b1","tag":"v7.0.1"}}}'; Error = '*Invalid catalog entry*' }
        @{ Case = 'catalog with a non-SHA copy pin'; Content = '{"version":2,"actions":{"actions/checkout":{"repository":"customer-actions/actions-checkout","sha":"not-a-commit","upstreamCommit":"3d3c42e5aac5ba805825da76410c181273ba90b1","tag":"v7.0.1"}}}'; Error = '*Invalid catalog entry*' }
        @{ Case = 'catalog with a non-SHA upstream commit'; Content = '{"version":2,"actions":{"actions/checkout":{"repository":"customer-actions/actions-checkout","sha":"1111111111111111111111111111111111111111","upstreamCommit":"not-a-commit","tag":"v7.0.1"}}}'; Error = '*upstreamCommit*full lowercase commit SHA*' }
        @{ Case = 'catalog with the wrong version'; Content = '{"version":1,"actions":{"actions/checkout":{"repository":"customer-actions/actions-checkout","sha":"1111111111111111111111111111111111111111","upstreamCommit":"3d3c42e5aac5ba805825da76410c181273ba90b1","tag":"v7.0.1"}}}'; Error = '*must declare version 2*' }
    ) {
        Remove-Item (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'new release' | Set-Content (Join-Path $prepared 'platform/README.md')
        '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
            Set-Content (Join-Path $prepared '.platform-bootstrap.json')
        $catalogPath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '-release-catalog.json')
        if ($null -ne $Content) { Set-Content $catalogPath $Content }
        else { Test-Path -LiteralPath $catalogPath | Should -BeFalse }

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com `
            -CatalogPath $catalogPath -ActionsOrganization customer-actions } | Should -Throw $Error
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects catalog snapshot <Case> at the public publisher boundary' -Tag 'CatalogSnapshot' -ForEach @(
        @{ Case = 'string version'; Change = { $catalog.version = '2' }; Error = '*Action catalog must declare version 2 and an actions mapping*' }
        @{ Case = 'non-object actions'; Change = { $catalog.actions = 'invalid' }; Error = '*Action catalog must declare version 2 and an actions mapping*' }
        @{ Case = 'non-object copy'; Change = { $catalog.actions['actions/checkout'] = 'invalid' }; Error = "*Invalid catalog entry 'actions/checkout'*" }
        @{ Case = 'repository capitalization'; Change = { $catalog.actions['actions/checkout'].repository = 'CUSTOMER-ACTIONS/actions-checkout' }; Error = "*Invalid catalog entry 'actions/checkout'*" }
        @{ Case = 'SHA capitalization'; Change = { $catalog.actions['actions/checkout'].sha = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' }; Error = "*Invalid catalog entry 'actions/checkout'*" }
        @{ Case = 'invalid action key'; Change = {
            $copy = $catalog.actions['actions/checkout']
            $catalog.actions.Remove('actions/checkout')
            $copy.repository = 'customer-actions/actions?-checkout'
            $catalog.actions['actions?/checkout'] = $copy
        }; Error = "*Invalid catalog entry 'actions?/checkout'*" }
        @{ Case = 'action key capitalization'; Change = {
            $copy = $catalog.actions['actions/checkout']
            $catalog.actions.Remove('actions/checkout')
            $copy.repository = 'customer-actions/Actions-checkout'
            $catalog.actions['Actions/checkout'] = $copy
        }; Error = "*Invalid catalog entry 'Actions/checkout'*" }
    ) {
        Remove-Item (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'release content' | Set-Content (Join-Path $prepared 'platform/README.md')
        '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
            Set-Content (Join-Path $prepared '.platform-bootstrap.json')
        $catalog = Get-Content $releaseCatalogArgs.CatalogPath -Raw | ConvertFrom-Json -AsHashtable
        . $Change
        $catalogPath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '-invalid-catalog.json')
        $catalog | ConvertTo-Json -Depth 10 | Set-Content $catalogPath

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com `
            -CatalogPath $catalogPath -ActionsOrganization customer-actions } | Should -Throw $Error
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
    }

    It 'rejects array-valued catalog snapshot <Field> at the public publisher boundary' -Tag 'ScalarSnapshot' -ForEach @(
        @{ Field = 'copy SHA'; Change = {
            $catalog.actions['actions/checkout'].sha = @('1111111111111111111111111111111111111111')
        }; Error = "*Invalid catalog entry 'actions/checkout'*" }
        @{ Field = 'copy repository'; Change = {
            $catalog.actions['actions/checkout'].repository = @('customer-actions/actions-checkout')
        }; Error = "*Invalid catalog entry 'actions/checkout'*" }
        @{ Field = 'upstream commit'; Change = {
            $catalog.actions['actions/checkout'].upstreamCommit = @('3d3c42e5aac5ba805825da76410c181273ba90b1')
        }; Error = "*Catalog upstreamCommit for 'actions/checkout' must be a full lowercase commit SHA*" }
        @{ Field = 'annotated tag'; Change = {
            $catalog.actions['actions/checkout'].tag = @('v7.0.1')
        }; Error = "*Invalid catalog entry 'actions/checkout'*" }
    ) {
        Remove-Item (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'release content' | Set-Content (Join-Path $prepared 'platform/README.md')
        '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
            Set-Content (Join-Path $prepared '.platform-bootstrap.json')
        $catalog = Get-Content $releaseCatalogArgs.CatalogPath -Raw | ConvertFrom-Json -AsHashtable
        . $Change
        $catalogPath = Join-Path $TestDrive ([guid]::NewGuid().ToString() + '-scalar-catalog.json')
        $catalog | ConvertTo-Json -Depth 10 | Set-Content $catalogPath

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com `
            -CatalogPath $catalogPath -ActionsOrganization customer-actions } | Should -Throw $Error
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects array-valued source receipt <Field> before publication' -Tag 'ScalarSnapshot' -ForEach @(
        @{ Field = 'repository'; Change = { $sourceReceipt.Repository = @('upstream/action') } }
        @{ Field = 'tag'; Change = { $sourceReceipt.Tag = @('v1') } }
        @{ Field = 'commit'; Change = { $sourceReceipt.Commit = @('3333333333333333333333333333333333333333') } }
        @{ Field = 'digest'; Change = { $sourceReceipt.Sha256 = @('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa') } }
        @{ Field = 'attestation'; Change = { $sourceReceipt.Attestation = @('not-present') } }
    ) {
        $sourceReceipt = Get-Content $receipt -Raw | ConvertFrom-Json -AsHashtable
        . $Change
        $sourceReceipt | ConvertTo-Json -Depth 10 | Set-Content $receipt

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Invalid source receipt*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects malformed source receipt <Field> before publication' -Tag 'ScalarSnapshot' -ForEach @(
        @{ Field = 'root array'; Change = {
            $sourceJson = '[' + ($sourceReceipt | ConvertTo-Json -Depth 10 -Compress) + ']'
        } }
        @{ Field = 'commit pin'; Change = { $sourceReceipt.Commit = 'not-a-commit' } }
        @{ Field = 'commit capitalization'; Change = { $sourceReceipt.Commit = 'A' * 40 } }
        @{ Field = 'digest'; Change = { $sourceReceipt.Sha256 = 'not-a-digest' } }
        @{ Field = 'digest capitalization'; Change = { $sourceReceipt.Sha256 = 'A' * 64 } }
        @{ Field = 'attestation'; Change = { $sourceReceipt.Attestation = 'unknown' } }
        @{ Field = 'attestation capitalization'; Change = { $sourceReceipt.Attestation = 'VERIFIED' } }
        @{ Field = 'repository'; Change = { $sourceReceipt.Repository = 'invalid' } }
        @{ Field = 'tag'; Change = { $sourceReceipt.Tag = 'invalid tag' } }
    ) {
        $sourceReceipt = Get-Content $receipt -Raw | ConvertFrom-Json -AsHashtable
        $sourceJson = $null
        . $Change
        if ($null -eq $sourceJson) { $sourceJson = $sourceReceipt | ConvertTo-Json -Depth 10 }
        $sourceJson | Set-Content $receipt

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Invalid source receipt*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'requires an explicit catalog snapshot for every new release publication' -Tag 'CatalogSnapshot' {
        Remove-Item (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'release content' | Set-Content (Join-Path $prepared 'platform/README.md')
        '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
            Set-Content (Join-Path $prepared '.platform-bootstrap.json')
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Import-time catalog snapshot path is required for release publication*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
    }

    It 'requires the configured actions organization when publishing a release snapshot' -Tag 'CatalogSnapshot' {
        Remove-Item (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'release content' | Set-Content (Join-Path $prepared 'platform/README.md')
        '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
            Set-Content (Join-Path $prepared '.platform-bootstrap.json')
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com `
            -CatalogPath $releaseCatalogArgs.CatalogPath } |
            Should -Throw '*Import-time catalog snapshot requires an actions organization*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
    }

    It 'resumes a freshly prepared release with identical receipt bytes despite catalog key order' -Tag 'CatalogSnapshot' {
        $fixtures = Join-Path $PSScriptRoot 'fixtures/vendoring'
        $source = Join-Path $TestDrive 'snapshot-release-source'
        Copy-Item (Join-Path $fixtures 'release') $source -Recurse
        $markerPath = Join-Path $TestDrive 'snapshot-marker.json'
        '{"instance":"demo","releaseVersion":"1.0.0","files":{}}' | Set-Content $markerPath
        $catalogPath = Join-Path $TestDrive 'release-catalog.json'
        $forward = '{"version":2,"actions":{"actions/checkout":{"repository":"customer-actions/actions-checkout","upstreamCommit":"3d3c42e5aac5ba805825da76410c181273ba90b1","sha":"1111111111111111111111111111111111111111"},"example/tool":{"repository":"customer-actions/example-tool","upstreamCommit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","sha":"2222222222222222222222222222222222222222"}}}'
        $reverse = '{"actions":{"example/tool":{"sha":"2222222222222222222222222222222222222222","upstreamCommit":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","repository":"customer-actions/example-tool"},"actions/checkout":{"sha":"1111111111111111111111111111111111111111","upstreamCommit":"3d3c42e5aac5ba805825da76410c181273ba90b1","repository":"customer-actions/actions-checkout"}},"version":2}'
        $converter = Join-Path (Split-Path $PSScriptRoot -Parent) 'ConvertTo-VendoredSource.ps1'
        $pwsh = (Get-Process -Id $PID).Path
        $firstReceipt = $null
        $firstHead = $null
        foreach ($attempt in 1..2) {
            $catalogText = if ($attempt -eq 1) { $forward } else { $reverse }
            Set-Content $catalogPath $catalogText
            $regenerated = Join-Path $TestDrive "snapshot-prepared-$attempt"
            & $pwsh -NoLogo -NoProfile -File $converter -SourcePath $source -OutputPath $regenerated `
                -CatalogPath $catalogPath -ActionsOrganization customer-actions -Kind release `
                -ReleaseMarkerPath $markerPath -ReleaseVersion '1.2.3'
            $LASTEXITCODE | Should -Be 0
            if ($firstHead) { & $gitExecutable -C $target switch --quiet main }
            $result = & $publisher -PreparedPath $regenerated -TargetPath $target -ReceiptPath $receipt -Kind release `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com `
                -CatalogPath $catalogPath -ActionsOrganization customer-actions
            $result.HasChanges | Should -BeTrue
            $receiptBytes = [string]::Join("`n", @(& $gitExecutable -C $target show HEAD:platform/.vendoring.json))
            if ($null -eq $firstReceipt) {
                $firstReceipt = $receiptBytes
                $firstHead = & $gitExecutable -C $target rev-parse HEAD
            }
            else {
                $receiptBytes | Should -BeExactly $firstReceipt
                & $gitExecutable -C $target rev-parse HEAD | Should -BeExactly $firstHead
            }
        }
        $cloud.pulls.Count | Should -Be 1
    }

    It 'resumes a release after regenerating its canonical marker in fresh processes' -Tag 'DeploymentRelease', 'ReleaseMarkerResume' {
        $fixtures = Join-Path $PSScriptRoot 'fixtures/vendoring'
        $source = Join-Path $TestDrive 'regenerated-release'
        Copy-Item (Join-Path $fixtures 'release') $source -Recurse
        'uppercase path' | Set-Content (Join-Path $source 'Zebra.txt')
        'lowercase path' | Set-Content (Join-Path $source 'alpha.txt')
        $markerPath = Join-Path $TestDrive 'regeneration-marker.json'
        '{"instance":"demo","releaseVersion":"1.0.0","files":{}}' | Set-Content $markerPath
        $expectedFiles = [ordered]@{}
        foreach ($relative in @('README.md', 'Zebra.txt', 'alpha.txt', 'templates/instance/.github/workflows/deploy.yml')) {
            $expectedFiles[$relative] = (Get-FileHash (Join-Path $source $relative)).Hash.ToLowerInvariant()
        }
        $expected = ([ordered]@{
            instance = 'demo'; releaseVersion = '1.2.3'; files = $expectedFiles
        } | ConvertTo-Json -Depth 10) + "`n"
        $markers = [Collections.Generic.List[string]]::new()
        $prepare = Join-Path (Split-Path $PSScriptRoot -Parent) 'ConvertTo-VendoredSource.ps1'
        $pwsh = (Get-Process -Id $PID).Path
        $first = $null
        $firstHead = $null
        foreach ($attempt in 1..4) {
            $regenerated = Join-Path $TestDrive "regenerated-$attempt"
            & $pwsh -NoLogo -NoProfile -File $prepare -SourcePath $source -OutputPath $regenerated `
                -CatalogPath (Join-Path $fixtures 'catalog.json') -ActionsOrganization customer-actions -Kind release `
                -ReleaseMarkerPath $markerPath -ReleaseVersion '1.2.3'
            $LASTEXITCODE | Should -Be 0
            $markers.Add((Get-Content (Join-Path $regenerated '.platform-bootstrap.json') -Raw))
            if ($first) { & $gitExecutable -C $target switch --quiet main }
            $result = & $publisher -PreparedPath $regenerated -TargetPath $target -ReceiptPath $receipt -Kind release @releaseCatalogArgs `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
            if (-not $first) {
                $first = $result
                $firstHead = & $gitExecutable -C $target rev-parse HEAD
            }
            $result.PullRequest | Should -BeExactly $first.PullRequest
            & $gitExecutable -C $target rev-parse HEAD | Should -BeExactly $firstHead
        }
        $cloud.pulls.Count | Should -Be 1
        foreach ($marker in $markers) { $marker | Should -BeExactly $expected }
    }

    It 'rejects a release prepared without its root marker before publishing' -Tag 'DeploymentRelease' {
        Remove-Item (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'release' | Set-Content (Join-Path $prepared 'platform/README.md')
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*include the root release marker*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
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
        & $gitExecutable -C $target push --quiet $remotePath main
        $cloud.pulls[0].state = 'closed'
        $cloud.pulls[0].merged_at = '2026-10-22T12:00:00Z'

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier second
        $result.HasChanges | Should -BeFalse
        $result.PullRequest | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'imports a second tag into the existing action copy while preserving the first tag and governance' {
        $governance = Join-Path $target '.github'
        $null = New-Item -ItemType Directory -Path $governance
        '* @customer-actions/security' | Set-Content (Join-Path $governance 'CODEOWNERS')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m governance
        & $gitExecutable -C $target push --quiet $remotePath main
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $firstSha = & $gitExecutable -C $target rev-parse HEAD
        & $gitExecutable -C $target branch -f main $firstSha
        & $gitExecutable -C $target switch --quiet main
        & $gitExecutable -C $target tag v1 $firstSha
        & $gitExecutable -C $target push --quiet $remotePath main refs/tags/v1
        $cloud.pulls[0].state = 'closed'
        $cloud.pulls[0].merged_at = '2026-10-27T18:00:00Z'

        'second version' | Set-Content (Join-Path $prepared 'action.yml')
        $source = Get-Content $receipt -Raw | ConvertFrom-Json -AsHashtable
        $source.Tag = 'v2'
        $source.Commit = '4444444444444444444444444444444444444444'
        $source.Sha256 = 'b' * 64
        $source | ConvertTo-Json | Set-Content $receipt
        $second = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com

        $second.PullRequest | Should -BeExactly 'https://example.ghe.com/customer-actions/upstream-action/pull/2'
        $second.Branch | Should -Not -BeExactly $first.Branch
        $cloud.pulls.Count | Should -Be 2
        & $gitExecutable -C $target rev-parse HEAD^ | Should -BeExactly $firstSha
        Get-Content (Join-Path $target 'action.yml') | Should -BeExactly 'second version'
        Get-Content (Join-Path $governance 'CODEOWNERS') | Should -BeExactly '* @customer-actions/security'
        $metadata = Get-Content (Join-Path $target '.vendoring.json') -Raw | ConvertFrom-Json
        $metadata.tag | Should -BeExactly 'v2'
        $metadata.commit | Should -BeExactly $source.Commit
        & $gitExecutable --git-dir=$remotePath rev-parse refs/tags/v1 | Should -BeExactly $firstSha
        & $gitExecutable --git-dir=$remotePath show v1:action.yml | Should -BeExactly 'updated'
        & $gitExecutable --git-dir=$remotePath tag --list v2 | Should -BeNullOrEmpty

        & $gitExecutable -C $target switch --quiet main
        $resumed = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $resumed.PullRequest | Should -BeExactly $second.PullRequest
        $cloud.pulls.Count | Should -Be 2
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
        @(& $gitExecutable --git-dir=$remotePath for-each-ref refs/heads/vendor).Count | Should -Be 1
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
        & $gitExecutable -C $target push --quiet $remotePath main

        $second = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com

        $second.PullRequest | Should -BeExactly $first.PullRequest
        $cloud.pulls.Count | Should -Be 1
    }

    It 'refuses a retargeted <ImportKind> PR after losing the create response without a second POST' -ForEach @(
        @{ ImportKind = 'action' }
        @{ ImportKind = 'release' }
    ) {
        if ($ImportKind -ceq 'release') {
            $platform = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
            Move-Item -LiteralPath (Join-Path $prepared 'action.yml') -Destination (Join-Path $platform.FullName 'README.md')
        }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            $response = & $cloudTransport -Uri $Uri -Method $Method -Body $Body
            if ($Method -eq 'POST') { throw 'Injected lost PR create response.' }
            return ,$response
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Injected lost PR create response*'
        $cloud.pulls.Count | Should -Be 1
        $branch = $cloud.pulls[0].head.ref
        $sha = & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$branch"
        & $gitExecutable -C $target switch --quiet main
        & $gitExecutable --git-dir=$remotePath update-ref refs/heads/other main
        $cloud.pulls[0].base.ref = 'other'

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*base is not main*'

        $cloud.pulls.Count | Should -Be 1
        & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$branch" | Should -BeExactly $sha
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects ambiguous PR history across bases and states before writing' {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $historical = Get-GitHubApiFixture -Name pulls/create -Set @{
            number = 2; html_url = 'https://example.ghe.com/customer-actions/upstream-action/pull/2'
            'head.ref' = $first.Branch; 'head.sha' = $cloud.pulls[0].head.sha
            'head.repo.full_name' = 'customer-actions/upstream-action'
            'base.ref' = 'other'; 'base.repo.full_name' = 'customer-actions/upstream-action'
            state = 'closed'; merged_at = $null
        }
        $cloud.pulls.Add($historical)
        & $gitExecutable -C $target switch --quiet main

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*array with at most one import PR*'

        $cloud.pulls.Count | Should -Be 2
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'does not overwrite an orphaned <ImportKind> branch or duplicate a human PR opened after lookup' -ForEach @(
        @{ ImportKind = 'action' }
        @{ ImportKind = 'release' }
    ) {
        if ($ImportKind -ceq 'release') {
            $platform = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
            Move-Item -LiteralPath (Join-Path $prepared 'action.yml') -Destination (Join-Path $platform.FullName 'README.md')
        }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            if ($Method -eq 'POST') { throw 'Injected PR creation interruption.' }
            & $cloudTransport -Uri $Uri -Method $Method -Body $Body
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Injected PR creation interruption*'
        $refs = @(& $gitExecutable --git-dir=$remotePath for-each-ref '--format=%(refname)' refs/heads/vendor)
        $refs.Count | Should -Be 1
        $branch = $refs[0] -replace '^refs/heads/', ''
        $sha = & $gitExecutable --git-dir=$remotePath rev-parse $refs[0]
        & $gitExecutable -C $target switch --quiet main
        $cloud.lookupTransform = {
            param($items)
            $items.Count | Should -Be 0
            $cloud.Remove('lookupTransform')
            $human = Get-GitHubApiFixture -Name pulls/create -Set @{
                number = 1; html_url = 'https://example.ghe.com/customer-actions/upstream-action/pull/1'
                'head.ref' = $branch; 'head.sha' = $sha; 'head.repo.full_name' = 'customer-actions/upstream-action'
                'base.ref' = 'main'; 'base.repo.full_name' = 'customer-actions/upstream-action'
                state = 'open'; merged_at = $null
            }
            $human.user.type | Should -BeExactly 'User'
            $cloud.pulls.Add($human)
            return ,$items
        }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            & $cloudTransport -Uri $Uri -Method $Method -Body $Body
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*HTTP 422*'
        & $gitExecutable -C $target switch --quiet main
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*author type is not Bot*'

        $cloud.pulls.Count | Should -Be 1
        @(& $gitExecutable --git-dir=$remotePath for-each-ref refs/heads/vendor).Count | Should -Be 1
        & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$branch" | Should -BeExactly $sha
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'resumes an orphaned <ImportKind> import with main changes <Change>' -ForEach @(
        @{ ImportKind = 'action'; Change = 'inside (added file)'; Inside = $true; Mode = $false }
        @{ ImportKind = 'release'; Change = 'inside (added file)'; Inside = $true; Mode = $false }
        @{ ImportKind = 'release'; Change = 'inside (root marker)'; Inside = $true; Mode = $false }
        @{ ImportKind = 'action'; Change = 'inside (executable bit)'; Inside = $true; Mode = $true }
        @{ ImportKind = 'release'; Change = 'inside (executable bit)'; Inside = $true; Mode = $true }
        @{ ImportKind = 'action'; Change = 'outside'; Inside = $false; Mode = $false }
        @{ ImportKind = 'release'; Change = 'outside'; Inside = $false; Mode = $false }
        @{ ImportKind = 'action'; Change = 'remote inside (added file)'; Inside = $true; Mode = $false }
        @{ ImportKind = 'release'; Change = 'remote inside (added file)'; Inside = $true; Mode = $false }
        @{ ImportKind = 'action'; Change = 'remote inside (executable bit)'; Inside = $true; Mode = $true }
        @{ ImportKind = 'release'; Change = 'remote inside (executable bit)'; Inside = $true; Mode = $true }
        @{ ImportKind = 'action'; Change = 'remote outside'; Inside = $false; Mode = $false }
        @{ ImportKind = 'release'; Change = 'remote outside'; Inside = $false; Mode = $false }
    ) {
        $remoteOnlyChange = $Change.StartsWith('remote ')
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
        & $gitExecutable -C $target push --quiet $remotePath main
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            if ($Method -eq 'POST') { throw 'Injected PR creation interruption.' }
            & $cloudTransport -Uri $Uri -Method $Method -Body $Body
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Injected PR creation interruption*'
        $refs = @(& $gitExecutable --git-dir=$remotePath for-each-ref '--format=%(refname)' refs/heads/vendor)
        $refs.Count | Should -Be 1
        $remoteSha = & $gitExecutable --git-dir=$remotePath rev-parse $refs[0]
        & $gitExecutable -C $target switch --quiet main
        $checkoutSha = & $gitExecutable -C $target rev-parse main
        $mainWriter = $target
        if ($remoteOnlyChange) {
            $mainWriter = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            & $gitExecutable clone --quiet --branch main $remotePath $mainWriter
            & $gitExecutable -C $mainWriter config user.name fixture
            & $gitExecutable -C $mainWriter config user.email fixture@example.test
        }
        if ($Mode) {
            if (-not $IsWindows) { [IO.File]::SetUnixFileMode((Join-Path $mainWriter $modePath), [IO.UnixFileMode]493) }
            & $gitExecutable -C $mainWriter update-index --chmod=+x -- $modePath
        }
        else {
            $changedPath = if ($Inside) {
                if ($Change -ceq 'inside (root marker)') { '.platform-bootstrap.json' }
                elseif ($ImportKind -ceq 'release') { 'platform/extra.yml' } else { 'extra.js' }
            }
            else {
                if ($ImportKind -ceq 'release') { 'instance.yaml' } else { '.github/CODEOWNERS' }
            }
            $destination = Join-Path $mainWriter $changedPath
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            'main advanced' | Set-Content -LiteralPath $destination
            & $gitExecutable -C $mainWriter add .
        }
        & $gitExecutable -C $mainWriter commit --quiet -m main-advance
        & $gitExecutable -C $mainWriter push --quiet $remotePath main
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            & $cloudTransport -Uri $Uri -Method $Method -Body $Body
        }

        if ($Inside) {
            { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
                Should -Throw '*main changed inside the vendoring boundary*delete the orphaned import branch*run the import again*'
            $cloud.pulls.Count | Should -Be 0
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }
        else {
            $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
            $result.Branch | Should -BeExactly $refs[0].Substring('refs/heads/'.Length)
            $result.PullRequest | Should -BeExactly 'https://example.ghe.com/customer-actions/upstream-action/pull/1'
            $cloud.pulls.Count | Should -Be 1
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }
        & $gitExecutable --git-dir=$remotePath rev-parse $refs[0] | Should -BeExactly $remoteSha
        @(& $gitExecutable --git-dir=$remotePath for-each-ref refs/heads/vendor).Count | Should -Be 1
        if ($remoteOnlyChange) { & $gitExecutable -C $target rev-parse main | Should -BeExactly $checkoutSha }
    }

    It 'rejects an invalid target main ref: <Case>' -ForEach @(
        @{ Case = 'missing'; Response = { return @() } }
        @{ Case = 'multiple'; Response = { @($mainLine, $mainLine) } }
        @{ Case = 'invalid SHA'; Response = { $mainLine -replace '^[a-f0-9]{40}', ('z' * 40) } }
        @{ Case = 'SHA case'; Response = { $mainLine.Substring(0, 40).ToUpperInvariant() + $mainLine.Substring(40) } }
        @{ Case = 'other ref'; Response = { $mainLine.Replace('refs/heads/main', 'refs/heads/other') } }
        @{ Case = 'ref case'; Response = { $mainLine.Replace('refs/heads/main', 'refs/heads/MAIN') } }
    ) {
        $mainLine = (& $gitExecutable -C $target rev-parse main) + "`trefs/heads/main"
        # Deliberately malformed git responses isolate the target-main guard.
        Mock git {
            if ($Arguments -contains 'ls-remote' -and $Arguments[-1] -ceq 'refs/heads/main') { return & $Response }
            & $gitTransport -Arguments $Arguments
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Cannot resolve target main to one commit*'
        $cloud.pulls.Count | Should -Be 0
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
    }

    It 'bases a new <ImportKind> import on remote main without changing local main' -ForEach @(
        @{ ImportKind = 'action'; Outside = '.github/CODEOWNERS' }
        @{ ImportKind = 'release'; Outside = 'instance.yaml' }
    ) {
        if ($ImportKind -ceq 'release') {
            Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
            $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
            'release content' | Set-Content (Join-Path $prepared 'platform/README.md')
        }
        $checkoutSha = & $gitExecutable -C $target rev-parse main
        $writer = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        & $gitExecutable clone --quiet --branch main $remotePath $writer
        & $gitExecutable -C $writer config user.name fixture
        & $gitExecutable -C $writer config user.email fixture@example.test
        $destination = Join-Path $writer $Outside
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        'latest configuration' | Set-Content $destination
        & $gitExecutable -C $writer add .
        & $gitExecutable -C $writer commit --quiet -m remote-configuration
        & $gitExecutable -C $writer push --quiet $remotePath main
        $remoteMain = & $gitExecutable --git-dir=$remotePath rev-parse refs/heads/main

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com

        & $gitExecutable --git-dir=$remotePath rev-parse "$($result.Branch)^" | Should -BeExactly $remoteMain
        & $gitExecutable -C $target rev-parse main | Should -BeExactly $checkoutSha
        Get-Content (Join-Path $target $Outside) -Raw | Should -Match 'latest configuration'
        $cloud.pulls.Count | Should -Be 1
    }

    It 'rejects remote main moving during <ImportKind> publication after <Step> with orphan <Orphan>' -ForEach @(
        @{ ImportKind = 'action'; Step = 'PR lookup'; Orphan = $false }
        @{ ImportKind = 'release'; Step = 'PR lookup'; Orphan = $false }
        @{ ImportKind = 'action'; Step = 'import head check'; Orphan = $false }
        @{ ImportKind = 'release'; Step = 'import head check'; Orphan = $false }
        @{ ImportKind = 'action'; Step = 'PR lookup'; Orphan = $true }
        @{ ImportKind = 'release'; Step = 'PR lookup'; Orphan = $true }
        @{ ImportKind = 'action'; Step = 'import head check'; Orphan = $true }
        @{ ImportKind = 'release'; Step = 'import head check'; Orphan = $true }
    ) {
        if ($ImportKind -ceq 'release') {
            Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
            $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
            'release content' | Set-Content (Join-Path $prepared 'platform/README.md')
        }
        if ($Orphan) {
            Mock Invoke-RestMethod {
                param([uri] $Uri, [string] $Method = 'GET', $Body)
                if ($Method -eq 'POST') { throw 'Injected PR creation interruption.' }
                & $cloudTransport -Uri $Uri -Method $Method -Body $Body
            }
            { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
                Should -Throw '*Injected PR creation interruption*'
            & $gitExecutable -C $target switch --quiet main
        }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            & $cloudTransport -Uri $Uri -Method $Method -Body $Body
        }
        $checkoutSha = & $gitExecutable -C $target rev-parse main
        $writer = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        & $gitExecutable clone --quiet --branch main $remotePath $writer
        & $gitExecutable -C $writer config user.name fixture
        & $gitExecutable -C $writer config user.email fixture@example.test
        & $gitExecutable -C $writer commit --quiet --allow-empty -m remote-main-advance
        $advanceMain = { & $gitExecutable -C $writer push --quiet $remotePath main }
        if ($Step -ceq 'PR lookup') {
            $cloud.lookupTransform = { param($items) & $advanceMain; return ,$items }
        }
        else {
            $cloud.branchReads = 0
            Mock git {
                $result = & $gitTransport -Arguments $Arguments
                if ($Arguments -contains 'ls-remote' -and $Arguments[-1] -clike 'refs/heads/vendor/*') {
                    $cloud.branchReads++
                    if ($cloud.branchReads -eq 2) { & $advanceMain }
                }
                return $result
            }
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Target main changed during vendoring*retry*'
        $cloud.pulls.Count | Should -Be 0
        & $gitExecutable -C $target rev-parse main | Should -BeExactly $checkoutSha
        @(& $gitExecutable --git-dir=$remotePath for-each-ref refs/heads/vendor).Count | Should -Be 1
        $posts = if ($Orphan) { 1 } else { 0 }
        Should -Invoke Invoke-RestMethod -Times $posts -Exactly -ParameterFilter { $Method -eq 'POST' }
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

    It 'rejects an invalid App PR author: <Case>' -ForEach @(
        @{ Case = 'missing author'; Change = { param($pull) $pull.Remove('user') }; Message = '*author must be an object*' }
        @{ Case = 'null author'; Change = { param($pull) $pull.user = $null }; Message = '*author must be an object*' }
        @{ Case = 'unreadable author'; Change = { param($pull) $pull.user = 'unknown' }; Message = '*author must be an object*' }
        @{ Case = 'human type'; Change = { param($pull) $pull.user.type = 'User' }; Message = '*author type is not Bot*' }
        @{ Case = 'type case'; Change = { param($pull) $pull.user.type = 'bot' }; Message = '*author type is not Bot*' }
        @{ Case = 'missing type'; Change = { param($pull) $pull.user.Remove('type') }; Message = '*author type is not Bot*' }
        @{ Case = 'null type'; Change = { param($pull) $pull.user.type = $null }; Message = '*author type is not Bot*' }
        @{ Case = 'empty type'; Change = { param($pull) $pull.user.type = '' }; Message = '*author type is not Bot*' }
        @{ Case = 'non-string type'; Change = { param($pull) $pull.user.type = @('Bot') }; Message = '*author type is not Bot*' }
        @{ Case = 'human login'; Change = { param($pull) $pull.user.login = 'maintainer' }; Message = '*author login is not an App bot*' }
        @{ Case = 'login suffix case'; Change = { param($pull) $pull.user.login = 'platform-vendoring[BOT]' }; Message = '*author login is not an App bot*' }
        @{ Case = 'missing login'; Change = { param($pull) $pull.user.Remove('login') }; Message = '*author login is not an App bot*' }
        @{ Case = 'null login'; Change = { param($pull) $pull.user.login = $null }; Message = '*author login is not an App bot*' }
        @{ Case = 'empty login'; Change = { param($pull) $pull.user.login = '' }; Message = '*author login is not an App bot*' }
        @{ Case = 'non-string login'; Change = { param($pull) $pull.user.login = @('platform-vendoring[bot]') }; Message = '*author login is not an App bot*' }
        @{ Case = 'login without App name'; Change = { param($pull) $pull.user.login = '[bot]' }; Message = '*author login is not an App bot*' }
        @{ Case = 'login whitespace'; Change = { param($pull) $pull.user.login = ' [bot]' }; Message = '*author login is not an App bot*' }
        @{ Case = 'login trailing newline'; Change = { param($pull) $pull.user.login = "platform-vendoring[bot]`n" }; Message = '*author login is not an App bot*' }
    ) {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        $sha = & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($first.Branch)"
        # Includes documented human/null authors and deliberately malformed individual author fields.
        $cloud.lookupTransform = {
            param($items)
            $null = & $Change $items[0]
            return ,$items
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } | Should -Throw $Message

        & $gitExecutable --git-dir=$remotePath rev-parse "refs/heads/$($first.Branch)" | Should -BeExactly $sha
        $cloud.pulls.Count | Should -Be 1
        Should -Invoke git -Times 1 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
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
        & $gitExecutable -C $target push --quiet $remotePath main

        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*main no longer contains*'
        $cloud.pulls.Count | Should -Be 1
    }

    It 'checks a merged import after changes outside and inside the <ImportKind> boundary' -Tag 'MergedBoundary' -ForEach @(
        @{ ImportKind = 'action'; Owned = 'action.yml'; Outside = '.github/CODEOWNERS' }
        @{ ImportKind = 'release'; Owned = 'platform/README.md'; Outside = 'instance.yaml' }
        @{ ImportKind = 'release'; Owned = '.platform-bootstrap.json'; Outside = 'instance.yaml' }
    ) {
        if ($ImportKind -ceq 'release') {
            Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
            $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
            'release' | Set-Content (Join-Path $prepared 'platform/README.md')
        }
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target branch -f main HEAD
        & $gitExecutable -C $target switch --quiet main
        $cloud.pulls[0].state = 'closed'
        $cloud.pulls[0].merged_at = '2026-10-22T12:00:00Z'
        $null = New-Item -ItemType Directory -Path (Split-Path (Join-Path $target $Outside) -Parent) -Force
        'outside import' | Set-Content (Join-Path $target $Outside)
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m outside-boundary
        & $gitExecutable -C $target push --quiet $remotePath main

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        $result.HasChanges | Should -BeFalse
        $result.PullRequest | Should -BeNullOrEmpty

        & $gitExecutable -C $target switch --quiet main
        'inside import changed' | Set-Content (Join-Path $target $Owned)
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m inside-boundary
        & $gitExecutable -C $target push --quiet $remotePath main
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*main no longer contains*'
    }

    It 'rejects remote main moving before confirming a merged <ImportKind> import' -ForEach @(
        @{ ImportKind = 'action' }
        @{ ImportKind = 'release' }
    ) {
        if ($ImportKind -ceq 'release') {
            Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
            $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
            'release content' | Set-Content (Join-Path $prepared 'platform/README.md')
        }
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target branch -f main HEAD
        & $gitExecutable -C $target switch --quiet main
        & $gitExecutable -C $target push --quiet $remotePath main
        $cloud.pulls[0].state = 'closed'
        $cloud.pulls[0].merged_at = '2026-10-22T12:00:00Z'
        $writer = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        & $gitExecutable clone --quiet --branch main $remotePath $writer
        & $gitExecutable -C $writer config user.name fixture
        & $gitExecutable -C $writer config user.email fixture@example.test
        & $gitExecutable -C $writer commit --quiet --allow-empty -m remote-main-advance
        Mock git {
            $result = & $gitTransport -Arguments $Arguments
            if ($Arguments -contains 'diff' -and $Arguments -contains '--name-only') {
                & $gitExecutable -C $writer push --quiet $remotePath main
            }
            return $result
        }
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind @releaseCatalogArgs `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*Target main changed during vendoring*retry*'
        $cloud.pulls.Count | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'accepts documented nullable PR head users and case-insensitive repository names on resume' {
        $first = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        & $gitExecutable -C $target switch --quiet main
        $cloud.lookupTransform = {
            param($items)
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
        @(& $gitExecutable --git-dir=$remotePath for-each-ref refs/heads/vendor).Count | Should -Be 0
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
            if ($Arguments -contains $Operation -and
                ($Operation -cne 'ls-remote' -or $Arguments[-1] -clike 'refs/heads/vendor/*')) { return & $Response }
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
            if ($Arguments -contains 'ls-remote' -and $Arguments[-1] -clike 'refs/heads/vendor/*') {
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
        & $gitExecutable -C $target push --quiet $remotePath main
        Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'new release' | Set-Content -LiteralPath (Join-Path $prepared 'platform/README.md')
        '{"instance":"demo","releaseVersion":"1.2.3","files":{"README.md":"approved"}}' |
            Set-Content -LiteralPath (Join-Path $prepared '.platform-bootstrap.json')

        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release @releaseCatalogArgs `
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
