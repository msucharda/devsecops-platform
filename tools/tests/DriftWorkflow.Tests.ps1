BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $toolRoot = Split-Path $PSScriptRoot -Parent
    $repoRoot = Split-Path $toolRoot -Parent
    $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $repoRoot 'templates/instance/.github/workflows/drift.yml') -Raw)
    $steps = $workflow.jobs.report_drift.steps
    $tokenStep = @($steps | Where-Object { $_['run'] -like '*New-PlatformGitHubToken.ps1 -DriftReport' })[0]
    $publishStep = @($steps | Where-Object { $_['run'] -like '*Publish-DriftIssue.ps1*' })[0]
}

Describe 'Drift workflow reconciliation' {
    It 'issues the existing isolated token and publishes both report and clean outcomes' {
        $tokenStep.Contains('if') | Should -BeFalse -Because 'a successful clean evaluation must reach token issuance'
        $publishStep.Contains('if') | Should -BeFalse -Because 'a successful clean evaluation must reach the publisher'
        $tokenStep.env.Keys.Count | Should -Be 4
        $workflow.jobs.report_drift.permissions.contents | Should -BeExactly 'read'
        $publishStep.env.DRIFT_OUTCOME | Should -BeExactly '${{ steps.evaluate.outputs.outcome }}'
    }

    It 'executes the actual publish step for a clean result without creating an issue' {
        $savedOutcome = $env:DRIFT_OUTCOME
        $savedTokens = $env:PLATFORM_GITHUB_TOKENS
        $savedSlug = $env:PLATFORM_APP_SLUG
        $savedRepo = $env:GITHUB_REPOSITORY
        $savedApi = $env:GITHUB_API_URL
        Mock Invoke-RestMethod { return , @() } -ParameterFilter { $Method -eq 'GET' }
        Mock Invoke-RestMethod { throw 'A clean run must not write without a matching open drift issue.' } -ParameterFilter { $Method -ne 'GET' }
        try {
            $env:DRIFT_OUTCOME = 'Clean'
            $env:PLATFORM_GITHUB_TOKENS = '{"platform":"issue-token"}'
            $env:PLATFORM_APP_SLUG = 'octoapp'
            $env:GITHUB_REPOSITORY = 'platform/instance'
            $env:GITHUB_API_URL = 'https://api.example.test'
            [IO.File]::WriteAllText((Join-Path $TestDrive 'drift-report.md'), "<!-- platform-drift-report -->`nNo drift detected.`n")
            $command = $publishStep.run.Replace('./trusted/platform/tools/Publish-DriftIssue.ps1', "& '$(Join-Path $toolRoot 'Publish-DriftIssue.ps1')'")
            $command = $command.Replace('./drift-report.md', "'$(Join-Path $TestDrive 'drift-report.md')'")
            $result = & ([scriptblock]::Create($command))

            $result.Action | Should -BeExactly 'unchanged'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }
        finally {
            $env:DRIFT_OUTCOME = $savedOutcome
            $env:PLATFORM_GITHUB_TOKENS = $savedTokens
            $env:PLATFORM_APP_SLUG = $savedSlug
            $env:GITHUB_REPOSITORY = $savedRepo
            $env:GITHUB_API_URL = $savedApi
        }
    }
}
