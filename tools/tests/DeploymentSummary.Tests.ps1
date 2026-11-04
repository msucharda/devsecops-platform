BeforeAll {
    $reporter = Join-Path (Split-Path $PSScriptRoot -Parent) 'Write-DeploymentSummary.ps1'

    function New-PlanNeeds {
        return @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{
                modules = '["enterprise-baseline","observer"]'
                phaseNodes = '["enterprise-baseline:code-security","enterprise-baseline","observer"]'
                rulesetModules = '["enterprise-baseline"]'
            } }
            module_enterprise_baseline_code_security = @{ result = 'success'; outputs = @{ changes = 'false' } }
            module_enterprise_baseline = @{ result = 'success'; outputs = @{ changes = 'false' } }
            module_observer = @{ result = 'success'; outputs = @{ changes = 'false' } }
            ruleset_plan_enterprise_baseline = @{ result = 'success'; outputs = @{ changes = 'false' } }
            module_unselected = @{ result = 'skipped'; outputs = @{ changes = 'true' } }
        }
    }
}

Describe 'Deployment plan status' {
    BeforeEach {
        $caseDirectory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $caseDirectory
    }

    It 'publishes a complete plan decision for <Case>' -ForEach @(
        @{ Case = 'no changes'; ChangedJob = ''; Expected = 'false' }
        @{ Case = 'an early phase change'; ChangedJob = 'module_enterprise_baseline_code_security'; Expected = 'true' }
        @{ Case = 'an ordinary module change'; ChangedJob = 'module_enterprise_baseline'; Expected = 'true' }
        @{ Case = 'another module change'; ChangedJob = 'module_observer'; Expected = 'true' }
        @{ Case = 'a ruleset-only change'; ChangedJob = 'ruleset_plan_enterprise_baseline'; Expected = 'true' }
    ) {
        $needs = New-PlanNeeds
        if ($ChangedJob) { $needs[$ChangedJob].outputs.changes = 'true' }
        $summary = Join-Path $caseDirectory 'decision.md'
        $output = Join-Path $caseDirectory 'decision.txt'

        & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary -GitHubOutputPath $output 6>$null

        [IO.File]::ReadAllText($output) | Should -BeExactly "changes=$Expected`n"
        if ($Expected -ceq 'false') {
            [IO.File]::ReadAllText($summary) | Should -Match 'No changes. No apply approval or apply is required.'
        }
    }

    # Invalid outputs deliberately model missing or corrupt runner results.
    It 'rejects plan change output <Case> without publishing a successful decision' -ForEach @(
        @{ Case = 'missing outputs'; Outputs = $null; Reason = 'no readable plan outputs' }
        @{ Case = 'an array instead of outputs'; Outputs = @(@{ changes = 'false' }); Reason = 'no readable plan outputs' }
        @{ Case = 'missing changes'; Outputs = @{}; Reason = 'missing the changes output' }
        foreach ($value in @('', 'unknown', 'TRUE', 'FALSE', $null, $true, $false, 0, @('false'), @{ value = 'false' })) {
            @{ Case = "invalid changes [$value]"; Outputs = @{ changes = $value }; Reason = 'invalid changes output' }
        }
    ) {
        $needs = New-PlanNeeds
        $needs.module_enterprise_baseline_code_security.outputs.changes = 'true'
        if ($null -eq $Outputs) { $needs.module_observer.Remove('outputs') }
        else { $needs.module_observer.outputs = $Outputs }
        $output = Join-Path $caseDirectory 'invalid.txt'

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath (Join-Path $TestDrive 'invalid.md') -GitHubOutputPath $output 6>$null } |
            Should -Throw "*INCOMPLETE*module_observer*$Reason*Apply is blocked*"

        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'does not publish a decision before summary persistence and can retry after an interrupted report' {
        $needs = New-PlanNeeds
        $needs.module_observer.outputs.changes = 'true'
        $output = Join-Path $TestDrive 'retry.txt'
        $summary = Join-Path $TestDrive 'retry.md'

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath (Join-Path $TestDrive 'missing/summary.md') -GitHubOutputPath $output 6>$null } |
            Should -Throw
        Test-Path -LiteralPath $output | Should -BeFalse

        & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary -GitHubOutputPath $output 6>$null

        [IO.File]::ReadAllText($output) | Should -BeExactly "changes=true`n"
    }

    It 'reports an empty selection as successful without apply' {
        $needs = New-PlanNeeds
        $needs.select.outputs = @{ modules = '[]'; phaseNodes = '[]'; rulesetModules = '[]' }
        $output = Join-Path $TestDrive 'empty.txt'
        $summary = Join-Path $TestDrive 'empty.md'

        & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary -GitHubOutputPath $output 6>$null

        [IO.File]::ReadAllText($output) | Should -BeExactly "changes=false`n"
        [IO.File]::ReadAllText($summary) | Should -Match 'No modules selected'
    }

    It 'accepts only successful plans for every selected staged phase before apply' {
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{
                modules = '["enterprise-baseline","organizations"]'
                phaseNodes = '["enterprise-baseline:code-security","organizations"]'
                rulesetModules = '[]'
            } }
            module_enterprise_baseline_code_security = @{ result = 'success'; outputs = @{ changes = 'false' } }
            module_organizations = @{ result = 'success'; outputs = @{ changes = 'false' } }
            module_enterprise_baseline = @{ result = 'skipped' }
        }
        $summary = Join-Path $TestDrive 'stage.md'

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary 6>$null } |
            Should -Not -Throw
        $needs.module_enterprise_baseline_code_security.result = 'failure'
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary 6>$null } |
            Should -Throw '*INCOMPLETE*module_enterprise_baseline_code_security*'
        $needs.select.outputs.phaseNodes = 'not-json'
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary 6>$null } |
            Should -Throw '*invalid selected deployment phases*'
    }

    It 'explicitly marks denied PR plans as unperformed, not verified' {
        $summary = Join-Path $TestDrive 'denied.md'
        $needs = @{ authorize = @{ result = 'success'; outputs = @{ allowed = 'false' } } }

        & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary 6>$null

        [IO.File]::ReadAllText($summary) | Should -Match 'Cloud plan NOT PERFORMED'
        [IO.File]::ReadAllText($summary) | Should -Match 'validation is not a cloud plan'
    }

    It 'blocks apply if a selected module or ruleset exception has not completed: <Case>' -ForEach @(
        @{ Case = 'failed prerequisite'; ModuleStatus = 'failure'; RulesetStatus = 'success' }
        @{ Case = 'skipped ruleset exception'; ModuleStatus = 'success'; RulesetStatus = 'skipped' }
    ) {
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{ modules = '["enterprise-baseline"]'; rulesetModules = '["enterprise-baseline"]' } }
            module_enterprise_baseline = @{ result = $ModuleStatus }
            ruleset_plan_enterprise_baseline = @{ result = $RulesetStatus }
        }
        $summary = Join-Path $TestDrive 'incomplete.md'

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary 6>$null } |
            Should -Throw '*INCOMPLETE*Apply is blocked*'
    }

    It 'blocks stale workflows that omit a declared ruleset plan job' {
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{ modules = '["enterprise-baseline"]'; rulesetModules = '["enterprise-baseline"]' } }
            module_enterprise_baseline = @{ result = 'success' }
        }

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath (Join-Path $TestDrive 'missing-ruleset.md') 6>$null } |
            Should -Throw '*INCOMPLETE*ruleset_plan_enterprise_baseline*'
    }

    It 'blocks apply when the workflow is stale and lacks a selected module job' {
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{ modules = '["new-module"]'; rulesetModules = '[]' } }
        }

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath (Join-Path $TestDrive 'stale.md') 6>$null } |
            Should -Throw '*INCOMPLETE*module_new_module*'
    }

    It 'blocks workflows that cannot report their declared ruleset selection' {
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{ modules = '["observer"]' } }
            module_observer = @{ result = 'success'; outputs = @{ changes = 'false' } }
        }

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath (Join-Path $TestDrive 'missing-selection.md') 6>$null } |
            Should -Throw '*INCOMPLETE*missing declared ruleset selection*regenerate*'
    }

    It 'reports successful complete plans without claiming to verify manual confirmations' {
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{ modules = '["observer"]'; rulesetModules = '[]' } }
            module_observer = @{ result = 'success'; outputs = @{ changes = 'false' } }
        }
        $summary = Join-Path $TestDrive 'complete.md'

        & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary 6>$null

        [IO.File]::ReadAllText($summary) | Should -Match 'Cloud plan completed'
        [IO.File]::ReadAllText($summary) | Should -Match 'Manual confirmations are not automatically verified'
    }
}
