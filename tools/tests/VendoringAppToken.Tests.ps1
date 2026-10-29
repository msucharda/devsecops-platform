BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $issuer = Join-Path (Split-Path $PSScriptRoot -Parent) 'New-PlatformGitHubToken.ps1'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()
}

Describe 'Vendoring App installation scope' {
    BeforeEach {
        $PSDefaultParameterValues = @{} + $PSDefaultParameterValues
        $PSDefaultParameterValues['New-PlatformGitHubToken.ps1:IssuanceStatePath'] = Join-Path $TestDrive "issuance-$([guid]::NewGuid())/pending.json"
        $savedEnvironment = @{}
        foreach ($name in @('PLATFORM_APP_ID', 'PLATFORM_APP_INSTALLATION_ID', 'PLATFORM_APP_ENTERPRISE', 'PLATFORM_APP_PRIVATE_KEY')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:PLATFORM_APP_ID = '101'
        $env:PLATFORM_APP_INSTALLATION_ID = '201'
        $env:PLATFORM_APP_ENTERPRISE = 'example'
        $env:PLATFORM_APP_PRIVATE_KEY = $privateKey
        $environmentPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $actualPermissions = @{ contents = 'write'; pull_requests = 'write'; metadata = 'read' }
        $fakeRepositoryNames = @('instance')
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Uri -eq 'https://api.example.test/app') {
                return Get-GitHubApiFixture -Name apps/get-app.owner-simple-user -Set @{
                    id = 101; 'owner.login' = 'example'; 'owner.type' = 'enterprise'; permissions = $actualPermissions
                }
            }
            if ($Uri -like '*/app/installations`?*') {
                return Get-GitHubApiFixture -Name apps/list-installations -Set @{
                    '0.id' = 201; '0.account.login' = 'platform'; '0.account.type' = 'Organization'; '0.target_type' = 'Organization'
                    '0.permissions' = $actualPermissions; '0.repository_selection' = 'selected'; '0.suspended_at' = $null
                }
            }
            if ($Uri -like '*/access_tokens') {
                return Get-GitHubApiFixture -Name apps/create-installation-access-token -Set @{ token = 'fake-installation-token'; permissions = $actualPermissions }
            }
            if ($Uri -like '*/installation/repositories`?*') {
                $repositories = @($fakeRepositoryNames | ForEach-Object {
                    (Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{ 'repositories.0.name' = $_ }).repositories[0]
                })
                return Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{ total_count = $repositories.Count; repositories = $repositories }
            }
            if ($Uri -like '*/installation/token' -and $Method -eq 'DELETE') { return }
            throw "Unexpected GitHub request: $Method $Uri"
        }
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    }

    It 'issues a repository-restricted writer with only Contents and Pull requests' {
        & $issuer -VendoringRepository platform/instance -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null
        Get-Content -LiteralPath $environmentPath -Raw | Should -Match 'GH_TOKEN=fake-installation-token'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and
            ($Body | ConvertFrom-Json -AsHashtable).permissions.contents -ceq 'write' -and
            ($Body | ConvertFrom-Json -AsHashtable).permissions.pull_requests -ceq 'write' -and
            ($Body | ConvertFrom-Json -AsHashtable).repositories[0] -ceq 'instance'
        }
    }

    It 'refuses a key with broader administration authority before issuing a token' {
        $actualPermissions.administration = 'write'
        { & $issuer -VendoringRepository platform/instance -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Actual GitHub App permissions differ*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'issues source credentials from an independently read-only App with attestation access' {
        $actualPermissions = @{ contents = 'read'; attestations = 'read'; metadata = 'read' }
        & $issuer -VendoringRepository platform/instance -ReadOnlySource -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and
            ($Body | ConvertFrom-Json -AsHashtable).permissions.contents -ceq 'read' -and
            ($Body | ConvertFrom-Json -AsHashtable).permissions.attestations -ceq 'read'
        }
    }

    It 'revokes a provisional token that unexpectedly covers another repository' {
        $fakeRepositoryNames = @('instance', 'unrelated')
        { & $issuer -VendoringRepository platform/instance -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Actual App repository access*differs*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'does not narrow a writer key into the read-only source phase' {
        { & $issuer -VendoringRepository platform/instance -ReadOnlySource -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Actual GitHub App permissions differ*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }
}
