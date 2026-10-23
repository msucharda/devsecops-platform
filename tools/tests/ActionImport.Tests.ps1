BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $resolve = Join-Path $root 'tools/Resolve-ActionImport.ps1'
}

Describe 'Action import public entry point' {
    BeforeEach {
        $instancePath = Join-Path $TestDrive 'instance.yaml'
        "instance:`n  name: demo`n" | Set-Content -LiteralPath $instancePath
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
