BeforeAll {
    $authorize = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-DeploymentAuthorization.ps1'
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
}

Describe 'Deployment authorization' {
    BeforeEach {
        $savedTokens = $env:PLATFORM_GITHUB_TOKENS
        $env:PLATFORM_GITHUB_TOKENS = '{"platform":"fake-membership-token"}'
        $pullRequest = Get-GitHubApiFixture -Name 'pulls/create' -Set @{
            'head.ref' = 'feature/update'
            'head.sha' = ('b' * 40)
            'head.repo.id' = 1
            'head.repo.full_name' = 'platform/instance'
            'base.ref' = 'main'
            'base.repo.id' = 1
            'base.repo.full_name' = 'platform/instance'
            'user.login' = 'member'
            'user.type' = 'User'
            'draft' = $false
        }
        $teamResponse = Get-GitHubApiFixture -Name 'teams/get-by-name' -Set @{ slug = 'platform-team' }
        $membershipResponse = Get-GitHubApiFixture -Name 'teams/get-membership-for-user-in-org'
    }

    AfterEach {
        $env:PLATFORM_GITHUB_TOKENS = $savedTokens
    }

    It 'denies a platform-team author on a vendoring branch: <Branch>, preflight <Preflight>' -ForEach @(
        foreach ($branch in @('vendor/release/0123456789abcdef', 'Vendor/action/update', 'VENDOR/update', 'vEnDoR/nested/update')) {
            @{ Branch = $branch; Preflight = $false }
            @{ Branch = $branch; Preflight = $true }
        }
    ) {
        $pullRequest.head.ref = $Branch
        $path = Join-Path $TestDrive 'vendor.json'
        @{ pull_request = $pullRequest } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -eq 'https://api.example.test/orgs/platform/teams/platform-team') { return [pscustomobject] $teamResponse }
            [pscustomobject] $membershipResponse
        }
        $output = Join-Path $TestDrive 'vendor-output'
        [IO.File]::WriteAllText($output, '')

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance `
            -Ref refs/heads/main -Team platform-team -ApiUrl https://api.example.test -GitHubOutputPath $output -Preflight:$Preflight

        $result.Allowed | Should -BeFalse
        $result.Eligible | Should -BeFalse
        $result.Revision | Should -Be ('b' * 40)
        $result.Reason | Should -Match 'vendoring import branch; cloud plan NOT PERFORMED'
        [IO.File]::ReadAllText($output) | Should -Be "allowed=false`neligible=false`nrevision=$('b' * 40)`n"
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'grants an active platform-team author on an ordinary branch: <Branch>' -ForEach @(
        @{ Branch = 'feature/update' }
        @{ Branch = 'feature/vendor-x' }
        @{ Branch = 'feature/vendor/update' }
        @{ Branch = 'vendoring-docs' }
        @{ Branch = 'vendor-update' }
        @{ Branch = 'vendor' }
        @{ Branch = 'vendors/update' }
    ) {
        $pullRequest.head.ref = $Branch
        $path = Join-Path $TestDrive 'ordinary.json'
        @{ pull_request = $pullRequest } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -eq 'https://api.example.test/orgs/platform/teams/platform-team') { return [pscustomobject] $teamResponse }
            [pscustomobject] $membershipResponse
        }

        $preflightResult = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance -Preflight
        $preflightResult.Allowed | Should -BeFalse
        $preflightResult.Eligible | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance `
            -Ref refs/heads/main -Team platform-team -ApiUrl https://api.example.test

        $result.Allowed | Should -BeTrue
        $result.Eligible | Should -BeTrue
        $result.Reason | Should -Be 'Active platform-team author in the instance repository.'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/teams/platform-team/memberships/member'
        }
    }

    It 'denies an unreadable head branch before membership lookup: <Case>' -ForEach @(
        @{ Case = 'missing'; Value = $null }
        @{ Case = 'null'; Value = $null }
        @{ Case = 'empty'; Value = '' }
        @{ Case = 'whitespace'; Value = ' ' }
        @{ Case = 'object'; Value = @{ name = 'feature/update' } }
        @{ Case = 'array'; Value = @('feature/update') }
    ) {
        # Intentionally invalid input: change only the documented head.ref field.
        if ($Case -eq 'missing') { $pullRequest.head.Remove('ref') }
        else { $pullRequest.head.ref = $Value }
        $path = Join-Path $TestDrive 'unreadable.json'
        @{ pull_request = $pullRequest } | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -eq 'https://api.example.test/orgs/platform/teams/platform-team') { return [pscustomobject] $teamResponse }
            [pscustomobject] $membershipResponse
        }

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance `
            -Ref refs/heads/main -Team platform-team -ApiUrl https://api.example.test

        $result.Allowed | Should -BeFalse
        $result.Eligible | Should -BeFalse
        $result.Reason | Should -Match 'head branch is missing or unreadable; cloud plan NOT PERFORMED'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'denies a fork without contacting the membership API or receiving module credentials' {
        $payload = @{
            pull_request = @{
                head = @{ ref = 'feature/update'; sha = ('a' * 40); repo = @{ id = 2; full_name = 'outsider/instance' } }
                base = @{ ref = 'main'; repo = @{ id = 1; full_name = 'platform/instance' } }
                user = @{ login = 'member'; type = 'User' }
            }
        }
        $path = Join-Path $TestDrive 'fork.json'
        ConvertTo-Json $payload -Depth 20 | Set-Content -LiteralPath $path

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance -Ref refs/heads/main

        $result.Allowed | Should -BeFalse
        $result.Reason | Should -Match 'fork'
    }

    It 'denies App-created PRs even with a human-looking author: <Kind>' -ForEach @(
        @{ Kind = 'bot author'; Type = 'Bot'; ViaApp = $null }
        @{ Kind = 'App attribution'; Type = 'User'; ViaApp = @{ id = 101 } }
    ) {
        $payload = @{
            pull_request = @{
                head = @{ ref = 'feature/update'; sha = ('a' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
                base = @{ ref = 'main'; repo = @{ id = 1; full_name = 'platform/instance' } }
                user = @{ login = 'importer'; type = $Type }
                performed_via_github_app = $ViaApp
            }
        }
        $path = Join-Path $TestDrive 'app.json'
        ConvertTo-Json $payload -Depth 20 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod { throw 'App-created PR must never reach membership lookup.' }

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance -Ref refs/heads/main

        $result.Allowed | Should -BeFalse
        $result.Reason | Should -Match 'App'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'grants credentials only for active platform-team authors: <State>' -ForEach @(
        @{ State = 'active'; Allowed = $true }
        @{ State = 'pending'; Allowed = $false }
    ) {
        $payload = @{
            pull_request = @{
                head = @{ ref = 'feature/update'; sha = ('b' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
                base = @{ ref = 'main'; repo = @{ id = 1; full_name = 'platform/instance' } }
                user = @{ login = 'member'; type = 'User' }
            }
        }
        $path = Join-Path $TestDrive 'membership.json'
        ConvertTo-Json $payload -Depth 20 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -eq 'https://api.example.test/orgs/platform/teams/platform-team') { return [pscustomobject]@{ slug = 'platform-team' } }
            [pscustomobject]@{ state = $State }
        }
        $output = Join-Path $TestDrive 'authorization-output'

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance `
            -Ref refs/heads/main -Team platform-team -ApiUrl https://api.example.test -GitHubOutputPath $output

        $result.Allowed | Should -Be $Allowed
        $result.Revision | Should -Be ('b' * 40)
        [IO.File]::ReadAllText($output) | Should -Match "allowed=$($Allowed.ToString().ToLowerInvariant())"
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/teams/platform-team/memberships/member'
        }
    }

    It 'denies an unrelated author after establishing that the protected team API is available' {
        $payload = @{
            pull_request = @{
                head = @{ ref = 'feature/update'; sha = ('d' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
                base = @{ ref = 'main'; repo = @{ id = 1; full_name = 'platform/instance' } }
                user = @{ login = 'outsider'; type = 'User' }
            }
        }
        $path = Join-Path $TestDrive 'outsider.json'
        ConvertTo-Json $payload -Depth 20 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -eq 'https://api.example.test/orgs/platform/teams/platform-team') { return [pscustomobject]@{ slug = 'platform-team' } }
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found',
                [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound))
        }

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance `
            -Ref refs/heads/main -Team platform-team -ApiUrl https://api.example.test

        $result.Allowed | Should -BeFalse
        $result.Reason | Should -Match 'not a platform-team member'
    }

    It 'never treats unavailable authorization API as successful membership' {
        $payload = @{
            pull_request = @{
                head = @{ ref = 'feature/update'; sha = ('a' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
                base = @{ ref = 'main'; repo = @{ id = 1; full_name = 'platform/instance' } }
                user = @{ login = 'member'; type = 'User' }
            }
        }
        $path = Join-Path $TestDrive 'unavailable.json'
        ConvertTo-Json $payload -Depth 20 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod { throw 'API unavailable' }

        { & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance `
                -Ref refs/heads/main -Team platform-team -ApiUrl https://api.example.test } |
            Should -Throw '*authorization API failed*API unavailable*'
    }

    It 'rejects manually dispatched deployments outside protected main' {
        $path = Join-Path $TestDrive 'dispatch.json'
        '{}' | Set-Content -LiteralPath $path

        { & $authorize -EventPath $path -EventName workflow_dispatch -Repository platform/instance `
                -Ref refs/heads/feature -Sha ('c' * 40) } | Should -Throw '*protected main*'
    }

    It 'authorizes immutable main for reviewed imports and nightly plans: <Event>' -ForEach @(
        @{ Event = 'push' }
        @{ Event = 'schedule' }
    ) {
        $path = Join-Path $TestDrive 'merge.json'
        '{}' | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod { throw 'Main must not require PR membership lookup.' }

        $result = & $authorize -EventPath $path -EventName $Event -Repository platform/instance `
            -Ref refs/heads/main -Sha ('c' * 40)

        $result.Allowed | Should -BeTrue
        $result.Revision | Should -Be ('c' * 40)
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}
