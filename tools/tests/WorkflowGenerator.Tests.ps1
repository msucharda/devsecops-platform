BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $generator = Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'

    function New-ModuleGraphFixture {
        [CmdletBinding(SupportsShouldProcess)]
        param(
            [Parameter(Mandatory)][string] $ModuleName,
            [Parameter(Mandatory)][scriptblock] $Change
        )

        $modules = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        if (-not $PSCmdlet.ShouldProcess($modules, 'Create module graph fixture')) {
            return
        }
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules "$ModuleName/module.yaml"
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        & $Change $manifest
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        return $modules
    }
}

Describe 'Deployment workflow generation' {
    It 'loads the released enterprise-baseline manifest with phase-separated App access and enterprise prerequisites' {
        Import-Module (Join-Path $toolsPath 'PlatformTools.psm1') -Force
        $released = Join-Path (Split-Path $toolsPath -Parent) 'modules'

        $manifest = (Get-PlatformModuleGraph -ModulesPath $released)['enterprise-baseline']

        $manifest.permissions.githubApp.plan.permissions.Keys | Should -Be @('organization_administration')
        $manifest.permissions.githubApp.plan.permissions.organization_administration | Should -Be 'read'
        $manifest.permissions.githubApp.apply.permissions.organization_administration | Should -Be 'write'
        $manifest.permissions.githubApp.rulesetPlan.purpose | Should -Be 'organization-rulesets-full-read'
        foreach ($phase in @('plan', 'apply', 'rulesetPlan')) {
            $manifest.permissions.githubApp[$phase].resources.organizations | Should -Be 'target_organizations'
        }
        @($manifest.permissions.adminPat) | Should -BeNullOrEmpty
        @($manifest.permissions.azure) | Should -BeNullOrEmpty
        @($manifest.permissions.microsoftGraph) | Should -BeNullOrEmpty
        @($manifest.manualPrerequisites | Sort-Object) | Should -Be @(
            'emuUserNamespacesRestricted', 'fineGrainedPatApprovalRequired', 'patMaxLifetime90Days',
            'privateInternalForksDisabled', 'repositoryManagementPoliciesEnforced')
        Test-Path -LiteralPath (Join-Path $released 'enterprise-baseline/rulesets/versions.tf') | Should -BeTrue
    }

    It 'leaves nightly plans to the separate drift workflow' {
        $output = Join-Path $TestDrive 'nightly.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)

        $workflow.on.ContainsKey('schedule') | Should -BeFalse
        $workflow.jobs.module_enterprise_baseline.environment | Should -Be '${{ fromJSON(needs.select.outputs.environments)[''enterprise-baseline''] }}'
        $workflow.jobs.ContainsKey('report_drift') | Should -BeFalse
        @($workflow.jobs.Values | Where-Object { $_.ContainsKey('outputs') -and $_.outputs.ContainsKey('changes') }).Count | Should -Be 0
    }

    It 'rejects write permissions in the ordinary plan before writing a workflow' {
        $modules = New-ModuleGraphFixture -ModuleName application -Change {
            param($manifest)
            $manifest.permissions.adminPat = @()
            $manifest.permissions.githubApp = @{
                plan = @{ permissions = @{ contents = 'write' }; resources = @{ organizations = 'organizations' } }
                apply = @{ permissions = @{ contents = 'write' }; resources = @{ organizations = 'organizations' } }
            }
        }
        $output = Join-Path $TestDrive 'unsafe-plan.yml'

        { & $generator -ModulesPath $modules -OutputPath $output } | Should -Throw '*read-only*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'plans protected PRs and main before a single shared apply approval' {
        $output = Join-Path $TestDrive 'protected-deploy.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)

        $workflow.on.ContainsKey('pull_request_target') | Should -BeTrue
        $workflow.on.push.branches | Should -Be @('main')
        $workflow.jobs.approve_apply.environment | Should -Be 'approve-apply'
        $workflow.jobs.approve_apply.needs | Should -Contain 'plan_complete'
        $workflow.jobs.apply_application.needs | Should -Contain 'approve_apply'
        $workflow.jobs.apply_application.needs | Should -Contain 'apply_foundation'
    }

    It 'ships an instance example accepted by its release schema and assigns the platform team as repository owner' {
        $template = Join-Path (Split-Path $toolsPath -Parent) 'templates/instance'
        { & (Join-Path $toolsPath 'Test-InstanceConfiguration.ps1') -InstancePath (Join-Path $template 'instance.yaml') } |
            Should -Not -Throw
        (Get-Content -LiteralPath (Join-Path $template '.github/CODEOWNERS') -Raw).Trim() |
            Should -Be '* @example-platform/platform'
    }

    It 'creates a deployment job for each module manifest' {
        $output = Join-Path $TestDrive 'deploy.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output

        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        $workflow.jobs.Keys | Should -Contain 'module_foundation'
    }

    It 'makes the application job depend on its foundation prerequisite' {
        $output = Join-Path $TestDrive 'dependencies.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output

        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        $moduleJobs = @($workflow.jobs.Keys | Where-Object { $_ -like 'module_*' } | Sort-Object)
        $moduleJobs | Should -Be @('module_application', 'module_enterprise_baseline', 'module_foundation', 'module_observer', 'module_service')
        $workflow.jobs.module_application.needs | Should -Contain 'module_foundation'
        $workflow.jobs.module_observer.needs | Should -Not -Contain 'module_foundation'
    }

    It 'wires Terraform, prerequisite artifacts and publication of only the runner output file' {
        $output = Join-Path $TestDrive 'runner.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        $job = $workflow.jobs.module_application

        @($job.steps | Where-Object { $_['uses'] -like 'hashicorp/setup-terraform@*' }).Count | Should -Be 1
        $download = $job.steps | Where-Object { $_['uses'] -like 'actions/download-artifact@*' }
        $download.with.name | Should -Be 'plan-outputs-foundation'
        $download.with.path | Should -Be './artifacts/prerequisites'
        $run = $job.steps | Where-Object { $_['name'] -eq 'Run module' }
        $run.run | Should -Match '-PrerequisiteOutputsPath ./artifacts/prerequisites'
        $run.run | Should -Match '-ArtifactsPath ./artifacts/module-outputs'
        $upload = $job.steps | Where-Object { $_['uses'] -like 'actions/upload-artifact@*' }
        $upload.with.path | Should -Be './artifacts/module-outputs/application.json'
        $upload.with.'if-no-files-found' | Should -Be 'error'
        $job.environment | Should -Be '${{ fromJSON(needs.select.outputs.environments)[''application''] }}'
    }

    It 'gates jobs on runtime selection and successful prerequisites without propagating unrelated skips' {
        $output = Join-Path $TestDrive 'selection.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output

        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        $workflow.jobs.select.outputs.modules | Should -Be '${{ steps.modules.outputs.modules }}'
        $workflow.jobs.module_application.needs | Should -Be @('authorize', 'select', 'module_foundation')
        $workflow.jobs.module_observer.needs | Should -Be @('authorize', 'select')
        $workflow.jobs.module_application.if | Should -Be '${{ !cancelled() && needs.authorize.outputs.allowed == ''true'' && needs.select.result == ''success'' && contains(fromJSON(needs.select.outputs.modules), ''application'') && needs.module_foundation.result == ''success'' }}'
        $workflow.jobs.module_observer.if | Should -Be '${{ !cancelled() && needs.authorize.outputs.allowed == ''true'' && needs.select.result == ''success'' && contains(fromJSON(needs.select.outputs.modules), ''observer'') }}'
        $workflow.jobs.select.steps[-1].run | Should -Match 'trusted/platform/tools/Select-InstanceModules\.ps1 @arguments'
        $workflow.jobs.select.steps[-1].run | Should -Match 'TrustedInstancePath'
    }

    It 'produces identical bytes despite directory creation order and prerequisite ordering' {
        $modules = Join-Path $TestDrive 'reordered'
        New-Item -ItemType Directory -Path $modules | Out-Null
        foreach ($name in @('service', 'observer', 'enterprise-baseline', 'foundation', 'application')) {
            Copy-Item -LiteralPath (Join-Path $fixtures $name) -Destination $modules -Recurse
        }
        $manifestPath = Join-Path $modules 'service/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.prerequisites = @('foundation', 'application')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $first = Join-Path $TestDrive 'first.yml'
        $second = Join-Path $TestDrive 'second.yml'

        & $generator -ModulesPath $fixtures -OutputPath $first
        & $generator -ModulesPath $modules -OutputPath $second

        [Convert]::ToBase64String([IO.File]::ReadAllBytes($first)) |
            Should -Be ([Convert]::ToBase64String([IO.File]::ReadAllBytes($second)))
        [IO.File]::ReadAllBytes($first)[0] | Should -Be 35
        [IO.File]::ReadAllText($first) | Should -Not -Match "`r"
    }

    It 'isolates complete ruleset plans and preserves the additional security apply environment' {
        $output = Join-Path $TestDrive 'ruleset.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        $job = $workflow.jobs.ruleset_plan_enterprise_baseline

        $job.environment | Should -Be '${{ fromJSON(needs.select.outputs.rulesetEnvironments)[''enterprise-baseline''] }}'
        $job.needs | Should -Be @('authorize', 'select', 'module_service', 'module_enterprise_baseline')
        $job.if | Should -Match "contains.*enterprise-baseline.*needs.module_service.result == 'success'.*needs.module_enterprise_baseline.result == 'success'"
        ($job.steps | Where-Object { $_['name'] -eq 'Run module' }).run | Should -Match '-Action plan.*-Rulesets$'
        ($job.steps | Where-Object { $_['name'] -like 'Issue a phase*' }).run | Should -Match '-Phase rulesetPlan'
        $workflow.jobs.module_enterprise_baseline.environment | Should -Be '${{ fromJSON(needs.select.outputs.environments)[''enterprise-baseline''] }}'
        $workflow.jobs.apply_enterprise_baseline.environment | Should -Be '${{ fromJSON(needs.select.outputs.applyEnvironments)[''enterprise-baseline''] }}'
        $workflow.jobs.plan_complete.needs | Should -Contain 'ruleset_plan_enterprise_baseline'
        ($workflow.jobs.apply_enterprise_baseline.steps | Where-Object { $_['name'] -like 'Apply the complete*' }).run | Should -Match '-Action apply.*-Rulesets$'
    }

    It 'waits for both roots of a prerequisite before releasing dependent plan credentials' {
        $modules = New-ModuleGraphFixture -ModuleName observer -Change {
            param($manifest)
            $manifest.prerequisites = @('enterprise-baseline')
        }
        $output = Join-Path $TestDrive 'ruleset-prerequisite.yml'
        & $generator -ModulesPath $modules -OutputPath $output
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)

        $workflow.jobs.module_observer.needs | Should -Contain 'module_enterprise_baseline'
        $workflow.jobs.module_observer.needs | Should -Contain 'ruleset_plan_enterprise_baseline'
        $workflow.jobs.module_observer.if | Should -Match "needs.ruleset_plan_enterprise_baseline.result == 'success'"
    }

    It 'pins all upstream actions and uses secretless Azure OIDC only in credential jobs' {
        $output = Join-Path $TestDrive 'oidc.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)

        foreach ($job in $workflow.jobs.Values) {
            $job.'runs-on' | Should -Be 'ubuntu-latest'
            foreach ($step in $job.steps) {
                if ($step.ContainsKey('uses')) { $step.uses | Should -Match '@[0-9a-f]{40}$' }
            }
        }
        foreach ($id in @('module_application', 'ruleset_plan_enterprise_baseline', 'apply_application')) {
            $workflow.jobs[$id].permissions.'id-token' | Should -Be 'write'
            $login = $workflow.jobs[$id].steps | Where-Object { $_['uses'] -like 'Azure/login@*' }
            $login.with.'client-id' | Should -Be '${{ vars.AZURE_CLIENT_ID }}'
            $login.with.Keys | Should -Not -Contain 'creds'
        }
        $workflow.jobs.validate.ContainsKey('environment') | Should -BeFalse
        $workflow.jobs.select.ContainsKey('environment') | Should -BeFalse
    }

    It 'uses immutable base tools for authorization and gates every candidate credential job' {
        $output = Join-Path $TestDrive 'authorization.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        $authorization = $workflow.jobs.authorize
        $authorization.environment | Should -Be 'pr-authorization'
        $authorization.steps[0].with.ref | Should -Be '${{ github.event.pull_request.base.sha || github.sha }}'
        $authorization.steps[0].with.'persist-credentials' | Should -BeFalse
        $authorization.steps[1].run | Should -Match '-Preflight'
        $authorization.steps[3].if | Should -Be '${{ steps.preflight.outputs.eligible == ''true'' }}'
        @($authorization.steps | Where-Object { $_['uses'] -like 'actions/checkout@*' }).Count | Should -Be 1
        $workflow.jobs.validate.steps[-1].run | Should -Match 'candidate/platform/tools/Test-InstanceConfiguration'
        $workflow.jobs.select.needs | Should -Contain 'validate'
        foreach ($id in @($workflow.jobs.Keys | Where-Object { $_ -match '^(module_|apply_|ruleset_plan_)' })) {
            $workflow.jobs[$id].needs | Should -Contain 'authorize'
            $workflow.jobs[$id].if | Should -Match "needs.authorize.outputs.allowed == 'true'"
        }
    }

    It 'rejects a ruleset exception with undeclared broader privileges' {
        $modules = New-ModuleGraphFixture -ModuleName enterprise-baseline -Change {
            param($manifest)
            $manifest.permissions.githubApp.rulesetPlan.permissions.contents = 'write'
        }
        { & $generator -ModulesPath $modules -OutputPath (Join-Path $TestDrive 'invalid-exception.yml') } |
            Should -Throw '*rulesetPlan*only organization_administration*'
    }

    It 'checks committed output without rewriting stale content' {
        $output = Join-Path $TestDrive 'checked.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        { & $generator -ModulesPath $fixtures -OutputPath $output -Check } | Should -Not -Throw
        [IO.File]::WriteAllText($output, 'stale workflow')

        { & $generator -ModulesPath $fixtures -OutputPath $output -Check } |
            Should -Throw '*workflow differs*'
        [IO.File]::ReadAllText($output) | Should -Be 'stale workflow'
    }

    It 'keeps validation, authorization and explicit plan reporting when no executable modules exist' {
        $modules = Join-Path $TestDrive 'empty-modules'
        New-Item -ItemType Directory -Path $modules | Out-Null
        $output = Join-Path $TestDrive 'empty.yml'

        & $generator -ModulesPath $modules -OutputPath $output

        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        @($workflow.jobs.Keys | Sort-Object) | Should -Be @('approve_apply', 'authorize', 'plan_complete', 'select', 'validate')
    }

    It 'supports module names matching dictionary members or the selection job: <Name>' -ForEach @(
        @{ Name = 'keys' }
        @{ Name = 'values' }
        @{ Name = 'count' }
        @{ Name = 'select' }
        @{ Name = 'null' }
        @{ Name = 'true' }
        @{ Name = 'false' }
    ) {
        $modules = Join-Path $TestDrive "member-$Name"
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        Copy-Item -LiteralPath (Join-Path $fixtures 'observer') -Destination (Join-Path $modules $Name) -Recurse
        $manifestPath = Join-Path $modules "$Name/module.yaml"
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.name = $Name
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $output = Join-Path $TestDrive "$Name.yml"

        & $generator -ModulesPath $modules -OutputPath $output

        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        $workflow.jobs.Keys | Should -Contain "module_$Name"
        $workflow.jobs["module_$Name"].name | Should -BeExactly $Name
        $workflow.jobs.Keys | Should -Contain 'module_application'
        $workflow.jobs.Keys | Should -Contain 'select'
    }

    It 'rejects <Case> in a manifest and identifies its file' -ForEach @(
        @{ Case = 'multiple YAML documents'; Kind = 'multiple'; Error = '*one YAML mapping*application*' }
        @{ Case = 'duplicate YAML keys'; Kind = 'duplicate'; Error = '*application*Duplicate key*' }
        @{ Case = 'a YAML sequence instead of a mapping'; Kind = 'sequence'; Error = '*one YAML mapping*application*' }
    ) {
        $modules = Join-Path $TestDrive "yaml-$Kind"
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'application/module.yaml'
        $yaml = Get-Content -LiteralPath $manifestPath -Raw
        switch ($Kind) {
            'multiple' { $yaml += "`n---`nname: extra`n" }
            'duplicate' { $yaml += "`nname: duplicate`n" }
            'sequence' { $yaml = "-`n" + (($yaml -split "`n" | ForEach-Object { "  $_" }) -join "`n") }
        }
        $yaml | Set-Content -LiteralPath $manifestPath

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw $Error
    }

    It 'rejects manual prerequisite <Case> in a manifest' -ForEach @(
        @{ Case = 'names unknown to the instance schema'; Value = @('repositoryCreationDisabled'); Error = '*application*unknown manual prerequisite*repositoryCreationDisabled*' }
        @{ Case = 'duplicates'; Value = @('licenses', 'licenses'); Error = '*application*' }
        @{ Case = 'a non-list value'; Value = 'licenses'; Error = '*application*' }
    ) {
        $modules = New-ModuleGraphFixture -ModuleName application -Change {
            param($manifest)
            $manifest.manualPrerequisites = $Value
        }

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw $Error
    }

    It 'rejects duplicate manual step identifiers even if their descriptions differ' {
        $modules = New-ModuleGraphFixture -ModuleName application -Change {
            param($manifest)
            $manifest.manualSteps += @{ id = 'verify-access'; description = 'A different description.' }
        }

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw '*application*duplicate manual step*verify-access*'
    }

    It 'rejects module names that do not match their directory' {
        $modules = New-ModuleGraphFixture -ModuleName observer -Change {
            param($manifest)
            $manifest.name = 'different'
        }

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw '*different*directory*observer*'
    }

    It 'rejects <Case> and names the affected modules without writing a workflow' -ForEach @(
        @{ Case = 'a missing prerequisite'; Module = 'application'; Prerequisites = '[missing]'; Error = "*application*missing*" }
        @{ Case = 'a prerequisite cycle'; Module = 'foundation'; Prerequisites = '[application]'; Error = "*Prerequisite cycle*application*foundation*application*" }
        @{ Case = 'a self cycle'; Module = 'observer'; Prerequisites = '[observer]'; Error = "*Prerequisite cycle*observer*observer*" }
    ) {
        $modules = New-ModuleGraphFixture -ModuleName $Module -Change {
            param($manifest)
            $manifest.prerequisites = ConvertFrom-Yaml $Prerequisites
        }
        $output = Join-Path $modules 'invalid.yml'

        { & $generator -ModulesPath $modules -OutputPath $output } | Should -Throw $Error
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects an invalid manifest value for <Field>' -ForEach @(
        @{ Field = 'name'; Value = 'application; echo unsafe' }
        @{ Field = 'description'; Value = ' ' }
        @{ Field = 'prerequisites'; Value = @('foundation', 42) }
        @{ Field = 'manualSteps'; Value = @(@{ id = 'Bad ID'; description = 'Verify access.' }) }
        @{ Field = 'manualSteps'; Value = @(@{ id = 'verify'; description = '' }) }
        @{ Field = 'permissions.azure'; Value = @(@{ role = 'Reader'; scope = '' }) }
        @{ Field = 'permissions.azure'; Value = @(@{ role = 42; scope = '/subscriptions/example' }) }
        @{ Field = 'permissions.microsoftGraph'; Value = @(42) }
        @{ Field = 'permissions.githubApp'; Value = @{ contents = 'admin' } }
        @{ Field = 'permissions.adminPat'; Value = @(42) }
        @{ Field = 'unexpected'; Value = 'unknown property' }
    ) {
        $modules = New-ModuleGraphFixture -ModuleName application -Change {
            param($manifest)
            $segments = $Field.Split('.')
            $parent = $manifest
            foreach ($segment in $segments[0..($segments.Count - 1)] | Select-Object -SkipLast 1) {
                $parent = $parent[$segment]
            }
            $parent[$segments[-1]] = $Value
        }

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw '*Invalid module manifest*application*'
    }

    It 'rejects a manifest missing required <Field>' -ForEach @(
        @{ Field = 'name' }
        @{ Field = 'description' }
        @{ Field = 'prerequisites' }
        @{ Field = 'manualSteps' }
        @{ Field = 'permissions' }
        @{ Field = 'permissions.azure' }
        @{ Field = 'permissions.microsoftGraph' }
        @{ Field = 'permissions.githubApp' }
        @{ Field = 'permissions.adminPat' }
    ) {
        $modules = New-ModuleGraphFixture -ModuleName application -Change {
            param($manifest)
            $segments = $Field.Split('.')
            if ($segments.Count -eq 1) {
                $manifest.Remove($Field)
            }
            else {
                $manifest.permissions.Remove($segments[1])
            }
        }

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw '*Invalid module manifest*application*'
    }
}

