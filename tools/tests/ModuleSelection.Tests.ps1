BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $selector = Join-Path $toolsPath 'Select-InstanceModules.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
    $releasedModules = Join-Path (Split-Path $toolsPath -Parent) 'modules'
    $header = @'
instance: {name: demo}
regions: {primary: westeurope}
teams:
  platform: [platform@example.test]
  security: [security@example.test]

'@

    function Get-ReleasedPhaseInstance {
        Import-Module (Join-Path $toolsPath 'PlatformTools.psm1')
        $graph = Get-PlatformModuleGraph -ModulesPath $releasedModules
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $toolsPath '../templates/instance/instance.yaml') -Raw)
        $organizations = @('demo-actions', 'demo-platform', 'demo-workloads')
        $reviewers = @{}
        foreach ($organization in $organizations) {
            $reviewers[$organization] = @(@{ reviewer_type = 'TEAM'; reviewer_id = 17 })
        }
        $instance.modules = @{
            organizations = @{ parameters = @{
                admin_logins = @('admin')
                billing_email = 'billing@example.test'
            } }
            'enterprise-baseline' = @{ parameters = @{
                target_organizations = $organizations
                secret_scanning_bypass_reviewers = $reviewers
            } }
            'organization-rulesets' = @{ parameters = @{ target_organizations = $organizations } }
            'actions-catalog' = @{ parameters = @{ target_organizations = $organizations; security_team = 'security' } }
        }
        $instance.githubApps = @{}
        $instance.credentials = @{}
        $appId = 100
        foreach ($name in @('organizations', 'enterprise-baseline', 'organization-rulesets', 'actions-catalog')) {
            $instance.credentials[$name] = @{}
            foreach ($phase in $graph[$name].permissions.githubApp.PSBase.Keys) {
                $declaration = $graph[$name].permissions.githubApp[$phase]
                $alias = "$name-$($phase.ToLowerInvariant())"
                $resources = if ($declaration.resources.Contains('enterprise')) {
                    @{ enterprise = $true }
                }
                else {
                    $scope = @{ organizations = $organizations }
                    if ($declaration.resources.Contains('installationSelection') -and
                        $declaration.resources.installationSelection -ceq 'none') { $scope.repositories = @{} }
                    $scope
                }
                $instance.githubApps[$alias] = @{
                    appId = "$appId"
                    installationId = "$($appId + 100)"
                    enterprise = 'example'
                    permissions = $declaration.permissions
                    resources = $resources
                }
                $instance.credentials[$name][$phase] = @{
                    environment = "$name-$($phase.ToLowerInvariant())"
                    githubApp = $alias
                }
                $appId++
            }
        }
        return $instance
    }
}

