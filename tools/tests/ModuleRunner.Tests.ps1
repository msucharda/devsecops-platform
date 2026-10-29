BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-Module.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/runner-modules'
    $example = Join-Path $PSScriptRoot 'fixtures/instance.yaml'
}

Describe 'Legacy Code Security transition identity validation' -Tag 'CodeSecurityTransition' {
    BeforeAll {
        $ast = [Management.Automation.Language.Parser]::ParseFile($runner, [ref] $null, [ref] $null)
        $definition = $ast.Find({
            param($node)
            $node -is [Management.Automation.Language.FunctionDefinitionAst] -and
            $node.Name -ceq 'Assert-LegacyCodeSecurityTransition'
        }, $true)
        if ($null -eq $definition) { throw 'Missing legacy Code Security transition guard.' }
        . ([scriptblock]::Create($definition.Extent.Text))
    }

    BeforeEach {
        $late = @{
            values = @{ root_module = @{ resources = @(
                @{ mode = 'managed'; type = 'terraform_data'; name = 'code_security_configuration'; index = 'demo'; values = @{ input = @{ organization = 'demo'; name = 'platform-baseline' } } }
                @{ mode = 'managed'; type = 'terraform_data'; name = 'custom_pattern'; index = 'demo/Old token'; values = @{ input = @{ organization = 'demo'; name = 'Old token' } } }
            ) } }
        }
        $early = ConvertFrom-Json -AsHashtable -InputObject (ConvertTo-Json -Depth 20 -InputObject $late)
        $configured = @(@{ name = 'Old token' })
        $readEarly = { $early }
    }

    It 'accepts matching adopted configuration and pattern identities' {
        { Assert-LegacyCodeSecurityTransition -LateState $late -ReadEarlyState $readEarly -ConfiguredPatterns $configured } |
            Should -Not -Throw
    }

    It 'rejects malformed or unadopted <Case> before forgetting legacy state' -ForEach @(
        @{ Case = 'late values type'; Expected = '*readable late root state*' }
        @{ Case = 'late root type'; Expected = '*readable late root state*' }
        @{ Case = 'configured pattern type'; Expected = '*unique configured customPatterns names*' }
        @{ Case = 'configured pattern name type'; Expected = '*unique configured customPatterns names*' }
        @{ Case = 'configured pattern whitespace'; Expected = '*unique configured customPatterns names*' }
        @{ Case = 'early state type'; Expected = '*readable adopted early root state*' }
        @{ Case = 'early values type'; Expected = '*readable adopted early root state*' }
        @{ Case = 'early root type'; Expected = '*readable adopted early root state*' }
        @{ Case = 'legacy organization type'; Expected = '*unreadable identity in late state*' }
        @{ Case = 'legacy organization whitespace'; Expected = '*unreadable identity in late state*' }
        @{ Case = 'legacy pattern name type'; Expected = '*unreadable identity in late state*' }
        @{ Case = 'legacy configuration name whitespace'; Expected = '*unreadable identity in late state*' }
        @{ Case = 'legacy mode'; Expected = '*unreadable identity in late state*' }
        @{ Case = 'legacy mode case'; Expected = '*unreadable identity in late state*' }
        @{ Case = 'legacy index'; Expected = '*unreadable identity in late state*' }
        @{ Case = 'legacy index case'; Expected = '*unreadable identity in late state*' }
        @{ Case = 'legacy configuration name'; Expected = '*differs from the managed platform-baseline*' }
        @{ Case = 'legacy configuration name case'; Expected = '*differs from the managed platform-baseline*' }
        @{ Case = 'adopted input type'; Expected = '*different identity in the early root state*' }
        @{ Case = 'adopted organization case'; Expected = '*different identity in the early root state*' }
        @{ Case = 'adopted pattern name'; Expected = '*different identity in the early root state*' }
        @{ Case = 'adopted pattern name case'; Expected = '*different identity in the early root state*' }
    ) {
        switch ($Case) {
            'late values type' { $late['values'] = 'invalid' }
            'late root type' { $late['values'].root_module = 'invalid' }
            'configured pattern type' { $configured[0] = 'invalid' }
            'configured pattern name type' {
                $configured[0].name = 42
                $late['values'].root_module.resources[1]['values'].input.name = 42
                $early['values'].root_module.resources[1]['values'].input.name = 42
                $late['values'].root_module.resources[1].index = 'demo/42'
                $early['values'].root_module.resources[1].index = 'demo/42'
            }
            'configured pattern whitespace' { $configured[0].name = ' ' }
            'early state type' { $early = 'invalid' }
            'early values type' { $early['values'] = 'invalid' }
            'early root type' { $early['values'].root_module = 'invalid' }
            'legacy organization type' {
                $late['values'].root_module.resources[1]['values'].input.organization = 42
                $early['values'].root_module.resources[1]['values'].input.organization = 42
                $late['values'].root_module.resources[1].index = '42/Old token'
                $early['values'].root_module.resources[1].index = '42/Old token'
            }
            'legacy organization whitespace' {
                $late['values'].root_module.resources[1]['values'].input.organization = ' '
                $early['values'].root_module.resources[1]['values'].input.organization = ' '
                $late['values'].root_module.resources[1].index = ' /Old token'
                $early['values'].root_module.resources[1].index = ' /Old token'
            }
            'legacy pattern name type' {
                $configured[0].name = '42'
                $late['values'].root_module.resources[1]['values'].input.name = 42
                $early['values'].root_module.resources[1]['values'].input.name = 42
                $late['values'].root_module.resources[1].index = 'demo/42'
                $early['values'].root_module.resources[1].index = 'demo/42'
            }
            'legacy configuration name whitespace' {
                $late['values'].root_module.resources[0]['values'].input.name = ' '
                $early['values'].root_module.resources[0]['values'].input.name = ' '
            }
            'legacy mode' { $late['values'].root_module.resources[1].mode = 'data' }
            'legacy mode case' { $late['values'].root_module.resources[1].mode = 'MANAGED' }
            'legacy index' {
                $late['values'].root_module.resources[1].index = 'demo/Renamed token'
                $early['values'].root_module.resources[1].index = 'demo/Renamed token'
            }
            'legacy index case' {
                $late['values'].root_module.resources[1].index = 'demo/OLD TOKEN'
                $early['values'].root_module.resources[1].index = 'demo/OLD TOKEN'
            }
            'legacy configuration name' {
                $late['values'].root_module.resources[0]['values'].input.name = 'alternative'
                $early['values'].root_module.resources[0]['values'].input.name = 'alternative'
            }
            'legacy configuration name case' {
                $late['values'].root_module.resources[0]['values'].input.name = 'PLATFORM-BASELINE'
                $early['values'].root_module.resources[0]['values'].input.name = 'PLATFORM-BASELINE'
            }
            'adopted input type' { $early['values'].root_module.resources[1]['values'].input = 'invalid' }
            'adopted organization case' { $early['values'].root_module.resources[1]['values'].input.organization = 'DEMO' }
            'adopted pattern name' { $early['values'].root_module.resources[1]['values'].input.name = 'Other token' }
            'adopted pattern name case' { $early['values'].root_module.resources[1]['values'].input.name = 'OLD TOKEN' }
        }
        { Assert-LegacyCodeSecurityTransition -LateState $late -ReadEarlyState $readEarly -ConfiguredPatterns $configured } |
            Should -Throw $Expected
    }
}