Describe 'Drift workflow generation' {
    BeforeAll {
        $directory = Join-Path $TestDrive 'drift-generated'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $deployPath = Join-Path $directory 'deploy.yml'
        & $generator -ModulesPath $fixtures -OutputPath $deployPath
        $driftPath = Join-Path $directory 'drift.yml'
        $drift = ConvertFrom-Yaml (Get-Content -LiteralPath $driftPath -Raw)
        $planJobs = @($drift.jobs.Keys | Where-Object { $_ -match '^(module_|ruleset_plan_)' } | Sort-Object)
    }

    It 'writes the drift workflow next to the deployment workflow by default' {
        [IO.File]::ReadAllBytes($driftPath)[0] | Should -Be 35
        [IO.File]::ReadAllText($driftPath) | Should -Not -Match "`r"
        [IO.File]::ReadAllText($driftPath) | Should -Match '^# Generated by tools/Generate-DeploymentWorkflow\.ps1\. Do not edit\.'
    }

    It 'writes the drift workflow to an explicit path' {
        $output = Join-Path $TestDrive 'explicit-deploy.yml'
        $explicit = Join-Path $TestDrive 'explicit-drift.yml'

        & $generator -ModulesPath $fixtures -OutputPath $output -DriftOutputPath $explicit

        [IO.File]::ReadAllText($explicit) | Should -BeExactly ([IO.File]::ReadAllText($driftPath))
    }

    It 'runs nightly and on demand, never for pull requests or pushes' {
        $drift.on.schedule[0].cron | Should -Be '17 2 * * *'
        @($drift.on.Keys | Sort-Object) | Should -Be @('schedule', 'workflow_dispatch')
        $drift.permissions.Keys | Should -Be @('contents')
        $drift.permissions.contents | Should -Be 'read'
        $drift.concurrency['cancel-in-progress'] | Should -BeFalse
    }

    It 'authorizes only the immutable main revision without any App key' {
        $job = $drift.jobs.authorize

        $job.ContainsKey('environment') | Should -BeFalse
        $job.outputs.allowed | Should -Be '${{ steps.preflight.outputs.allowed }}'
        $job.outputs.revision | Should -Be '${{ steps.preflight.outputs.revision }}'
        $job.steps[0].with.ref | Should -Be '${{ github.event.pull_request.base.sha || github.sha }}'
        $job.steps[-1].run | Should -Match 'Test-DeploymentAuthorization\.ps1 -Preflight'
        (ConvertTo-Json $job -Depth 20) | Should -Not -Match 'PRIVATE_KEY|New-PlatformGitHubToken'
        $drift.jobs.select.steps[-1].run | Should -Not -Match 'TrustedInstancePath'
    }

    It 'plans every module in its separate read-only drift environment and publishes only the change state' {
        $planJobs | Should -Be @('module_application', 'module_enterprise_baseline', 'module_foundation', 'module_observer', 'module_service', 'ruleset_plan_enterprise_baseline')
        foreach ($id in $planJobs) {
            $job = $drift.jobs[$id]
            $job.outputs.changes | Should -Be '${{ steps.run.outputs.changes }}'
            $run = $job.steps | Where-Object { $_['name'] -eq 'Run module' }
            $run.id | Should -Be 'run'
            $run.run | Should -Match '-Action plan .*-GitHubOutputPath \$env:GITHUB_OUTPUT'
            $job.permissions.Keys | Sort-Object | Should -Be @('contents', 'id-token')
            $job.permissions.contents | Should -Be 'read'
            (ConvertTo-Json $job -Depth 20) | Should -Not -Match 'Publish-DriftIssue|-DriftReport|issues'
            @($job.steps | Where-Object { $_['run'] -match '-Action apply' }).Count | Should -Be 0
        }
        $drift.jobs.module_application.environment | Should -Be '${{ format(''{0}-drift'', fromJSON(needs.select.outputs.environments)[''application'']) }}'
        $drift.jobs.module_application.needs | Should -Contain 'module_foundation'
    }

    It 'keeps the enterprise-baseline ruleset key in a separate drift environment with a bypass check' {
        $ruleset = $drift.jobs.ruleset_plan_enterprise_baseline
        $plan = $drift.jobs.module_enterprise_baseline

        $ruleset.environment | Should -Be '${{ format(''{0}-drift'', fromJSON(needs.select.outputs.rulesetEnvironments)[''enterprise-baseline'']) }}'
        $plan.environment | Should -Be '${{ format(''{0}-drift'', fromJSON(needs.select.outputs.environments)[''enterprise-baseline'']) }}'
        ($ruleset.steps | Where-Object { $_['name'] -like 'Issue a phase*' }).run | Should -Match '-Phase rulesetPlan'
        ($plan.steps | Where-Object { $_['name'] -like 'Issue a phase*' }).run | Should -Match '-Phase plan'
        ($ruleset.steps | Where-Object { $_['name'] -eq 'Run module' }).run | Should -Match '-Rulesets -GitHubOutputPath'
        $names = @($ruleset.steps | ForEach-Object { $_['name'] })
        $bypassIndex = [array]::IndexOf($names, 'Check ruleset bypass visibility')
        $bypassIndex | Should -BeGreaterThan 0
        $bypassIndex | Should -BeLessThan ([array]::IndexOf($names, 'Revoke the job installation tokens'))
        $ruleset.steps[$bypassIndex].id | Should -Be 'bypass'
        $ruleset.steps[$bypassIndex].run | Should -Match 'trusted/platform/tools/Test-RulesetBypassVisibility\.ps1 -GitHubOutputPath \$env:GITHUB_OUTPUT'
        $ruleset.outputs.inheritedRulesets | Should -Be '${{ steps.bypass.outputs.inheritedRulesets }}'
        $plan.outputs.ContainsKey('inheritedRulesets') | Should -BeFalse
    }

    It 'reports drift in a separate job with the only issue-write credential' {
        $job = $drift.jobs.report_drift

        $job.environment | Should -Be 'drift-report'
        $job.if | Should -Be '${{ !cancelled() && github.ref == ''refs/heads/main'' }}'
        @($job.needs | Sort-Object) | Should -Be (@('authorize', 'select', 'validate') + $planJobs | Sort-Object)
        $job.permissions.Keys | Should -Be @('contents')
        $job.ContainsKey('outputs') | Should -BeFalse
        $evaluate = $job.steps | Where-Object { $_['id'] -eq 'evaluate' }
        $evaluate.env.DRIFT_NEEDS | Should -Be '${{ toJSON(needs) }}'
        $evaluate.run | Should -Match 'trusted/platform/tools/Get-DriftReport\.ps1 '
        $token = $job.steps | Where-Object { $_['run'] -match 'New-PlatformGitHubToken' }
        $token.run | Should -Match 'New-PlatformGitHubToken\.ps1 -DriftReport$'
        $token.if | Should -Be '${{ steps.evaluate.outputs.report == ''true'' }}'
        ($job.steps | Where-Object { $_['run'] -match 'Publish-DriftIssue' }).if | Should -Be '${{ steps.evaluate.outputs.report == ''true'' }}'
        ($job.steps | Where-Object { $_['run'] -match 'Remove-PlatformGitHubToken' }).if | Should -Be '${{ always() && env.PLATFORM_GITHUB_TOKENS != '''' }}'
        $job.steps[-1].if | Should -Be '${{ steps.evaluate.outputs.complete != ''true'' }}'
        (ConvertTo-Json $job -Depth 20) | Should -Not -Match 'candidate|id-token|Azure/login'
        @($drift.jobs.Keys | Where-Object { (ConvertTo-Json $drift.jobs[$_] -Depth 20) -match '-DriftReport' }) | Should -Be @('report_drift')
    }

    It 'pins actions and never runs an apply or approval' {
        foreach ($job in $drift.jobs.Values) {
            foreach ($step in $job.steps) {
                if ($step.ContainsKey('uses')) { $step.uses | Should -Match '@[0-9a-f]{40}$' }
            }
        }
        @($drift.jobs.Keys | Where-Object { $_ -match '^(apply_|approve_)' }).Count | Should -Be 0
        [IO.File]::ReadAllText($driftPath) | Should -Not -Match '-Action apply|approve-apply|pr-authorization'
    }

    It 'checks the committed drift workflow without rewriting it' {
        $directory = Join-Path $TestDrive 'drift-check'
        New-Item -ItemType Directory -Path $directory | Out-Null
        $output = Join-Path $directory 'deploy.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        { & $generator -ModulesPath $fixtures -OutputPath $output -Check } | Should -Not -Throw
        [IO.File]::WriteAllText((Join-Path $directory 'drift.yml'), 'stale drift')

        { & $generator -ModulesPath $fixtures -OutputPath $output -Check } | Should -Throw '*workflow differs*drift.yml*'
        [IO.File]::ReadAllText((Join-Path $directory 'drift.yml')) | Should -Be 'stale drift'
        Remove-Item -LiteralPath (Join-Path $directory 'drift.yml')
        { & $generator -ModulesPath $fixtures -OutputPath $output -Check } | Should -Throw '*workflow differs*drift.yml*'
    }

    It 'keeps authorization, validation and fail-closed reporting when no modules exist' {
        $modules = Join-Path $TestDrive 'drift-empty-modules'
        New-Item -ItemType Directory -Path $modules | Out-Null
        $output = Join-Path $TestDrive 'drift-empty.yml'
        $emptyDrift = Join-Path $TestDrive 'drift-empty-drift.yml'

        & $generator -ModulesPath $modules -OutputPath $output -DriftOutputPath $emptyDrift

        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $emptyDrift -Raw)
        @($workflow.jobs.Keys | Sort-Object) | Should -Be @('authorize', 'report_drift', 'select', 'validate')
        $workflow.jobs.report_drift.needs | Should -Be @('authorize', 'validate', 'select')
    }
}