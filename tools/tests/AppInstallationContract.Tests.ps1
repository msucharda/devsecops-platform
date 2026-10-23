BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $tools = Split-Path $PSScriptRoot -Parent
    $validator = Join-Path $tools 'Test-InstanceConfiguration.ps1'
}

Describe 'Manifest App installation selection' {
    BeforeEach {
        $modules = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/modules') -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'enterprise-baseline/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        foreach ($phase in @('plan', 'apply', 'rulesetPlan')) {
            $manifest.permissions.githubApp[$phase].resources.installationSelection = 'none'
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ 'enterprise-baseline' = @{ parameters = @{ target_organizations = @('actions', 'workloads') } } }
        $instance.githubApps = @{
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ organization_administration = 'read' }; resources = @{ organizations = @('actions', 'workloads'); repositories = @{} } }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads'); repositories = @{} } }
            rulesets = @{ appId = '103'; installationId = '203'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('actions', 'workloads'); repositories = @{} } }
        }
        $instance.credentials = @{
            'enterprise-baseline' = @{
                plan = @{ environment = 'enterprise-baseline-plan'; githubApp = 'reader' }
                apply = @{ environment = 'enterprise-baseline-apply'; githubApp = 'writer' }
                rulesetPlan = @{ environment = 'enterprise-baseline-ruleset-plan'; githubApp = 'rulesets' }
            }
        }
        $path = Join-Path $TestDrive 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path
    }

    It 'accepts a manifest none selection only with the explicit empty repository identity' {
        $validated = & $validator -InstancePath $path -ModulesPath $modules | ConvertFrom-Json -AsHashtable

        $validated.githubApps.reader.resources.repositories.Count | Should -Be 0
    }

    It 'rejects all-repository access when the manifest declares none' {
        $instance.githubApps.reader.resources.Remove('repositories')
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Throw '*resources differ*'
    }

    It 'rejects empty repository access when the manifest declares all' {
        $manifest.permissions.githubApp.plan.resources.installationSelection = 'all'
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Throw '*resources differ*'
    }

    It 'rejects selected repository access when the manifest declares all' {
        $manifest.permissions.githubApp.plan.resources.installationSelection = 'all'
        $instance.githubApps.reader.resources.repositories = @{ actions = @('instance'); workloads = @('instance') }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Throw '*resources differ*'
    }

    It 'rejects uppercase organization names at the configuration schema boundary' {
        $instance.githubApps.reader.resources.organizations = @('ACTIONS', 'workloads')
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Throw '*githubApps.reader.resources.organizations.0*'
    }

    It 'rejects a different repository name case in a declared repository scope' {
        $manifest.permissions.githubApp.plan.resources.Remove('installationSelection')
        $manifest.permissions.githubApp.plan.resources.repositories = 'target_repositories'
        $instance.modules['enterprise-baseline'].parameters.target_repositories = @{ actions = @('instance'); workloads = @('instance') }
        $instance.githubApps.reader.resources.repositories = @{ actions = @('INSTANCE'); workloads = @('instance') }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Throw '*resources differ*'
    }

    It 'preserves the legacy empty-repository identity when selection is not declared' {
        $manifest.permissions.githubApp.plan.resources.Remove('installationSelection')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        $validated = & $validator -InstancePath $path -ModulesPath $modules | ConvertFrom-Json -AsHashtable

        $validated.githubApps.reader.resources.repositories.Count | Should -Be 0
    }

    It 'accepts all-repository access when every phase declares all' {
        foreach ($phase in @('plan', 'apply', 'rulesetPlan')) {
            $manifest.permissions.githubApp[$phase].resources.installationSelection = 'all'
        }
        foreach ($alias in @('reader', 'writer', 'rulesets')) {
            $instance.githubApps[$alias].resources.Remove('repositories')
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        $validated = & $validator -InstancePath $path -ModulesPath $modules | ConvertFrom-Json -AsHashtable

        $validated.githubApps.reader.resources.Contains('repositories') | Should -BeFalse
    }

    It 'rejects an unsupported installation selection <Selection>' -ForEach @(
        @{ Selection = 'None' }
        @{ Selection = 'ALL' }
        @{ Selection = 'selected' }
        @{ Selection = '' }
    ) {
        $manifest.permissions.githubApp.plan.resources.installationSelection = $Selection
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Throw '*Invalid module manifest*'
    }

    It 'rejects combining an installation selection with a repository parameter' {
        $manifest.permissions.githubApp.plan.resources.repositories = 'repositories'
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Throw '*Invalid module manifest*'
    }

    It 'rejects applying an organization installation selection to an enterprise credential' {
        $manifest.permissions.githubApp.plan.resources = @{ enterprise = $true; installationSelection = 'none' }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $validator -InstancePath $path -ModulesPath $modules } | Should -Throw '*Invalid module manifest*'
    }

    It 'derives the installation checklist for every manifest phase and target organization' {
        $checklist = & (Join-Path $tools 'Get-GitHubAppInstallationChecklist.ps1') -InstancePath $path -ModulesPath $modules -GitHubHost 'example.ghe.com' |
            ConvertFrom-Json -AsHashtable
        $requirements = @($checklist.installations | Where-Object { $_.module -ceq 'enterprise-baseline' })

        $requirements.Count | Should -Be 6
        @($requirements.organization | Sort-Object -Unique) | Should -Be @('actions', 'workloads')
        @($requirements.phase | Sort-Object -Unique) | Should -Be @('apply', 'plan', 'rulesetPlan')
        @($requirements.repositorySelection | Sort-Object -Unique) | Should -Be @('none')
        $requirements | Where-Object { $_.phase -ceq 'plan' } | ForEach-Object {
            $_.appId | Should -BeExactly '101'
            $_.organizationSettingsUrl | Should -BeExactly "https://example.ghe.com/organizations/$($_.organization)/settings/installations"
        }
    }

    It 'derives the second-stage checklist before Apps and bindings exist' -Tag InstallationChecklist {
        $instance.githubApps = @{}
        $instance.credentials = @{}
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        $checklist = & (Join-Path $tools 'Get-GitHubAppInstallationChecklist.ps1') -InstancePath $path -ModulesPath $modules -GitHubHost 'example.ghe.com' |
            ConvertFrom-Json -AsHashtable
        $requirements = @($checklist.installations | Where-Object { $_.module -ceq 'enterprise-baseline' })

        $requirements.Count | Should -Be 6
        @($requirements | Where-Object { -not $_.registrationRequired }).Count | Should -Be 0
        @($requirements.organization | Sort-Object -Unique) | Should -Be @('actions', 'workloads')
        @($requirements.repositorySelection | Sort-Object -Unique) | Should -Be @('none')
    }
}