Describe 'Module runner with local Terraform' {
    BeforeEach {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $directory | Out-Null
        $modules = Join-Path $directory 'modules'
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.modules = @{ foundation = @{ parameters = @{ message = 'hello' } } }
        $instancePath = Join-Path $directory 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $arguments = @{
            ModulesPath = $modules
            InstancePath = $instancePath
            Backend = 'local'
            StatePath = (Join-Path $directory 'state')
            ArtifactsPath = (Join-Path $directory 'outputs')
            JobSummaryPath = (Join-Path $directory 'summary.md')
        }
        function Write-OrganizationBinding([string[]] $Organizations) {
            $manifestPath = Join-Path $modules 'foundation/module.yaml'
            $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
            $manifest.permissions.githubApp = @{
                plan = @{ permissions = @{ organization_administration = 'read' }; resources = @{ organizations = 'target_organizations' } }
                apply = @{ permissions = @{ organization_administration = 'write' }; resources = @{ organizations = 'target_organizations' } }
            }
            ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
            $instance.modules.foundation.parameters.target_organizations = $Organizations
            $instance.githubApps = @{
                reader = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ organization_administration = 'read' }; resources = @{ organizations = $Organizations } }
                writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = $Organizations } }
            }
            $instance.credentials = @{
                foundation = @{
                    plan = @{ environment = 'foundation-plan'; githubApp = 'reader' }
                    apply = @{ environment = 'foundation-apply'; githubApp = 'writer' }
                }
            }
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        }
    }

    It 'applies a module in its root with instance data and module parameters' {
        $result = & $runner -Module foundation -Action apply @arguments 6>$null

        $outputs = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json
        $outputs.foundation_name | Should -Be 'demo-foundation'
        $outputs.message | Should -Be 'hello'
        $outputs.primary_region | Should -Be 'westeurope'
        $result.HasChanges | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'foundation.tfstate') | Should -BeTrue
    }

    It 'isolates a declared early root state and artifact from its late root without requiring late manual confirmations' {
        $phaseRoot = Join-Path $modules 'foundation/code-security'
        New-Item -ItemType Directory -Path $phaseRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $modules 'foundation/main.tf') -Destination $phaseRoot
        $manifestPath = Join-Path $modules 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.manualPrerequisites = @('liveWorkflowsPromoted')
        $manifest.phases = @{ 'code-security' = @{ prerequisites = @(); manualPrerequisites = @() } }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $instance.manualPrerequisites.liveWorkflowsPromoted = $false
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $early = & $runner -Module foundation -DeploymentPhase code-security -Action apply @arguments 6>$null

        $early.OutputsPath | Should -Match 'foundation\.code-security\.json$'
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'foundation.code-security.tfstate') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'foundation.tfstate') | Should -BeFalse
        { & $runner -Module foundation -Action plan @arguments 6>$null } |
            Should -Throw '*$.manualPrerequisites.liveWorkflowsPromoted*'
        $lateArtifact = Join-Path $arguments.ArtifactsPath 'foundation.json'
        Test-Path -LiteralPath $lateArtifact | Should -BeFalse
        (Get-Content -LiteralPath $early.OutputsPath -Raw | ConvertFrom-Json).message | Should -Be 'hello'
    }

    It 'refuses a late root when only its early phase is a selected prerequisite' {
        $phaseRoot = Join-Path $modules 'foundation/code-security'
        New-Item -ItemType Directory -Path $phaseRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $modules 'foundation/main.tf') -Destination $phaseRoot
        $manifestPath = Join-Path $modules 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.phases = @{ 'code-security' = @{ prerequisites = @() } }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $manifestPath = Join-Path $modules 'application/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.prerequisites = @('foundation:code-security')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $instance.modules = @{ application = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        function terraform { throw 'Selected early phase reached Terraform.' }
        { & $runner -Module foundation -Action plan @arguments 6>$null } |
            Should -Throw "*Module 'foundation' is not selected*"
        { & $runner -Module foundation -DeploymentPhase code-security -Action plan @arguments 6>$null } |
            Should -Throw '*Selected early phase reached Terraform*'
    }

    It 'protects legacy pattern migration when <Case>' -Tag 'CodeSecurityTransition' -ForEach @(
        foreach ($scenario in @(
            @{ Case = 'the pattern is renamed'; DesiredName = 'Renamed token'; EarlyName = 'Renamed token'; ExpectedError = '*legacy*pattern*Old token*absent from customPatterns*' }
            @{ Case = 'the pattern is removed'; DesiredName = $null; EarlyName = $null; ExpectedError = '*legacy*pattern*Old token*absent from customPatterns*' }
            @{ Case = 'the pattern changes case'; DesiredName = 'old token'; EarlyName = 'old token'; ExpectedError = '*legacy*pattern*Old token*absent from customPatterns*' }
            @{ Case = 'the early root did not adopt the pattern'; DesiredName = 'Old token'; EarlyName = 'Renamed token'; ExpectedError = '*legacy*pattern*Old token*no matching identity*' }
            @{ Case = 'the early root lost the content record'; DesiredName = 'Old token'; EarlyName = 'Old token'; MissingContent = $true; ExpectedError = '*legacy*pattern*Old token*no matching identity*' }
            @{ Case = 'the early root points to another organization'; DesiredName = 'Old token'; EarlyName = 'Old token'; WrongOrganization = $true; ExpectedError = '*legacy*pattern*Old token*different identity*' }
            @{ Case = 'the early root has not yet been applied'; DesiredName = 'Old token'; EarlyName = 'Old token'; DelayEarly = $true }
            @{ Case = 'the unchanged pattern was adopted before the late state is forgotten'; DesiredName = 'Old token'; EarlyName = 'Old token'; Success = $true }
        )) {
            $defaults = @{ Success = $false; DelayEarly = $false; MissingContent = $false; WrongOrganization = $false; ExpectedError = '' }
            foreach ($key in $scenario.Keys) { $defaults[$key] = $scenario[$key] }
            $defaults
        }
    ) {
        $baseline = Join-Path $modules 'enterprise-baseline'
        Copy-Item -LiteralPath (Join-Path $modules 'foundation') -Destination $baseline -Recurse
        $manifestPath = Join-Path $baseline 'module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.name = 'enterprise-baseline'
        $manifest.phases = @{ 'code-security' = @{ prerequisites = @() } }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $early = Join-Path $baseline 'code-security'
        New-Item -ItemType Directory -Path $early | Out-Null
        Copy-Item -LiteralPath (Join-Path $baseline 'main.tf') -Destination $early
        $legacyResources = @'
resource "terraform_data" "code_security_configuration" {
  for_each = toset(["demo"])
  input = { organization = each.key, name = "platform-baseline" }
}
resource "terraform_data" "code_security_configuration_settings" {
  for_each = toset(["demo"])
  input = { organization = each.key, configuration = { name = "platform-baseline" } }
}
resource "terraform_data" "custom_pattern" {
  for_each = { "demo/Old token" = "Old token" }
  input = { organization = "demo", name = each.value }
}
resource "terraform_data" "custom_pattern_content" {
  for_each = { "demo/Old token" = "Old token" }
  input = { organization = "demo", pattern = { name = each.value } }
}
'@
        Set-Content -LiteralPath (Join-Path $baseline 'legacy.tf') -Value $legacyResources
        $earlySource = $legacyResources.Replace('Old token', $(if ($EarlyName) { $EarlyName } else { 'Old token' }))
        if (-not $EarlyName) { $earlySource = $earlySource.Replace('for_each = { "demo/Old token" = "Old token" }', 'for_each = {}') }
        if ($MissingContent) {
            $earlySource = [regex]::Replace($earlySource,
                '(?s)(resource "terraform_data" "custom_pattern_content" \{\s*for_each\s*=\s*)\{[^}]*\}', '${1}{}')
        }
        if ($WrongOrganization) { $earlySource = $earlySource.Replace('organization = "demo"', 'organization = "other"') }
        Set-Content -LiteralPath (Join-Path $early 'adopted.tf') -Value $earlySource
        [IO.Directory]::CreateDirectory($arguments.StatePath) | Out-Null
        $lateState = Join-Path $arguments.StatePath 'enterprise-baseline.tfstate'
        $earlyState = Join-Path $arguments.StatePath 'enterprise-baseline.code-security.tfstate'
        $legacyVars = @{
            instance = @{ name = 'demo'; regions = @{ primary = 'westeurope' }; customPatterns = @(@{ name = 'Old token'; secretRegex = 'itk_.*' }) }
            prerequisites = @{}
        }
        $legacyVars | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $baseline 'terraform.tfvars.json')
        $legacyInit = & terraform "-chdir=$baseline" init -input=false "-backend-config=path=$lateState" -no-color 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $legacyInit
        $legacyApply = & terraform "-chdir=$baseline" apply -input=false -auto-approve -no-color 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $legacyApply

        Remove-Item -LiteralPath (Join-Path $baseline 'legacy.tf')
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../../modules/enterprise-baseline/removed.tf') -Destination $baseline
        $legacyVars.instance.customPatterns = @()
        if ($DesiredName) {
            $legacyVars.instance.customPatterns = @(@{ name = $DesiredName; secretRegex = 'itk_.*' })
        }
        $legacyVars | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $early 'terraform.tfvars.json')
        if (-not $DelayEarly) {
            $earlyInit = & terraform "-chdir=$early" init -input=false "-backend-config=path=$earlyState" -no-color 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $earlyInit
            $earlyApply = & terraform "-chdir=$early" apply -input=false -auto-approve -no-color 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $earlyApply
        }
        $instance.modules = @{ 'enterprise-baseline' = @{} }
        $instance.customPatterns = $legacyVars.instance.customPatterns
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        if ($Success) {
            { & $runner -Module enterprise-baseline -Action destroy @arguments 6>$null } | Should -Not -Throw
            { & $runner -Module enterprise-baseline -Action destroy @arguments 6>$null } | Should -Not -Throw
        }
        elseif ($DelayEarly) {
            { & $runner -Module enterprise-baseline -Action destroy @arguments 6>$null } |
                Should -Throw '*Legacy Code Security*early*'
        }
        else {
            { & $runner -Module enterprise-baseline -Action destroy @arguments 6>$null } | Should -Throw $ExpectedError
        }
        $legacyAddresses = & terraform "-chdir=$baseline" state list -no-color 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $legacyAddresses
        if ($Success) {
            $legacyAddresses | Should -Not -Match 'terraform_data\.custom_pattern\['
        }
        else {
            $legacyAddresses | Should -Match 'terraform_data\.custom_pattern\["demo/Old token"\]'
        }
        if ($DelayEarly) {
            $earlyInit = & terraform "-chdir=$early" init -input=false "-backend-config=path=$earlyState" -no-color 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $earlyInit
            $earlyApply = & terraform "-chdir=$early" apply -input=false -auto-approve -no-color 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $earlyApply
            { & $runner -Module enterprise-baseline -Action destroy @arguments 6>$null } | Should -Not -Throw
            $resumedState = & terraform "-chdir=$baseline" state list -no-color 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $resumedState
            $resumedState | Should -Not -Match 'terraform_data\.custom_pattern\['
        }
    }

    It 'rejects undeclared phases and clears a stale phase artifact before invoking Terraform' {
        $stale = Join-Path $arguments.ArtifactsPath 'foundation.unknown.json'
        New-Item -ItemType Directory -Path $arguments.ArtifactsPath -Force | Out-Null
        Set-Content -LiteralPath $stale -Value '{"stale":true}'
        function terraform { throw 'Terraform must not run.' }

        { & $runner -Module foundation -DeploymentPhase unknown -Action plan @arguments 6>$null } |
            Should -Throw '*no declared deployment phase*'
        Test-Path -LiteralPath $stale | Should -BeFalse
    }

    It 'clears a stale ruleset artifact before refusing a phase during <Action>' -Tag 'PhaseArtifactCleanup' -ForEach @(
        @{ Action = 'plan' }
        @{ Action = 'apply' }
        @{ Action = 'destroy' }
        @{ Action = 'output' }
    ) {
        $stale = Join-Path $arguments.ArtifactsPath 'foundation.rulesets.json'
        New-Item -ItemType Directory -Path $arguments.ArtifactsPath -Force | Out-Null
        Set-Content -LiteralPath $stale -Value '{"stale":true}'
        function terraform { throw 'Terraform must not run.' }

        { & $runner -Module foundation -Action $Action -Rulesets -DeploymentPhase code-security @arguments 6>$null } |
            Should -Throw '*A deployment phase cannot use the isolated rulesets root*'
        Test-Path -LiteralPath $stale | Should -BeFalse
    }

    It 'refuses a ruleset component without a declared isolated exception' {
        { & $runner -Module foundation -Action plan -Rulesets @arguments 6>$null } |
            Should -Throw '*declared ruleset*'
    }

    It 'plans the complete isolated rulesets root including bypass drift without touching ordinary module state, then destroys it' {
        $null = & $runner -Module foundation -Action apply @arguments 6>$null
        $ordinaryState = Join-Path $arguments.StatePath 'foundation.tfstate'
        $stateBefore = [IO.File]::ReadAllText($ordinaryState)
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/rulesets') -Destination (Join-Path $modules 'foundation/rulesets') -Recurse
        $manifestPath = Join-Path $modules 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.githubApp = @{
            plan = @{ permissions = @{ organization_administration = 'read' }; resources = @{ organizations = 'target_organizations' } }
            apply = @{ permissions = @{ organization_administration = 'write' }; resources = @{ organizations = 'target_organizations' } }
            rulesetPlan = @{ permissions = @{ organization_administration = 'write' }; resources = @{ organizations = 'target_organizations' }; purpose = 'organization-rulesets-full-read' }
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $instance.modules.foundation.parameters.target_organizations = @('example')
        $instance.githubApps = @{
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ organization_administration = 'read' }; resources = @{ organizations = @('example') } }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('example') } }
            rulesets = @{ appId = '103'; installationId = '203'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = @('example') } }
        }
        $instance.credentials = @{
            foundation = @{
                plan = @{ environment = 'foundation-plan'; githubApp = 'reader' }
                apply = @{ environment = 'foundation-apply'; githubApp = 'writer' }
                rulesetPlan = @{ environment = 'foundation-ruleset-plan'; githubApp = 'rulesets' }
            }
        }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action apply -Rulesets @arguments 6>$null
        $rulesetState = Join-Path $arguments.StatePath 'foundation.rulesets.tfstate'
        $rulesetStateBefore = [IO.File]::ReadAllText($rulesetState)
        $instance.modules.foundation.parameters.bypass_actors = @('unexpected-owner')
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $runner -Module foundation -Action plan -Rulesets @arguments 6>$null

        $result.HasChanges | Should -BeTrue
        $result.OutputsPath | Should -Match 'foundation.rulesets.json$'
        $outputs = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json
        $ruleset = $outputs.ruleset
        $ruleset.rules | Should -Be @('pull_request', 'non_fast_forward', 'deletion')
        $ruleset.bypass_actors | Should -Be @('unexpected-owner')
        $outputs.runner_inputs.instance_name | Should -Be 'demo'
        $outputs.runner_inputs.prerequisite_count | Should -Be 0
        $outputs.runner_inputs.message | Should -Be 'hello'
        [IO.File]::ReadAllText($ordinaryState) | Should -BeExactly $stateBefore
        [IO.File]::ReadAllText($rulesetState) | Should -BeExactly $rulesetStateBefore

        # A generic rulesets root has no organization-rulesets recovery helper, so destroy must not invoke it.
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action destroy -Rulesets @arguments 6>$null 3>$null

        $destroyed = Get-Content -LiteralPath $rulesetState -Raw | ConvertFrom-Json
        @($destroyed.resources).Count | Should -Be 0
    }

    It 'plans known outputs without applying or creating a module state' {
        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        $outputs = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json
        $outputs.message | Should -Be 'hello'
        $outputs.entra_application | Should -Be 'none'
        $result.HasChanges | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'foundation.tfstate') | Should -BeFalse
    }

    It 'passes the Entra connection identifiers from the bootstrap section' {
        $instance.bootstrap = @{
            tenantId = '11111111-1111-1111-1111-111111111111'
            managementSubscriptionId = '22222222-2222-2222-2222-222222222222'
            subscriptionIds = @('22222222-2222-2222-2222-222222222222')
            enterpriseApplicationObjectId = '33333333-3333-3333-3333-333333333333'
            githubHost = 'example.ghe.com'
            enterprise = 'example'
        }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        $outputs = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json
        $outputs.entra_application | Should -Be '33333333-3333-3333-3333-333333333333'
        $outputs.github_host | Should -Be 'example.ghe.com'
        $outputs.github_enterprise | Should -Be 'example'
    }

    It 'passes no GitHub connection without a bootstrap section' {
        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        (Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json).github_host | Should -Be 'none'
    }

    It 'passes the instance organizations derived from the platform organization <Organization>' -ForEach @(
        @{ Organization = 'demo-a1b2c3-platform'; Identifier = 'a1b2c3'; Actions = 'demo-a1b2c3-actions'; Workloads = 'demo-a1b2c3-workloads' }
        @{ Organization = 'demo-platform'; Identifier = $null; Actions = 'demo-actions'; Workloads = 'demo-workloads' }
    ) {
        $result = & $runner -Module foundation -Action plan -PlatformOrganization $Organization @arguments 6>$null

        $organizations = (Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json).organizations
        $organizations.deploymentIdentifier | Should -Be $Identifier
        $organizations.platform | Should -BeExactly $Organization
        $organizations.actions | Should -BeExactly $Actions
        $organizations.workloads | Should -BeExactly $Workloads
    }

    It 'refuses a platform organization of another instance before Terraform and removes the stale output' {
        function terraform { throw 'Terraform must not run.' }
        $stale = Join-Path $arguments.ArtifactsPath 'foundation.json'
        $null = New-Item -ItemType Directory -Path $arguments.ArtifactsPath -Force
        Set-Content -LiteralPath $stale -Value '{"stale":true}'

        { & $runner -Module foundation -Action plan -PlatformOrganization 'other-a1b2c3-platform' @arguments 6>$null } |
            Should -Throw "*does not match instance.name 'demo'*"
        Test-Path -LiteralPath $stale | Should -BeFalse
    }

    It 'passes no instance organizations without a platform organization' {
        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        (Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json).organizations | Should -Be 'none'
    }

    It 'exposes the installation token to Terraform as the REST provider bearer only during the run' {
        $nativeTerraform = (Get-Command terraform -CommandType Application).Source
        $previousToken = $env:GITHUB_TOKEN
        $previousBearer = $env:REST_API_BEARER
        $previousExitCode = $global:LASTEXITCODE
        $observedBearers = [System.Collections.Generic.List[string]]::new()
        function terraform {
            $observedBearers.Add([string] $env:REST_API_BEARER)
            & $nativeTerraform @args
            $global:LASTEXITCODE = $LASTEXITCODE
        }
        try {
            $env:GITHUB_TOKEN = 'installation-token'
            $env:REST_API_BEARER = 'outer-value'

            $null = & $runner -Module foundation -Action plan @arguments 6>$null

            $observedBearers.Count | Should -BeGreaterThan 0
            @($observedBearers | Sort-Object -Unique) | Should -Be @('installation-token')
            $env:REST_API_BEARER | Should -BeExactly 'outer-value'
        }
        finally {
            Remove-Item -LiteralPath Function:\terraform
            $env:GITHUB_TOKEN = $previousToken
            $env:REST_API_BEARER = $previousBearer
            $global:LASTEXITCODE = $previousExitCode
        }
    }

    It 'clears an outer REST provider bearer when no installation token is present and restores it after a failure' {
        $nativeTerraform = (Get-Command terraform -CommandType Application).Source
        $previousToken = $env:GITHUB_TOKEN
        $previousBearer = $env:REST_API_BEARER
        $previousExitCode = $global:LASTEXITCODE
        $observedBearers = [System.Collections.Generic.List[string]]::new()
        function terraform {
            $observedBearers.Add([string] $env:REST_API_BEARER)
            if ($args -contains 'plan') { $global:LASTEXITCODE = 1; return 'interrupted' }
            & $nativeTerraform @args
            $global:LASTEXITCODE = $LASTEXITCODE
        }
        try {
            $env:GITHUB_TOKEN = $null
            $env:REST_API_BEARER = 'unrelated-credential'

            { & $runner -Module foundation -Action plan @arguments 6>$null } | Should -Throw '*Terraform plan failed*'

            @($observedBearers | Sort-Object -Unique) | Should -Be @('')
            $env:REST_API_BEARER | Should -BeExactly 'unrelated-credential'
        }
        finally {
            Remove-Item -LiteralPath Function:\terraform
            $env:GITHUB_TOKEN = $previousToken
            $env:REST_API_BEARER = $previousBearer
            $global:LASTEXITCODE = $previousExitCode
        }
    }

    It '<Case> before Terraform for a REST provider root bound to <Count> target organizations' -ForEach @(
        @{ Case = 'refuses'; Organizations = @('first', 'second'); Count = 2; Refused = $true }
        @{ Case = 'proceeds'; Organizations = @('first'); Count = 1; Refused = $false }
    ) {
        Set-Content -LiteralPath (Join-Path $modules 'foundation/rest.tf') -Value @'
terraform {
  required_providers {
    restapi = {
      source = "Mastercard/restapi"
    }
  }
}
'@
        Write-OrganizationBinding -Organizations $Organizations
        $previousExitCode = $global:LASTEXITCODE
        $terraformCalls = [System.Collections.Generic.List[string]]::new()
        function terraform {
            $terraformCalls.Add(($args -join ' '))
            $global:LASTEXITCODE = 1
            'stopped by test'
        }
        try {
            if ($Refused) {
                { & $runner -Module foundation -Action plan @arguments 6>$null } |
                    Should -Throw "*exactly one organization in 'target_organizations' per run; got $Count*"
                $terraformCalls.Count | Should -Be 0
            }
            else {
                { & $runner -Module foundation -Action plan @arguments 6>$null } | Should -Throw '*Terraform init failed*'
                $terraformCalls.Count | Should -Be 1
            }
        }
        finally {
            Remove-Item -LiteralPath Function:\terraform
            $global:LASTEXITCODE = $previousExitCode
        }
    }

    It 'keeps multiple target organizations for a root without the REST provider' {
        Write-OrganizationBinding -Organizations @('first', 'second')

        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        $result.HasChanges | Should -BeTrue
    }

    It 'reports no changes after apply but publishes newly planned values without mutating state' {
        $null = & $runner -Module foundation -Action apply @arguments 6>$null
        $result = & $runner -Module foundation -Action plan @arguments 6>$null
        $result.HasChanges | Should -BeFalse
        $stateFile = Join-Path $arguments.StatePath 'foundation.tfstate'
        $stateBefore = [IO.File]::ReadAllText($stateFile)
        $instance.modules.foundation.parameters.message = 'updated'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        (Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json).message | Should -Be 'updated'
        $result.HasChanges | Should -BeTrue
        [IO.File]::ReadAllText($stateFile) | Should -BeExactly $stateBefore
    }

    It 'publishes the plan change state as a workflow output only after a successful plan' {
        $outputFile = Join-Path $directory 'github-output.txt'
        $null = & $runner -Module foundation -Action apply @arguments 6>$null

        $null = & $runner -Module foundation -Action plan -GitHubOutputPath $outputFile @arguments 6>$null
        [IO.File]::ReadAllText($outputFile) | Should -BeExactly "changes=false`n"

        $instance.modules.foundation.parameters.message = 'drifted'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action plan -GitHubOutputPath $outputFile @arguments 6>$null
        [IO.File]::ReadAllText($outputFile) | Should -BeExactly "changes=false`nchanges=true`n"
    }

    It 'publishes no change state when the plan fails' {
        $outputFile = Join-Path $directory 'github-output.txt'
        Set-Content -LiteralPath (Join-Path $modules 'foundation/broken.tf') -Value 'resource "terraform_data" "broken" {'

        { & $runner -Module foundation -Action plan -GitHubOutputPath $outputFile @arguments 6>$null } | Should -Throw
        Test-Path -LiteralPath $outputFile | Should -BeFalse
    }

    It 'refuses a workflow change output for apply and destroy' {
        { & $runner -Module foundation -Action apply -GitHubOutputPath (Join-Path $directory 'out.txt') @arguments 6>$null } |
            Should -Throw '*only for plan*'
    }

    It 'passes prerequisite artifacts as variables without requiring their state' {
        $instance.modules = @{ application = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action plan @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath

        $result = & $runner -Module application -Action apply @arguments 6>$null

        (Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json).application_name |
            Should -Be 'demo-foundation-application'
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'foundation.tfstate') | Should -BeFalse
    }

    It 'imports the public output of the declared phase rather than the late module output' {
        $phaseRoot = Join-Path $modules 'foundation/code-security'
        New-Item -ItemType Directory -Path $phaseRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $modules 'foundation/main.tf') -Destination $phaseRoot
        $manifestPath = Join-Path $modules 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.phases = @{ 'code-security' = @{ prerequisites = @() } }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $manifestPath = Join-Path $modules 'application/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.prerequisites = @('foundation:code-security')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $applicationRoot = Join-Path $modules 'application/main.tf'
        (Get-Content -LiteralPath $applicationRoot -Raw).Replace('var.prerequisites.foundation.foundation_name', 'var.prerequisites["foundation:code-security"].foundation_name') |
            Set-Content -LiteralPath $applicationRoot
        $instance.modules = @{ application = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -DeploymentPhase code-security -Action plan @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath

        $result = & $runner -Module application -Action plan @arguments 6>$null

        (Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json).application_name |
            Should -Be 'demo-foundation-application'
        Test-Path -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json') | Should -BeFalse
    }

    It 'fails clearly for missing prerequisite artifacts before executing the dependent module' {
        $instance.modules = @{ application = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath

        { & $runner -Module application -Action apply @arguments 6>$null } |
            Should -Throw '*Missing prerequisite outputs*foundation*'
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'application.tfstate') | Should -BeFalse
    }

    It 'refuses sensitive outputs for <Action> and leaves no stale or new artifact' -ForEach @(
        @{ Action = 'plan' }
        @{ Action = 'apply' }
    ) {
        $instance.modules = @{ sensitive = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        New-Item -ItemType Directory -Path $arguments.ArtifactsPath | Out-Null
        $artifact = Join-Path $arguments.ArtifactsPath 'sensitive.json'
        [IO.File]::WriteAllText($artifact, '{"stale":true}')

        { & $runner -Module sensitive -Action $Action @arguments 6>$null } |
            Should -Throw '*Sensitive output*restricted*'
        Test-Path -LiteralPath $artifact | Should -BeFalse
    }

    It 'refuses partially unknown planned outputs rather than publishing placeholder values' {
        $instance.modules = @{ unknown = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $runner -Module unknown -Action plan @arguments 6>$null } |
            Should -Throw '*Unknown planned output*identifier*'
        Test-Path -LiteralPath (Join-Path $arguments.ArtifactsPath 'unknown.json') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'unknown.tfstate') | Should -BeFalse
    }

    It 'warns about unconfirmed manual steps without stopping the module and retains existing summary' {
        $instance.modules = @{ application = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action plan @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath
        [IO.File]::WriteAllText($arguments.JobSummaryPath, "Earlier summary`n")

        $result = & $runner -Module application -Action apply @arguments 6>$null 3>$null

        $summary = [IO.File]::ReadAllText($arguments.JobSummaryPath)
        $summary | Should -Match 'Earlier summary'
        $summary | Should -Match 'WARNING.*verify-access'
        $summary | Should -Match 'Plan.*not automatically verified'
        $summary | Should -Match 'Drift.*not automatically detected'
        $summary | Should -Match 'Teardown.*not automatically reversed'
        $result.ManualSteps[0].Confirmed | Should -BeFalse
        $result.ManualSteps[0].Verified | Should -BeFalse
        Test-Path -LiteralPath $result.OutputsPath | Should -BeTrue
    }

    It 'distinguishes a manual confirmation from an automatically verified state' {
        $instance.modules = @{ application = @{} }
        $instance.manualSteps = @{ application = @{ 'verify-access' = $true } }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action plan @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath

        $result = & $runner -Module application -Action plan @arguments 6>$null

        $summary = [IO.File]::ReadAllText($arguments.JobSummaryPath)
        $summary | Should -Match 'CONFIRMED.*verify-access'
        $summary | Should -Match 'not automatically verified'
        $summary | Should -Not -Match 'WARNING.*verify-access'
        $result.ManualSteps[0].Confirmed | Should -BeTrue
        $result.ManualSteps[0].Verified | Should -BeFalse
    }

    It 'blocks bootstrap <Action> when an enterprise prerequisite is unconfirmed' -ForEach @(
        @{ Action = 'plan' }
        @{ Action = 'apply' }
    ) {
        $bootstrapRoot = Join-Path $modules 'bootstrap'
        Copy-Item -LiteralPath (Join-Path $modules 'foundation') -Destination $bootstrapRoot -Recurse
        $manifestFile = Join-Path $bootstrapRoot 'module.yaml'
        (Get-Content -LiteralPath $manifestFile -Raw).Replace('name: foundation', 'name: bootstrap') |
            Set-Content -LiteralPath $manifestFile
        $instance.modules = @{ bootstrap = @{} }
        $instance.manualPrerequisites.privateInternalForksDisabled = $false
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $runner -Module bootstrap -Action $Action @arguments 6>$null } |
            Should -Throw '*$.manualPrerequisites.privateInternalForksDisabled*'
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'bootstrap.tfstate') | Should -BeFalse
    }

    It 'does not require the post-bootstrap confirmation liveWorkflowsPromoted for bootstrap when it is <Case>' -ForEach @(
        @{ Case = 'false'; Remove = $false }
        @{ Case = 'missing'; Remove = $true }
    ) {
        $bootstrapRoot = Join-Path $modules 'bootstrap'
        Copy-Item -LiteralPath (Join-Path $modules 'foundation') -Destination $bootstrapRoot -Recurse
        $manifestFile = Join-Path $bootstrapRoot 'module.yaml'
        (Get-Content -LiteralPath $manifestFile -Raw).Replace('name: foundation', 'name: bootstrap') |
            Set-Content -LiteralPath $manifestFile
        $instance.modules = @{ bootstrap = @{ parameters = @{ message = 'hello' } } }
        if ($Remove) { $instance.manualPrerequisites.Remove('liveWorkflowsPromoted') }
        else { $instance.manualPrerequisites.liveWorkflowsPromoted = $false }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $runner -Module bootstrap -Action plan @arguments 6>$null

        $result.HasChanges | Should -BeTrue
    }

    It 'blocks module plan when the declared liveWorkflowsPromoted confirmation is <Case>' -ForEach @(
        @{ Case = 'false'; Remove = $false }
        @{ Case = 'missing'; Remove = $true }
    ) {
        $manifestFile = Join-Path $modules 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestFile -Raw)
        $manifest.manualPrerequisites = @('liveWorkflowsPromoted')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestFile
        if ($Remove) { $instance.manualPrerequisites.Remove('liveWorkflowsPromoted') }
        else { $instance.manualPrerequisites.liveWorkflowsPromoted = $false }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $runner -Module foundation -Action plan @arguments 6>$null } |
            Should -Throw "*foundation*requires manual prerequisite confirmations*$.manualPrerequisites.liveWorkflowsPromoted*"
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'foundation.tfstate') | Should -BeFalse
    }

    It 'plans a module whose declared liveWorkflowsPromoted confirmation is true' {
        $manifestFile = Join-Path $modules 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestFile -Raw)
        $manifest.manualPrerequisites = @('liveWorkflowsPromoted')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestFile

        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        $result.HasChanges | Should -BeTrue
        @($result.ManualPrerequisites | Where-Object { $_.Name -ceq 'liveWorkflowsPromoted' -and $_.Confirmed }).Count | Should -Be 1
    }

    It 'blocks module <Action> when a declared enterprise prerequisite is <Case>' -ForEach @(
        @{ Action = 'plan'; Case = 'false'; Remove = $false }
        @{ Action = 'apply'; Case = 'false'; Remove = $false }
        @{ Action = 'plan'; Case = 'missing'; Remove = $true }
        @{ Action = 'apply'; Case = 'missing'; Remove = $true }
    ) {
        $manifestFile = Join-Path $modules 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestFile -Raw)
        $manifest.manualPrerequisites = @('repositoryManagementPoliciesEnforced', 'privateInternalForksDisabled')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestFile
        if ($Remove) { $instance.manualPrerequisites.Remove('repositoryManagementPoliciesEnforced') }
        else { $instance.manualPrerequisites.repositoryManagementPoliciesEnforced = $false }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $runner -Module foundation -Action $Action @arguments 6>$null } |
            Should -Throw "*foundation*requires manual prerequisite confirmations*$.manualPrerequisites.repositoryManagementPoliciesEnforced*"
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'foundation.tfstate') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json') | Should -BeFalse
    }

    It 'reports confirmed enterprise prerequisites as declarations, not as plan or drift evidence' {
        $manifestFile = Join-Path $modules 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestFile -Raw)
        $manifest.manualPrerequisites = @('repositoryManagementPoliciesEnforced', 'privateInternalForksDisabled')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestFile

        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        @($result.ManualPrerequisites.Name) | Should -Be @('repositoryManagementPoliciesEnforced', 'privateInternalForksDisabled')
        @($result.ManualPrerequisites | Where-Object { $_.Confirmed }).Count | Should -Be 2
        @($result.ManualPrerequisites | Where-Object { $_.Verified }).Count | Should -Be 0
        $summary = [IO.File]::ReadAllText($arguments.JobSummaryPath)
        $summary | Should -Match 'CONFIRMED \(manual declaration only\).*\$\.manualPrerequisites\.repositoryManagementPoliciesEnforced'
        $summary | Should -Match 'not read by plan or drift detection'
        $summary | Should -Match 'not changed by teardown'
        $summary | Should -Not -Match 'WARNING'
    }

    It 'destroys without requiring declared enterprise prerequisites and keeps them unchanged' {
        $manifestFile = Join-Path $modules 'unknown/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestFile -Raw)
        $manifest.manualPrerequisites = @('repositoryManagementPoliciesEnforced')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestFile
        $instance.modules = @{ unknown = @{} }
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module unknown -Action apply @arguments 6>$null
        $instance.manualPrerequisites.repositoryManagementPoliciesEnforced = $false
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $configurationBefore = [IO.File]::ReadAllText($instancePath)

        $result = & $runner -Module unknown -Action destroy @arguments 6>$null 3>$null

        $result.HasChanges | Should -BeTrue
        $result.ManualPrerequisites[0].Confirmed | Should -BeFalse
        $result.ManualPrerequisites[0].Verified | Should -BeFalse
        [IO.File]::ReadAllText($arguments.JobSummaryPath) | Should -Match 'WARNING \(unconfirmed\).*repositoryManagementPoliciesEnforced'
        [IO.File]::ReadAllText($instancePath) | Should -BeExactly $configurationBefore
    }

    It 'denies destroy by default' {
        { & $runner -Module foundation -Action destroy @arguments 6>$null } |
            Should -Throw '*$.teardown.allowed*'
    }

    It 'destroys only its module when allowed and preserves manual prerequisite confirmations' {
        $instance.modules = @{ unknown = @{} }
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $configurationBefore = [IO.File]::ReadAllText($instancePath)
        $null = & $runner -Module unknown -Action apply @arguments 6>$null

        $result = & $runner -Module unknown -Action destroy @arguments 6>$null

        (Get-Content -LiteralPath $result.OutputsPath -Raw).Trim() | Should -Be '{}'
        $result.HasChanges | Should -BeTrue
        [IO.File]::ReadAllText($instancePath) | Should -BeExactly $configurationBefore
        $state = Get-Content -LiteralPath (Join-Path $arguments.StatePath 'unknown.tfstate') -Raw | ConvertFrom-Json
        @($state.resources).Count | Should -Be 0
    }

    It 'reads applied outputs from state without planning, locking or changing state' {
        $null = & $runner -Module foundation -Action apply @arguments 6>$null
        $stateFile = Join-Path $arguments.StatePath 'foundation.tfstate'
        $stateBefore = [IO.File]::ReadAllText($stateFile)
        $instance.modules.foundation.parameters.message = 'changed-after-apply'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $runner -Module foundation -Action output @arguments 6>$null

        $outputs = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json
        $outputs.foundation_name | Should -Be 'demo-foundation'
        $outputs.message | Should -Be 'hello'
        $result.HasChanges | Should -BeFalse
        [IO.File]::ReadAllText($stateFile) | Should -BeExactly $stateBefore
    }

    It 'reads outputs of a dependent module without requiring prerequisite artifacts' {
        $instance.modules = @{ application = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $runner -Module application -Action output @arguments 6>$null

        (Get-Content -LiteralPath $result.OutputsPath -Raw).Trim() | Should -Be '{}'
    }

    It 'refuses sensitive outputs in state for output and leaves no stale artifact' {
        $instance.modules = @{ sensitive = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        New-Item -ItemType Directory -Path $arguments.StatePath | Out-Null
        $state = [ordered]@{
            version = 4; terraform_version = '1.9.0'; serial = 1; lineage = [guid]::NewGuid().ToString()
            outputs = @{ restricted = @{ value = 'secret'; type = 'string'; sensitive = $true } }
            resources = @(); check_results = $null
        }
        [IO.File]::WriteAllText((Join-Path $arguments.StatePath 'sensitive.tfstate'), (ConvertTo-Json $state -Depth 10))
        New-Item -ItemType Directory -Path $arguments.ArtifactsPath | Out-Null
        $artifact = Join-Path $arguments.ArtifactsPath 'sensitive.json'
        [IO.File]::WriteAllText($artifact, '{"stale":true}')

        { & $runner -Module sensitive -Action output @arguments 6>$null } |
            Should -Throw '*Sensitive output*restricted*'
        Test-Path -LiteralPath $artifact | Should -BeFalse
    }

    It 'completes a repeated destroy of an already destroyed dependent after its prerequisite is gone' {
        $instance.modules = @{ application = @{} }
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action apply @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath
        $applied = & $runner -Module application -Action apply @arguments 6>$null
        $null = & $runner -Module application -Action destroy @arguments 6>$null
        $null = & $runner -Module foundation -Action destroy @arguments 6>$null
        $null = & $runner -Module foundation -Action output @arguments 6>$null
        # The teardown job of a repeated run has no artifact of the already destroyed prerequisite.
        Remove-Item -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json')

        $result = & $runner -Module application -Action destroy @arguments 6>$null

        $result.HasChanges | Should -BeFalse
        (Get-Content -LiteralPath $result.OutputsPath -Raw).Trim() | Should -Be '{}'
        $result.PSObject.Properties.Name | Should -Contain 'ManualPrerequisites'
        @($result.ManualPrerequisites | ForEach-Object Name) | Should -Be @($applied.ManualPrerequisites | ForEach-Object Name)
    }

    It 'does not treat a state with only deposed instances as empty' {
        $instance.modules = @{ application = @{} }
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        Add-Content -LiteralPath (Join-Path $modules 'application/main.tf') -Value 'resource "terraform_data" "fixture" { input = var.instance.name }'
        $null = & $runner -Module foundation -Action apply @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath
        $null = & $runner -Module application -Action apply @arguments 6>$null
        Remove-Item -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json')
        # An interrupted create_before_destroy replacement leaves the old object deposed and no current object or output.
        $statePath = Join-Path $arguments.StatePath 'application.tfstate'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        @($state['resources']).Count | Should -BeGreaterThan 0
        foreach ($resource in $state['resources']) {
            foreach ($object in $resource['instances']) { $object['deposed'] = '00000001' }
        }
        $state['outputs'] = @{}
        $state['serial']++
        [IO.File]::WriteAllText($statePath, (ConvertTo-Json $state -Depth 100))

        { & $runner -Module application -Action destroy @arguments 6>$null } | Should -Throw "*Missing prerequisite outputs for 'foundation'*"
    }

    It 'reads whether a dependent state is empty without tokens, prerequisite outputs or manual confirmations' {
        $manifestFile = Join-Path $modules 'application/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestFile -Raw)
        $manifest.manualPrerequisites = @('repositoryManagementPoliciesEnforced')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestFile
        $instance.modules = @{ application = @{} }
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        Add-Content -LiteralPath (Join-Path $modules 'application/main.tf') -Value 'resource "terraform_data" "fixture" { input = var.instance.name }'
        $null = & $runner -Module foundation -Action apply @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath
        $null = & $runner -Module application -Action apply @arguments 6>$null
        Remove-Item -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json')
        $artifact = Join-Path $arguments.ArtifactsPath 'application.json'
        $artifactBefore = [IO.File]::ReadAllText($artifact)
        $instance.manualPrerequisites.repositoryManagementPoliciesEnforced = $false
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $statePath = Join-Path $arguments.StatePath 'application.tfstate'
        $stateBefore = [IO.File]::ReadAllText($statePath)
        $previousToken = $env:GITHUB_TOKEN
        $env:GITHUB_TOKEN = $null
        try {
            $applied = & $runner -Module application -Action state @arguments 6>$null 3>$null
        }
        finally {
            $env:GITHUB_TOKEN = $previousToken
        }

        $applied.Module | Should -Be 'application'
        $applied.Action | Should -Be 'state'
        $applied.Empty | Should -BeExactly $false
        [IO.File]::ReadAllText($statePath) | Should -BeExactly $stateBefore
        [IO.File]::ReadAllText($artifact) | Should -BeExactly $artifactBefore

        $null = & $runner -Module foundation -Action output @arguments 6>$null
        $null = & $runner -Module application -Action destroy @arguments 6>$null 3>$null
        Remove-Item -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json')

        $destroyed = & $runner -Module application -Action state @arguments 6>$null 3>$null

        $destroyed.Empty | Should -BeExactly $true
    }

    It 'reads a never applied module state as empty' {
        $instance.modules = @{ unknown = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $runner -Module unknown -Action state @arguments 6>$null

        $result.Empty | Should -BeExactly $true
    }

    It 'does not read a state with only deposed instances as empty' {
        $instance.modules = @{ application = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        Add-Content -LiteralPath (Join-Path $modules 'application/main.tf') -Value 'resource "terraform_data" "fixture" { input = var.instance.name }'
        $null = & $runner -Module foundation -Action apply @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath
        $null = & $runner -Module application -Action apply @arguments 6>$null
        $statePath = Join-Path $arguments.StatePath 'application.tfstate'
        $state = Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($resource in $state['resources']) {
            foreach ($object in $resource['instances']) { $object['deposed'] = '00000001' }
        }
        $state['outputs'] = @{}
        $state['serial']++
        [IO.File]::WriteAllText($statePath, (ConvertTo-Json $state -Depth 100))

        $result = & $runner -Module application -Action state @arguments 6>$null

        $result.Empty | Should -BeExactly $false
    }

    It 'requires prerequisite outputs to destroy a dependent with remaining resources' {
        $instance.modules = @{ application = @{} }
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action apply @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath
        $null = & $runner -Module application -Action apply @arguments 6>$null
        Remove-Item -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json')

        { & $runner -Module application -Action destroy @arguments 6>$null } | Should -Throw "*Missing prerequisite outputs for 'foundation'*"
    }

    It 'still destroys a dependent with remaining resources rather than skipping it' {
        $instance.modules = @{ unknown = @{} }
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module unknown -Action apply @arguments 6>$null

        $result = & $runner -Module unknown -Action destroy @arguments 6>$null

        $result.HasChanges | Should -BeTrue
        $again = & $runner -Module unknown -Action destroy @arguments 6>$null
        $again.HasChanges | Should -BeFalse
    }

    It 'does not silently fall back to an implicit local backend' {
        $rootFile = Join-Path $modules 'foundation/main.tf'
        (Get-Content -LiteralPath $rootFile -Raw).Replace('backend "local" {}', '') |
            Set-Content -LiteralPath $rootFile

        { & $runner -Module foundation -Action plan @arguments 6>$null } |
            Should -Throw '*must declare*local*backend*'
        Test-Path -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json') | Should -BeFalse
    }

    It 'reports Terraform failures rather than publishing an artifact' {
        $instance.modules.foundation.parameters.message = 42
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $rootFile = Join-Path $modules 'foundation/main.tf'
        (Get-Content -LiteralPath $rootFile -Raw).Replace('type        = string', 'type        = list(string)').Replace('default     = "default"', 'default     = []') |
            Set-Content -LiteralPath $rootFile

        { & $runner -Module foundation -Action apply @arguments 6>$null } |
            Should -Throw '*Terraform plan failed*foundation*exit 1*'
        Test-Path -LiteralPath (Join-Path $arguments.ArtifactsPath 'foundation.json') | Should -BeFalse
    }

    It 'reports module-specific manual ownership and limits' {
        $manifestFile = Join-Path $modules 'application/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestFile -Raw)
        $manifest.manualSteps[0].owner = 'security'
        $manifest.manualSteps[0].limitations = @{
            plan = 'API does not expose the access setting.'
            drift = 'Security team reviews access every month.'
            teardown = 'Security team must remove access manually.'
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestFile
        $instance.modules = @{ application = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $runner -Module foundation -Action plan @arguments 6>$null
        $arguments.PrerequisiteOutputsPath = $arguments.ArtifactsPath

        $result = & $runner -Module application -Action plan @arguments 6>$null 3>$null

        $result.ManualSteps[0].Owner | Should -Be 'security'
        [IO.File]::ReadAllText($arguments.JobSummaryPath) | Should -Match 'API does not expose the access setting'
        [IO.File]::ReadAllText($arguments.JobSummaryPath) | Should -Match 'reviews access every month'
        [IO.File]::ReadAllText($arguments.JobSummaryPath) | Should -Match 'remove access manually'
    }

    It 'rejects unknown output changes even when planned values omit the output record' {
        $instance.modules = @{ unknown = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $nativeTerraform = (Get-Command terraform -CommandType Application).Source
        $previousExitCode = $global:LASTEXITCODE
        function terraform {
            $text = & $nativeTerraform @args
            $global:LASTEXITCODE = $LASTEXITCODE
            if ($args -contains 'show') {
                $json = ($text -join "`n") | ConvertFrom-Json -AsHashtable
                $json['planned_values']['outputs'].Remove('identifier')
                ConvertTo-Json -InputObject $json -Depth 100
            }
            else {
                $text
            }
        }
        try {
            { & $runner -Module unknown -Action plan @arguments 6>$null } |
                Should -Throw '*Unknown planned output*identifier*'
            Test-Path -LiteralPath (Join-Path $arguments.ArtifactsPath 'unknown.json') | Should -BeFalse
        }
        finally {
            Remove-Item -LiteralPath Function:\terraform
            $global:LASTEXITCODE = $previousExitCode
        }
    }
}
