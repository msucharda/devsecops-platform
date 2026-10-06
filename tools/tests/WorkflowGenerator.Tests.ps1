BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $generator = Join-Path $toolsPath 'Generate-DeploymentWorkflow.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
}

Describe 'Deployment workflow generation' {
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
        $moduleJobs | Should -Be @('module_application', 'module_foundation', 'module_observer', 'module_service')
        $workflow.jobs.module_application.needs | Should -Contain 'module_foundation'
        $workflow.jobs.module_observer.needs | Should -Not -Contain 'module_foundation'
    }

    It 'gates jobs on runtime selection and successful prerequisites without propagating unrelated skips' {
        $output = Join-Path $TestDrive 'selection.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output

        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        $workflow.jobs.select.outputs.modules | Should -Be '${{ steps.modules.outputs.modules }}'
        $workflow.jobs.module_application.needs | Should -Be @('select', 'module_foundation')
        $workflow.jobs.module_observer.needs | Should -Be @('select')
        $workflow.jobs.module_application.if | Should -Be '${{ !cancelled() && needs.select.result == ''success'' && contains(fromJSON(needs.select.outputs.modules), ''application'') && needs.module_foundation.result == ''success'' }}'
        $workflow.jobs.module_observer.if | Should -Be '${{ !cancelled() && needs.select.result == ''success'' && contains(fromJSON(needs.select.outputs.modules), ''observer'') }}'
        $workflow.jobs.select.steps[-1].run | Should -Match 'Select-InstanceModules\.ps1.*-InstancePath ./instance.yaml.*-GitHubOutputPath'
    }

    It 'produces identical bytes despite directory creation order and prerequisite ordering' {
        $modules = Join-Path $TestDrive 'reordered'
        New-Item -ItemType Directory -Path $modules | Out-Null
        foreach ($name in @('service', 'observer', 'foundation', 'application')) {
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

    It 'checks committed output without rewriting stale content' {
        $output = Join-Path $TestDrive 'checked.yml'
        & $generator -ModulesPath $fixtures -OutputPath $output
        { & $generator -ModulesPath $fixtures -OutputPath $output -Check } | Should -Not -Throw
        [IO.File]::WriteAllText($output, 'stale workflow')

        { & $generator -ModulesPath $fixtures -OutputPath $output -Check } |
            Should -Throw '*workflow differs*'
        [IO.File]::ReadAllText($output) | Should -Be 'stale workflow'
    }

    It 'generates a selection-only scaffold when no executable modules exist' {
        $modules = Join-Path $TestDrive 'empty-modules'
        New-Item -ItemType Directory -Path $modules | Out-Null
        $output = Join-Path $TestDrive 'empty.yml'

        & $generator -ModulesPath $modules -OutputPath $output

        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        @($workflow.jobs.Keys) | Should -Be @('select')
    }

    It 'supports module names matching dictionary members or the selection job: <Name>' -ForEach @(
        @{ Name = 'keys' }
        @{ Name = 'values' }
        @{ Name = 'count' }
        @{ Name = 'select' }
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

    It 'rejects duplicate manual step identifiers even if their descriptions differ' {
        $modules = Join-Path $TestDrive 'duplicate-steps'
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'application/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.manualSteps += @{ id = 'verify-access'; description = 'A different description.' }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw '*application*duplicate manual step*verify-access*'
    }

    It 'rejects module names that do not match their directory' {
        $modules = Join-Path $TestDrive 'mismatched-name'
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'observer/module.yaml'
        (Get-Content -LiteralPath $manifestPath -Raw).Replace('name: observer', 'name: different') |
            Set-Content -LiteralPath $manifestPath

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw '*different*directory*observer*'
    }

    It 'rejects <Case> and names the affected modules without writing a workflow' -ForEach @(
        @{ Case = 'a missing prerequisite'; Module = 'application'; Prerequisites = '[missing]'; Error = "*application*missing*" }
        @{ Case = 'a prerequisite cycle'; Module = 'foundation'; Prerequisites = '[application]'; Error = "*Prerequisite cycle*application*foundation*application*" }
        @{ Case = 'a self cycle'; Module = 'observer'; Prerequisites = '[observer]'; Error = "*Prerequisite cycle*observer*observer*" }
    ) {
        $modules = Join-Path $TestDrive $Module
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules "$Module/module.yaml"
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.prerequisites = ConvertFrom-Yaml $Prerequisites
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
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
        $modules = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'application/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $segments = $Field.Split('.')
        $parent = $manifest
        foreach ($segment in $segments[0..($segments.Count - 1)] | Select-Object -SkipLast 1) {
            $parent = $parent[$segment]
        }
        $parent[$segments[-1]] = $Value
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

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
        $modules = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Copy-Item -LiteralPath $fixtures -Destination $modules -Recurse
        $manifestPath = Join-Path $modules 'application/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $segments = $Field.Split('.')
        if ($segments.Count -eq 1) {
            $manifest.Remove($Field)
        }
        else {
            $manifest.permissions.Remove($segments[1])
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $generator -ModulesPath $modules -OutputPath (Join-Path $modules 'invalid.yml') } |
            Should -Throw '*Invalid module manifest*application*'
    }
}
