BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $modulesPath = Join-Path $root 'tools/acceptance/github/modules'
    Import-Module (Join-Path $root 'tools/InstanceSetup.psm1') -Force
    InModuleScope InstanceSetup -Parameters @{ Root = $root } {
        param($Root)
        Import-Module (Join-Path $Root 'tools/PlatformTools.psm1') -Force
    }
}

Describe 'Acceptance App bindings after a persisted reader interruption' {
    It 'resumes G5 with both module targets and the original registered App identities' {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $directory = Join-Path $work 'github-acceptance'
        $null = New-Item -ItemType Directory -Path $directory -Force
        $instancePath = Join-Path $directory 'instance.yaml'
        $statePath = Join-Path $directory 'setup-state.json'
        $organization = 'demo-a1b2c3-platform'
        @{ repository = "$organization/instance" } | ConvertTo-Json |
            Set-Content -LiteralPath (Join-Path $directory 'bootstrap-resources.json')

        $config = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $config.modules = @{
            'enterprise-baseline' = @{ parameters = @{} }
            'organization-rulesets' = @{ parameters = @{} }
        }
        $config.credentials = @{
            'enterprise-baseline' = @{
                plan = @{ environment = 'enterprise-baseline-plan' }
                apply = @{ environment = 'enterprise-baseline-apply' }
            }
            'organization-rulesets' = @{
                plan = @{ environment = 'organization-rulesets-plan' }
                apply = @{ environment = 'organization-rulesets-apply' }
                rulesetPlan = @{ environment = 'organization-rulesets-ruleset-plan' }
            }
        }
        $config.githubApps = @{}
        ConvertTo-Yaml $config | Set-Content -LiteralPath $instancePath

        $registered = @{
            authorization = @{ AppId = '401'; InstallationId = '501'; Permission = 'members'; Access = 'read' }
            reader = @{ AppId = '402'; InstallationId = '502'; Permission = 'organization_administration'; Access = 'read' }
            writer = @{ AppId = '403'; InstallationId = '503'; Permission = 'organization_administration'; Access = 'write' }
            rulesets = @{ AppId = '404'; InstallationId = '504'; Permission = 'organization_administration'; Access = 'write' }
        }
        $apps = @{}
        $keyPaths = @{}
        foreach ($alias in $registered.Keys) {
            $apps[$alias] = @{ "${alias}AppId" = $registered[$alias].AppId }
            $keyPaths[$alias] = Join-Path $directory "$alias.pem"
            $rsa = [Security.Cryptography.RSA]::Create(2048)
            try { $rsa.ExportRSAPrivateKeyPem() | Set-Content -LiteralPath $keyPaths[$alias] }
            finally { $rsa.Dispose() }
        }
        $initialState = @{ confirmations = @{}; probe = @{}; acceptance = @{ apps = $apps } }
        $newSetup = {
            param($State)
            @{
                RepoPath = $root; WorkPath = $work; ModulesPath = $modulesPath
                InstancePath = $instancePath; StatePath = $statePath; State = $State
                Settings = @{ name = 'demo'; enterprise = 'example'; githubHost = 'example.ghe.com' }
                Acceptance = @{ directory = $directory }
            }
        }
        $setup = & $newSetup $initialState
        InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
            param($Setup)
            Save-SetupState -Setup $Setup
        }

        $interruption = @{ BeforeWriter = $true }
        $requested = [Collections.Generic.List[string]]::new()
        $createdAt = [DateTimeOffset]::UtcNow.AddDays(-1).ToString('o')
        Mock Read-Host -ModuleName InstanceSetup {
            if ($Prompt -like 'Actual creation timestamp*') { return $createdAt }
            throw "Unexpected prompt: $Prompt"
        }
        Mock Get-SetupProbeApp -ModuleName InstanceSetup {
            if (-not $registered.ContainsKey($Role)) { throw "Unexpected App role: $Role" }
            $expected = $registered[$Role]
            if ($Organization -cne $organization -or $Selection -cne 'none' -or
                $AppName -cne "demo-bootstrap-$Role" -or
                $Permission.Count -ne 1 -or $Permission[$expected.Permission] -cne $expected.Access -or
                [string] $RegistrationState["${Role}AppId"] -cne $expected.AppId) {
                throw "Unexpected registration contract for $Role."
            }
            $requested.Add($Role)
            if ($Role -ceq 'writer' -and $interruption.BeforeWriter) {
                $interruption.BeforeWriter = $false
                throw 'Injected interruption before writer binding.'
            }
            @{ AppId = $expected.AppId; InstallationId = $expected.InstallationId; KeyPath = $keyPaths[$Role] }
        }

        { InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-StepAcceptanceApp -Setup $Setup
            } } | Should -Throw '*Injected interruption before writer binding*'
        $partial = ConvertFrom-Yaml (Get-Content -LiteralPath $instancePath -Raw)
        @($partial.githubApps.Keys | Sort-Object) | Should -Be @('authorization', 'reader')
        $partial.githubApps.reader.appId | Should -Be '402'
        foreach ($module in @('enterprise-baseline', 'organization-rulesets')) {
            $partial.credentials[$module].plan.githubApp | Should -Be 'reader'
            $partial.credentials[$module].apply.Contains('githubApp') | Should -BeFalse
            @($partial.modules[$module].parameters.target_organizations) | Should -Be @($organization)
        }
        $partial.credentials['organization-rulesets'].rulesetPlan.Contains('githubApp') | Should -BeFalse
        $partialKeys = Get-Content -LiteralPath (Join-Path $directory 'keys.json') -Raw | ConvertFrom-Json -AsHashtable
        @($partialKeys.Keys | Sort-Object) | Should -Be @('authorization', 'reader')

        $savedState = InModuleScope InstanceSetup -Parameters @{ StatePath = $statePath } {
            param($StatePath)
            Read-SetupState -Path $StatePath
        }
        @($savedState.acceptance.apps.Keys | Sort-Object) | Should -Be @('authorization', 'reader', 'rulesets', 'writer')
        $resumedSetup = & $newSetup $savedState
        $null = InModuleScope InstanceSetup -Parameters @{ Setup = $resumedSetup } {
            param($Setup)
            Invoke-StepAcceptanceApp -Setup $Setup
        }

        @($requested) | Should -Be @('authorization', 'reader', 'writer', 'authorization', 'reader', 'writer', 'rulesets')
        $resumed = ConvertFrom-Yaml (Get-Content -LiteralPath $instancePath -Raw)
        @($resumed.githubApps.Keys | Sort-Object) | Should -Be @('authorization', 'reader', 'rulesets', 'writer')
        foreach ($alias in $registered.Keys) {
            $expected = $registered[$alias]
            $app = $resumed.githubApps[$alias]
            $app.appId | Should -Be $expected.AppId
            $app.installationId | Should -Be $expected.InstallationId
            $app.enterprise | Should -Be 'example'
            $app.permissions.Count | Should -Be 1
            $app.permissions[$expected.Permission] | Should -Be $expected.Access
            @($app.resources.organizations) | Should -Be @($organization)
            $app.resources.repositories.Count | Should -Be 0
            $savedState.acceptance.apps[$alias]["${alias}AppId"] | Should -Be $expected.AppId
        }
        $resumed.githubApps.reader.appId | Should -Be $partial.githubApps.reader.appId
        foreach ($module in @('enterprise-baseline', 'organization-rulesets')) {
            @($resumed.modules[$module].parameters.target_organizations) | Should -Be @($organization)
            $resumed.credentials[$module].plan.githubApp | Should -Be 'reader'
            $resumed.credentials[$module].apply.githubApp | Should -Be 'writer'
            $resumed.credentials[$module].plan.environment | Should -Be "$module-plan"
            $resumed.credentials[$module].apply.environment | Should -Be "$module-apply"
        }
        $resumed.credentials['organization-rulesets'].rulesetPlan.githubApp | Should -Be 'rulesets'
        $resumed.credentials['organization-rulesets'].rulesetPlan.environment | Should -Be 'organization-rulesets-ruleset-plan'
        $resumed.credentials['enterprise-baseline'].Contains('rulesetPlan') | Should -BeFalse
        $keys = Get-Content -LiteralPath (Join-Path $directory 'keys.json') -Raw | ConvertFrom-Json -AsHashtable
        @($keys.Keys | Sort-Object) | Should -Be @('authorization', 'reader', 'rulesets', 'writer')
        $keys.reader.fingerprint | Should -Be $partialKeys.reader.fingerprint
    }
}
