BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-Module.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/runner-modules'
    $example = Join-Path $PSScriptRoot 'fixtures/instance.yaml'
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

    It 'plans known outputs without applying or creating a module state' {
        $result = & $runner -Module foundation -Action plan @arguments 6>$null

        $outputs = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json
        $outputs.message | Should -Be 'hello'
        $result.HasChanges | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $arguments.StatePath 'foundation.tfstate') | Should -BeFalse
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
