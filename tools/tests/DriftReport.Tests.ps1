BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $reporter = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-DriftReport.ps1'
    $modulesPath = Join-Path $PSScriptRoot 'fixtures/modules'
    $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/runner-instance.yaml') -Raw)
    $instance.modules['enterprise-baseline'] = @{ parameters = @{ target_organizations = @('platform') } }
    $instance.manualPrerequisites = @{ tenant = $true }
    $instance.manualSteps = @{ application = @{ 'verify-access' = $true } }
    $instancePath = Join-Path $TestDrive 'instance.yaml'
    ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
    $revision = 'a' * 40
    $coverageArtifact = Join-Path $TestDrive 'code-security-coverage.json'

    function New-CoverageReportModule {
        [CmdletBinding(SupportsShouldProcess)]
        param()

        $path = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        if (-not $PSCmdlet.ShouldProcess($path, 'Create Code Security report fixture')) { return }
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/modules') -Destination $path -Recurse
        $manifestPath = Join-Path $path 'enterprise-baseline/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest['phases'] = @{ 'code-security' = @{ prerequisites = @('foundation'); manualPrerequisites = @() } }
        New-Item -ItemType Directory -Path (Join-Path $path 'enterprise-baseline/code-security') | Out-Null
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        return $path
    }

    function Write-CoverageArtifact {
        param([object[]] $Repositories)
        $counts = @{ repositories = $Repositories }
        foreach ($status in @('compliant', 'drift', 'unverified')) {
            $counts[$status] = @($Repositories | Where-Object { $_.status -ceq $status }).Count
        }
        ConvertTo-Json -InputObject @{ organizations = @{ platform = $counts } } -Depth 10 -Compress |
            Set-Content -LiteralPath $coverageArtifact
    }

    function Get-DriftNeed {
        [CmdletBinding()]
        param()

        $needs = [ordered]@{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true'; revision = $revision } }
            validate = @{ result = 'success'; outputs = @{} }
            select = @{ result = 'success'; outputs = @{
                    modules = '["application","enterprise-baseline","foundation","service"]'
                    rulesetModules = '["enterprise-baseline"]'
                } }
        }
        foreach ($job in @('module_application', 'module_enterprise_baseline', 'module_foundation', 'module_service', 'module_observer')) {
            $needs[$job] = @{ result = 'success'; outputs = @{ changes = 'false' } }
        }
        $needs.module_observer = @{ result = 'skipped'; outputs = @{} }
        $needs['ruleset_plan_enterprise_baseline'] = @{ result = 'success'; outputs = @{ changes = 'false'; inheritedRulesets = '0' } }
        return $needs
    }

    function Invoke-DriftReport {
        [CmdletBinding()]
        param([Parameter(Mandatory)][System.Collections.IDictionary] $Needs, [string] $Instance = $instancePath,
            [string] $CoverageFile = $coverageArtifact)

        $script:reportPath = Join-Path $TestDrive "$([guid]::NewGuid()).md"
        $script:outputPath = Join-Path $TestDrive "$([guid]::NewGuid()).out"
        $script:summaryPath = Join-Path $TestDrive "$([guid]::NewGuid()).summary"
        & $reporter -NeedsJson (ConvertTo-Json -InputObject $Needs -Depth 10)         -InstancePath $Instance -ModulesPath $modulesPath `
            -ReportPath $script:reportPath -GitHubOutputPath $script:outputPath -JobSummaryPath $script:summaryPath `
            -CodeSecurityCoveragePath $CoverageFile -RunUrl 'https://github.example.test/platform/instance/actions/runs/7' 6>$null
        $script:output = @{}
        foreach ($line in [IO.File]::ReadAllLines($script:outputPath)) {
            $name, $value = $line -split '=', 2
            $script:output[$name] = $value
        }
        $script:report = [IO.File]::ReadAllText($script:reportPath)
    }
}

