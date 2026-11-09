BeforeAll {
    $reporter = Join-Path (Split-Path $PSScriptRoot -Parent) 'Write-DeploymentSummary.ps1'

    function Get-PlanContext {
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

Describe 'Deployment apply status' {
    BeforeEach {
        $needs = Get-PlanContext
        $needs.authorize.outputs.attempt = '1'
        $needs.plan_complete = @{ result = 'success'; outputs = @{ changes = 'true' } }
        $needs.approve_apply = @{ result = 'success' }
        foreach ($node in @('enterprise-baseline:code-security', 'enterprise-baseline', 'observer')) {
            $needs['apply_' + $node.Replace('-', '_').Replace(':', '_')] = @{ result = 'success' }
        }
    }

    It 'reports successful completion only for the selected apply phases' {
        $needs.apply_unselected = @{ result = 'skipped' }
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -Apply -ApplyRequested true -RunAttempt 1 -JobSummaryPath '' 6>$null } |
            Should -Not -Throw
    }

    It 'rejects a failed-only rerun even when every formerly failed apply was skipped' {
        $needs.apply_observer.result = 'skipped'
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -Apply -ApplyRequested true -RunAttempt 2 -JobSummaryPath '' 6>$null } |
            Should -Throw '*Re-run all jobs*'
    }

    It 'rejects a selected apply with result <Result>' -ForEach @(
        @{ Result = 'failure' }
        @{ Result = 'skipped' }
        @{ Result = 'cancelled' }
        @{ Result = '' }
        @{ Result = 'unknown' }
        @{ Result = $null }
    ) {
        $needs.apply_observer.result = $Result
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -Apply -ApplyRequested true -RunAttempt 1 -JobSummaryPath '' 6>$null } |
            Should -Throw '*Apply INCOMPLETE*apply_observer*'
    }

    It 'keeps no-change and explicitly plan-only execution distinct from a performed apply: <Case>' -ForEach @(
        @{ Case = 'no change'; Requested = 'true'; Changes = 'false' }
        @{ Case = 'plan-only'; Requested = 'false'; Changes = 'true' }
    ) {
        $needs.plan_complete.outputs.changes = $Changes
        $needs.approve_apply.result = 'skipped'
        $needs.apply_observer.result = 'skipped'
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -Apply -ApplyRequested $Requested -RunAttempt 1 -JobSummaryPath '' 6>$null } |
            Should -Not -Throw
    }

    It 'reports denied authorization without implying an apply' {
        $needs.authorize.outputs.allowed = 'false'
        $needs.select.result = 'skipped'
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -Apply -ApplyRequested true -RunAttempt 1 -JobSummaryPath '' 6>$null } |
            Should -Not -Throw
    }

    It 'rejects incomplete apply context: <Case>' -ForEach @(
        @{ Case = 'missing attempt'; Change = { $needs.authorize.outputs.Remove('attempt') }; Error = '*stale authorization*' }
        @{ Case = 'non-string attempt'; Change = { $needs.authorize.outputs.attempt = @(1) }; Error = '*stale authorization*' }
        @{ Case = 'failed authorization'; Change = { $needs.authorize.result = 'failure' }; Error = '*authorization failed*' }
        @{ Case = 'uppercase authorization status'; Change = { $needs.authorize.result = 'SUCCESS' }; Error = '*authorization failed*' }
        @{ Case = 'unknown authorization'; Change = { $needs.authorize.outputs.allowed = '' }; Error = '*unreadable authorization*' }
        @{ Case = 'uppercase allowed decision'; Change = { $needs.authorize.outputs.allowed = 'TRUE' }; Error = '*unreadable authorization*' }
        @{ Case = 'uppercase denied decision'; Change = { $needs.authorize.outputs.allowed = 'FALSE' }; Error = '*unreadable authorization*' }
        @{ Case = 'failed selection'; Change = { $needs.select.result = 'failure' }; Error = '*selection or cloud plan*' }
        @{ Case = 'uppercase selection status'; Change = { $needs.select.result = 'SUCCESS' }; Error = '*selection or cloud plan*' }
        @{ Case = 'failed plan'; Change = { $needs.plan_complete.result = 'failure' }; Error = '*selection or cloud plan*' }
        @{ Case = 'uppercase plan status'; Change = { $needs.plan_complete.result = 'SUCCESS' }; Error = '*selection or cloud plan*' }
        @{ Case = 'scalar selection'; Change = { $needs.select.outputs.phaseNodes = '"observer"' }; Error = '*unreadable selected phases*' }
        @{ Case = 'non-string phase'; Change = { $needs.select.outputs.phaseNodes = '[1]' }; Error = '*unreadable selected phases*' }
        @{ Case = 'invalid phase'; Change = { $needs.select.outputs.phaseNodes = '["../observer"]' }; Error = '*unreadable selected phases*' }
        @{ Case = 'unknown plan decision'; Change = { $needs.plan_complete.outputs.changes = 'unknown' }; Error = '*unreadable plan change*' }
        @{ Case = 'uppercase plan decision'; Change = { $needs.plan_complete.outputs.changes = 'TRUE' }; Error = '*unreadable plan change*' }
        @{ Case = 'empty changed selection'; Change = { $needs.select.outputs.phaseNodes = '[]' }; Error = '*empty phase selection*' }
        @{ Case = 'missing shared approval'; Change = { $needs.approve_apply.result = 'skipped' }; Error = '*shared apply approval*' }
        @{ Case = 'uppercase shared approval'; Change = { $needs.approve_apply.result = 'SUCCESS' }; Error = '*shared apply approval*' }
        @{ Case = 'missing selected apply'; Change = { $needs.Remove('apply_observer') }; Error = '*apply_observer*' }
        @{ Case = 'uppercase selected apply status'; Change = { $needs.apply_observer.result = 'SUCCESS' }; Error = '*apply_observer*' }
    ) {
        . $Change
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -Apply -ApplyRequested true -RunAttempt 1 -JobSummaryPath '' 6>$null } |
            Should -Throw $Error
    }

    It 'rejects an unreadable current workflow attempt: <Attempt>' -ForEach @(
        @{ Attempt = '' }
        @{ Attempt = '0' }
        @{ Attempt = '01' }
        @{ Attempt = 'unknown' }
    ) {
        $needs.authorize.outputs.attempt = $Attempt
        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -Apply -ApplyRequested true -RunAttempt $Attempt -JobSummaryPath '' 6>$null } |
            Should -Throw '*stale authorization*'
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
        $needs = Get-PlanContext
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
        @{ Case = 'missing changes'; Outputs = @{}; Reason = 'missing the changes output. Promote the updated vendored deployment workflow template to the live .github/workflows in a separate reviewed PR (see platform/docs/vendoring.md)' }
        foreach ($value in @('', 'unknown', 'TRUE', 'FALSE', $null, $true, $false, 0, @('false'), @{ value = 'false' })) {
            @{ Case = "invalid changes [$value]"; Outputs = @{ changes = $value }; Reason = 'invalid changes output' }
        }
    ) {
        $needs = Get-PlanContext
        $needs.module_enterprise_baseline_code_security.outputs.changes = 'true'
        if ($null -eq $Outputs) { $needs.module_observer.Remove('outputs') }
        else { $needs.module_observer.outputs = $Outputs }
        $output = Join-Path $caseDirectory 'invalid.txt'
        $summary = Join-Path $caseDirectory 'invalid.md'

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary -GitHubOutputPath $output 6>$null } |
            Should -Throw "*INCOMPLETE*module_observer*$Reason*Apply is blocked*"

        Test-Path -LiteralPath $output | Should -BeFalse
        Test-Path -LiteralPath $summary | Should -BeTrue
        [IO.File]::ReadAllText($summary) | Should -BeLike "*INCOMPLETE*module_observer*$Reason*Apply is blocked*"
    }

    It 'does not publish a decision before summary persistence and can retry after an interrupted report' {
        $needs = Get-PlanContext
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
        $needs = Get-PlanContext
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
