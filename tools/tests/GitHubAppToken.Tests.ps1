BeforeAll {
    $issuer = Join-Path (Split-Path $PSScriptRoot -Parent) 'New-PlatformGitHubToken.ps1'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()
}

Describe 'Enterprise App key and installation token isolation' {
    BeforeEach {
        $savedEnvironment = @{}
        foreach ($name in @('PLATFORM_APP_ID', 'PLATFORM_APP_INSTALLATION_ID', 'PLATFORM_APP_ENTERPRISE', 'PLATFORM_APP_PRIVATE_KEY', 'GITHUB_REPOSITORY')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:PLATFORM_APP_ID = '101'
        $env:PLATFORM_APP_INSTALLATION_ID = '201'
        $env:PLATFORM_APP_ENTERPRISE = 'example'
        $env:PLATFORM_APP_PRIVATE_KEY = $privateKey
        $env:GITHUB_REPOSITORY = 'platform/instance'
        $environmentPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $actualPermissions = @{ members = 'read'; metadata = 'read' }
        $actualOrganizations = @('platform')
        $fakeRepositoryNames = @()
        $actualOwner = @{ login = 'example'; type = 'enterprise' }
        $repositorySelection = 'selected'
        $rulesetApp = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ organization_administration = 'write' }
            resources = @{ organizations = @('platform') }
        }
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Uri -eq 'https://api.example.test/app') {
                return @{ id = 101; owner = $actualOwner; permissions = $actualPermissions }
            }
            if ($Uri -like 'https://api.example.test/app/installations`?*') {
                return ,@($actualOrganizations | ForEach-Object {
                    @{ id = $(if ($_ -eq 'workloads') { 202 } else { 201 }); account = @{ login = $_ }; target_type = 'Organization'; permissions = $actualPermissions; repository_selection = $repositorySelection; suspended_at = $null }
                })
            }
            if ($Uri -like '*/access_tokens') {
                return @{ token = 'fake-installation-token'; permissions = $actualPermissions }
            }
            if ($Uri -like '*/installation/repositories`?*') {
                return @{ repositories = @($fakeRepositoryNames | ForEach-Object { @{ name = $_ } }) }
            }
            if ($Uri -like '*/installation/token' -and $Method -eq 'DELETE') { return }
            if ($Uri -like '*/orgs/platform/teams`?*') { return ,@(@{ id = 30; slug = 'platform' }) }
            if ($Uri -like '*/orgs/platform/actions/permissions') { return @{ enabled_repositories = 'all' } }
            if ($Uri -like '*/orgs/platform/code-security/configurations*') { return ,@() }
            throw "Unexpected GitHub API request: $Method $Uri"
        }
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    }

    It 'issues a members-only token after verifying enterprise ownership and exact installation resources' {
        & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        $content = [IO.File]::ReadAllText($environmentPath)
        $content | Should -Match 'PLATFORM_GITHUB_TOKENS=\{"platform":"fake-installation-token"\}'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Body -eq '{"permissions":{"members":"read"}}'
        }
    }

    It 'registers validation tokens before use and confirms revocation rejection without exposing the token' -Tag 'Resume' {
        $events = [Collections.Generic.List[string]]::new()
        $lifecycle = {
            param($LifecycleEvent)
            $events.Add($LifecycleEvent.Event)
            $LifecycleEvent.Token | Should -BeExactly 'fake-installation-token'
            $LifecycleEvent.RevocationProofRequired | Should -BeTrue
            return $true
        }.GetNewClosure()
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $(if ($Method -eq 'DELETE') { 204 } else { 401 }) } }
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }
            resources = @{ organizations = @('platform'); repositories = @{} }
        }

        $result = & $issuer -BootstrapApp $app -Authorization -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -TokenLifecycle $lifecycle -VerifyRevocation

        $result.Verified | Should -BeTrue
        $result.RevocationsVerified | Should -Be 1
        @($events) | Should -Be @('Issued', 'Revoking', 'Revoked')
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/installation/repositories*' }
    }

    It 'revokes a captured token when its supervisor rejects registration' -Tag 'Resume' {
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }; resources = @{ organizations = @('platform'); repositories = @{} }
        }
        $lifecycle = { param($LifecycleEvent) if ($LifecycleEvent.Event -ceq 'Issued') { throw 'Supervisor registration failed.' }; return $true }

        { & $issuer -BootstrapApp $app -Authorization -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -TokenLifecycle $lifecycle } | Should -Throw '*Supervisor registration failed*'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'does not retry an ambiguous validation-token revocation' -Tag 'Resume' {
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }; resources = @{ organizations = @('platform'); repositories = @{} }
        }
        Mock Invoke-WebRequest { throw 'Simulated response loss.' }

        { & $issuer -BootstrapApp $app -Authorization -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -VerifyRevocation } | Should -Throw '*Simulated response loss*'

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'rejects a successful revocation response without a subsequent HTTP 401 proof' -Tag 'Resume' {
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }; resources = @{ organizations = @('platform'); repositories = @{} }
        }
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $(if ($Method -eq 'DELETE') { 204 } else { 200 }) } }

        { & $issuer -BootstrapApp $app -Authorization -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -VerifyRevocation } | Should -Throw '*not rejected*HTTP 401*'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'issues a read-only module token map with <Selection> repository selection' -ForEach @(
        @{ Selection = 'all' }
        @{ Selection = 'selected' }
    ) {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $actualOrganizations = @('actions', 'workloads')
        $actualPermissions = @{ organization_administration = 'read'; metadata = 'read' }
        $repositorySelection = $Selection
        $fakeRepositoryNames = @('instance')
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ 'enterprise-baseline' = @{ parameters = @{ target_organizations = @('actions', 'workloads') } } }
        $instance.githubApps = @{
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ organization_administration = 'read' }; resources = @{ organizations = @('actions', 'workloads') } }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads') } }
            rulesets = @{ appId = '103'; installationId = '203'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads') } }
        }
        $modulesPath = Join-Path $PSScriptRoot 'fixtures/modules'
        if ($Selection -eq 'selected') {
            $modulesPath = Join-Path $TestDrive 'selected-modules'
            Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/modules') -Destination $modulesPath -Recurse
            $manifestPath = Join-Path $modulesPath 'enterprise-baseline/module.yaml'
            $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
            foreach ($phase in @('plan', 'apply')) {
                $manifest.permissions.githubApp[$phase].resources.repositories = 'target_repositories'
            }
            ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
            $instance.modules['enterprise-baseline'].parameters.target_repositories = @{ actions = @('instance'); workloads = @('instance') }
            foreach ($alias in @('reader', 'writer')) {
                $instance.githubApps[$alias].resources.repositories = @{ actions = @('instance'); workloads = @('instance') }
            }
        }
        $instance.credentials = @{
            'enterprise-baseline' = @{
                plan = @{ environment = 'enterprise-baseline-plan'; githubApp = 'reader' }
                apply = @{ environment = 'enterprise-baseline-apply'; githubApp = 'writer' }
                rulesetPlan = @{ environment = 'enterprise-baseline-ruleset-plan'; githubApp = 'rulesets' }
            }
        }
        $path = Join-Path $TestDrive 'module.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        & $issuer -Module enterprise-baseline -Phase plan -InstancePath $path -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        $line = Get-Content -LiteralPath $environmentPath | Where-Object { $_ -like 'PLATFORM_GITHUB_TOKENS=*' }
        $tokens = $line.Substring('PLATFORM_GITHUB_TOKENS='.Length) | ConvertFrom-Json -AsHashtable
        @($tokens.Keys | Sort-Object) | Should -Be @('actions', 'workloads')
        [IO.File]::ReadAllText($environmentPath) | Should -Not -Match '(?m)^GH_TOKEN='
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'issues an organization-only module token without repository access' {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $actualOrganizations = @('actions', 'workloads')
        $actualPermissions = @{ organization_administration = 'read'; metadata = 'read' }
        $repositorySelection = 'selected'
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ 'enterprise-baseline' = @{ parameters = @{ target_organizations = @('actions', 'workloads') } } }
        $instance.githubApps = @{
            reader = @{
                appId = '101'; installationId = '201'; enterprise = 'example'
                permissions = @{ organization_administration = 'read' }
                resources = @{ organizations = @('actions', 'workloads'); repositories = @{} }
            }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads') } }
            rulesets = @{ appId = '103'; installationId = '203'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads') } }
        }
        $instance.credentials = @{
            'enterprise-baseline' = @{
                plan = @{ environment = 'enterprise-baseline-plan'; githubApp = 'reader' }
                apply = @{ environment = 'enterprise-baseline-apply'; githubApp = 'writer' }
                rulesetPlan = @{ environment = 'enterprise-baseline-ruleset-plan'; githubApp = 'rulesets' }
            }
        }
        $path = Join-Path $TestDrive 'organization-only.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        & $issuer -Module enterprise-baseline -Phase plan -InstancePath $path `
            -ModulesPath (Join-Path $PSScriptRoot 'fixtures/modules') -ApiUrl https://api.example.test `
            -EnvironmentPath $environmentPath 6>$null

        Test-Path -LiteralPath $environmentPath | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
            $Uri -like '*/installation/repositories`?*'
        }
    }

    It 'rejects repository access for an organization-only module App' {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $actualOrganizations = @('actions', 'workloads')
        $actualPermissions = @{ organization_administration = 'read'; metadata = 'read' }
        $repositorySelection = 'selected'
        $fakeRepositoryNames = @('instance')
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ 'enterprise-baseline' = @{ parameters = @{ target_organizations = @('actions', 'workloads') } } }
        $instance.githubApps = @{
            reader = @{
                appId = '101'; installationId = '201'; enterprise = 'example'
                permissions = @{ organization_administration = 'read' }
                resources = @{ organizations = @('actions', 'workloads'); repositories = @{} }
            }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads') } }
            rulesets = @{ appId = '103'; installationId = '203'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads') } }
        }
        $instance.credentials = @{
            'enterprise-baseline' = @{
                plan = @{ environment = 'enterprise-baseline-plan'; githubApp = 'reader' }
                apply = @{ environment = 'enterprise-baseline-apply'; githubApp = 'writer' }
                rulesetPlan = @{ environment = 'enterprise-baseline-ruleset-plan'; githubApp = 'rulesets' }
            }
        }
        $path = Join-Path $TestDrive 'organization-only-with-repository.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $issuer -Module enterprise-baseline -Phase plan -InstancePath $path `
            -ModulesPath (Join-Path $PSScriptRoot 'fixtures/modules') -ApiUrl https://api.example.test `
            -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Organization-only App*must not have repository access*'

        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'DELETE' -and $Uri -eq 'https://api.example.test/installation/token'
        }
    }

    It 'rejects a key that can mint write tokens before issuing any installation token' {
        $actualPermissions.members = 'write'

        { & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Actual GitHub App permissions differ*write-capable*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects installations outside the declared organization scope' {
        $actualOrganizations = @('platform', 'unrelated')

        { & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*installations differ*target organizations*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'revokes a provisional token when the key has access to undeclared repositories' {
        $fakeRepositoryNames = @('instance', 'unrelated')

        { & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Authorization App*repository access*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'DELETE' -and $Uri -eq 'https://api.example.test/installation/token'
        }
    }

    It 'accepts a members-only installation without repository selection for authorization' {
        $repositorySelection = 'all'
        & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        Test-Path -LiteralPath $environmentPath | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*/installation/repositories`?*'
        }
    }

    It 'issues an enterprise token without issuing organization tokens for missing target organizations' {
        $actualOrganizations = @('platform')
        $actualPermissions = @{ enterprise_organization_installations = 'write'; metadata = 'read' }
        $repositorySelection = 'none'
        Mock Invoke-RestMethod {
            return ,@(@{
                id = 201; account = @{ login = 'example'; type = 'Enterprise' }; target_type = 'Enterprise'
                permissions = $actualPermissions; repository_selection = 'none'; suspended_at = $null
            })
        } -ParameterFilter { $Uri -like 'https://api.example.test/app/installations`?*' }
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ enterprise_organization_installations = 'write' }
            resources = @{ enterprise = $true; organizations = @('platform') }
        }

        $result = & $issuer -BootstrapApp $app -Phase apply -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        $result.Verified | Should -BeTrue
        $result.EnterpriseInstallationId | Should -Be '201'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -eq 'https://api.example.test/app/installations/201/access_tokens'
        }
    }

    It 'allows an enterprise plan without target organization installations and validates both permission scopes' {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $actualPermissions = @{
            enterprise_organization_installations = 'read'
            members = 'read'
            metadata = 'read'
        }
        $actualOrganizations = @('example')
        Mock Invoke-RestMethod {
            return ,@(@{
                id = 201; account = @{ login = 'example' }; target_type = 'Enterprise'
                permissions = @{ enterprise_organization_installations = 'read'; metadata = 'read' }
                repository_selection = 'none'; suspended_at = $null
            })
        } -ParameterFilter { $Uri -like 'https://api.example.test/app/installations`?*' }
        Mock Invoke-RestMethod {
            return @{
                token = 'fake-installation-token'
                permissions = @{ enterprise_organization_installations = 'read'; metadata = 'read' }
            }
        } -ParameterFilter { $Uri -eq 'https://api.example.test/app/installations/201/access_tokens' }
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{
                enterprise = @{ enterprise_organization_installations = 'read'; metadata = 'read' }
                organization = @{ members = 'read'; metadata = 'read' }
            }
            resources = @{ enterprise = $true; organizations = @('actions', 'workloads'); repositories = @{} }
        }

        $result = & $issuer -BootstrapApp $app -Phase plan -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        $result.Verified | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -eq 'https://api.example.test/app/installations/201/access_tokens'
        }
    }

    It 'rejects an enterprise installation that was not declared in resources' {
        $actualOrganizations = @('example', 'platform')
        Mock Invoke-RestMethod {
            return ,@(
                @{ id = 201; account = @{ login = 'example' }; target_type = 'Enterprise'; permissions = $actualPermissions; repository_selection = 'none'; suspended_at = $null }
                @{ id = 202; account = @{ login = 'platform' }; target_type = 'Organization'; permissions = @{ members = 'read' }; repository_selection = 'none'; suspended_at = $null }
            )
        } -ParameterFilter { $Uri -like 'https://api.example.test/app/installations`?*' }
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }
            resources = @{ organizations = @('platform') }
        }

        { & $issuer -BootstrapApp $app -Authorization -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*enterprise installation is not declared*'
    }

    It 'rejects organization-owned Apps instead of treating them as enterprise-owned' {
        $actualOwner = @{ login = 'example'; type = 'Organization' }

        { & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*not owned by the declared enterprise*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }

    It 'rejects an invalid enterprise owner: <Case>' -ForEach @(
        @{ Case = 'another enterprise'; Owner = @{ login = 'another'; type = 'enterprise' } }
        @{ Case = 'a user with the same login'; Owner = @{ login = 'example'; type = 'User' } }
        @{ Case = 'a missing owner type'; Owner = @{ login = 'example' } }
        @{ Case = 'a slug without a login'; Owner = @{ slug = 'example'; type = 'enterprise' } }
        @{ Case = 'no owner'; Owner = $null }
    ) {
        $actualOwner = $Owner
        { & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*not owned by the declared enterprise*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'reports unavailable App APIs explicitly without PAT or permission fallback' {
        Mock Invoke-RestMethod { throw 'API unavailable' }

        { & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*GitHub App API GET /app failed*GHE.com API availability*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }

    It 'checks the authorization team API with its trial installation token and revokes it on failure' {
        Mock Invoke-RestMethod { throw 'Team API unavailable' } -ParameterFilter { $Uri -like '*/orgs/platform/teams`?*' }
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }; resources = @{ organizations = @('platform'); repositories = @{} }
        }

        { & $issuer -BootstrapApp $app -Authorization -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath } |
            Should -Throw '*Team API unavailable*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }

    It 'checks required organization <Endpoint> API before validating an administration App' -ForEach @(
        @{ Endpoint = 'actions/permissions' }
        @{ Endpoint = 'code-security/configurations' }
        @{ Endpoint = 'code-security/configurations/defaults' }
    ) {
        $actualPermissions = @{ organization_administration = 'read'; metadata = 'read' }
        $repositorySelection = 'all'
        Mock Invoke-RestMethod { throw 'Organization API unavailable' } -ParameterFilter {
            $Uri -eq "https://api.example.test/orgs/platform/$Endpoint"
        }
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ organization_administration = 'read' }; resources = @{ organizations = @('platform') }
        }

        { & $issuer -BootstrapApp $app -PrivateKey $privateKey -ValidateOnly `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath } |
            Should -Throw '*Organization API unavailable*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }

    It 'validates local ruleset bypass details without claiming inherited enterprise detail coverage' {
        $actualPermissions = @{ organization_administration = 'write'; metadata = 'read' }
        $repositorySelection = 'all'
        Mock Invoke-RestMethod {
            return ,@(
                @{ id = 41; source_type = 'Organization'; source = 'platform' }
                @{ id = 42; source_type = 'Enterprise'; source = 'example' }
            )
        } -ParameterFilter { $Uri -like '*/orgs/platform/rulesets`?includes_parents=true*' }
        Mock Invoke-RestMethod {
            return @{ id = 41; bypass_actors = @(@{ actor_type = 'Team'; actor_id = 7; bypass_mode = 'pull_request' }) }
        } -ParameterFilter { $Uri -eq 'https://api.example.test/orgs/platform/rulesets/41' }
        $result = & $issuer -BootstrapApp $rulesetApp -PrivateKey $privateKey -ValidateOnly -Phase rulesetPlan `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath -WarningVariable rulesetWarnings

        $result.Verified | Should -BeTrue
        $result.InheritedRulesetsNotDetailValidated | Should -Be 1
        @($rulesetWarnings).Count | Should -Be 1
        [string] $rulesetWarnings[0] | Should -Match '1 inherited enterprise ruleset.*not detail-validated'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/rulesets/41'
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/rulesets/42'
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'rejects <Case> ruleset source metadata instead of silently skipping validation' -ForEach @(
        @{ Case = 'missing source type'; Rule = @{ id = 51; source = 'platform' } }
        @{ Case = 'unknown source type'; Rule = @{ id = 51; source_type = 'Repository'; source = 'platform' } }
        @{ Case = 'missing source'; Rule = @{ id = 51; source_type = 'Organization' } }
        @{ Case = 'mismatched organization source'; Rule = @{ id = 51; source_type = 'Organization'; source = 'another' } }
        @{ Case = 'mismatched enterprise source'; Rule = @{ id = 51; source_type = 'Enterprise'; source = 'another' } }
    ) {
        $actualPermissions = @{ organization_administration = 'write'; metadata = 'read' }
        $repositorySelection = 'all'
        Mock Invoke-RestMethod { return ,@($Rule) } -ParameterFilter {
            $Uri -like '*/orgs/platform/rulesets`?includes_parents=true*'
        }
        { & $issuer -BootstrapApp $rulesetApp -PrivateKey $privateKey -ValidateOnly -Phase rulesetPlan `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath } |
            Should -Throw '*unknown or mismatched source metadata*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter {
            $Uri -match '/orgs/platform/rulesets/[0-9]+$'
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'rejects a local ruleset detail without a bypass actor collection' {
        $actualPermissions = @{ organization_administration = 'write'; metadata = 'read' }
        $repositorySelection = 'all'
        Mock Invoke-RestMethod {
            return ,@(@{ id = 61; source_type = 'Organization'; source = 'platform' })
        } -ParameterFilter { $Uri -like '*/orgs/platform/rulesets`?includes_parents=true*' }
        Mock Invoke-RestMethod { return @{ id = 61 } } -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/rulesets/61'
        }
        { & $issuer -BootstrapApp $rulesetApp -PrivateKey $privateKey -ValidateOnly -Phase rulesetPlan `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath } |
            Should -Throw '*did not expose the complete bypass configuration*'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/rulesets/61'
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'fails closed and revokes the token when a local ruleset detail request fails' {
        $actualPermissions = @{ organization_administration = 'write'; metadata = 'read' }
        $repositorySelection = 'all'
        Mock Invoke-RestMethod {
            return ,@(@{ id = 71; source_type = 'Organization'; source = 'platform' })
        } -ParameterFilter { $Uri -like '*/orgs/platform/rulesets`?includes_parents=true*' }
        Mock Invoke-RestMethod { throw 'Local ruleset detail unavailable' } -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/rulesets/71'
        }
        { & $issuer -BootstrapApp $rulesetApp -PrivateKey $privateKey -ValidateOnly -Phase rulesetPlan `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath } |
            Should -Throw '*GitHub App API GET /orgs/platform/rulesets/71 failed*Local ruleset detail unavailable*'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/rulesets/71'
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }
}
