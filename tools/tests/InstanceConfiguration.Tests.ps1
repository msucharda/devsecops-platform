BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $validator = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-InstanceConfiguration.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
    $example = Join-Path $PSScriptRoot 'fixtures/instance.yaml'
}

Describe 'Offline schema reference boundary through instance validation' {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item (Join-Path $root 'tools') -ItemType Directory
        $null = New-Item (Join-Path $root 'schemas') -ItemType Directory
        $repo = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        Copy-Item (Join-Path $repo 'tools/PlatformTools.psm1') (Join-Path $root 'tools/PlatformTools.psm1')
        Copy-Item (Join-Path $repo 'tools/ToolDependencies.psm1'), (Join-Path $repo 'tools/requirements.psd1') (Join-Path $root 'tools')
        Copy-Item (Join-Path $repo 'tools/vendor') (Join-Path $root 'tools') -Recurse
        Copy-Item (Join-Path $repo 'schemas/*.schema.json') (Join-Path $root 'schemas')
        $instanceSchemaPath = Join-Path $root 'schemas/instance.schema.json'
        $moduleSchemaPath = Join-Path $root 'schemas/module.schema.json'
    }

    It 'rejects an untrusted or missing schema reference: <Reference>' -ForEach @(
        @{ Reference = 'https://untrusted.invalid/schema.json#/definitions/moduleName'; Error = '*Unsupported schema reference*' }
        @{ Reference = 'file:///untrusted/schema.json#/definitions/moduleName'; Error = '*Unsupported schema reference*' }
        @{ Reference = '../module.schema.json#/definitions/moduleName'; Error = '*Unsupported schema reference*' }
        @{ Reference = 'unknown.schema.json#/definitions/moduleName'; Error = '*Unsupported schema reference*' }
        @{ Reference = 'module.schema.json#/definitions/doesNotExist'; Error = '*Missing schema definition*doesNotExist*' }
        @{ Reference = '#/definitions/doesNotExist'; Error = '*Missing schema definition*doesNotExist*' }
        @{ Reference = 42; Error = '*Unsupported schema reference*' }
    ) {
        $schema = Get-Content $instanceSchemaPath -Raw | ConvertFrom-Json -AsHashtable
        $schema.properties.modules.propertyNames['$ref'] = $Reference
        ConvertTo-Json $schema -Depth 100 | Set-Content $instanceSchemaPath
        $module = Import-Module (Join-Path $root 'tools/PlatformTools.psm1') -Force -PassThru

        { & $module { param($Path) Get-PlatformInstance -Path $Path -Modules @{} } $example } | Should -Throw $Error
    }

    It 'rejects an external reference nested in the trusted sibling schema' {
        $schema = Get-Content $moduleSchemaPath -Raw | ConvertFrom-Json -AsHashtable
        $schema.definitions.githubAppResources.properties.organizations.items['$ref'] = 'https://untrusted.invalid/org.json'
        ConvertTo-Json $schema -Depth 100 | Set-Content $moduleSchemaPath
        $module = Import-Module (Join-Path $root 'tools/PlatformTools.psm1') -Force -PassThru

        { & $module { param($Path) Get-PlatformInstance -Path $Path -Modules @{} } $example } |
            Should -Throw '*Unsupported schema reference*'
    }

    It 'rejects a schema identifier that could change local reference resolution' {
        $schema = Get-Content $moduleSchemaPath -Raw | ConvertFrom-Json -AsHashtable
        $schema.definitions.githubAppResources['$id'] = 'https://untrusted.invalid/'
        ConvertTo-Json $schema -Depth 100 | Set-Content $moduleSchemaPath
        $module = Import-Module (Join-Path $root 'tools/PlatformTools.psm1') -Force -PassThru

        { & $module { param($Path) Get-PlatformInstance -Path $Path -Modules @{} } $example } |
            Should -Throw '*Unsupported schema keyword*'
    }

    It 'rejects an absent trusted sibling instead of fetching a replacement' {
        Remove-Item -LiteralPath $moduleSchemaPath
        $module = Import-Module (Join-Path $root 'tools/PlatformTools.psm1') -Force -PassThru

        { & $module { param($Path) $ErrorActionPreference = 'Continue'; Get-PlatformInstance -Path $Path -Modules @{} } $example } |
            Should -Throw '*module.schema.json*'
    }

    It 'rejects a collision with the bundled sibling namespace' {
        $schema = Get-Content $instanceSchemaPath -Raw | ConvertFrom-Json -AsHashtable
        $schema.definitions['platformModuleSchema'] = @{}
        ConvertTo-Json $schema -Depth 100 | Set-Content $instanceSchemaPath
        $module = Import-Module (Join-Path $root 'tools/PlatformTools.psm1') -Force -PassThru

        { & $module { param($Path) Get-PlatformInstance -Path $Path -Modules @{} } $example } |
            Should -Throw '*reserved platformModuleSchema definition*'
    }

    It 'treats a reference-looking module parameter as data rather than a schema to fetch' {
        $instance = ConvertFrom-Yaml (Get-Content $example -Raw)
        $instance.modules.observer.parameters = @{ options = @{ '$ref' = 'https://untrusted.invalid/data.json' } }
        $path = Join-Path $TestDrive 'reference-data.yaml'
        ConvertTo-Yaml $instance | Set-Content $path
        $module = Import-Module (Join-Path $root 'tools/PlatformTools.psm1') -Force -PassThru
        $validated = & $module {
            param($Path, $ModulesPath)
            Get-PlatformInstance -Path $Path -Modules (Get-PlatformModuleGraph -ModulesPath $ModulesPath)
        } $path $fixtures

        $validated.modules.observer.parameters.options['$ref'] | Should -BeExactly 'https://untrusted.invalid/data.json'
    }
}

