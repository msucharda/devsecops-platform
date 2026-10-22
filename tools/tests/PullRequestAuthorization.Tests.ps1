BeforeAll {
    $authorize = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-DeploymentAuthorization.ps1'
}

Describe 'Deployment authorization' {
    BeforeEach {
        $savedTokens = $env:PLATFORM_GITHUB_TOKENS
        $env:PLATFORM_GITHUB_TOKENS = '{"platform":"fake-membership-token"}'
    }

    AfterEach {
        $env:PLATFORM_GITHUB_TOKENS = $savedTokens
    }

    It 'denies a fork without contacting the membership API or receiving module credentials' {
        $payload = @{
            pull_request = @{
                head = @{ sha = ('a' * 40); repo = @{ id = 2; full_name = 'outsider/instance' } }
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
                head = @{ sha = ('a' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
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

    It 'denies a platform-team PR from a vendoring import branch without contacting the membership API: <Branch>' -ForEach @(
        @{ Branch = 'vendor/release/platform-org-devsecops-platform-v1.2.0-0123456789abcdef' }
        @{ Branch = 'Vendor/action/upstream-action-v1-0123456789abcdef' }
    ) {
        $payload = @{
            pull_request = @{
                head = @{ ref = $Branch; sha = ('a' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
                base = @{ ref = 'main'; repo = @{ id = 1; full_name = 'platform/instance' } }
                user = @{ login = 'member'; type = 'User' }
            }
        }
        $path = Join-Path $TestDrive 'vendoring.json'
        ConvertTo-Json $payload -Depth 20 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod { throw 'A vendoring import branch must never reach membership lookup.' }

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance `
            -Ref refs/heads/main -Team platform-team -ApiUrl https://api.example.test

        $result.Allowed | Should -BeFalse
        $result.Reason | Should -Match 'vendoring import branch'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'still grants an active platform-team author on an ordinary branch: <Branch>' -ForEach @(
        @{ Branch = 'feature/vendor/update' }
        @{ Branch = 'vendoring-docs' }
    ) {
        $payload = @{
            pull_request = @{
                head = @{ ref = $Branch; sha = ('b' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
                base = @{ ref = 'main'; repo = @{ id = 1; full_name = 'platform/instance' } }
                user = @{ login = 'member'; type = 'User' }
            }
        }
        $path = Join-Path $TestDrive 'ordinary.json'
        ConvertTo-Json $payload -Depth 20 | Set-Content -LiteralPath $path
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -eq 'https://api.example.test/orgs/platform/teams/platform-team') { return [pscustomobject]@{ slug = 'platform-team' } }
            [pscustomobject]@{ state = 'active' }
        }

        $result = & $authorize -EventPath $path -EventName pull_request_target -Repository platform/instance `
            -Ref refs/heads/main -Team platform-team -ApiUrl https://api.example.test

        $result.Allowed | Should -BeTrue
    }

    It 'grants credentials only for active platform-team authors: <State>' -ForEach @(
        @{ State = 'active'; Allowed = $true }
        @{ State = 'pending'; Allowed = $false }
    ) {
        $payload = @{
            pull_request = @{
                head = @{ sha = ('b' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
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
                head = @{ sha = ('d' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
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
                head = @{ sha = ('a' * 40); repo = @{ id = 1; full_name = 'platform/instance' } }
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
