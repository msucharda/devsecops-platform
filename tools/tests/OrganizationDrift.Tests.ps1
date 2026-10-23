BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $reporter = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-DriftReport.ps1'
}

Describe 'Per-organization drift completeness' {
    BeforeEach {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $modules = Join-Path $directory 'modules'
        $null = New-Item -ItemType Directory -Path $modules -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/organization-module') -Destination (Join-Path $modules 'scoped') -Recurse
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ scoped = @{ parameters = @{ target_organizations = @('demo-platform', 'demo-actions', 'demo-workloads') } } }
        $instancePath = Join-Path $directory 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $results = [ordered]@{
            'demo-platform' = @{ result = 'success'; changes = $false }
            'demo-actions' = @{ result = 'success'; changes = $false }
            'demo-workloads' = @{ result = 'success'; changes = $false }
        }
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true'; revision = ('a' * 40) } }
            validate = @{ result = 'success'; outputs = @{} }
            select = @{ result = 'success'; outputs = @{ modules = '["scoped"]'; rulesetModules = '[]' } }
            module_scoped = @{ result = 'success'; outputs = @{ changes = 'false' } }
        }
        $reportPath = Join-Path $directory 'report.md'
        $outputPath = Join-Path $directory 'output'
        function Invoke-OrganizationDriftReport {
            $needs.module_scoped.outputs.organizations = ConvertTo-Json -InputObject $results -Depth 10 -Compress
            & $reporter -NeedsJson (ConvertTo-Json -InputObject $needs -Depth 20) -InstancePath $instancePath `
                -ModulesPath $modules -ReportPath $reportPath -GitHubOutputPath $outputPath `
                -JobSummaryPath (Join-Path $directory 'summary.md') 6>$null
        }
        $oldOwner = $env:GITHUB_REPOSITORY_OWNER
        $env:GITHUB_REPOSITORY_OWNER = 'demo-platform'
    }

    AfterEach { $env:GITHUB_REPOSITORY_OWNER = $oldOwner }

    It 'requires a successful no-change plan for every organization before reporting no drift' {
        Invoke-OrganizationDriftReport
        Get-Content -LiteralPath $outputPath -Raw | Should -BeExactly "report=false`ncomplete=true`n"
    }

    It 'rejects a singleton array wrapping complete organization results' {
        # Deliberately invalid: per-organization results must be a JSON object, not an array.
        $results = @($results)

        Invoke-OrganizationDriftReport

        Get-Content -LiteralPath $outputPath -Raw | Should -BeExactly "report=true`ncomplete=false`n"
        Get-Content -LiteralPath $reportPath -Raw | Should -Match 'did not publish per-organization results'
    }

    It 'names the organization with drift' {
        $results['demo-workloads'].changes = $true
        $needs.module_scoped.outputs.changes = 'true'
        Invoke-OrganizationDriftReport
        $report = Get-Content -LiteralPath $reportPath -Raw
        $report | Should -Match '`scoped` / `demo-workloads`'
        $report | Should -Not -Match 'organization results incomplete'
    }

    It 'preserves reported drift when the configured organization scope cannot be verified' {
        $instance.modules.scoped.parameters.target_organizations = @('demo-platform', 'demo-actions')
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $results['demo-workloads'].changes = $true
        $needs.module_scoped.outputs.changes = 'true'

        Invoke-OrganizationDriftReport

        Get-Content -LiteralPath $outputPath -Raw | Should -Match 'complete=false'
        $report = Get-Content -LiteralPath $reportPath -Raw
        $report | Should -Match 'Drift detected'
        $report | Should -Match '`scoped`.*organization scope unverified'
    }

    It 'preserves aggregate drift without verified organization details: <Case>' -ForEach @(
        @{ Case = 'empty results'; Change = { param($r) $r.Clear() } }
        @{ Case = 'missing organization'; Change = { param($r) $r.Remove('demo-actions') } }
        @{ Case = 'string change state'; Change = { param($r) $r['demo-actions'].changes = 'true' } }
        @{ Case = 'null record'; Change = { param($r) $r['demo-actions'] = $null } }
        @{ Case = 'aggregate disagrees'; Change = { param($r) $null = $r } }
    ) {
        & $Change $results
        $needs.module_scoped.outputs.changes = 'true'

        Invoke-OrganizationDriftReport

        Get-Content -LiteralPath $outputPath -Raw | Should -BeExactly "report=true`ncomplete=false`n"
        $report = Get-Content -LiteralPath $reportPath -Raw
        $report | Should -Match 'Drift detected'
        $report | Should -Match '`scoped`.*organization results incomplete'
        $report | Should -Match 'Drift detection INCOMPLETE'
    }

    It 'marks missing or invalid organization results as incomplete: <Case>' -ForEach @(
        @{ Case = 'missing organization'; Change = { param($r) $r.Remove('demo-actions') } }
        @{ Case = 'extra organization'; Change = { param($r) $r['foreign'] = @{ result = 'success'; changes = $false } } }
        @{ Case = 'failed organization'; Change = { param($r) $r['demo-actions'].result = 'failure' } }
        @{ Case = 'pending organization'; Change = { param($r) $r['demo-actions'].result = 'pending' } }
        @{ Case = 'missing status'; Change = { param($r) $r['demo-actions'].Remove('result') } }
        @{ Case = 'missing change state'; Change = { param($r) $r['demo-actions'].Remove('changes') } }
        @{ Case = 'string change state'; Change = { param($r) $r['demo-actions'].changes = 'false' } }
        @{ Case = 'null record'; Change = { param($r) $r['demo-actions'] = $null } }
        @{ Case = 'aggregate disagrees'; Change = { param($r) $r['demo-actions'].changes = $true } }
    ) {
        & $Change $results
        Invoke-OrganizationDriftReport
        Get-Content -LiteralPath $outputPath -Raw | Should -Match 'complete=false'
        Get-Content -LiteralPath $reportPath -Raw | Should -Match 'Drift detection INCOMPLETE'
    }
}
