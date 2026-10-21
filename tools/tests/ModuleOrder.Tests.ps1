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

        $baselinePath = Join-Path $modules 'enterprise-baseline/module.yaml'
        $baseline = ConvertFrom-Yaml (Get-Content -LiteralPath $baselinePath -Raw)
        $baseline.prerequisites = @($baseline.prerequisites | ForEach-Object { if ($_ -ceq 'organizations') { $OrganizationsName } else { $_ } })
        ConvertTo-Yaml $baseline | Set-Content -LiteralPath $baselinePath
        return $modules
    }
}

Describe 'Released module order' {
    It 'declares organizations as a prerequisite of enterprise-baseline' {
        Import-Module (Join-Path $toolsPath 'PlatformTools.psm1') -Force
        $graph = Get-PlatformModuleGraph -ModulesPath $released

        $graph['enterprise-baseline'].prerequisites | Should -Contain 'organizations'
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
            $workflow.jobs.ruleset_plan_enterprise_baseline.needs | Should -Contain "module_$suffix"
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