Describe 'Instance module selection' {
    BeforeAll {
        $releaseInstancePath = Join-Path $TestDrive 'release-phase-instance.yaml'
        ConvertTo-Yaml (Get-ReleasedPhaseInstance) | Set-Content -LiteralPath $releaseInstancePath
        $workflowPath = Join-Path $TestDrive 'release-phase-deploy.yml'
        & (Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1') -ModulesPath $releasedModules -OutputPath $workflowPath
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $workflowPath -Raw)
    }

    It 'uses the released manifest App permissions instead of an unbound baseline fixture' {
        $baseline = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $releasedModules 'enterprise-baseline/module.yaml') -Raw)
        $rulesets = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $releasedModules 'organization-rulesets/module.yaml') -Raw)
        $catalog = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $releasedModules 'actions-catalog/module.yaml') -Raw)

        $baseline.permissions.githubApp.plan.permissions.organization_administration | Should -Be 'read'
        $baseline.permissions.githubApp.apply.permissions.organization_administration | Should -Be 'write'
        $rulesets.permissions.githubApp.rulesetPlan.permissions.organization_administration | Should -Be 'write'
        $catalog.permissions.githubApp.apply.permissions.administration | Should -Be 'write'
    }

    It 'uses the released manifest credentials and selects only <Scope> phase nodes before promotion' -ForEach @(
        @{
            Scope = 'code-security'
            Nodes = @('enterprise-baseline:code-security', 'organizations')
            Modules = @('enterprise-baseline', 'organizations')
            RulesetModules = @()
        },
        @{
            Scope = 'catalog'
            Nodes = @('actions-catalog', 'enterprise-baseline:code-security', 'organization-rulesets', 'organizations')
            Modules = @('actions-catalog', 'enterprise-baseline', 'organization-rulesets', 'organizations')
            RulesetModules = @('organization-rulesets')
        },
        @{
            Scope = 'full'
            Nodes = @('actions-catalog', 'enterprise-baseline', 'enterprise-baseline:code-security', 'organization-rulesets', 'organizations')
            Modules = @('actions-catalog', 'enterprise-baseline', 'organization-rulesets', 'organizations')
            RulesetModules = @('organization-rulesets')
        }
    ) {
        $output = Join-Path $TestDrive "release-$Scope-selection"
        $json = & $selector -ModulesPath $releasedModules -InstancePath $releaseInstancePath -DeploymentScope $Scope -GitHubOutputPath $output
        $selection = @{}
        foreach ($line in [IO.File]::ReadAllLines($output)) {
            $key, $value = $line.Split('=', 2)
            $selection[$key] = $value
        }

        $json | Should -Be (ConvertTo-Json -InputObject $Modules -Compress)
        @(ConvertFrom-Json -InputObject $selection.phaseNodes) | Should -Be $Nodes
        @(ConvertFrom-Json -InputObject $selection.rulesetModules) | Should -Be $RulesetModules
        (ConvertFrom-Json -AsHashtable -InputObject $selection.environments)['enterprise-baseline'] |
            Should -Be 'enterprise-baseline-plan'
        (ConvertFrom-Json -AsHashtable -InputObject $selection.applyEnvironments)['enterprise-baseline'] |
            Should -Be 'enterprise-baseline-apply'
        if ($Scope -cne 'code-security') {
            (ConvertFrom-Json -AsHashtable -InputObject $selection.rulesetEnvironments)['organization-rulesets'] |
                Should -Be 'organization-rulesets-rulesetplan'
        }
        $workflow.jobs.approve_apply.environment | Should -Be 'approve-apply'
        $workflow.jobs.approve_apply.needs | Should -Contain 'plan_complete'
        $workflow.jobs.authorize.needs | Should -Be 'validate_scope'
        $workflow.jobs.validate.needs | Should -Be 'authorize'
        @($workflow.jobs.select.needs) | Should -Be @('authorize', 'validate')
        $workflow.jobs.validate.Contains('if') | Should -BeFalse
        $workflow.jobs.validate.steps[0].with.ref | Should -Be '${{ needs.authorize.outputs.revision }}'
        $preflight = @($workflow.jobs.authorize.steps | Where-Object { $_.Contains('id') -and $_.id -ceq 'preflight' })
        $preflight.Count | Should -Be 1
        $preflight[0].run | Should -Be './trusted/platform/tools/Test-DeploymentAuthorization.ps1 -Preflight -GitHubOutputPath $env:GITHUB_OUTPUT'
        $configuration = @($workflow.jobs.validate.steps | Where-Object { $_.Contains('run') -and $_.run -match 'Test-InstanceConfiguration\.ps1' })
        $configuration.Count | Should -Be 1
        $configuration[0].run | Should -Be './candidate/platform/tools/Test-InstanceConfiguration.ps1 -InstancePath ./candidate/instance.yaml'
        foreach ($boundary in @('authorize', 'validate')) {
            ConvertTo-Json -InputObject $workflow.jobs[$boundary] -Depth 100 |
                Should -Not -Match 'DEPLOYMENT_SCOPE|inputs\.deployment|DeploymentScope'
        }
        foreach ($node in $Nodes) {
            $suffix = $node.Replace('-', '_').Replace(':', '_')
            $job = $workflow.jobs["module_$suffix"]
            $job.needs | Should -Contain 'authorize'
            $job.needs | Should -Contain 'select'
            $job.if | Should -Match ([regex]::Escape("contains(fromJSON(needs.select.outputs.phaseNodes), '$node')"))
            $job.environment | Should -Be ('${{ fromJSON(needs.select.outputs.environments)[''' + $node.Split(':')[0] + '''] }}')
            $workflow.jobs["apply_$suffix"].needs | Should -Contain 'approve_apply'
        }
        if ($Scope -cne 'full') {
            $selection.phaseNodes | Should -Not -Match '"enterprise-baseline"'
            $workflow.jobs.module_enterprise_baseline.if |
                Should -Match "contains\(fromJSON\(needs.select.outputs.phaseNodes\), 'enterprise-baseline'\)"
        }
        if ($Scope -ceq 'catalog') {
            $workflow.jobs.module_actions_catalog.needs | Should -Contain 'ruleset_plan_organization_rulesets'
            $workflow.jobs.apply_actions_catalog.needs | Should -Contain 'apply_organization_rulesets'
            $workflow.jobs.apply_actions_catalog.if | Should -Match "needs.approve_apply.result == 'success'"
        }
    }

    It 'rejects differently cased and unknown scopes before publishing selections' {
        foreach ($scope in @('Code-Security', 'Catalog', 'CATALOG', 'FULL', 'unexpected', '')) {
            $output = Join-Path $TestDrive "scope-$([guid]::NewGuid())"
            { & $selector -ModulesPath $releasedModules -InstancePath $releaseInstancePath -DeploymentScope $scope -GitHubOutputPath $output } |
                Should -Throw '*DeploymentScope*'
            Test-Path -LiteralPath $output | Should -BeFalse
        }
    }

    It 'rejects an invalid or unconfigured staged deployment before publishing selection' {
        $instance = Join-Path $TestDrive 'invalid-stage.yaml'
        ($header + 'modules: {observer: {}}') | Set-Content -LiteralPath $instance
        $output = Join-Path $TestDrive 'invalid-stage-output'

        { & $selector -ModulesPath $fixtures -InstancePath $instance -DeploymentScope code-security -GitHubOutputPath $output } |
            Should -Throw '*requires a configured enterprise-baseline*'
        { & $selector -ModulesPath $fixtures -InstancePath $instance -DeploymentScope unexpected -GitHubOutputPath $output } |
            Should -Throw
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'adds transitive prerequisites once and excludes unrelated modules' {
        $instance = Join-Path $TestDrive 'instance.yaml'
        $header + @'
modules:
  service:
    parameters: {}
  application: {}
'@ | Set-Content -LiteralPath $instance

        $json = & $selector -ModulesPath $fixtures -InstancePath $instance

        $json | Should -Be '["application","foundation","service"]'
    }

    It 'always returns a JSON array for <Case>' -ForEach @(
        @{ Case = 'no selected modules'; Yaml = 'modules: {}'; Expected = '[]' }
        @{ Case = 'one independent module'; Yaml = 'modules: {observer: {}}'; Expected = '["observer"]' }
        @{ Case = 'a module and its prerequisite'; Yaml = 'modules: {application: {}}'; Expected = '["application","foundation"]' }
    ) {
        $instance = Join-Path $TestDrive 'instance.yaml'
        ($header + $Yaml) | Set-Content -LiteralPath $instance

        & $selector -ModulesPath $fixtures -InstancePath $instance | Should -Be $Expected
    }

    It 'writes the same selection to the GitHub job output without replacing existing outputs' {
        $instance = Join-Path $TestDrive 'instance.yaml'
        ($header + 'modules: {application: {}}') | Set-Content -LiteralPath $instance
        $githubOutput = Join-Path $TestDrive 'github-output'
        [IO.File]::WriteAllText($githubOutput, "previous=value`n")

        $json = & $selector -ModulesPath $fixtures -InstancePath $instance -GitHubOutputPath $githubOutput

        $json | Should -Be '["application","foundation"]'
        [IO.File]::ReadAllText($githubOutput) | Should -Be "previous=value`nmodules=[`"application`",`"foundation`"]`nenvironments={`"application`":`"application-plan`",`"foundation`":`"foundation-plan`"}`napplyEnvironments={`"application`":`"application-apply`",`"foundation`":`"foundation-apply`"}`nrulesetEnvironments={}`nrulesetModules=[]`n"
    }

    It 'can select a module named keys without treating it as a dictionary property' {
        $modules = Join-Path $TestDrive 'member-modules'
        New-Item -ItemType Directory -Path $modules | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixtures 'observer') -Destination (Join-Path $modules 'keys') -Recurse
        $manifestPath = Join-Path $modules 'keys/module.yaml'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw
        $manifest.Replace('name: observer', 'name: keys') | Set-Content -LiteralPath $manifestPath
        $instance = Join-Path $TestDrive 'keys-instance.yaml'
        ($header + 'modules: {keys: {}}') | Set-Content -LiteralPath $instance

        & $selector -ModulesPath $modules -InstancePath $instance | Should -Be '["keys"]'
    }

    It 'validates the full instance and publishes configured plan environments for selected modules' {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $configuration = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $configuration.modules = @{ application = @{} }
        $configuration.credentials = @{
            application = @{
                plan = @{ environment = 'application-read' }
                apply = @{ environment = 'application-write' }
            }
        }
        $instance = Join-Path $TestDrive 'configured.yaml'
        ConvertTo-Yaml $configuration | Set-Content -LiteralPath $instance
        $githubOutput = Join-Path $TestDrive 'environments'

        $null = & $selector -ModulesPath $fixtures -InstancePath $instance -GitHubOutputPath $githubOutput

        [IO.File]::ReadAllText($githubOutput) |
            Should -Match 'environments=\{"application":"application-read","foundation":"foundation-plan"\}'
        $configuration.instance.name = 'x'
        ConvertTo-Yaml $configuration | Set-Content -LiteralPath $instance
        { & $selector -ModulesPath $fixtures -InstancePath $instance } | Should -Throw '*$.instance.name*'
    }

    It 'rejects <Case> with an instance configuration path' -ForEach @(
        @{ Case = 'missing modules'; Yaml = ''; Error = '*$.modules*' }
        @{ Case = 'a module list'; Yaml = 'modules: [application]'; Error = '*$.modules*' }
        @{ Case = 'null modules'; Yaml = 'modules: null'; Error = '*$.modules*' }
        @{ Case = 'a non-mapping module configuration'; Yaml = 'modules: {application: true}'; Error = '*$.modules.application*' }
        @{ Case = 'an unknown module'; Yaml = 'modules: {missing: {}}'; Error = '*$.modules.missing*unknown*missing*' }
        @{ Case = 'an invalid module name'; Yaml = 'modules: {Application: {}}'; Error = '*$.modules.Application*' }
        @{ Case = 'multiple YAML documents'; Yaml = "modules: {}`n---`nmodules: {}"; Error = '*one YAML mapping*invalid-instance*' }
        @{ Case = 'duplicate YAML keys'; Yaml = "modules: {}`nmodules: {}"; Error = '*invalid-instance*Duplicate key*' }
    ) {
        $instance = Join-Path $TestDrive 'invalid-instance.yaml'
        ($header + $Yaml) | Set-Content -LiteralPath $instance
        $githubOutput = Join-Path $TestDrive 'not-written'

        { & $selector -ModulesPath $fixtures -InstancePath $instance -GitHubOutputPath $githubOutput } |
            Should -Throw $Error
        Test-Path -LiteralPath $githubOutput | Should -BeFalse
    }
}