Describe 'Organizations module parameters' {
    BeforeAll {
        $modulesPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules'
        function Write-OrganizationsInstance {
            param([System.Collections.IDictionary] $Parameters)

            $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
            $instance.modules = @{ organizations = @{ parameters = $Parameters } }
            $instance.githubApps = @{
                'organizations-reader' = @{ appId = '111'; installationId = '211'; enterprise = 'example'; permissions = @{ enterprise_organization_installations = 'read' }; resources = @{ enterprise = $true } }
                'organizations-writer' = @{ appId = '112'; installationId = '212'; enterprise = 'example'; permissions = @{ enterprise_organization_installations = 'write'; enterprise_organizations = 'write' }; resources = @{ enterprise = $true } }
            }
            $instance.credentials = @{
                organizations = @{
                    plan = @{ environment = 'organizations-plan'; githubApp = 'organizations-reader' }
                    apply = @{ environment = 'organizations-apply'; githubApp = 'organizations-writer' }
                }
            }
            $path = Join-Path $TestDrive "organizations-$([guid]::NewGuid().ToString('N')).yaml"
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $path
            $path
        }
        function Get-DefaultOrganizationParameter {
            [ordered]@{
                admin_logins = @('alice_demo', 'bob-smith_demo')
                billing_email = 'billing@example.test'
                app_client_ids = @('Iv23liExample01', 'Iv1.0123456789abcdef')
            }
        }
    }

    It 'accepts explicit EMU owners, a billing email and App client IDs' {
        $path = Write-OrganizationsInstance -Parameters (Get-DefaultOrganizationParameter)

        $validated = & $validator -InstancePath $path -ModulesPath $modulesPath | ConvertFrom-Json

        $validated.modules.organizations.parameters.admin_logins | Should -Be @('alice_demo', 'bob-smith_demo')
        $validated.modules.organizations.parameters.app_client_ids | Should -Be @('Iv23liExample01', 'Iv1.0123456789abcdef')
    }

    It 'accepts an owner login <Login> with an optional EMU shortcode' -ForEach @(
        @{ Login = 'msucharda' }
        @{ Login = 'alice_demo' }
        @{ Login = 'alice' }
        @{ Login = 'gh-reviewer' }
        @{ Login = 'mpolivka' }
        @{ Login = 'A' }
        @{ Login = 'Alice-Smith_demo' }
        @{ Login = 'a' * 39 }
        @{ Login = ('a' * 34) + '_demo' }
    ) {
        $parameters = Get-DefaultOrganizationParameter
        $parameters.admin_logins = @($Login)
        $path = Write-OrganizationsInstance -Parameters $parameters

        $validated = & $validator -InstancePath $path -ModulesPath $modulesPath | ConvertFrom-Json

        $validated.modules.organizations.parameters.admin_logins | Should -Be @($Login)
    }

    It 'requires the organizations parameters <Missing>' -ForEach @(
        @{ Missing = 'parameters' }
        @{ Missing = 'admin_logins' }
        @{ Missing = 'billing_email' }
    ) {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $parameters = Get-DefaultOrganizationParameter
        $instance.modules = @{ organizations = @{ parameters = $parameters } }
        if ($Missing -eq 'parameters') { $instance.modules.organizations.Remove('parameters') } else { $parameters.Remove($Missing) }
        $path = Join-Path $TestDrive 'missing.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $modulesPath } | Should -Throw "*$Missing*"
    }

    It 'rejects organizations parameter <Field> = <Case>' -ForEach @(
        @{ Field = 'admin_logins'; Case = 'empty list'; Value = @(); Rule = 'at least' }
        @{ Field = 'admin_logins'; Case = 'duplicate'; Value = @('alice_demo', 'alice_demo'); Rule = 'duplicates' }
        @{ Field = 'admin_logins'; Case = 'empty login'; Value = @(''); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'null login'; Value = @($null); Rule = 'string' }
        @{ Field = 'admin_logins'; Case = 'leading hyphen'; Value = @('-alice'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'trailing hyphen without shortcode'; Value = @('alice-'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'trailing hyphen'; Value = @('alice-_demo'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'consecutive hyphens'; Value = @('alice--smith'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'consecutive hyphens with shortcode'; Value = @('alice--smith_demo'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'invalid character'; Value = @('alice.smith'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'leading underscore'; Value = @('_demo'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'multiple underscores'; Value = @('alice_team_demo'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'empty shortcode'; Value = @('alice_'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'invalid shortcode'; Value = @('alice_de-mo'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'whitespace'; Value = @('alice smith'); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'trailing newline'; Value = @("alice_demo`n"); Rule = 'regular expression' }
        @{ Field = 'admin_logins'; Case = 'too long without shortcode'; Value = @('a' * 40); Rule = '39' }
        @{ Field = 'admin_logins'; Case = 'too long'; Value = @(('a' * 35) + '_demo'); Rule = '39' }
        @{ Field = 'admin_logins'; Case = 'string instead of list'; Value = 'alice_demo'; Rule = 'array' }
        @{ Field = 'billing_email'; Case = 'no domain'; Value = 'billing@example' }
        @{ Field = 'billing_email'; Case = 'empty'; Value = '' }
        @{ Field = 'app_client_ids'; Case = 'blank'; Value = @('') }
        @{ Field = 'app_client_ids'; Case = 'path characters'; Value = @('Iv1/../x') }
        @{ Field = 'adopt_organizations'; Case = 'removed adoption escape hatch'; Value = @('actions') }
        @{ Field = 'unknown_parameter'; Case = 'undeclared'; Value = 'x' }
    ) {
        $parameters = Get-DefaultOrganizationParameter
        $parameters[$Field] = $Value
        $path = Write-OrganizationsInstance -Parameters $parameters

        $failure = { & $validator -InstancePath $path -ModulesPath $modulesPath } |
            Should -Throw '*$.modules.organizations.parameters*' -PassThru
        if ($Field -eq 'admin_logins') {
            $location = '$.modules.organizations.parameters.admin_logins'
            if ($Case -notin @('empty list', 'duplicate', 'string instead of list')) { $location += '.0' }
            $failure.Exception.Message | Should -Match "$([regex]::Escape($Rule))[^;]*at '$([regex]::Escape($location))'"
        }
    }
}

Describe 'Instance configuration validation' {
    It 'resolves trusted sibling schema definitions through the public instance validator without runtime defaults' {
        $module = Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PlatformTools.psm1') -Force -PassThru
        $validated = & $module {
            param($Path, $ModulesPath)
            Get-PlatformInstance -Path $Path -Modules (Get-PlatformModuleGraph -ModulesPath $ModulesPath)
        } $example $fixtures

        $validated.instance.name | Should -BeExactly 'demo'
        $validated.modules.Contains('observer') | Should -BeTrue
    }

    It 'rejects a one-character instance name with its configuration path' {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.instance.name = 'a'
        $path = Join-Path $TestDrive 'invalid.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        { & $validator -InstancePath $path -ModulesPath $fixtures } |
            Should -Throw '*$.instance.name*'
    }

    It 'accepts the instance contract and defaults teardown to denied' {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.regions.secondary = 'northeurope'
        $instance.modules.observer.parameters = @{ message = 'example'; options = @{ enabled = $true } }
        $instance.customPatterns = @(@{ name = 'internal-id'; secretRegex = 'ID-[0-9]{8}' })
        $instance.manualSteps = @{ application = @{ 'verify-access' = $true } }
        $instance.githubApps = @{
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{}; resources = @{ organizations = @('example') } }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{}; resources = @{ organizations = @('example') } }
        }
        $instance.credentials = @{
            observer = @{
                plan = @{ environment = 'observer-plan'; githubApp = 'reader' }
                apply = @{ environment = 'observer-apply'; githubApp = 'writer' }
            }
        }
        $path = Join-Path $TestDrive 'complete.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        $validated = & $validator -InstancePath $path -ModulesPath $fixtures | ConvertFrom-Json

        $validated.teardown.allowed | Should -BeFalse
        $validated.regions.secondary | Should -Be 'northeurope'
        $validated.modules.observer.parameters.options.enabled | Should -BeTrue
        $validated.credentials.observer.plan.githubApp | Should -Be 'reader'
        $validated.manualSteps.application.'verify-access' | Should -BeTrue
    }

    It 'rejects invalid <Field> with its path' -ForEach @(
        @{ Field = 'instance.name'; Value = 'toolong99'; Path = '$.instance.name' }
        @{ Field = 'instance.name'; Value = 'Bad'; Path = '$.instance.name' }
        @{ Field = 'regions.primary'; Value = ''; Path = '$.regions.primary' }
        @{ Field = 'regions.secondary'; Value = $null; Path = '$.regions.secondary' }
        @{ Field = 'teams.platform'; Value = @('not-a-upn'); Path = '$.teams.platform' }
        @{ Field = 'teams.security'; Value = @(); Path = '$.teams.security' }
        @{ Field = 'teardown'; Value = @{ allowed = 'true' }; Path = '$.teardown.allowed' }
        @{ Field = 'customPatterns'; Value = @(@{ name = 'pattern' }); Path = '$.customPatterns' }
        @{ Field = 'manualPrerequisites.tenant'; Value = 'verified'; Path = '$.manualPrerequisites.tenant' }
        @{ Field = 'modules.observer.parameters'; Value = @{ options = @{ clientSecret = 'unsafe' } }; Path = '$.modules.observer.parameters' }
        @{ Field = 'modules.observer.parameters'; Value = @{ message = '-----BEGIN PRIVATE KEY-----' }; Path = '$.modules.observer.parameters' }
        @{ Field = 'modules.observer.parameters'; Value = @{ token = 'unsafe' }; Path = '$.modules.observer.parameters' }
        @{ Field = 'modules.observer.parameters'; Value = @{ prerequisites = @{} }; Path = '$.modules.observer.parameters' }
        @{ Field = 'modules.observer.parameters'; Value = @{ Instance = @{} }; Path = '$.modules.observer.parameters' }
        @{ Field = 'modules.observer.parameters'; Value = @{ options = @(@{ details = @{ ACCESS_TOKEN = 'unsafe' } }) }; Path = '$.modules.observer.parameters' }
    ) {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $segments = $Field.Split('.')
        $parent = $instance
        foreach ($segment in $segments | Select-Object -SkipLast 1) {
            $parent = $parent[$segment]
        }
        $parent[$segments[-1]] = $Value
        $file = Join-Path $TestDrive 'invalid-field.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $file

        { & $validator -InstancePath $file -ModulesPath $fixtures } |
            Should -Throw "*$Path*"
    }

    It 'rejects unsafe credential binding: <Case>' -ForEach @(
        @{ Case = 'unknown App'; App = 'missing'; ApplyEnvironment = 'observer-apply'; WriterId = '102'; Error = '*$.credentials.observer.plan.githubApp*' }
        @{ Case = 'shared environment'; App = 'reader'; ApplyEnvironment = 'observer-plan'; WriterId = '102'; Error = '*$.credentials.observer.apply.environment*' }
        @{ Case = 'the same App under different aliases'; App = 'reader'; ApplyEnvironment = 'observer-apply'; WriterId = '101'; Error = '*$.credentials.observer*githubApp*' }
    ) {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.githubApps = @{
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{}; resources = @{ organizations = @('example') } }
            writer = @{ appId = $WriterId; installationId = '202'; enterprise = 'example'; permissions = @{}; resources = @{ organizations = @('example') } }
        }

        $instance.credentials = @{
            observer = @{
                plan = @{ environment = 'observer-plan'; githubApp = $App }
                apply = @{ environment = $ApplyEnvironment; githubApp = 'writer' }
            }
        }
        $file = Join-Path $TestDrive 'unsafe-binding.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $file

        { & $validator -InstancePath $file -ModulesPath $fixtures } | Should -Throw $Error
    }

    It 'rejects sharing one App key across different resource scopes in the same phase' {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.githubApps = @{
            first = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{}; resources = @{ organizations = @('first-org') } }
            second = @{ appId = '101'; installationId = '202'; enterprise = 'example'; permissions = @{}; resources = @{ organizations = @('second-org') } }
        }
        $instance.credentials = @{
            observer = @{ plan = @{ environment = 'observer-plan'; githubApp = 'first' }; apply = @{ environment = 'observer-apply' } }
            foundation = @{ plan = @{ environment = 'foundation-plan'; githubApp = 'second' }; apply = @{ environment = 'foundation-apply' } }
        }
        $file = Join-Path $TestDrive 'different-resources.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $file

        { & $validator -InstancePath $file -ModulesPath $fixtures } | Should -Throw '*private-key identity*resources*'
    }

    It 'rejects a write-capable App key in plan even if a token could be narrowed' {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.githubApps = @{
            writer = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ contents = 'write' }; resources = @{ organizations = @('example') } }
        }
        $instance.credentials = @{
            observer = @{ plan = @{ environment = 'observer-plan'; githubApp = 'writer' }; apply = @{ environment = 'observer-apply' } }
        }
        $file = Join-Path $TestDrive 'write-key.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $file

        { & $validator -InstancePath $file -ModulesPath $fixtures } | Should -Throw '*read-only App*write-capable key*'
    }

    It 'reserves each effective credential environment for one module and phase: <Case>' -ForEach @(
        @{ Case = 'collision with an implicit plan environment'; Foundation = $false; PlanEnvironment = 'application-read'; ApplyEnvironment = 'foundation-plan'; Error = '*$.credentials.application.apply.environment*' }
        @{ Case = 'two modules sharing an explicit plan environment'; Foundation = $true; PlanEnvironment = 'foundation-read'; ApplyEnvironment = 'application-write'; Error = '*$.credentials.*.plan.environment*' }
    ) {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.modules = @{ application = @{} }
        $instance.credentials = @{
            application = @{
                plan = @{ environment = $PlanEnvironment }
                apply = @{ environment = $ApplyEnvironment }
            }
        }
        if ($Foundation) {
            $instance.credentials.foundation = @{
                plan = @{ environment = 'foundation-read' }
                apply = @{ environment = 'foundation-write' }
            }
        }
        $file = Join-Path $TestDrive 'environment-collision.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $file

        { & $validator -InstancePath $file -ModulesPath $fixtures } | Should -Throw $Error
    }

    It 'rejects a module environment reserved for workflow gate <Gate>' -ForEach @(
        @{ Gate = 'approve-apply' }, @{ Gate = 'pr-authorization' }, @{ Gate = 'approve-teardown-platform' }
        @{ Gate = 'teardown' }, @{ Gate = 'drift-report' }
    ) {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.modules = @{ application = @{} }
        $instance.credentials = @{ application = @{ plan = @{ environment = $Gate }; apply = @{ environment = 'application-write' } } }
        $file = Join-Path $TestDrive 'reserved-environment.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $file

        { & $validator -InstancePath $file -ModulesPath $fixtures } | Should -Throw '*$.credentials.application.plan.environment is reserved*'
    }
}
