BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $tools = Split-Path $PSScriptRoot -Parent
    $issuer = Join-Path $tools 'New-PlatformGitHubToken.ps1'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()
}

Describe 'Enterprise installation credentials' {
    BeforeEach {
        $savedEnvironment = @{}
        foreach ($name in @('PLATFORM_APP_ID', 'PLATFORM_APP_INSTALLATION_ID', 'PLATFORM_APP_ENTERPRISE')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:PLATFORM_APP_ID = '101'
        $env:PLATFORM_APP_INSTALLATION_ID = '201'
        $env:PLATFORM_APP_ENTERPRISE = 'example'
        $casePath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $casePath
        $modulesPath = Join-Path $casePath 'modules'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/modules') -Destination $modulesPath -Recurse
        $manifestPath = Join-Path $modulesPath 'observer/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.githubApp = @{
            plan = @{ permissions = @{ enterprise_organization_installations = 'read' }; resources = @{ enterprise = $true } }
            apply = @{ permissions = @{ enterprise_organization_installations = 'write' }; resources = @{ enterprise = $true } }
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ observer = @{} }
        $instance.githubApps = @{
            reader = @{
                appId = '101'; installationId = '201'; enterprise = 'example'
                permissions = @{ enterprise_organization_installations = 'read' }; resources = @{ enterprise = $true }
            }
            writer = @{
                appId = '102'; installationId = '202'; enterprise = 'example'
                permissions = @{ enterprise_organization_installations = 'write' }; resources = @{ enterprise = $true }
            }
        }
        $instance.credentials = @{
            observer = @{
                plan = @{ environment = 'observer-plan'; githubApp = 'reader' }
                apply = @{ environment = 'observer-apply'; githubApp = 'writer' }
            }
        }
        $instancePath = Join-Path $casePath 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $environmentPath = Join-Path $casePath 'github-env'
        $owner = @{ slug = 'example'; id = 10; node_id = 'E_example' }
        $permissions = @{ enterprise_organization_installations = 'read' }
        $actualInstallations = @(@{
            id = 201; app_id = 101; target_type = 'Enterprise'; target_id = 10
            account = $owner; permissions = $permissions; suspended_at = $null
        })
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Uri -eq 'https://api.example.test/app') {
                return @{ id = 101; owner = $owner; permissions = $permissions }
            }
            if ($Uri -like '*/app/installations`?*') { return ,$actualInstallations }
            if ($Uri -like '*/access_tokens') { return @{ token = 'enterprise-token'; permissions = $permissions } }
            if ($Uri -like '*/installation/token' -and $Method -eq 'DELETE') { return }
            throw "Unexpected API request: $Method $Uri"
        }
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
        }
    }

    It 'issues an enterprise token through the module contract without repository or permission scoping' {
        & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        $content = Get-Content -LiteralPath $environmentPath -Raw
        $content | Should -Match 'PLATFORM_GITHUB_TOKENS=\{"enterprise":"enterprise-token"\}'
        $content | Should -Match 'TF_VAR_github_tokens=\{"enterprise":"enterprise-token"\}'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -like '*/installations/201/access_tokens' -and -not $Body
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*/installation/repositories*' }
    }

    It 'keeps enterprise apply separate from plan and issues its full declared permissions' {
        $env:PLATFORM_APP_ID = '102'
        $env:PLATFORM_APP_INSTALLATION_ID = '202'
        $permissions = @{ enterprise_organization_installations = 'write' }
        $actualInstallations[0].id = 202
        $actualInstallations[0].app_id = 102
        $actualInstallations[0].permissions = $permissions
        Mock Invoke-RestMethod {
            return @{ id = 102; owner = $owner; permissions = $permissions }
        } -ParameterFilter { $Uri -eq 'https://api.example.test/app' }

        & $issuer -Module observer -Phase apply -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        Get-Content -LiteralPath $environmentPath -Raw | Should -Match '"enterprise":"enterprise-token"'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -like '*/installations/202/access_tokens' -and -not $Body
        }
    }

    It 'rejects enterprise identity sharing across plan and apply even under different aliases' {
        $instance.githubApps.writer.appId = '101'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*private-key identity across different phases*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects mixed enterprise and organization scopes in instance identities' {
        $instance.githubApps.reader.resources.organizations = @('platform')
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*Invalid instance configuration*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects enterprise scope in the organization-only ruleset exception' {
        $manifest.permissions.githubApp.apply.permissions = @{ organization_administration = 'write' }
        $manifest.permissions.githubApp.rulesetPlan = @{
            permissions = @{ organization_administration = 'write' }
            resources = @{ enterprise = $true }; purpose = 'organization-rulesets-full-read'
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*rulesetPlan*target organizations*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects unexpected enterprise installation inventory before issuing any token: <Case>' -ForEach @(
        @{ Case = 'another enterprise slug'; Field = 'slug'; Value = 'other'; Account = $true }
        @{ Case = 'another enterprise ID'; Field = 'id'; Value = 99; Account = $true }
        @{ Case = 'another target ID'; Field = 'target_id'; Value = 99; Account = $false }
        @{ Case = 'another App'; Field = 'app_id'; Value = 999; Account = $false }
        @{ Case = 'another installation ID'; Field = 'id'; Value = 999; Account = $false }
        @{ Case = 'organization installation'; Field = 'target_type'; Value = 'Organization'; Account = $false }
        @{ Case = 'user installation'; Field = 'target_type'; Value = 'User'; Account = $false }
        @{ Case = 'suspended installation'; Field = 'suspended_at'; Value = '2026-10-20T00:00:00Z'; Account = $false }
    ) {
        $actualInstallations[0].account = @{} + $owner
        if ($Account) { $actualInstallations[0].account[$Field] = $Value }
        else { $actualInstallations[0][$Field] = $Value }

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*installation*'

        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'requires positive enterprise IDs even when invalid values would compare equal: <Case>' -ForEach @(
        @{ Case = 'missing IDs'; EnterpriseId = $null }
        @{ Case = 'zero IDs'; EnterpriseId = 0 }
        @{ Case = 'malformed IDs'; EnterpriseId = 'invalid' }
    ) {
        $owner = @{ login = 'example'; type = 'Enterprise'; id = $EnterpriseId; node_id = 'E_example' }
        $actualInstallations[0].account = @{ slug = 'example'; id = $EnterpriseId }
        $actualInstallations[0].target_id = $EnterpriseId

        # The App owner check rejects the invalid owner ID before the installation inventory is compared.
        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*not owned by the declared enterprise*'

        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects missing or additional installations instead of weakening exact inventory: <Case>' -ForEach @(
        @{ Case = 'missing enterprise installation'; Extra = $false }
        @{ Case = 'additional organization installation'; Extra = $true }
    ) {
        if ($Extra) {
            $actualInstallations += @{
                id = 202; app_id = 101; account = @{ login = 'platform' }; target_type = 'Organization'
                permissions = $permissions; suspended_at = $null
            }
        } else { $actualInstallations = @() }

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*enterprise installation*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'requires enterprise scope in both manifest and identity: <Case>' -ForEach @(
        @{ Case = 'undeclared in manifest'; ChangeManifest = $true }
        @{ Case = 'undeclared in identity'; ChangeManifest = $false }
    ) {
        if ($ChangeManifest) {
            $manifest.permissions.githubApp.plan.resources = @{ organizations = 'target_organizations' }
            $instance.modules.observer = @{ parameters = @{ target_organizations = @('platform') } }
            ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        } else {
            $instance.githubApps.reader.resources = @{ organizations = @('platform') }
        }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*resources differ*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects ambiguous enterprise resource declarations: <Case>' -ForEach @(
        @{ Case = 'organization scope'; Scope = @{ enterprise = $true; organizations = 'target_organizations' } }
        @{ Case = 'repository scope'; Scope = @{ enterprise = $true; repositories = 'target_repositories' } }
        @{ Case = 'disabled enterprise scope'; Scope = @{ enterprise = $false } }
    ) {
        $manifest.permissions.githubApp.plan.resources = $Scope
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*Invalid module manifest*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects a write-capable enterprise App in ordinary plan before any HTTP request' {
        $manifest.permissions.githubApp.plan.permissions.enterprise_organization_installations = 'write'
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*plan*read-only*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects broader installation permissions before token issuance' {
        $actualInstallations[0].permissions = @{ enterprise_organization_installations = 'write' }

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*permissions differ*'

        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'revokes an issued enterprise token if returned permissions differ and publishes nothing' {
        Mock Invoke-RestMethod {
            return @{ token = 'enterprise-token'; permissions = @{ enterprise_organization_installations = 'write' } }
        } -ParameterFilter { $Uri -like '*/access_tokens' }

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } | Should -Throw '*permissions differ*'

        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'validates and proves revocation with an enterprise endpoint, not a repository endpoint' {
        $validationEvents = [Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            $validationEvents.Add('Read')
            return @()
        } -ParameterFilter { $Uri -like '*/enterprises/example/apps/installable_organizations*' }
        Mock Invoke-WebRequest {
            $validationEvents.Add($Method)
            [pscustomobject]@{ StatusCode = $(if ($Method -eq 'DELETE') { 204 } else { 401 }) }
        }

        $result = & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath -ValidateOnly -VerifyRevocation

        $result.Verified | Should -BeTrue
        $result.Installations | Should -Be @('201')
        $result.RevocationsVerified | Should -Be 1
        @($validationEvents) | Should -Be @('Read', 'DELETE', 'GET')
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'GET' -and $Uri -eq 'https://api.example.test/enterprises/example/apps/installable_organizations?per_page=1'
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*/installation/repositories*' }
    }

    It 'revokes the enterprise token and fails validation when the active-token read fails' {
        Mock Invoke-RestMethod { throw 'Active enterprise read denied.' } -ParameterFilter {
            $Uri -like '*/enterprises/example/apps/installable_organizations*'
        }

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath -ValidateOnly } |
            Should -Throw '*Active enterprise read denied*'

        Test-Path -LiteralPath $environmentPath | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'rejects a revocation proof with HTTP <Status> instead of treating it as token rejection' -ForEach @(
        @{ Status = 200 }
        @{ Status = 403 }
        @{ Status = 404 }
        @{ Status = 500 }
    ) {
        Mock Invoke-RestMethod { return @() } -ParameterFilter {
            $Uri -like '*/enterprises/example/apps/installable_organizations*'
        }
        Mock Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = $(if ($Method -eq 'DELETE') { 204 } else { $Status }) }
        }

        { & $issuer -Module observer -InstancePath $instancePath -ModulesPath $modulesPath -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath -ValidateOnly -VerifyRevocation } |
            Should -Throw '*not rejected*HTTP 401*'

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }
}
