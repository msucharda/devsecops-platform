BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $released = Join-Path (Split-Path $toolsPath -Parent) 'modules'

    # Copies the released modules and renames organizations so that the module order cannot follow from names.
    function Copy-ReleasedModuleWithRenamedOrganization {
        param([Parameter(Mandatory)][string] $OrganizationsName)

        $modules = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Copy-Item -LiteralPath $released -Destination $modules -Recurse
        if ($OrganizationsName -cne 'organizations') {
            Rename-Item -LiteralPath (Join-Path $modules 'organizations') -NewName $OrganizationsName
        }
        $organizationsPath = Join-Path $modules "$OrganizationsName/module.yaml"
        $organizations = ConvertFrom-Yaml (Get-Content -LiteralPath $organizationsPath -Raw)
        $organizations.name = $OrganizationsName
        ConvertTo-Yaml $organizations | Set-Content -LiteralPath $organizationsPath

        foreach ($manifestPath in (Get-ChildItem -LiteralPath $modules -Filter 'module.yaml' -Recurse -Depth 1).FullName) {
            $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
            if (@($manifest.prerequisites) -cnotcontains 'organizations') { continue }
            $manifest.prerequisites = @($manifest.prerequisites | ForEach-Object { if ($_ -ceq 'organizations') { $OrganizationsName } else { $_ } })
            if ($manifest.Contains('phases')) {
                foreach ($phase in $manifest.phases.Values) {
                    $phase.prerequisites = @($phase.prerequisites | ForEach-Object { if ($_ -ceq 'organizations') { $OrganizationsName } else { $_ } })
                }
            }
            ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        }
        return $modules
    }
}

