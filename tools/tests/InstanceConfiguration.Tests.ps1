BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $validator = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-InstanceConfiguration.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
    $example = Join-Path $PSScriptRoot 'fixtures/instance.yaml'
}

Describe 'Instance configuration validation' {
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
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example' }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example' }
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
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example' }
            writer = @{ appId = $WriterId; installationId = '202'; enterprise = 'example' }
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
}
