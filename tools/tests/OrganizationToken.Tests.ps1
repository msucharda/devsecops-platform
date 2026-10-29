BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $issuer = Join-Path (Split-Path $PSScriptRoot -Parent) 'New-PlatformGitHubToken.ps1'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()
}

Describe 'Organization-scoped App token issuance' {
    BeforeEach {
        Mock Invoke-WebRequest {
            param($Uri, $Method, $Headers, $MaximumRedirection, $TimeoutSec, $MaximumRetryCount)
            $null = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -MaximumRedirection $MaximumRedirection `
                -TimeoutSec $TimeoutSec -MaximumRetryCount $MaximumRetryCount
            [pscustomobject]@{ StatusCode = 204 }
        }
        $PSDefaultParameterValues = @{} + $PSDefaultParameterValues
        $PSDefaultParameterValues['New-PlatformGitHubToken.ps1:IssuanceStatePath'] = Join-Path $TestDrive "issuance-$([guid]::NewGuid())/pending.json"
        $savedEnvironment = @{}
        foreach ($name in @('PLATFORM_APP_ID', 'PLATFORM_APP_INSTALLATION_ID', 'PLATFORM_APP_ENTERPRISE', 'GITHUB_REPOSITORY_OWNER')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:PLATFORM_APP_ID = '101'
        $env:PLATFORM_APP_INSTALLATION_ID = '201'
        $env:PLATFORM_APP_ENTERPRISE = 'example'
        $env:GITHUB_REPOSITORY_OWNER = 'demo-platform'
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $modules = Join-Path $directory 'modules'
        $null = New-Item -ItemType Directory -Path $modules -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/organization-module') -Destination (Join-Path $modules 'scoped') -Recurse
        $organizations = @('demo-platform', 'demo-actions', 'demo-workloads')
        $actualOrganizations = $organizations
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/organization-module-instance.yaml') -Raw)
        $instancePath = Join-Path $directory 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $environmentPath = Join-Path $directory 'environment'
        $ownerVariant = 'owner-simple-user'
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Uri -eq 'https://api.example.test/app') {
                $app = Get-GitHubApiFixture -Name "apps/get-app.$ownerVariant" -Set @{ id = 101; permissions = @{ organization_administration = 'read' } }
                if ($ownerVariant -eq 'owner-enterprise') { $app.owner.slug = 'example' }
                else { $app.owner.login = 'example'; $app.owner.type = 'enterprise' }
                return $app
            }
            if ($Uri -like '*/app/installations`?*') {
                $id = 200
                return ,@($actualOrganizations | ForEach-Object {
                    $id++
                    (Get-GitHubApiFixture -Name apps/list-installations -Set @{
                        '0.id' = $id; '0.account.login' = $_; '0.account.type' = 'Organization'
                        '0.target_type' = 'Organization'; '0.permissions' = @{ organization_administration = 'read' }
                        '0.repository_selection' = 'all'; '0.suspended_at' = $null
                    })[0]
                })
            }
            if ($Uri -match '/app/installations/([0-9]+)/access_tokens$') {
                return Get-GitHubApiFixture -Name apps/create-installation-access-token `
                    -Set @{ token = "installation-$($Matches[1])"; permissions = @{ organization_administration = 'read' } }
            }
            if ($Method -eq 'DELETE' -and $Uri -like '*/installation/token') { return }
            throw "Unexpected GitHub API request: $Method $Uri"
        }
    }

    AfterEach {
        foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
    }

    It 'issues exactly one token for each instance organization with the documented <Variant> owner' -ForEach @(
        @{ Variant = 'owner-simple-user' }
        @{ Variant = 'owner-enterprise' }
    ) {
        $ownerVariant = $Variant
        & $issuer -Module scoped -InstancePath $instancePath -ModulesPath $modules -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null

        $content = Get-Content -LiteralPath $environmentPath -Raw
        $tokens = ($content -split "`n" | Where-Object { $_ -like 'PLATFORM_GITHUB_TOKENS=*' }) -replace '^PLATFORM_GITHUB_TOKENS=', '' |
            ConvertFrom-Json -AsHashtable
        $tokens['demo-platform'] | Should -BeExactly 'installation-201'
        $tokens['demo-actions'] | Should -BeExactly 'installation-202'
        $tokens['demo-workloads'] | Should -BeExactly 'installation-203'
        $content | Should -Not -Match '(?m)^GH_TOKEN='
        Should -Invoke Invoke-RestMethod -Times 3 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'refuses a configured organization outside the instance before calling GitHub' {
        $instance.modules.scoped.parameters.target_organizations = @('demo-platform', 'demo-actions', 'foreign')
        foreach ($app in $instance.githubApps.Values) { $app.resources.organizations = $instance.modules.scoped.parameters.target_organizations }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $issuer -Module scoped -InstancePath $instancePath -ModulesPath $modules -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*must contain exactly all instance organizations*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }

    It 'refuses unexpected actual installation scope: <Case>' -ForEach @(
        @{ Case = 'additional organization'; Value = @('demo-platform', 'demo-actions', 'demo-workloads', 'foreign') }
        @{ Case = 'missing organization'; Value = @('demo-platform', 'demo-actions') }
    ) {
        $actualOrganizations = $Value
        { & $issuer -Module scoped -InstancePath $instancePath -ModulesPath $modules -PrivateKey $privateKey `
            -ApiUrl https://api.example.test -EnvironmentPath $environmentPath 6>$null } |
            Should -Throw '*Actual App installations differ*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Test-Path -LiteralPath $environmentPath | Should -BeFalse
    }
}