Describe 'Drift report evaluation' {
    It 'reports early Code Security coverage as <Status> with <Security> direct state' -ForEach @(
        @{ Status = 'compliant'; Security = 'enabled'; Publish = 'false'; Complete = 'true' }
        @{ Status = 'drift'; Security = 'disabled'; Publish = 'true'; Complete = 'true' }
        @{ Status = 'drift'; Security = 'unverified'; Publish = 'true'; Complete = 'false' }
        @{ Status = 'unverified'; Security = 'unverified'; Publish = 'true'; Complete = 'false' }
    ) {
        $modulesPath = New-CoverageReportModule
        $needs = Get-DriftNeed
        $counts = @{ compliant = 0; drift = 0; unverified = 0 }
        $counts[$Status] = 1
        $counts['repositories'] = @(@{ repository = 'platform/app'; status = $Status; security_status = $Security; attachment_status = @('attached') })
        $needs['module_enterprise_baseline_code_security'] = @{
            result = 'success'
            outputs = @{
                changes = 'false'
                codeSecurityCoverage = '123'
            }
        }
        Write-CoverageArtifact -Repositories $counts.repositories

        Invoke-DriftReport -Needs $needs

        $output.report | Should -BeExactly $Publish
        $output.complete | Should -BeExactly $Complete
        $report | Should -Match 'Repository Code Security coverage'
        $report | Should -Match "$Status 1"
        if ($Status -cne 'compliant') { $report | Should -Match 'platform/app' }
        if ($Status -ceq 'drift') { $report | Should -Match '### Drift detected' }
        if ($Security -ceq 'unverified') {
            $report | Should -Match 'direct state unverified 1'
            $report | Should -Match "Code Security of repository 'platform/app' is unverified"
            $report | Should -Match 'Drift detection INCOMPLETE'
        }
    }

        It 'marks missing or unreadable coverage artifacts incomplete: <Case>' -ForEach @(
            @{ Case = 'missing'; ArtifactText = $null }
            @{ Case = 'unreadable'; ArtifactText = 'invalid JSON' }
        ) {
            $modulesPath = New-CoverageReportModule
            $needs = Get-DriftNeed
            $needs['module_enterprise_baseline_code_security'] = @{ result = 'success'; outputs = @{ changes = 'false'; codeSecurityCoverage = '123' } }
            $missingOrInvalid = Join-Path $TestDrive "$Case-coverage.json"
            if ($null -ne $ArtifactText) { Set-Content -LiteralPath $missingOrInvalid -Value $ArtifactText }

            Invoke-DriftReport -Needs $needs -CoverageFile $missingOrInvalid

            $output.complete | Should -BeExactly 'false'
            $output.report | Should -BeExactly 'true'
            $report | Should -Match 'coverage.*readable'
        }

        It 'bounds the issue at the exact UTF-8 boundary without discarding drift before unverified: <Target>' -ForEach @(
            @{ Target = 49999; Truncated = $false }
            @{ Target = 50001; Truncated = $true }
        ) {
            $modulesPath = New-CoverageReportModule
            $needs = Get-DriftNeed
            $needs['module_enterprise_baseline_code_security'] = @{ result = 'success'; outputs = @{ changes = 'false'; codeSecurityCoverage = '123' } }
            $needs.module_enterprise_baseline_code_security.outputs.codeSecurityCoverageUrl = 'https://github.example.test/platform/instance/actions/runs/7/artifacts/123'
            $repositories = @(1..250 | ForEach-Object {
                @{ repository = ('platform/u{0:D3}' -f $_); status = 'unverified'; security_status = 'unverified' }
            }) + @(@{ repository = 'platform/real-drift'; status = 'drift'; security_status = 'enabled' })
            Write-CoverageArtifact -Repositories $repositories
            Invoke-DriftReport -Needs $needs
            $sourceLines = ($report -split "`n").Count - 1
            $padding = $Target - [Text.Encoding]::UTF8.GetByteCount($report)
            $padding | Should -BeGreaterThan 0
            foreach ($repository in $repositories) {
                if ($repository.status -cne 'unverified') { continue }
                $added = [Math]::Min(80, $padding)
                $repository.repository += 'x' * $added
                $padding -= $added
                if ($padding -eq 0) { break }
            }
            $padding | Should -Be 0
            Write-CoverageArtifact -Repositories $repositories

            Invoke-DriftReport -Needs $needs

            $report | Should -Match 'drift 1, unverified 250'
            $report | Should -Match 'platform/real-drift'
            $output.complete | Should -BeExactly 'false'
            if ($Truncated) {
                [Text.Encoding]::UTF8.GetByteCount($report) | Should -BeLessOrEqual 50000
                $report | Should -Match 'TRUNCATED'
                $report | Should -Match 'code-security-coverage'
                $report | Should -Match 'retained for 1 day'
                $report | Should -Match 'actions/runs/7/artifacts/123'
                $omitted = [int] [regex]::Match($report, '(\d+) omitted lines').Groups[1].Value
                $omitted | Should -BeGreaterThan 0
                $footer = $report.IndexOf("`n### Drift detection INCOMPLETE: TRUNCATED", [StringComparison]::Ordinal)
                $footer | Should -BeGreaterThan 0
                $retainedLines = ($report.Substring(0, $footer) -split "`n").Count - 1
                $omitted | Should -Be ($sourceLines - $retainedLines)
            }
            else {
                [Text.Encoding]::UTF8.GetByteCount($report) | Should -Be $Target
                $report | Should -Not -Match 'TRUNCATED'
            }
        }

            It 'rejects stale coverage artifacts without a valid current artifact ID: <Case>' -ForEach @(
                @{ Case = 'missing'; ArtifactId = $null }
                @{ Case = 'empty'; ArtifactId = '' }
                @{ Case = 'wrong type'; ArtifactId = 123 }
                @{ Case = 'malformed'; ArtifactId = 'invalid' }
                @{ Case = 'zero'; ArtifactId = '0' }
                @{ Case = 'leading zero'; ArtifactId = '0123' }
            ) {
                $modulesPath = New-CoverageReportModule
                $needs = Get-DriftNeed
                $needs['module_enterprise_baseline_code_security'] = @{
                    result = 'success'; outputs = @{ changes = 'false'; codeSecurityCoverage = $ArtifactId }
                }
                Write-CoverageArtifact -Repositories @(@{ repository = 'platform/app'; status = 'compliant'; security_status = 'enabled' })

                Invoke-DriftReport -Needs $needs

                $output.complete | Should -BeExactly 'false'
                $output.report | Should -BeExactly 'true'
                $report | Should -Match 'artifact was not published.*previous attempt is not evidence'
                $report | Should -Not -Match 'compliant 1'
            }

            It 'evaluates a large coverage artifact without putting repository details in the needs environment' {
                $modulesPath = New-CoverageReportModule
                $needs = Get-DriftNeed
                $needs['module_enterprise_baseline_code_security'] = @{
                    result = 'success'; outputs = @{ changes = 'false'; codeSecurityCoverage = '123' }
                }
                $repositories = @(1..2000 | ForEach-Object {
                    @{ repository = "platform/unverified-$_"; status = 'unverified'; security_status = 'unverified' }
                }) + @(@{ repository = 'platform/real-drift'; status = 'drift'; security_status = 'enabled' })
                Write-CoverageArtifact -Repositories $repositories
                [IO.File]::ReadAllBytes($coverageArtifact).Length | Should -BeGreaterThan 131072
                [Text.Encoding]::UTF8.GetByteCount((ConvertTo-Json -InputObject $needs -Depth 10)) | Should -BeLessThan 8192

                Invoke-DriftReport -Needs $needs

                $output.complete | Should -BeExactly 'false'
                $report | Should -Match 'drift 1, unverified 2000'
                $report | Should -Match 'platform/real-drift'
                $report | Should -Match 'TRUNCATED'
                [Text.Encoding]::UTF8.GetByteCount($report) | Should -BeLessOrEqual 50000
            }

    It 'publishes no issue when every selected plan completed without changes' {
        Invoke-DriftReport -Needs (Get-DriftNeed)

        $output.report | Should -BeExactly 'false'
        $output.complete | Should -BeExactly 'true'
        $report | Should -Match '^<!-- platform-drift-report -->\n'
        $report | Should -Match 'No drift detected'
        [IO.File]::ReadAllText($summaryPath) | Should -Match 'Not covered by automatic drift detection'
    }

    It 'checks only selected phase roots when the phase plan is <Result>' -ForEach @(
        @{ Result = 'success'; Complete = 'true'; Publish = 'false' }
        @{ Result = 'failure'; Complete = 'false'; Publish = 'true' }
    ) {
        $modulesPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/modules') -Destination $modulesPath -Recurse
        $manifestPath = Join-Path $modulesPath 'observer/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest['phases'] = @{ prepare = @{ prerequisites = @(); manualPrerequisites = @() } }
        New-Item -ItemType Directory -Path (Join-Path $modulesPath 'observer/prepare') | Out-Null
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $applicationPath = Join-Path $modulesPath 'application/module.yaml'
        $application = ConvertFrom-Yaml (Get-Content -LiteralPath $applicationPath -Raw)
        $application['prerequisites'] = @('foundation', 'observer:prepare')
        ConvertTo-Yaml $application | Set-Content -LiteralPath $applicationPath
        $needs = Get-DriftNeed
        $needs.select.outputs.modules = '["application","enterprise-baseline","foundation","observer","service"]'
        $needs['module_observer_prepare'] = @{ result = $Result; outputs = @{ changes = 'false' } }

        Invoke-DriftReport -Needs $needs

        $output.complete | Should -BeExactly $Complete
        $output.report | Should -BeExactly $Publish
        $report | Should -Not -Match 'Plan job module_observer did not complete'
        if ($Result -cne 'success') { $report | Should -Match 'Plan job module_observer_prepare did not complete' }
    }

    It 'lists a module with drift in its <Root> root' -ForEach @(
        @{ Root = 'plan'; Job = 'module_application'; Expected = '- `application` (Terraform plan)' }
        @{ Root = 'ruleset'; Job = 'ruleset_plan_enterprise_baseline'; Expected = '- `enterprise-baseline` (rulesets)' }
    ) {
        $needs = Get-DriftNeed
        $needs[$Job].outputs.changes = 'true'

        Invoke-DriftReport -Needs $needs

        $output.report | Should -BeExactly 'true'
        $output.complete | Should -BeExactly 'true'
        $report | Should -Match ([regex]::Escape($Expected))
        $report | Should -Match 'https://github\.example\.test/platform/instance/actions/runs/7'
        $report | Should -Match $revision
    }

    It 'admits drift that the workflow does not detect automatically' {
        $needs = Get-DriftNeed
        $needs['ruleset_plan_enterprise_baseline'].outputs.inheritedRulesets = '3'

        Invoke-DriftReport -Needs $needs

        $report | Should -Match 'Not covered by automatic drift detection'
        $report | Should -Match 'manual enterprise prerequisite `tenant`: confirmed declaration'
        $report | Should -Match 'manual enterprise prerequisite `licenses`: NOT confirmed'
        $report | Should -Match '`application` manual step `verify-access`: Manual changes are not automatically detected\.'
        $report | Should -Match '3 inherited enterprise rulesets'
        $report | Should -Not -Match '### Drift detected'
        $output.report | Should -BeExactly 'false'
    }

    It 'reports an incomplete run when <Case>' -ForEach @(
        @{ Case = 'authorization failed'; Change = { param($n) $n.authorize.result = 'failure' } }
        @{ Case = 'main was not confirmed'; Change = { param($n) $n.authorize.outputs.allowed = 'false' } }
        @{ Case = 'validation failed'; Change = { param($n) $n.validate.result = 'failure' } }
        @{ Case = 'selection was skipped'; Change = { param($n) $n.select.result = 'skipped' } }
        @{ Case = 'the ruleset selection is missing'; Change = { param($n) $n.select.outputs.Remove('rulesetModules') } }
        @{ Case = 'the selection is not a JSON list'; Change = { param($n) $n.select.outputs.modules = 'application' } }
        @{ Case = 'the selection differs from the trusted instance'; Change = { param($n) $n.select.outputs.modules = '["application","foundation"]' } }
        @{ Case = 'the ruleset selection differs from the manifests'; Change = { param($n) $n.select.outputs.rulesetModules = '[]' } }
        @{ Case = 'a selected plan failed'; Change = { param($n) $n.module_foundation.result = 'failure' } }
        @{ Case = 'a selected plan was skipped'; Change = { param($n) $n.module_service.result = 'skipped' } }
        @{ Case = 'a selected plan job is missing'; Change = { param($n) $n.Remove('module_application') } }
        @{ Case = 'a ruleset plan failed'; Change = { param($n) $n.ruleset_plan_enterprise_baseline.result = 'failure' } }
        @{ Case = 'a plan did not publish its change state'; Change = { param($n) $n.module_application.outputs.Remove('changes') } }
        @{ Case = 'a change state is not a boolean'; Change = { param($n) $n.module_application.outputs.changes = 'True' } }
        @{ Case = 'the inherited ruleset count is missing'; Change = { param($n) $n.ruleset_plan_enterprise_baseline.outputs.Remove('inheritedRulesets') } }
        @{ Case = 'the inherited ruleset count is invalid'; Change = { param($n) $n.ruleset_plan_enterprise_baseline.outputs.inheritedRulesets = '-1' } }
    ) {
        $needs = Get-DriftNeed
        & $Change $needs

        Invoke-DriftReport -Needs $needs

        $output.report | Should -BeExactly 'true'
        $output.complete | Should -BeExactly 'false'
        $report | Should -Match 'Drift detection INCOMPLETE'
        $report | Should -Not -Match 'No drift detected'
    }

    It 'keeps detected drift visible in an incomplete run' {
        $needs = Get-DriftNeed
        $needs.module_application.outputs.changes = 'true'
        $needs.module_service.result = 'failure'

        Invoke-DriftReport -Needs $needs

        $output.complete | Should -BeExactly 'false'
        $report | Should -Match '- `application` \(Terraform plan\)'
        $report | Should -Match 'module_service'
    }

    It 'keeps drift detected by a plan whose job later failed in the <Root> root' -ForEach @(
        @{ Root = 'plan'; Job = 'module_application'; Expected = '- `application` (Terraform plan)' }
        @{ Root = 'ruleset'; Job = 'ruleset_plan_enterprise_baseline'; Expected = '- `enterprise-baseline` (rulesets)' }
    ) {
        $needs = Get-DriftNeed
        $needs[$Job].outputs.changes = 'true'
        $needs[$Job].result = 'failure'

        Invoke-DriftReport -Needs $needs

        $output.report | Should -BeExactly 'true'
        $output.complete | Should -BeExactly 'false'
        $report | Should -Match '### Drift detected'
        $report | Should -Match ([regex]::Escape($Expected))
        $report | Should -Match "Plan job $Job did not complete"
    }

    It 'reports an incomplete run when the trusted instance cannot be read' {
        Invoke-DriftReport -Needs (Get-DriftNeed) -Instance (Join-Path $TestDrive 'missing.yaml')

        $output.complete | Should -BeExactly 'false'
        $output.report | Should -BeExactly 'true'
        $report | Should -Match 'trusted instance configuration'
    }

    It 'treats unreadable job results as incomplete instead of failing before reporting' {
        $script:reportPath = Join-Path $TestDrive 'invalid.md'
        $script:outputPath = Join-Path $TestDrive 'invalid.out'

        & $reporter -NeedsJson 'not json' -InstancePath $instancePath -ModulesPath $modulesPath -ReportPath $reportPath `
            -GitHubOutputPath $outputPath -JobSummaryPath (Join-Path $TestDrive 'invalid.summary') -RunUrl 'https://github.example.test/r' 6>$null

        [IO.File]::ReadAllText($outputPath) | Should -BeExactly "report=true`ncomplete=false`n"
        [IO.File]::ReadAllText($reportPath) | Should -Match 'Drift detection INCOMPLETE'
    }
}
