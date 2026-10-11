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
        $actualOwner = @{ slug = 'example' }
        $repositorySelection = 'selected'
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

    It 'rejects organization-owned Apps instead of treating them as enterprise-owned' {
        $actualOwner = @{ login = 'example'; type = 'Organization' }

        { & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*not owned by the declared enterprise*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }

    It 'reports unavailable App APIs explicitly without PAT or permission fallback' {
        Mock Invoke-RestMethod { throw 'API unavailable' }

        { & $issuer -Authorization -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*GitHub App API GET /app failed*GHE.com API availability*'
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }
}
