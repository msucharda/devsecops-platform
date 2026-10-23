BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $resolve = Join-Path $root 'tools/Resolve-ActionImport.ps1'
}

Describe 'Action import public entry point' {
    BeforeEach {
        $instancePath = Join-Path $TestDrive 'instance.yaml'
        "instance:`n  name: demo`nmodules:`n  actions-catalog:`n    parameters: {}`n" | Set-Content -LiteralPath $instancePath
    }

    It 'derives a catalog target from the complete normalized source identity' {
        $output = Join-Path $TestDrive 'outputs'
        $result = & $resolve -SourceRepository Azure/Login -Tag v2 -InstancePath $instancePath `
            -PlatformOrganization demo-a1b2c3-platform -GitHubOutputPath $output
        $result.TargetRepository | Should -BeExactly 'demo-a1b2c3-actions/azure-login'
        Get-Content $output | Should -Be @(
            'source-repository=azure/login'
            'target-repository=demo-a1b2c3-actions/azure-login'
            'actions-organization=demo-a1b2c3-actions'
        )
    }

    It 'rejects invalid caller inputs <Case> before writing workflow outputs' -ForEach @(
        @{ Case = 'empty repository'; Repository = ''; Tag = 'v1'; Organization = 'demo-platform' }
        @{ Case = 'a subpath'; Repository = 'actions/checkout/subpath'; Tag = 'v1'; Organization = 'demo-platform' }
        @{ Case = 'a newline'; Repository = "actions/checkout`ntarget-repository=evil"; Tag = 'v1'; Organization = 'demo-platform' }
        @{ Case = 'empty tag'; Repository = 'actions/checkout'; Tag = ''; Organization = 'demo-platform' }
        @{ Case = 'whitespace tag'; Repository = 'actions/checkout'; Tag = "v1`ninvalid"; Organization = 'demo-platform' }
        @{ Case = 'another instance'; Repository = 'actions/checkout'; Tag = 'v1'; Organization = 'other-platform' }
    ) {
        $output = Join-Path $TestDrive 'invalid-outputs'
        { & $resolve -SourceRepository $Repository -Tag $Tag -InstancePath $instancePath `
            -PlatformOrganization $Organization -GitHubOutputPath $output } | Should -Throw
        Test-Path $output | Should -BeFalse
    }

    It 'rejects an unlisted upstream that collides with an approved catalog repository' {
        @'
instance:
  name: demo
modules:
  actions-catalog:
    parameters:
      catalog: [a/b-c]
'@ | Set-Content -LiteralPath $instancePath
        $output = Join-Path $TestDrive 'collision-outputs'
        { & $resolve -SourceRepository a-b/c -Tag v1 -InstancePath $instancePath `
            -PlatformOrganization demo-a1b2c3-platform -GitHubOutputPath $output } | Should -Throw '*not in the actions-catalog*'
        Test-Path $output | Should -BeFalse
    }

    It 'accepts the configured canonical upstream instead of assuming the default catalog' {
        "instance:`n  name: demo`nmodules:`n  actions-catalog:`n    parameters:`n      catalog: [a/b-c]`n" |
            Set-Content -LiteralPath $instancePath
        (& $resolve -SourceRepository A/B-C -Tag v1 -InstancePath $instancePath `
                -PlatformOrganization demo-a1b2c3-platform).TargetRepository | Should -BeExactly 'demo-a1b2c3-actions/a-b-c'
    }

    It 'accepts each Terraform default catalog entry through the public resolver' {
        $variables = Get-Content (Join-Path $root 'modules/actions-catalog/variables.tf') -Raw
        $default = [regex]::Match($variables, '(?s)variable "catalog".*?default\s*=\s*\[(.*?)\]').Groups[1].Value
        $entries = @([regex]::Matches($default, '"([^"]+)"') | ForEach-Object { $_.Groups[1].Value })
        $entries.Count | Should -BeGreaterThan 0
        foreach ($entry in $entries) {
            (& $resolve -SourceRepository $entry -Tag v1 -InstancePath $instancePath `
                    -PlatformOrganization demo-a1b2c3-platform).SourceRepository | Should -BeExactly $entry
        }
    }

    It 'rejects invalid catalog state <Case> before writing workflow outputs' -ForEach @(
        @{ Case = 'missing modules'; Modules = '' ; Error = '*requires the actions-catalog module*' }
        @{ Case = 'unselected module'; Modules = 'modules: {}'; Error = '*requires the actions-catalog module*' }
        @{ Case = 'empty catalog'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: []"; Error = '*nonempty list*' }
        @{ Case = 'scalar catalog'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: actions/checkout"; Error = '*nonempty list*' }
        @{ Case = 'null catalog'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: null"; Error = '*nonempty list*' }
        @{ Case = 'numeric entry'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: [123]"; Error = '*canonical lowercase*' }
        @{ Case = 'nested list entry'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: [[actions/checkout]]"; Error = '*canonical lowercase*' }
        @{ Case = 'noncanonical identity'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: [Actions/Checkout]"; Error = '*canonical lowercase*' }
        @{ Case = 'invalid repo name'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: [actions/..]"; Error = '*canonical lowercase*' }
        @{ Case = 'overlong target'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: [a/$('b' * 99)]"; Error = '*canonical lowercase*' }
        @{ Case = 'target collision'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: [a/b-c, a-b/c]"; Error = '*same target repository*' }
        @{ Case = 'duplicate entry'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: [actions/checkout, actions/checkout]"; Error = '*same target repository*' }
        @{ Case = 'unlisted default entry'; Modules = "modules:`n  actions-catalog:`n    parameters:`n      catalog: [azure/login]"; Error = '*not in the actions-catalog*' }
    ) {
        "instance:`n  name: demo`n$Modules`n" | Set-Content -LiteralPath $instancePath
        $output = Join-Path $TestDrive 'invalid-catalog-outputs'
        { & $resolve -SourceRepository actions/checkout -Tag v1 -InstancePath $instancePath `
                -PlatformOrganization demo-a1b2c3-platform -GitHubOutputPath $output } | Should -Throw $Error
        Test-Path $output | Should -BeFalse
    }

    It 'uses the shared protected vendoring entry point without accepting a target override' {
        $workflow = Get-Content (Join-Path $root 'templates/instance/.github/workflows/import-action.yml') -Raw | ConvertFrom-Yaml
        @($workflow.on.Keys) | Should -Be @('workflow_dispatch')
        @($workflow.on.workflow_dispatch.inputs.Keys | Sort-Object) | Should -Be @('repository', 'tag')
        $workflow.jobs.import.uses | Should -BeExactly './.github/workflows/vendor.yml'
        $workflow.jobs.import.with.kind | Should -BeExactly 'action'
        $workflow.jobs.import.with.'private-source' | Should -BeFalse
        $workflow.jobs.import.with.'target-repository' | Should -BeExactly '${{ needs.resolve.outputs.target-repository }}'
    }

    It 'rejects missing writer credential <Missing> before any token job can start' -ForEach @(
        @{ Missing = 'PLATFORM_APP_ID' }
        @{ Missing = 'PLATFORM_APP_INSTALLATION_ID' }
        @{ Missing = 'PLATFORM_APP_ENTERPRISE' }
        @{ Missing = 'PLATFORM_APP_PRIVATE_KEY' }
    ) {
        $workflow = Get-Content (Join-Path $root 'templates/instance/.github/workflows/vendor.yml') -Raw | ConvertFrom-Yaml
        $workflow.jobs.authorize.ContainsKey('environment') | Should -BeFalse
        $workflow.jobs.check_writer.environment | Should -BeExactly '${{ inputs.kind == ''action'' && ''vendoring-action-import'' || ''vendoring-release-import'' }}'
        $workflow.jobs.check_writer.needs | Should -BeExactly 'authorize'
        $workflow.jobs.prepare.needs | Should -BeExactly 'check_writer'
        $check = $workflow.jobs.check_writer.steps | Where-Object name -EQ 'Require configured writer credentials before issuing any token'
        $check | Should -Not -BeNullOrEmpty
        $values = @{
            PLATFORM_APP_ID = '160'; PLATFORM_APP_INSTALLATION_ID = '260'
            PLATFORM_APP_ENTERPRISE = 'example'; PLATFORM_APP_PRIVATE_KEY = 'test-key'
        }
        $saved = @{}
        try {
            foreach ($name in $values.Keys) {
                $saved[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $values[$name])
            }
            & ([scriptblock]::Create($check.run))
            [Environment]::SetEnvironmentVariable($Missing, '')
            { & ([scriptblock]::Create($check.run)) } | Should -Throw '*writer credentials are not configured*'
        }
        finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
}
