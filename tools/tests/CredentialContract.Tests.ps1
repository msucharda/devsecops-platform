BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $tools = Split-Path $PSScriptRoot -Parent
    $validator = Join-Path $tools 'Test-InstanceConfiguration.ps1'
    $selector = Join-Path $tools 'Select-InstanceModules.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
}

Describe 'Phase-specific App credential contracts' {
    BeforeEach {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{
            'enterprise-baseline' = @{ parameters = @{ target_organizations = @('workloads', 'actions') } }
        }
        $instance.githubApps = @{
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ organization_administration = 'read' }; resources = @{ organizations = @('actions', 'workloads') } }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('workloads', 'actions') } }
            rulesets = @{ appId = '103'; installationId = '203'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads') } }
        }
        $instance.credentials = @{
            'enterprise-baseline' = @{
                plan = @{ environment = 'enterprise-baseline-plan'; githubApp = 'reader' }
                apply = @{ environment = 'enterprise-baseline-apply'; githubApp = 'writer' }
                rulesetPlan = @{ environment = 'enterprise-baseline-ruleset-plan'; githubApp = 'rulesets' }
            }
        }
        $path = Join-Path $TestDrive 'governance.yaml'
    }

    It 'validates distinct phase identities and publishes all phase environments including prerequisites' {
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path
        $output = Join-Path $TestDrive 'selection'

        $selection = & $selector -InstancePath $path -ModulesPath $fixtures -GitHubOutputPath $output

        $selection | Should -Be '["application","enterprise-baseline","foundation","service"]'
        [IO.File]::ReadAllText($output) | Should -Match 'applyEnvironments=.*"enterprise-baseline":"enterprise-baseline-apply"'
        [IO.File]::ReadAllText($output) | Should -Match 'rulesetEnvironments=\{"enterprise-baseline":"enterprise-baseline-ruleset-plan"\}'
        [IO.File]::ReadAllText($output) | Should -Match 'rulesetModules=\["enterprise-baseline"\]'
    }

    It 'does not select the late ruleset plan when only the early baseline phase uses its module credentials' {
        $modules = Join-Path $TestDrive 'credential-phase-modules'
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'enterprise-baseline/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.phases = @{ 'code-security' = @{ prerequisites = @('foundation') } }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        New-Item -ItemType Directory -Path (Join-Path $modules 'enterprise-baseline/code-security') | Out-Null
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path
        $output = Join-Path $TestDrive 'staged-credentials'

        $null = & $selector -InstancePath $path -ModulesPath $modules -DeploymentScope code-security -GitHubOutputPath $output

        $published = [IO.File]::ReadAllText($output)
        $published | Should -Match 'modules=\["enterprise-baseline","foundation"\]'
        $published | Should -Match 'phaseNodes=\["enterprise-baseline:code-security","foundation"\]'
        $published | Should -Match 'rulesetEnvironments=\{"enterprise-baseline":"enterprise-baseline-ruleset-plan"\}'
        $published | Should -Match 'rulesetModules=\[\]'
    }

    It 'rejects mismatched target organizations rather than accepting a wider App identity' {
        $instance.githubApps.reader.resources.organizations += 'unrelated'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $fixtures } | Should -Throw '*resources differ*target resources*'
    }

    It 'accepts an explicit empty repository scope for an organization-only App' {
        foreach ($alias in @('reader', 'writer', 'rulesets')) {
            $instance.githubApps[$alias].resources.repositories = @{}
        }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $fixtures } | Should -Not -Throw
    }

    It 'rejects write permission sharing between apply and the isolated ruleset plan even under different aliases' {
        $instance.githubApps.rulesets.appId = '102'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $fixtures } | Should -Throw '*private-key identity across different phases*'
    }

    It 'requires the App alias and target parameter declared by a selected module: <Case>' -ForEach @(
        @{ Case = 'missing App binding'; RemoveBinding = $true; Error = '*credentials.enterprise-baseline.plan.githubApp is required*' }
        @{ Case = 'missing resource parameter'; RemoveBinding = $false; Error = '*parameters.target_organizations must declare*' }
    ) {
        if ($RemoveBinding) { $instance.credentials.'enterprise-baseline'.plan.Remove('githubApp') }
        else { $instance.modules.'enterprise-baseline'.parameters.Remove('target_organizations') }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $fixtures } | Should -Throw $Error
    }

    It 'permits App sharing only with identical permissions, target resources and phase' {
        $modules = Join-Path $TestDrive 'shared-modules'
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'observer/module.yaml'
        $observer = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $baseline = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $modules 'enterprise-baseline/module.yaml') -Raw)
        $observer.permissions.githubApp = @{
            plan = $baseline.permissions.githubApp.plan
            apply = $baseline.permissions.githubApp.apply
        }
        ConvertTo-Yaml $observer | Set-Content -LiteralPath $manifestPath
        $instance.modules.observer = @{ parameters = @{ target_organizations = @('actions', 'workloads') } }
        $instance.credentials.observer = @{
            plan = @{ environment = 'observer-plan'; githubApp = 'reader' }
            apply = @{ environment = 'observer-apply'; githubApp = 'writer' }
        }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Not -Throw
    }

    It 'prevents PR-controlled credential bindings from choosing an apply key for a plan environment' {
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path
        $candidate = Join-Path $TestDrive 'candidate.yaml'
        $instance.credentials.'enterprise-baseline'.plan.environment = 'new-plan-environment'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $candidate
        $output = Join-Path $TestDrive 'not-published'

        { & $selector -InstancePath $candidate -TrustedInstancePath $path -TrustedModulesPath $fixtures -ModulesPath $fixtures -GitHubOutputPath $output } |
            Should -Throw '*PR changes protected credentials*main after review and merge*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'prevents PR changes to App identity metadata from being used before merge' {
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path
        $candidate = Join-Path $TestDrive 'app-change.yaml'
        $instance.githubApps.reader.installationId = '999'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $candidate

        { & $selector -InstancePath $candidate -TrustedInstancePath $path -TrustedModulesPath $fixtures -ModulesPath $fixtures } |
            Should -Throw '*PR changes protected githubApps*'
    }
}