Describe 'Released module order' {
    It 'places the early baseline before rulesets and the late baseline after the catalog in all three workflows' {
        $deployPath = Join-Path $TestDrive 'deploy-phases.yml'
        $driftPath = Join-Path $TestDrive 'drift-phases.yml'
        $teardownPath = Join-Path $TestDrive 'teardown-phases.yml'
        & (Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1') -ModulesPath $released -OutputPath $deployPath -DriftOutputPath $driftPath
        & (Join-Path $toolsPath 'Generate-TeardownWorkflow.ps1') -ModulesPath $released -OutputPath $teardownPath
        $deploy = ConvertFrom-Yaml (Get-Content -LiteralPath $deployPath -Raw)
        $drift = ConvertFrom-Yaml (Get-Content -LiteralPath $driftPath -Raw)
        $teardown = ConvertFrom-Yaml (Get-Content -LiteralPath $teardownPath -Raw)

        foreach ($workflow in @($deploy, $drift)) {
            $workflow.jobs.module_enterprise_baseline_code_security.needs | Should -Contain 'module_organizations'
            $workflow.jobs.module_enterprise_baseline_code_security.needs | Should -Not -Contain 'module_actions_catalog'
            $workflow.jobs.module_organization_rulesets.needs | Should -Contain 'module_enterprise_baseline_code_security'
            $workflow.jobs.module_enterprise_baseline.needs | Should -Contain 'module_actions_catalog'
            $workflow.jobs.module_enterprise_baseline_code_security.environment | Should -Be $workflow.jobs.module_enterprise_baseline.environment
            $workflow.jobs.module_enterprise_baseline_code_security.steps |
                Where-Object { $_.Contains('run') -and $_.run -match '-DeploymentPhase code-security' } | Should -Not -BeNullOrEmpty
        }
        $deploy.jobs.plan_complete.needs | Should -Contain 'module_enterprise_baseline_code_security'
        $deploy.jobs.apply_organization_rulesets.needs | Should -Contain 'apply_enterprise_baseline_code_security'
        $coverageJob = $drift.jobs.module_enterprise_baseline_code_security
        $coverageJob.outputs.codeSecurityCoverage | Should -Be '${{ steps.code_security.outputs.codeSecurityCoverage }}'
        $coverage = @($coverageJob.steps | Where-Object { $_.Contains('id') -and $_.id -eq 'code_security' })
        $coverage.Count | Should -Be 1
        $coverage[0].if | Should -Be '${{ !cancelled() && env.PLATFORM_GITHUB_TOKENS != '''' }}'
        $coverage[0].run | Should -Be './trusted/platform/tools/Test-CodeSecurityCoverage.ps1 -GitHubOutputPath $env:GITHUB_OUTPUT'
        $steps = @($coverageJob.steps)
        $coverageIndex = [array]::IndexOf($steps, $coverage[0])
        $coverageIndex | Should -BeGreaterThan ([array]::FindIndex($steps, [Predicate[object]] { param($s) $s.Contains('run') -and $s.run -match 'Invoke-Module\.ps1' }))
        $coverageIndex | Should -BeLessThan ($steps.Count - 1)
        $teardown.jobs.destroy_enterprise_baseline_code_security.needs | Should -Contain 'destroy_organization_rulesets'
        $teardown.jobs.destroy_organization_rulesets.needs | Should -Contain 'destroy_actions_catalog'
        $teardown.jobs.destroy_enterprise_baseline.needs | Should -Not -Contain 'destroy_organization_rulesets'
    }

    It 'continues drift plans after a Code Security coverage read fails, leaving coverage absent for the report' {
        $deployPath = Join-Path $TestDrive 'coverage-deploy.yml'
        $driftPath = Join-Path $TestDrive 'coverage-drift.yml'
        & (Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1') -ModulesPath $released -OutputPath $deployPath -DriftOutputPath $driftPath
        $drift = ConvertFrom-Yaml (Get-Content -LiteralPath $driftPath -Raw)
        $early = $drift.jobs.module_enterprise_baseline_code_security
        $coverage = @($early.steps | Where-Object { $_.Contains('id') -and $_.id -eq 'code_security' })

        $coverage.Count | Should -Be 1
        $coverage[0]['continue-on-error'] | Should -BeTrue
        $coverage[0].if | Should -Be '${{ !cancelled() && env.PLATFORM_GITHUB_TOKENS != '''' }}'
        $early.outputs.codeSecurityCoverage | Should -Be '${{ steps.code_security.outputs.codeSecurityCoverage }}'
        $drift.jobs.module_organization_rulesets.needs | Should -Contain 'module_enterprise_baseline_code_security'
        $drift.jobs.module_organization_rulesets.if | Should -Match "needs.module_enterprise_baseline_code_security.result == 'success'"
        $drift.jobs.module_actions_catalog.needs | Should -Contain 'module_organization_rulesets'
        $drift.jobs.module_enterprise_baseline.needs | Should -Contain 'module_actions_catalog'
    }

    It 'rejects a cycle introduced only by an early-phase dependency before writing workflows' {
        $modules = Join-Path $TestDrive 'phase-cycle-modules'
        Copy-Item -LiteralPath $released -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'enterprise-baseline/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.phases['code-security'].prerequisites = @('organization-rulesets')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $output = Join-Path $TestDrive 'invalid-phase.yml'

        { & (Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1') -ModulesPath $modules -OutputPath $output } |
            Should -Throw '*cycle*'
        { & (Join-Path $toolsPath 'Test-ModuleManifests.ps1') -ModulesPath $modules } |
            Should -Throw '*cycle*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'keeps organization execution inside one job and publishes complete per-organization drift results' {
        $deployPath = Join-Path $TestDrive 'deploy-organizations.yml'
        $driftPath = Join-Path $TestDrive 'drift-organizations.yml'
        $teardownPath = Join-Path $TestDrive 'teardown-organizations.yml'
        & (Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1') -ModulesPath $released -OutputPath $deployPath -DriftOutputPath $driftPath
        & (Join-Path $toolsPath 'Generate-TeardownWorkflow.ps1') -ModulesPath $released -OutputPath $teardownPath
        $deploy = ConvertFrom-Yaml (Get-Content -LiteralPath $deployPath -Raw)
        $drift = ConvertFrom-Yaml (Get-Content -LiteralPath $driftPath -Raw)
        $teardown = ConvertFrom-Yaml (Get-Content -LiteralPath $teardownPath -Raw)

        foreach ($suffix in @('enterprise_baseline', 'organization_rulesets')) {
            $drift.jobs["module_$suffix"].outputs.organizations | Should -Be '${{ steps.run.outputs.organizations }}'
            foreach ($workflow in @($deploy, $drift)) {
                $workflow.jobs["module_$suffix"].Contains('strategy') | Should -BeFalse
                $workflow.jobs["ruleset_plan_organization_rulesets"].Contains('strategy') | Should -BeFalse
            }
            $runs = @($teardown.jobs["destroy_$suffix"].steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run })
            foreach ($run in @($runs | Where-Object { $_ -match 'Invoke-Module\.ps1' })) {
                $run | Should -Match '-PlatformOrganization \$env:GITHUB_REPOSITORY_OWNER'
            }
        }
        $drift.jobs.ruleset_plan_organization_rulesets.outputs.organizations | Should -Be '${{ steps.run.outputs.organizations }}'
        $apply = @($deploy.jobs.apply_organization_rulesets.steps)
        $ordinary = [array]::FindIndex($apply, [Predicate[object]] { param($s) $s.Contains('run') -and $s.run -match 'Invoke-Module.*-Action apply' -and $s.run -notmatch '\s-Rulesets(?:\s|$)' })
        $rulesets = [array]::FindIndex($apply, [Predicate[object]] { param($s) $s.Contains('run') -and $s.run -match 'Invoke-Module.*-Action apply.*\s-Rulesets(?:\s|$)' })
        $upload = [array]::FindIndex($apply, [Predicate[object]] { param($s) $s.Contains('uses') -and $s.uses -like 'actions/upload-artifact@*' })
        $ordinary | Should -BeGreaterOrEqual 0
        $rulesets | Should -BeGreaterThan $ordinary
        $upload | Should -BeGreaterThan $rulesets
        $apply[$upload].with.path | Should -Be './artifacts/module-outputs/organization-rulesets.json'
    }

    It 'declares organizations as a prerequisite of enterprise-baseline' {
        Import-Module (Join-Path $toolsPath 'PlatformTools.psm1') -Force
        $graph = Get-PlatformModuleGraph -ModulesPath $released

        $graph['enterprise-baseline'].prerequisites | Should -Contain 'organizations'
    }

    It 'orders enterprise-baseline after actions-catalog, so the catalog exists before the actions policy blocks upstream actions' {
        $deployPath = Join-Path $TestDrive 'deploy-catalog.yml'
        $driftPath = Join-Path $TestDrive 'drift-catalog.yml'
        $teardownPath = Join-Path $TestDrive 'teardown-catalog.yml'
        & (Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1') -ModulesPath $released -OutputPath $deployPath -DriftOutputPath $driftPath
        & (Join-Path $toolsPath 'Generate-TeardownWorkflow.ps1') -ModulesPath $released -OutputPath $teardownPath
        $deploy = ConvertFrom-Yaml (Get-Content -LiteralPath $deployPath -Raw)
        $teardown = ConvertFrom-Yaml (Get-Content -LiteralPath $teardownPath -Raw)

        $deploy.jobs.apply_enterprise_baseline.needs | Should -Contain 'apply_actions_catalog'
        $deploy.jobs.apply_enterprise_baseline.if | Should -Match "needs\.apply_actions_catalog\.result == 'success'"
        $teardown.jobs.destroy_actions_catalog.needs | Should -Contain 'destroy_enterprise_baseline'
        $teardown.jobs.destroy_enterprise_baseline.needs | Should -Not -Contain 'destroy_actions_catalog'
    }

    It 'orders actions-catalog after organization-rulesets, so the actions organization ruleset exists before the catalog apply' {
        $deployPath = Join-Path $TestDrive 'deploy-rulesets.yml'
        $driftPath = Join-Path $TestDrive 'drift-rulesets.yml'
        $teardownPath = Join-Path $TestDrive 'teardown-rulesets.yml'
        & (Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1') -ModulesPath $released -OutputPath $deployPath -DriftOutputPath $driftPath
        & (Join-Path $toolsPath 'Generate-TeardownWorkflow.ps1') -ModulesPath $released -OutputPath $teardownPath
        $deploy = ConvertFrom-Yaml (Get-Content -LiteralPath $deployPath -Raw)
        $drift = ConvertFrom-Yaml (Get-Content -LiteralPath $driftPath -Raw)
        $teardown = ConvertFrom-Yaml (Get-Content -LiteralPath $teardownPath -Raw)

        foreach ($workflow in @($deploy, $drift)) {
            $workflow.jobs.module_actions_catalog.needs | Should -Contain 'module_organization_rulesets'
            $workflow.jobs.module_actions_catalog.needs | Should -Contain 'ruleset_plan_organization_rulesets'
            $workflow.jobs.ContainsKey('ruleset_plan_enterprise_baseline') | Should -BeFalse
        }
        $deploy.jobs.apply_actions_catalog.needs | Should -Contain 'apply_organization_rulesets'
        $deploy.jobs.apply_actions_catalog.if | Should -Match "needs\.apply_organization_rulesets\.result == 'success'"
        $teardown.jobs.destroy_organization_rulesets.needs | Should -Contain 'destroy_actions_catalog'
        $teardown.jobs.destroy_actions_catalog.needs | Should -Not -Contain 'destroy_organization_rulesets'
    }

    It 'orders enterprise-baseline after <Name> in deploy, drift and teardown regardless of module names' -ForEach @(
        @{ Name = 'organizations' }
        @{ Name = 'aa-organizations' }
        @{ Name = 'zz-organizations' }
    ) {
        $modules = Copy-ReleasedModuleWithRenamedOrganization -OrganizationsName $Name
        $suffix = $Name.Replace('-', '_')
        $deployPath = Join-Path $TestDrive "deploy-$Name.yml"
        $driftPath = Join-Path $TestDrive "drift-$Name.yml"
        $teardownPath = Join-Path $TestDrive "teardown-$Name.yml"
        & (Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1') -ModulesPath $modules -OutputPath $deployPath -DriftOutputPath $driftPath
        & (Join-Path $toolsPath 'Generate-TeardownWorkflow.ps1') -ModulesPath $modules -OutputPath $teardownPath
        $deploy = ConvertFrom-Yaml (Get-Content -LiteralPath $deployPath -Raw)
        $drift = ConvertFrom-Yaml (Get-Content -LiteralPath $driftPath -Raw)
        $teardown = ConvertFrom-Yaml (Get-Content -LiteralPath $teardownPath -Raw)

        foreach ($workflow in @($deploy, $drift)) {
            $workflow.jobs.module_enterprise_baseline.needs | Should -Contain "module_$suffix"
            $workflow.jobs.module_enterprise_baseline.if | Should -Match "needs\.module_$suffix\.result == 'success'"
            $workflow.jobs.ContainsKey('ruleset_plan_enterprise_baseline') | Should -BeFalse
            $workflow.jobs.ruleset_plan_organization_rulesets.needs | Should -Contain "module_$suffix"
        }
        $deploy.jobs.apply_enterprise_baseline.needs | Should -Contain "apply_$suffix"
        $deploy.jobs.apply_enterprise_baseline.if | Should -Match "needs\.apply_$suffix\.result == 'success'"
        $deploy.jobs["apply_$suffix"].needs | Should -Not -Contain 'apply_enterprise_baseline'

        $teardown.jobs["destroy_$suffix"].needs | Should -Contain 'destroy_enterprise_baseline'
        $teardown.jobs["destroy_$suffix"].if | Should -Match "needs\.destroy_enterprise_baseline\.result == 'success'"
        $teardown.jobs.destroy_enterprise_baseline.needs | Should -Not -Contain "destroy_$suffix"
        $teardown.jobs.destroy_enterprise_baseline.needs | Should -Contain "outputs_$suffix"
    }
}
