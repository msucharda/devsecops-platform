BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $tools = Split-Path $PSScriptRoot -Parent
    $issuer = Join-Path $tools 'New-PlatformGitHubToken.ps1'
    $validator = Join-Path $tools 'Test-InstanceConfiguration.ps1'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()
}

Describe 'Explicit enterprise installation contract' {
    BeforeEach {
        $modulesPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $modulesPath -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/modules/observer') -Destination $modulesPath -Recurse
        $manifestPath = Join-Path $modulesPath 'observer/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.githubApp = @{
            plan = @{
                permissions = @{ enterprise_organization_installations = 'read' }
                resources = @{ enterprise = 'target_enterprise' }
            }
            apply = @{
                permissions = @{ enterprise_organization_installations = 'write' }
                resources = @{ enterprise = 'target_enterprise' }
            }
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ observer = @{ parameters = @{ target_enterprise = 'example' } } }
        $instance.githubApps = @{
            reader = @{
                appId = '101'; installationId = '201'; enterprise = 'example'
                permissions = @{ enterprise_organization_installations = 'read' }
                resources = @{ enterprise = 'example' }
            }
            writer = @{
                appId = '102'; installationId = '202'; enterprise = 'example'
                permissions = @{ enterprise_organization_installations = 'write' }
                resources = @{ enterprise = 'example' }
            }
        }
        $instance.credentials = @{
            observer = @{
                plan = @{ environment = 'observer-plan'; githubApp = 'reader' }
                apply = @{ environment = 'observer-apply'; githubApp = 'writer' }
            }
        }
        $instancePath = Join-Path $TestDrive 'enterprise.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $savedEnvironment = @{}
        foreach ($name in @('PLATFORM_APP_ID', 'PLATFORM_APP_INSTALLATION_ID', 'PLATFORM_APP_ENTERPRISE', 'PLATFORM_APP_PRIVATE_KEY')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:PLATFORM_APP_ID = '101'
        $env:PLATFORM_APP_INSTALLATION_ID = '201'
        $env:PLATFORM_APP_ENTERPRISE = 'example'
        $env:PLATFORM_APP_PRIVATE_KEY = $privateKey
        $environmentPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $actualPermissions = @{ enterprise_organization_installations = 'read' }
        $actualAppId = 101
        $actualOwner = @{ login = 'example'; type = 'enterprise' }
        $issuedPermissions = $null
        $actualInstallations = @(@{
            id = 201; account = @{ slug = 'example' }; target_type = 'Enterprise'
            permissions = $actualPermissions; suspended_at = $null
        })
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Uri -eq 'https://api.example.test/app') {
                return @{ id = $actualAppId; owner = $actualOwner; permissions = $actualPermissions }
            }
            if ($Uri -like 'https://api.example.test/app/installations`?*') { return ,$actualInstallations }
            if ($Uri -like '*/access_tokens') {
                return @{ token = 'fake-enterprise-token'; permissions = $(if ($null -ne $issuedPermissions) { $issuedPermissions } else { $actualPermissions }) }
            }
            if ($Uri -like '*/installation/token' -and $Method -eq 'DELETE') { return }
            if ($Uri -eq 'https://api.example.test/enterprises/example/apps/installable_organizations?per_page=1') {
                return @{ organizations = @(); total_count = 0 }
            }
            throw "Unexpected GitHub API request: $Method $Uri"
        }
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    }

    It 'validates a phase bound to exactly one declared enterprise without organization resources' {
        { & $validator -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Not -Throw
    }

    It 'exports an enterprise token without requesting permission or repository narrowing' {
        & $issuer -Module observer -Phase plan -InstancePath $instancePath -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        $content = [IO.File]::ReadAllText($environmentPath)
        $content | Should -Match '(?m)^PLATFORM_GITHUB_TOKENS=\{"enterprise":"fake-enterprise-token"\}$'
        $content | Should -Match '(?m)^TF_VAR_github_tokens=\{"enterprise":"fake-enterprise-token"\}$'
        $content | Should -Match '(?m)^GH_TOKEN=fake-enterprise-token$'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -eq 'https://api.example.test/app/installations/201/access_tokens' -and -not $Body
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*/installation/repositories*' }
    }

    It 'validates enterprise API access and proves revocation without using organization repository endpoints' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $(if ($Method -eq 'DELETE') { 204 } else { 401 }) } }

        $result = & $issuer -Module observer -Phase plan -InstancePath $instancePath -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -ValidateOnly -VerifyRevocation

        $result.Verified | Should -BeTrue
        $result.RevocationsVerified | Should -Be 1
        $result.Installations | Should -Be @('201')
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -like '*/enterprises/example/apps/installable_organizations*'
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -eq 'https://api.example.test/enterprises/example/apps/installable_organizations?per_page=1'
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*/installation/repositories*' }
    }

    It 'does not extend the ruleset plan exception to enterprise resources' {
        $manifest.permissions.githubApp.rulesetPlan = @{
            purpose = 'organization-rulesets-full-read'
            permissions = @{ organization_administration = 'write' }
            resources = @{ enterprise = 'target_enterprise' }
        }
        $manifest.permissions.githubApp.apply.permissions = @{ organization_administration = 'write' }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $validator -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*rulesetPlan*target organizations*'
    }

    It 'rejects an invalid enterprise contract: <Case>' -ForEach @(
        @{ Case = 'mixed manifest scope'; Error = '*Invalid module manifest*' }
        @{ Case = 'mixed identity scope'; Error = '*Invalid instance configuration*' }
        @{ Case = 'repository scope'; Error = '*Invalid module manifest*' }
        @{ Case = 'missing parameter'; Error = '*parameters.target_enterprise must declare*' }
        @{ Case = 'invalid enterprise slug'; Error = '*invalid GitHub App resource scope*' }
        @{ Case = 'different target parameter'; Error = '*resources differ*target resources*' }
        @{ Case = 'different owning enterprise'; Error = '*resources.enterprise differs*owning enterprise*' }
        @{ Case = 'write-capable plan'; Error = '*ordinary plan permissions must be read-only*' }
        @{ Case = 'write-capable plan identity'; Error = '*read-only App*' }
        @{ Case = 'shared key across phases'; Error = '*private-key identity across different phases*' }
    ) {
        switch ($Case) {
            'mixed manifest scope' { $manifest.permissions.githubApp.plan.resources.organizations = 'target_organizations' }
            'mixed identity scope' { $instance.githubApps.reader.resources.organizations = @('platform') }
            'repository scope' { $manifest.permissions.githubApp.plan.resources.repositories = 'target_repositories' }
            'missing parameter' { $instance.modules.observer.parameters.Remove('target_enterprise') }
            'invalid enterprise slug' { $instance.modules.observer.parameters.target_enterprise = 'not/a/slug' }
            'different target parameter' { $instance.modules.observer.parameters.target_enterprise = 'another' }
            'different owning enterprise' { $instance.githubApps.reader.resources.enterprise = 'another' }
            'write-capable plan' { $manifest.permissions.githubApp.plan.permissions.enterprise_organization_installations = 'write' }
            'write-capable plan identity' { $instance.githubApps.reader.permissions.enterprise_organization_installations = 'write' }
            'shared key across phases' { $instance.githubApps.writer.appId = '101' }
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $validator -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw $Error
    }

    It 'rejects unexpected installations before issuing a token: <Case>' -ForEach @(
        @{ Case = 'wrong enterprise slug' }
        @{ Case = 'a login instead of the enterprise slug' }
        @{ Case = 'wrong installation ID' }
        @{ Case = 'organization installation' }
        @{ Case = 'user installation' }
        @{ Case = 'suspended installation' }
        @{ Case = 'additional organization installation' }
        @{ Case = 'additional enterprise installation' }
        @{ Case = 'no installation' }
        @{ Case = 'broader installation permissions' }
        @{ Case = 'broader App permissions' }
        @{ Case = 'different App ID' }
        @{ Case = 'organization-owned App' }
    ) {
        switch ($Case) {
            'wrong enterprise slug' { $actualInstallations[0].account.slug = 'another' }
            'a login instead of the enterprise slug' { $actualInstallations[0].account = @{ login = 'example' } }
            'wrong installation ID' { $actualInstallations[0].id = 999 }
            'organization installation' { $actualInstallations[0].target_type = 'Organization' }
            'user installation' { $actualInstallations[0].target_type = 'User' }
            'suspended installation' { $actualInstallations[0].suspended_at = '2026-10-20T18:00:00Z' }
            'additional organization installation' {
                $actualInstallations += @{ id = 203; account = @{ login = 'platform' }; target_type = 'Organization' }
            }
            'additional enterprise installation' {
                $actualInstallations += @{ id = 203; account = @{ slug = 'another' }; target_type = 'Enterprise' }
            }
            'no installation' { $actualInstallations = @() }
            'broader installation permissions' {
                $actualInstallations[0].permissions = @{ enterprise_organization_installations = 'write' }
            }
            'broader App permissions' { $actualPermissions.enterprise_administration = 'write' }
            'different App ID' { $actualAppId = 999 }
            'organization-owned App' { $actualOwner.type = 'Organization' }
        }

        { & $issuer -Module observer -Phase plan -InstancePath $instancePath -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw

        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'issues a write-capable enterprise token only for the separately bound apply identity' {
        $env:PLATFORM_APP_ID = '102'
        $env:PLATFORM_APP_INSTALLATION_ID = '202'
        $actualAppId = 102
        $actualPermissions = @{ enterprise_organization_installations = 'write' }
        $actualInstallations[0].id = 202
        $actualInstallations[0].permissions = $actualPermissions

        & $issuer -Module observer -Phase apply -InstancePath $instancePath -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        Test-Path -LiteralPath $environmentPath | Should -BeTrue
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -like '*/installations/202/access_tokens' -and -not $Body
        }
    }

    It 'revokes a provisional enterprise token if its returned permissions differ from the contract' {
        $issuedPermissions = @{ enterprise_organization_installations = 'write' }

        { & $issuer -Module observer -Phase plan -InstancePath $instancePath -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Actual GitHub App permissions differ*'

        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'rejects an enterprise installation without explicit enterprise scope' {
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = $actualPermissions
            resources = @{ organizations = @('platform'); repositories = @{} }
        }

        { & $issuer -BootstrapApp $app -ValidateOnly -ApiUrl https://api.example.test } | Should -Throw

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'revokes the token and stops when the enterprise read probe is unavailable' {
        Mock Invoke-RestMethod { throw 'Enterprise API unavailable.' } -ParameterFilter {
            $Uri -like '*/enterprises/example/apps/installable_organizations*'
        }

        { & $issuer -Module observer -Phase plan -InstancePath $instancePath -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -ValidateOnly } | Should -Throw '*Enterprise API unavailable*'

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'does not treat a non-401 enterprise response as proof of revocation' {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $(if ($Method -eq 'DELETE') { 204 } else { 403 }) } }

        { & $issuer -Module observer -Phase plan -InstancePath $instancePath -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -ValidateOnly -VerifyRevocation } | Should -Throw '*not rejected*HTTP 401*'

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'does not publish a token when the protected environment selects another installation' {
        $env:PLATFORM_APP_INSTALLATION_ID = '999'

        { & $issuer -Module observer -Phase plan -InstancePath $instancePath -ModulesPath $modulesPath `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Protected environment App identity differs*'

        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}
