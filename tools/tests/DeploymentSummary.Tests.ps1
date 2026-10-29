BeforeAll {
    $reporter = Join-Path (Split-Path $PSScriptRoot -Parent) 'Write-DeploymentSummary.ps1'
}

Describe 'Deployment plan status' {
    It 'accepts only successful plans for every selected staged phase before apply' {
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{
                modules = '["enterprise-baseline","organizations"]'
                phaseNodes = '["enterprise-baseline:code-security","organizations"]'
                rulesetModules = '[]'
            } }
            module_enterprise_baseline_code_security = @{ result = 'success' }
            module_organizations = @{ result = 'success' }
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
            module_observer = @{ result = 'success' }
        }

        { & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath (Join-Path $TestDrive 'missing-selection.md') 6>$null } |
            Should -Throw '*INCOMPLETE*missing declared ruleset selection*regenerate*'
    }

    It 'reports successful complete plans without claiming to verify manual confirmations' {
        $needs = @{
            authorize = @{ result = 'success'; outputs = @{ allowed = 'true' } }
            validate = @{ result = 'success' }
            select = @{ result = 'success'; outputs = @{ modules = '["observer"]'; rulesetModules = '[]' } }
            module_observer = @{ result = 'success' }
        }
        $summary = Join-Path $TestDrive 'complete.md'

        & $reporter -NeedsJson (ConvertTo-Json $needs -Depth 20) -JobSummaryPath $summary 6>$null

        [IO.File]::ReadAllText($summary) | Should -Match 'Cloud plan completed'
        [IO.File]::ReadAllText($summary) | Should -Match 'Manual confirmations are not automatically verified'
    }
}
