BeforeAll {
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $selector = Join-Path $toolsPath 'Select-InstanceModules.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
    $header = @'
instance: {name: demo}
regions: {primary: westeurope}
teams:
  platform: [platform@example.test]
  security: [security@example.test]

'@
}

Describe 'Instance module selection' {
    It 'keeps the early phase but not the late baseline when deploying rulesets or the catalog before workflow promotion' {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $modules = Join-Path $TestDrive 'catalog-phase-modules'
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $baselinePath = Join-Path $modules 'enterprise-baseline/module.yaml'
        $baseline = ConvertFrom-Yaml (Get-Content -LiteralPath $baselinePath -Raw)
        $baseline.prerequisites = @('actions-catalog')
        $baseline.permissions.githubApp = @{}
        $baseline.phases = @{ 'code-security' = @{ prerequisites = @('foundation') } }
        ConvertTo-Yaml $baseline | Set-Content -LiteralPath $baselinePath
        New-Item -ItemType Directory -Path (Join-Path $modules 'enterprise-baseline/code-security') | Out-Null
        foreach ($name in @('organization-rulesets', 'actions-catalog')) {
            Copy-Item -LiteralPath (Join-Path $fixtures 'observer') -Destination (Join-Path $modules $name) -Recurse
            $manifestPath = Join-Path $modules "$name/module.yaml"
            $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
            $manifest.name = $name
            $manifest.prerequisites = @('organization-rulesets')
            if ($name -eq 'organization-rulesets') {
                $manifest.prerequisites = @('enterprise-baseline:code-security')
            }
            ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        }

        foreach ($case in @(
            @{ Module = 'organization-rulesets'; Nodes = @('enterprise-baseline:code-security', 'foundation', 'organization-rulesets') },
            @{ Module = 'actions-catalog'; Nodes = @('actions-catalog', 'enterprise-baseline:code-security', 'foundation', 'organization-rulesets') }
        )) {
            $instance = Join-Path $TestDrive "$($case.Module)-instance.yaml"
            $output = Join-Path $TestDrive "$($case.Module)-selection"
            ($header + "modules: {$($case.Module): {}}") | Set-Content -LiteralPath $instance

            $null = & $selector -ModulesPath $modules -InstancePath $instance -DeploymentScope full -GitHubOutputPath $output

            $selection = @{}
            foreach ($line in [IO.File]::ReadAllLines($output)) {
                $key, $value = $line.Split('=', 2)
                $selection[$key] = $value
            }
            @(ConvertFrom-Json $selection.phaseNodes) | Should -Be $case.Nodes
            @(ConvertFrom-Json $selection.modules) | Should -Contain 'enterprise-baseline'
            (ConvertFrom-Json -AsHashtable $selection.environments)['enterprise-baseline'] |
                Should -Be 'enterprise-baseline-plan'
            $selection.phaseNodes | Should -Not -Match '"enterprise-baseline"'
        }
    }

    It 'rejects differently cased deployment scopes instead of selecting the full graph' {
        $instance = Join-Path $TestDrive 'case-scope-instance.yaml'
        ($header + 'modules: {application: {}}') | Set-Content -LiteralPath $instance
        foreach ($scope in @('Code-Security', 'CODE-SECURITY', 'FULL')) {
            $output = Join-Path $TestDrive "scope-$scope-output"
            { & $selector -ModulesPath $fixtures -InstancePath $instance -DeploymentScope $scope -GitHubOutputPath $output } |
                Should -Throw '*DeploymentScope*'
            Test-Path -LiteralPath $output | Should -BeFalse
        }
    }

    It 'selects only the early Code Security node and its recursive prerequisites for staged deployment' {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $modules = Join-Path $TestDrive 'phase-modules'
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $baselinePath = Join-Path $modules 'enterprise-baseline/module.yaml'
        $baseline = ConvertFrom-Yaml (Get-Content -LiteralPath $baselinePath -Raw)
        $baseline.prerequisites = @('service')
        $baseline.permissions.githubApp = @{}
        $baseline.phases = @{ 'code-security' = @{ prerequisites = @('application') } }
        ConvertTo-Yaml $baseline | Set-Content -LiteralPath $baselinePath
        New-Item -ItemType Directory -Path (Join-Path $modules 'enterprise-baseline/code-security') | Out-Null
        $instance = Join-Path $TestDrive 'phase-instance.yaml'
        ($header + 'modules: {enterprise-baseline: {}}') | Set-Content -LiteralPath $instance
        $stageOutput = Join-Path $TestDrive 'stage-output'
        $fullOutput = Join-Path $TestDrive 'full-output'

        $stage = & $selector -ModulesPath $modules -InstancePath $instance -DeploymentScope code-security -GitHubOutputPath $stageOutput
        $full = & $selector -ModulesPath $modules -InstancePath $instance -DeploymentScope full -GitHubOutputPath $fullOutput

        $stage | Should -Be '["application","enterprise-baseline","foundation"]'
        ([IO.File]::ReadAllText($stageOutput)) | Should -Match 'phaseNodes=\["application","enterprise-baseline:code-security","foundation"\]'
        ([IO.File]::ReadAllText($stageOutput)) | Should -Not -Match 'phaseNodes=.*"enterprise-baseline",'
        ([IO.File]::ReadAllText($stageOutput)) | Should -Match 'rulesetModules=\[\]'
        $full | Should -Be '["application","enterprise-baseline","foundation","service"]'
        ([IO.File]::ReadAllText($fullOutput)) | Should -Match 'phaseNodes=\["application","enterprise-baseline","enterprise-baseline:code-security","foundation","service"\]'
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
