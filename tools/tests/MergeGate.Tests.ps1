BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../agents/MergeGate.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'MergeGateStub.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $repository = 'msucharda/devsecops-platform'

    function Invoke-ScenarioGate {
        param([Parameter(Mandatory)][hashtable] $Stub, [hashtable] $Parameters = @{})

        $arguments = @{ Repository = $repository; Pr = $Stub.Number; Now = $Stub.Now }
        foreach ($key in $Parameters.Keys) { $arguments[$key] = $Parameters[$key] }
        Invoke-MergeGate @arguments
    }

    function Get-ReasonCode {
        param([Parameter(Mandatory)] $Result)

        @($Result.reasons | ForEach-Object { "$($_.status):$($_.code)" })
    }

    function Get-WarningCode {
        param([Parameter(Mandatory)] $Result)

        @($Result.warnings | ForEach-Object { $_.code })
    }

    function Get-OtherSha {
        # A 40-hex SHA that differs from every fixture head.
        param([string] $Digit = 'a')

        $Digit * 40
    }
}

Describe 'Merge gate replay of real pull requests' {
    BeforeEach {
        $stub = $null
        Mock -ModuleName MergeGate Invoke-MergeGateGh { Invoke-MergeGateStub -Stub $stub -Arguments $Arguments }
    }

    It 'G10 requires acknowledgement for a GitHub-hosted runner change read at fixed SHAs' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $file = (Get-GitHubApiFixture -Name 'pulls/list-files.workflow-g10')[0]
        $file['patch'] = "@@ -1 +1 @@`n-runs-on: ubuntu-latest`n+runs-on: windows-latest"
        $stub.Files = @($file)
        $stub.Contents["$($stub.PullRequest.baseRefOid)/$($file.filename)"] = "on: push`njobs: {build: {runs-on: ubuntu-latest}}"
        $stub.Contents["$($stub.PullRequest.headRefOid)/$($file.filename)"] = "on: push`njobs: {build: {runs-on: windows-latest}}"

        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        $reads = @($stub.Calls | Where-Object { $_[-1] -match '/contents/' } | ForEach-Object { $_[-1] })
        $reads | Should -Be @(
            "repos/$repository/contents/.github/workflows/ci.yml?ref=$($stub.PullRequest.baseRefOid)"
            "repos/$repository/contents/.github/workflows/ci.yml?ref=$($stub.PullRequest.headRefOid)"
        )
    }

    It 'passes #78: green checks, Copilot review on the head; behind base only warns' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pass'
        $result.exitCode | Should -Be 0
        $result.reasons.Count | Should -Be 0
        Get-WarningCode $result | Should -Be @('behind-base')
        $result.headSha | Should -Be '5a86d28aa232fff72af137c29c1abd9e75f398a3'
        $result.details.copilot.reviewedHead | Should -BeTrue
        $result.details.copilot.rounds | Should -Be 1
        $result.details.base.behindBy | Should -Be 1
    }

    It 'writes one JSON object in the documented schema' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $json = ConvertTo-MergeGateJson -Result (Invoke-ScenarioGate -Stub $stub -Parameters @{ ExpectedHeadSha = '5a86d28aa232fff72af137c29c1abd9e75f398a3' })
        $parsed = $json | ConvertFrom-Json -AsHashtable

        @($parsed.Keys) | Should -Be @('schemaVersion', 'gateVersion', 'repository', 'host', 'pr', 'evaluatedAt', 'verdict', 'headSha', 'expectedHeadSha', 'reasons', 'warnings', 'details')
        $parsed.schemaVersion | Should -Be 1
        $parsed.repository | Should -Be $repository
        $parsed.host | Should -Be 'github.com'
        $parsed.expectedHeadSha | Should -Be '5a86d28aa232fff72af137c29c1abd9e75f398a3'
        @($parsed.details.Keys) | Should -Be @('state', 'checks', 'threads', 'copilot', 'merge', 'base', 'body', 'github', 'rules')
    }

    It 'reports #75 as already-merged with exit code 3 and stops after the pull request read' {
        $stub = Initialize-MergeGateStub -Scenario pr-75
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ ExpectedHeadSha = '4009e36ad18a3af4dffc8aa7369b671b5dbf1a04' }

        $result.verdict | Should -Be 'already-merged'
        $result.exitCode | Should -Be 3
        $result.details.state.mergeCommit | Should -Not -BeNullOrEmpty
        $result.warnings.Count | Should -Be 0
        $stub.Calls.Count | Should -Be 1
    }

    It 'warns when the merged head of #75 differs from the expected head' {
        $stub = Initialize-MergeGateStub -Scenario pr-75
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ ExpectedHeadSha = (Get-OtherSha) }

        $result.verdict | Should -Be 'already-merged'
        Get-WarningCode $result | Should -Be @('merged-head-differs')
    }

    It 'fails #40 as a draft without any Copilot review' {
        $stub = Initialize-MergeGateStub -Scenario pr-40
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'fail'
        $result.exitCode | Should -Be 1
        Get-ReasonCode $result | Should -Be @('fail:draft', 'fail:copilot-review-missing')
    }

    It 'keeps #40 pending after gh pr ready while Copilot reviews' {
        $stub = Initialize-MergeGateStub -Scenario pr-40-ready
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pending'
        $result.exitCode | Should -Be 2
        Get-ReasonCode $result | Should -Be @('pending:copilot-review-in-progress')
        $result.reasons[0].evidence.lastRequestAt | Should -Be '2026-10-13T16:17:29Z'
    }

    It 'keeps #48 pending while Source CI runs on the new head' {
        $stub = Initialize-MergeGateStub -Scenario pr-48
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pending'
        Get-ReasonCode $result | Should -Be @('pending:checks-pending')
        $result.reasons[0].evidence.subjects | Should -Contain 'Source CI'
        Get-WarningCode $result | Should -Contain 'copilot-review-stale'
    }

    It 'fails #52 with blocked-by-rules when only the ruleset blocks the merge' {
        $stub = Initialize-MergeGateStub -Scenario pr-52
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'fail'
        Get-ReasonCode $result | Should -Be @('fail:blocked-by-rules')
        $result.reasons[0].message | Should -Match 'never use --admin'
        $result.details.rules.requiredContexts | Should -Be @('copilot-pull-request-reviewer')
    }

    It 'fails #52 with required-check-missing when the required context never reports after the grace period' {
        $stub = Initialize-MergeGateStub -Scenario pr-52
        $stub.CheckRuns.check_runs = @($stub.CheckRuns.check_runs | Where-Object { $_.name -ne 'copilot-pull-request-reviewer' })
        $stub.CheckRuns.total_count = $stub.CheckRuns.check_runs.Count
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ Now = '2026-10-20T21:00:00Z' }

        $result.verdict | Should -Be 'fail'
        Get-ReasonCode $result | Should -Be @('fail:required-check-missing')
        $result.details.checks.missing | Should -Be @('copilot-pull-request-reviewer')
    }

    It 'G4 rejects a required context reported by another integration' {
        $stub = Initialize-MergeGateStub -Scenario pr-52
        $check = @($stub.CheckRuns.check_runs | Where-Object { $_.name -ceq 'copilot-pull-request-reviewer' })[0]
        $check.app.id = 99999
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ Now = '2026-10-20T21:00:00Z' }

        Get-ReasonCode $result | Should -Be @('fail:required-check-missing')
        $result.details.checks.missing | Should -Be @('copilot-pull-request-reviewer')
    }

    It 'G4 integration <Case>' -ForEach @(
        @{ Case = 'matches the required app'; Mode = 'matching'; Expected = @('fail:blocked-by-rules') }
        @{ Case = 'does not constrain a context without integration_id'; Mode = 'unbound'; Expected = @('fail:blocked-by-rules') }
        @{ Case = 'does not accept a differently named check'; Mode = 'name'; Expected = @('fail:required-check-missing') }
        @{ Case = 'does not accept a differently cased check name'; Mode = 'case'; Expected = @('fail:required-check-missing') }
        @{ Case = 'does not accept a null app'; Mode = 'null-app'; Expected = @('fail:required-check-missing') }
        @{ Case = 'does not accept a missing app'; Mode = 'missing-app'; Expected = @('fail:required-check-missing') }
        @{ Case = 'does not accept a missing app id'; Mode = 'missing-id'; Expected = @('fail:required-check-missing') }
        @{ Case = 'does not accept a null app id'; Mode = 'null-id'; Expected = @('fail:required-check-missing') }
        @{ Case = 'does not accept a string app id'; Mode = 'string-id'; Expected = @('fail:required-check-missing') }
        @{ Case = 'does not accept an empty app id'; Mode = 'empty-id'; Expected = @('fail:required-check-missing') }
        @{ Case = 'does not accept a null integration id'; Mode = 'null-integration'; Expected = @('fail:evaluation-error') }
        @{ Case = 'does not accept a string integration id'; Mode = 'string-integration'; Expected = @('fail:evaluation-error') }
        @{ Case = 'retains constraints from two rules with the same context'; Mode = 'two-rules'; Expected = @('fail:required-check-missing') }
        @{ Case = 'accepts the matching app among two apps'; Mode = 'two-apps'; Expected = @('fail:blocked-by-rules') }
    ) {
        $stub = Initialize-MergeGateStub -Scenario pr-52
        $check = @($stub.CheckRuns.check_runs | Where-Object { $_.name -ceq 'copilot-pull-request-reviewer' })[0]
        $required = $stub.Rules[1].parameters.required_status_checks[0]
        switch ($Mode) {
            'unbound' { $required.Remove('integration_id'); $check.app.id = 99999 }
            'name' { $check.name = 'another-check' }
            'case' { $check.name = 'Copilot-Pull-Request-Reviewer' }
            'null-app' { $check.app = $null }
            # Intentionally invalid API inputs: check-run app.id and integration_id are integers when present.
            'missing-app' { $check.Remove('app') }
            'missing-id' { $check.app.Remove('id') }
            'null-id' { $check.app.id = $null }
            'string-id' { $check.app.id = '15368' }
            'empty-id' { $check.app.id = '' }
            'null-integration' { $required.integration_id = $null }
            'string-integration' { $required.integration_id = '15368' }
            'two-rules' {
                $second = Get-GitHubApiFixture -Name 'repos/get-branch-rules.merge-gate-required-check' -Set @{ '1.parameters.required_status_checks.0.integration_id' = 99999 }
                $stub.Rules += $second[1]
            }
            'two-apps' {
                $other = Get-GitHubApiFixture -Name 'checks/list-for-ref.merge-gate-pr-52'
                $otherCheck = @($other.check_runs | Where-Object { $_.name -ceq 'copilot-pull-request-reviewer' })[0]
                $otherCheck.app.id = 99999
                $stub.CheckRuns.check_runs += $otherCheck
                $stub.CheckRuns.total_count++
            }
        }
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ Now = '2026-10-20T21:00:00Z' }

        Get-ReasonCode $result | Should -Be $Expected
        if ($Mode -in @('null-integration', 'string-integration')) {
            $result.reasons[0].message | Should -Match 'invalid integration_id'
        }
    }

    It 'G9 author rejects a marker after an edit by another login' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $history = $stub.DecisionAuthors.data.repository.pullRequest
        $stub.PullRequest.body = $history.body
        $history.userContentEdits.nodes[0].editor.login = 'another-user'
        $result = Invoke-ScenarioGate -Stub $stub

        Get-WarningCode $result | Should -Contain 'decisions-unconfirmed'
        $result.details.body.decisionsAccepted | Should -BeNullOrEmpty
    }

    It 'G9 author confirms complete same-login history for Actor <Kind>' -ForEach @(
        @{ Kind = 'User'; Login = 'msucharda' }
        @{ Kind = 'Bot'; Login = 'example[bot]' }
        @{ Kind = 'Organization'; Login = 'example-org' }
        @{ Kind = 'Mannequin'; Login = 'example-mannequin' }
        @{ Kind = 'EnterpriseUserAccount'; Login = 'example-user' }
    ) {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $stub.DecisionAuthors = Get-GitHubApiFixture -Name 'graphql/pull-request-decision-authors' -Set @{
            'data.repository.pullRequest.author.__typename' = $Kind
            'data.repository.pullRequest.author.login' = $Login
            'data.repository.pullRequest.userContentEdits.nodes.0.editor.__typename' = $Kind
            'data.repository.pullRequest.userContentEdits.nodes.0.editor.login' = $Login
        }
        $history = $stub.DecisionAuthors.data.repository.pullRequest
        $history.body = $history.body.Replace('msucharda', $Login)
        $stub.PullRequest.body = $history.body
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pass'
        Get-WarningCode $result | Should -Not -Contain 'decisions-unconfirmed'
        $result.details.body.decisionsAccepted.login | Should -BeExactly $Login
        $result.details.body.decisionsAccepted.date | Should -Be '2026-10-22'
    }

    It 'G9 author confirms <Case>' -ForEach @(
        @{ Case = 'an unedited body from its author'; Mode = 'unedited' }
        @{ Case = 'case-insensitive GitHub logins'; Mode = 'case' }
        @{ Case = 'multiple edits from the same login'; Mode = 'two-edits' }
    ) {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $history = $stub.DecisionAuthors.data.repository.pullRequest
        $stub.PullRequest.body = $history.body
        switch ($Mode) {
            'unedited' { $history.userContentEdits.nodes = @(); $history.userContentEdits.totalCount = 0 }
            'case' { $history.author.login = 'MSucharda'; $history.userContentEdits.nodes[0].editor.login = 'MSUCHARDA' }
            'two-edits' { $history.userContentEdits.nodes += $history.userContentEdits.nodes[0].Clone(); $history.userContentEdits.totalCount = 2 }
        }
        $result = Invoke-ScenarioGate -Stub $stub

        Get-WarningCode $result | Should -Not -Contain 'decisions-unconfirmed'
        $result.details.body.decisionsAccepted.login | Should -Be 'msucharda'
    }

    It 'G9 author leaves acceptance unconfirmed for <Case>' -ForEach @(
        @{ Case = 'another PR author'; Mode = 'author'; Message = 'pull request author' }
        @{ Case = 'a null PR author'; Mode = 'null-author'; Message = 'pull request author' }
        @{ Case = 'an empty author login'; Mode = 'empty-author'; Message = 'pull request author' }
        @{ Case = 'a null editor'; Mode = 'null-editor'; Message = 'edit author' }
        @{ Case = 'an empty editor login'; Mode = 'empty-editor'; Message = 'edit author' }
        @{ Case = 'an extra editor with another login'; Mode = 'extra-editor'; Message = 'edit author' }
        @{ Case = 'a redacted edit'; Mode = 'redacted'; Message = 'redacted' }
        @{ Case = 'a null history'; Mode = 'null-history'; Message = "no list at 'nodes'" }
        @{ Case = 'null edit nodes'; Mode = 'null-nodes'; Message = "no list at 'nodes'" }
        @{ Case = 'a null edit node'; Mode = 'null-node'; Message = 'unreadable edit' }
        @{ Case = 'an unread page'; Mode = 'next-page'; Message = 'incomplete or unreadable' }
        @{ Case = 'a count mismatch'; Mode = 'count'; Message = 'count does not match' }
        @{ Case = 'a changed head'; Mode = 'head'; Message = 'evaluated head' }
        @{ Case = 'a differently cased head'; Mode = 'head-case'; Message = 'evaluated head' }
        @{ Case = 'a changed body'; Mode = 'body'; Message = 'body changed' }
        @{ Case = 'a differently cased body'; Mode = 'body-case'; Message = 'body changed' }
        @{ Case = 'a null pull request'; Mode = 'null-pr'; Message = 'evaluated head' }
        @{ Case = 'multiple markers'; Mode = 'markers'; Message = 'exactly one' }
        # Intentionally invalid API inputs below: omitted selected fields, wrong scalar types and invalid JSON.
        @{ Case = 'a missing author login'; Mode = 'missing-author'; Message = 'pull request author' }
        @{ Case = 'a missing editor login'; Mode = 'missing-editor'; Message = 'edit author' }
        @{ Case = 'an array author login'; Mode = 'array-author'; Message = 'pull request author' }
        @{ Case = 'an array editor login'; Mode = 'array-editor'; Message = 'edit author' }
        @{ Case = 'a missing redaction field'; Mode = 'missing-redaction'; Message = 'unreadable edit' }
        @{ Case = 'an absent page flag'; Mode = 'missing-page'; Message = 'incomplete or unreadable' }
        @{ Case = 'a string page flag'; Mode = 'string-page'; Message = 'incomplete or unreadable' }
        @{ Case = 'a null count'; Mode = 'null-count'; Message = 'count does not match' }
        @{ Case = 'a string count'; Mode = 'string-count'; Message = 'count does not match' }
        @{ Case = 'an array head'; Mode = 'array-head'; Message = 'evaluated head' }
        @{ Case = 'an array body'; Mode = 'array-body'; Message = 'body changed' }
        @{ Case = 'an API failure'; Mode = 'api'; Message = 'history unavailable' }
        @{ Case = 'invalid JSON'; Mode = 'json'; Message = 'not JSON' }
    ) {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $history = $stub.DecisionAuthors.data.repository.pullRequest
        $stub.PullRequest.body = $history.body
        switch ($Mode) {
            'author' { $history.author.login = 'another-user' }
            'null-author' { $history.author = $null }
            'empty-author' { $history.author.login = '' }
            'null-editor' { $history.userContentEdits.nodes[0].editor = $null }
            'empty-editor' { $history.userContentEdits.nodes[0].editor.login = '' }
            'extra-editor' {
                $extra = Get-GitHubApiFixture -Name 'graphql/pull-request-decision-authors' -Set @{ 'data.repository.pullRequest.userContentEdits.nodes.0.editor.login' = 'another-user' }
                $history.userContentEdits.nodes += $extra.data.repository.pullRequest.userContentEdits.nodes[0]
                $history.userContentEdits.totalCount = 2
            }
            'redacted' { $history.userContentEdits.nodes[0].deletedAt = '2026-10-22T11:00:00Z' }
            'null-history' { $history.userContentEdits = $null }
            'null-nodes' { $history.userContentEdits.nodes = $null }
            'null-node' { $history.userContentEdits.nodes = @($null) }
            'next-page' { $history.userContentEdits.pageInfo.hasNextPage = $true }
            'count' { $history.userContentEdits.totalCount = 2 }
            'head' { $history.headRefOid = Get-OtherSha }
            'head-case' { $history.headRefOid = $history.headRefOid.ToUpperInvariant() }
            'body' { $history.body += "`nChanged after confirmation." }
            'body-case' { $history.body = $history.body.Replace('D1', 'd1') }
            'null-pr' { $stub.DecisionAuthors.data.repository.pullRequest = $null }
            'markers' { $history.body += "`n<!-- merge-gate: decisions-accepted another-user 2026-10-22 -->"; $stub.PullRequest.body = $history.body }
            'missing-author' { $history.author.Remove('login') }
            'missing-editor' { $history.userContentEdits.nodes[0].editor.Remove('login') }
            'array-author' { $history.author.login = @($history.author.login) }
            'array-editor' { $history.userContentEdits.nodes[0].editor.login = @($history.userContentEdits.nodes[0].editor.login) }
            'missing-redaction' { $history.userContentEdits.nodes[0].Remove('deletedAt') }
            'missing-page' { $history.userContentEdits.pageInfo.Remove('hasNextPage') }
            'string-page' { $history.userContentEdits.pageInfo.hasNextPage = 'false' }
            'null-count' { $history.userContentEdits.totalCount = $null }
            'string-count' { $history.userContentEdits.totalCount = '1' }
            'array-head' { $history.headRefOid = @($history.headRefOid) }
            'array-body' { $history.body = @($history.body) }
            'api' { $stub.Failures['graphql decisionAuthors'] = 'history unavailable' }
            'json' { $stub.Responses['graphql decisionAuthors'] = '{ invalid' }
        }
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pass'
        Get-WarningCode $result | Should -Contain 'decisions-unconfirmed'
        $result.details.body.decisionsAccepted | Should -BeNullOrEmpty
        @($result.warnings | Where-Object code -EQ 'decisions-unconfirmed')[0].evidence.error | Should -Match $Message
    }

    It 'G4 integration binds a context to an app, not a commit status' {
        $stub = Initialize-MergeGateStub -Scenario pr-52
        $stub.CheckRuns.check_runs = @($stub.CheckRuns.check_runs | Where-Object { $_.name -cne 'copilot-pull-request-reviewer' })
        $stub.CheckRuns.total_count = $stub.CheckRuns.check_runs.Count
        # One-off simple-commit-status example: required fields from the pinned OpenAPI used by the status fixture.
        $stub.Status.statuses = @(@{
            description = 'Build passed'; id = 1; node_id = 'SC_kwDOExample'; state = 'success'
            context = 'copilot-pull-request-reviewer'; target_url = $null; avatar_url = $null
            url = 'https://api.github.com/repos/example/repo/statuses/1'
            created_at = '2026-10-20T20:20:00Z'; updated_at = '2026-10-20T20:20:00Z'
        })
        $stub.Status.total_count = 1
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ Now = '2026-10-20T21:00:00Z' }
        Get-ReasonCode $result | Should -Be @('fail:required-check-missing')

        $stub.Rules[1].parameters.required_status_checks[0].Remove('integration_id')
        $unbound = Invoke-ScenarioGate -Stub $stub -Parameters @{ Now = '2026-10-20T21:00:00Z' }
        Get-ReasonCode $unbound | Should -Be @('fail:blocked-by-rules')
    }

    It 'keeps #60 pending while Copilot reviews the head after the review of an older commit' {
        $stub = Initialize-MergeGateStub -Scenario pr-60
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pending'
        Get-ReasonCode $result | Should -Be @('pending:copilot-review-in-progress')
        $result.reasons[0].evidence.lastReviewSha | Should -Be '122a4fb72dcca3f96453c41e49254d258631156e'
        $result.details.copilot.rounds | Should -Be 6
        Get-WarningCode $result | Should -Be @('copilot-review-stale', 'copilot-rounds-over-cap', 'decisions-unconfirmed')
    }

    It 'fails #70 for new workflow permissions without a human acknowledgement' {
        $stub = Initialize-MergeGateStub -Scenario pr-70
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'fail'
        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        ($result.reasons[0].evidence.sensitiveLines -join "`n") | Should -Match 'release\.yml: comparison unavailable: Workflow sensitive YAML expressions require acknowledgement\.'
        $result.details.github.workflowFiles | Should -Contain '.github/workflows/release.yml'
    }

    It 'passes #70 when a human acknowledged the workflow changes for the head' {
        $stub = Initialize-MergeGateStub -Scenario pr-70
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ AcknowledgeWorkflowChanges = $stub.PullRequest.headRefOid.ToUpperInvariant() }

        $result.verdict | Should -Be 'pass'
        $result.details.github.acknowledgedFor | Should -Be $stub.PullRequest.headRefOid
    }

    It 'fails #70 when the acknowledgement names another head' {
        $stub = Initialize-MergeGateStub -Scenario pr-70
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ AcknowledgeWorkflowChanges = (Get-OtherSha) }

        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
    }

    It 'fails #71 before the rename for open questions' {
        $stub = Initialize-MergeGateStub -Scenario pr-71-open-questions
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'fail'
        Get-ReasonCode $result | Should -Be @('fail:open-questions')
        $result.details.body.openQuestions | Should -BeTrue
    }

    It 'passes #71 after the rename and warns about the Copilot rounds over the cap' {
        $stub = Initialize-MergeGateStub -Scenario pr-71
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pass'
        Get-WarningCode $result | Should -Be @('copilot-rounds-over-cap')
        $result.details.copilot.headOverview | Should -Not -BeNullOrEmpty
    }

    It 'fails an open pull request that was reported as merged (-ExpectMerged)' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ ExpectMerged = $true }

        $result.verdict | Should -Be 'fail'
        @(Get-ReasonCode $result)[0] | Should -Be 'fail:not-merged'
    }

    It 'confirms a reported merge of #75 (-ExpectMerged)' {
        $stub = Initialize-MergeGateStub -Scenario pr-75
        (Invoke-ScenarioGate -Stub $stub -Parameters @{ ExpectMerged = $true }).exitCode | Should -Be 3
    }

    It 'fails head-moved when the expected head differs' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ ExpectedHeadSha = (Get-OtherSha) }

        Get-ReasonCode $result | Should -Be @('fail:head-moved')
        $result.headSha | Should -Be '5a86d28aa232fff72af137c29c1abd9e75f398a3'
    }

    It 'fails a closed pull request and still reports every other reason' {
        $stub = Initialize-MergeGateStub -Scenario pr-40
        $stub.PullRequest.state = 'CLOSED'
        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:pr-closed', 'fail:draft', 'fail:copilot-review-missing')
    }

    It 'fails behind-base when the base rules require an up-to-date branch' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ RequireUpToDate = $true }

        Get-ReasonCode $result | Should -Be @('fail:behind-base')
        $result.reasons[0].evidence.behindBy | Should -Be 1
    }

    It 'fails unresolved review threads, including outdated ones' {
        $stub = Initialize-MergeGateStub -Scenario pr-71
        $stub.PullRequest.reviewThreads.nodes[0].isResolved = $false
        $stub.PullRequest.reviewThreads.nodes[0].isOutdated = $true
        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:unresolved-threads')
        $result.reasons[0].evidence.threads[0].url | Should -Match '^https://github.com/msucharda/devsecops-platform/pull/71#discussion_r'
    }

    It 'fails a stale Copilot review with -RequireCopilotOnHead' {
        $stub = Initialize-MergeGateStub -Scenario pr-48
        $stub.WorkflowRuns.workflow_runs | ForEach-Object { $_.status = 'completed'; $_.conclusion = 'success' }
        $stub.CheckRuns.check_runs | ForEach-Object { $_.status = 'completed'; $_.conclusion = 'success'; $_.completed_at = '2026-10-20T17:59:00Z' }
        $result = Invoke-ScenarioGate -Stub $stub -Parameters @{ RequireCopilotOnHead = $true }

        Get-ReasonCode $result | Should -Be @('fail:copilot-review-stale')
    }

    It 'keeps #78 pending while the Copilot review workflow runs again' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $copilotRun = @($stub.WorkflowRuns.workflow_runs | Where-Object { $_.event -eq 'dynamic' -and $_.name -eq 'Running Copilot Code Review' })[0]
        $copilotRun.status = 'in_progress'
        $copilotRun.conclusion = $null
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pending'
        Get-ReasonCode $result | Should -Be @('pending:copilot-review-in-progress')
    }

    It 'fails #78 when the base branch requires a merge queue' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $queue = Get-GitHubApiFixture -Name 'repos/get-branch-rules.merge-queue'
        $stub.Rules = @($stub.Rules) + $queue
        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:merge-queue-unsupported')
        $result.details.rules.mergeQueue | Should -BeTrue
    }

    It 'returns already-merged for #75 before reading a partial review list' {
        $stub = Initialize-MergeGateStub -Scenario pr-75
        $stub.PullRequest.reviews.totalCount = 101
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 3
    }

    It 'calls only read-only API requests' {
        foreach ($scenario in @('pr-78', 'pr-60', 'pr-70', 'pr-75')) {
            $stub = Initialize-MergeGateStub -Scenario $scenario
            $null = Invoke-ScenarioGate -Stub $stub
            $stub.Calls.Count | Should -BeGreaterThan 0
            foreach ($call in $stub.Calls) {
                $call[0] | Should -Be 'api'
                if ($call[1] -eq 'graphql') { $call[3] | Should -Match '^query=query\(' }
                else { $call[1..2] -join ' ' | Should -Be '--method GET' }
                $call | Should -Not -Contain '--admin'
            }
        }
    }

    It 'reads every page of a long check run list' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $template = $stub.CheckRuns.check_runs[0]
        $stub.CheckRuns.check_runs = @(1..150 | ForEach-Object { $copy = $template.Clone(); $copy.name = "job $_"; $copy })
        $stub.CheckRuns.total_count = 150
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pass'
        $result.details.checks.checkRuns.Count | Should -Be 150
    }
}

Describe 'Merge gate structural G10' {
    BeforeEach {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $stub.Files = Get-GitHubApiFixture -Name 'pulls/list-files.workflow-g10'
        $file = $stub.Files[0]
        $baseKey = "$($stub.PullRequest.baseRefOid)/$($file.filename)"
        $headKey = "$($stub.PullRequest.headRefOid)/$($file.filename)"
        Mock -ModuleName MergeGate Invoke-MergeGateGh { Invoke-MergeGateStub -Stub $stub -Arguments $Arguments }
    }

    It 'G10 compares <Case> structurally without a patch' -ForEach @(
        @{ Case = 'block permissions'; Before = "permissions:`n  contents: read"; After = "permissions:`n  contents: write" }
        @{ Case = 'flow permissions'; Before = 'permissions: {contents: read}'; After = 'permissions: {contents: write}' }
        @{ Case = 'multiline flow permissions'; Before = "permissions: {`n contents:`n read`n}"; After = "permissions: {`n contents:`n write`n}" }
        @{ Case = 'quoted permission keys and values'; Before = "'permissions': {'contents': 'read'}"; After = '"permissions": {"contents": "write"}' }
        @{ Case = 'a permission scalar on another line'; Before = "permissions:`n  contents:`n    read"; After = "permissions:`n  contents:`n    write" }
        @{ Case = 'scalar permissions'; Before = 'permissions: read-all'; After = 'permissions: write-all' }
        @{ Case = 'removed permissions'; Before = 'permissions: {}'; After = 'name: CI' }
        @{ Case = 'job permissions'; Before = 'jobs: {build: {permissions: {id-token: none}}}'; After = 'jobs: {build: {permissions: {id-token: write}}}' }
        @{ Case = 'ordinary triggers'; Before = 'on: push'; After = 'on: pull_request' }
        @{ Case = 'a privileged trigger'; Before = 'on: pull_request'; After = 'on: pull_request_target' }
        @{ Case = 'trigger branches'; Before = 'on: {push: {branches: [main]}}'; After = 'on: {push: {branches: [release]}}' }
        @{ Case = 'trigger branch case'; Before = 'on: {push: {branches: [main]}}'; After = 'on: {push: {branches: [MAIN]}}' }
        @{ Case = 'trigger paths'; Before = "on:`n  push:`n    paths: ['src/**']"; After = "on:`n  push:`n    paths: ['**']" }
        @{ Case = 'a workflow_run filter'; Before = 'on: {workflow_run: {workflows: [Build]}}'; After = 'on: {workflow_run: {workflows: [Deploy]}}' }
        @{ Case = 'a scheduled trigger'; Before = "on: {schedule: [{cron: '0 1 * * *'}]}"; After = "on: {schedule: [{cron: '0 2 * * *'}]}" }
        @{ Case = 'a trigger sequence'; Before = 'on: [push]'; After = 'on: [push, pull_request]' }
        @{ Case = 'a hosted runner'; Before = 'jobs: {build: {runs-on: ubuntu-latest}}'; After = 'jobs: {build: {runs-on: windows-latest}}' }
        @{ Case = 'runner labels'; Before = 'jobs: {build: {runs-on: [self-hosted, linux]}}'; After = 'jobs: {build: {runs-on: [self-hosted, windows]}}' }
        @{ Case = 'runner groups'; Before = 'jobs: {build: {runs-on: {group: old}}}'; After = 'jobs: {build: {runs-on: {group: new}}}' }
        @{ Case = 'a self-hosted matrix value'; Before = 'jobs: {build: {strategy: {matrix: {os: [ubuntu-latest]}}}}'; After = 'jobs: {build: {strategy: {matrix: {os: [self-hosted]}}}}' }
        @{ Case = 'a runner expression'; Before = 'jobs: {build: {runs-on: "${{ inputs.runner }}"}}'; After = 'jobs: {build: {runs-on: "${{ inputs.other }}"}}' }
        @{ Case = 'inherited secrets'; Before = 'jobs: {build: {secrets: {}}}'; After = 'jobs: {build: {secrets: inherit}}' }
        @{ Case = 'a quoted secrets key'; Before = '"secrets": {}'; After = '"secrets": inherit' }
        @{ Case = 'a secret reference'; Before = 'env: {TOKEN: "${{ secrets.OLD }}"}'; After = 'env: {TOKEN: "${{ secrets.NEW }}"}' }
        @{ Case = 'an indexed secret'; Before = "env: {TOKEN: `"`${{ secrets['OLD'] }}`"}"; After = "env: {TOKEN: `"`${{ secrets['NEW'] }}`"}" }
        @{ Case = 'a removed secret reference'; Before = 'env: {TOKEN: "${{ secrets.TOKEN }}"}'; After = 'env: {TOKEN: literal}' }
        @{ Case = 'the whole secrets context'; Before = 'env: {TOKEN: literal}'; After = 'env: {TOKEN: "${{ toJSON(secrets) }}"}' }
        @{ Case = 'a nested secrets-context expression'; Before = 'env: {TOKEN: literal}'; After = "env: {TOKEN: `"`${{ format('{0}', toJSON(secrets)) }}`"}" }
        @{ Case = 'GITHUB_TOKEN binding'; Before = 'env: {GITHUB_TOKEN: "${{ github.token }}"}'; After = 'env: {GITHUB_TOKEN: literal}' }
        @{ Case = 'GITHUB_TOKEN usage'; Before = "run: 'echo `$GITHUB_TOKEN'"; After = "run: 'upload `$GITHUB_TOKEN'" }
        @{ Case = 'the github.token alias'; Before = 'env: {TOKEN: literal}'; After = 'env: {TOKEN: "${{ github.token }}"}' }
        @{ Case = 'an indexed github.token alias'; Before = 'env: {TOKEN: literal}'; After = "env: {TOKEN: `"`${{ github['token'] }}`"}" }
        @{ Case = 'the whole github context'; Before = 'env: {TOKEN: literal}'; After = 'env: {TOKEN: "${{ toJSON(github) }}"}' }
        @{ Case = 'a dynamic github context lookup'; Before = 'env: {TOKEN: literal}'; After = 'env: {TOKEN: "${{ github[inputs.key] }}"}' }
        @{ Case = 'a github wildcard filter'; Before = 'env: {TOKEN: literal}'; After = 'env: {TOKEN: "${{ toJSON(github.*) }}"}' }
        @{ Case = 'trigger-filter ordering'; Before = 'on: {push: {paths: ["src/**", "!src/private/**"]}}'; After = 'on: {push: {paths: ["!src/private/**", "src/**"]}}' }
        @{ Case = 'sensitive-step ordering'; Before = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}, {run: "deploy $GITHUB_TOKEN"}]}}'; After = 'jobs: {build: {steps: [{run: "deploy $GITHUB_TOKEN"}, {run: "echo $GITHUB_TOKEN"}]}}' }
        @{ Case = 'an added sensitive step'; Before = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}]}}'; After = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}, {run: "deploy $GITHUB_TOKEN"}]}}' }
        @{ Case = 'a removed sensitive step'; Before = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}, {run: "deploy $GITHUB_TOKEN"}]}}'; After = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}]}}' }
        @{ Case = 'a token binding moved between existing steps'; Before = 'jobs: {build: {steps: [{id: audit, run: "echo audit", env: {GITHUB_TOKEN: fixture-placeholder}}, {id: publish, run: "echo publish"}]}}'; After = 'jobs: {build: {steps: [{id: audit, run: "echo audit"}, {id: publish, run: "echo publish", env: {GITHUB_TOKEN: fixture-placeholder}}]}}' }
        @{ Case = 'a changed token execution target'; Before = 'jobs: {build: {steps: [{id: worker, run: "echo audit", env: {GITHUB_TOKEN: fixture-placeholder}}]}}'; After = 'jobs: {build: {steps: [{id: worker, run: "echo publish", env: {GITHUB_TOKEN: fixture-placeholder}}]}}' }
        @{ Case = 'an implicit token condition'; Before = 'jobs: {build: {steps: [{if: "github.token != null", run: "echo test"}]}}'; After = 'jobs: {build: {steps: [{if: "github.token == null", run: "echo test"}]}}' }
    ) {
        $stub.Contents[$baseKey] = $Before
        $stub.Contents[$headKey] = $After

        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        $result.details.github.sensitiveLines.Count | Should -Be 1
        $result.details.github.sensitiveLines[0] | Should -Match "^$([regex]::Escape($file.filename)): (sensitive YAML settings changed|comparison unavailable: Workflow sensitive YAML expressions require acknowledgement\.)$"
    }

    It 'G10 ignores <Case> when sensitive settings stay unchanged' -ForEach @(
        @{ Case = 'comments and mapping order'; Before = "on: push`npermissions: {contents: read, issues: none}"; After = "# comment`npermissions: {issues: none, contents: read}`non: push" }
        @{ Case = 'block/flow syntax and quoting'; Before = "on: push`npermissions:`n  contents: read"; After = "'permissions': {'contents': 'read'}`n'on': 'push'" }
        @{ Case = 'unrelated step text'; Before = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps: [{run: 'echo old'}]"; After = "jobs:`n  build:`n    runs-on: ubuntu-latest`n    steps: [{run: 'echo new'}]" }
        @{ Case = 'an unrelated step inserted before a token'; Before = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}]}}'; After = 'jobs: {build: {steps: [{run: "echo setup"}, {run: "echo $GITHUB_TOKEN"}]}}' }
        @{ Case = 'an unrelated step inserted between tokens'; Before = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}, {run: "deploy $GITHUB_TOKEN"}]}}'; After = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}, {run: "echo setup"}, {run: "deploy $GITHUB_TOKEN"}]}}' }
        @{ Case = 'an unrelated step removed before a token'; Before = 'jobs: {build: {steps: [{run: "echo setup"}, {run: "echo $GITHUB_TOKEN"}]}}'; After = 'jobs: {build: {steps: [{run: "echo $GITHUB_TOKEN"}]}}' }
        @{ Case = 'empty settings'; Before = '{}'; After = 'name: CI' }
        @{ Case = 'ordinary github context properties'; Before = 'env: {REF: "${{ github.ref }}"}'; After = 'env: {REF: "${{ github.sha }}"}' }
        @{ Case = 'literal GitHub step names'; Before = 'jobs: {build: {steps: [{name: "Build on GitHub", run: "echo test"}]}}'; After = 'jobs: {build: {steps: [{name: "Test on GitHub", run: "echo test"}]}}' }
        @{ Case = 'literal secrets documentation'; Before = 'name: Read secrets documentation'; After = 'name: Update secrets documentation' }
        @{ Case = 'ordinary implicit github conditions'; Before = 'jobs: {build: {steps: [{if: "github.ref != null", run: "echo test"}]}}'; After = 'jobs: {build: {steps: [{if: "github.sha != null", run: "echo test"}]}}' }
        @{ Case = 'exactly 100 nesting levels'; Before = 'permissions: ' + ('{x: ' * 99) + 'read' + ('}' * 99); After = 'permissions: ' + ('{x: ' * 99) + 'read' + ('}' * 99) }
    ) {
        $stub.Contents[$baseKey] = $Before
        $stub.Contents[$headKey] = $After

        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'pass'
        $result.details.github.sensitiveLines | Should -Be @()
    }

    It 'G10 fails closed for dynamic sensitive <Case>' -ForEach @(
        @{ Case = 'runner matrix labels'; Before = 'jobs: {build: {strategy: {matrix: {os: [ubuntu-latest]}}, runs-on: "${{ matrix.os }}"}}'; After = 'jobs: {build: {strategy: {matrix: {os: [windows-latest]}}, runs-on: "${{ matrix.os }}"}}' }
        @{ Case = 'runner matrix self-hosted labels'; Before = 'jobs: {build: {strategy: {matrix: {os: [ubuntu-latest]}}, runs-on: "${{ matrix.os }}"}}'; After = 'jobs: {build: {strategy: {matrix: {os: [self-hosted]}}, runs-on: "${{ matrix.os }}"}}' }
        @{ Case = 'secret matrix keys'; Before = 'jobs: {build: {strategy: {matrix: {name: [OLD]}}, env: {TOKEN: "${{ secrets[matrix.name] }}"}}}'; After = 'jobs: {build: {strategy: {matrix: {name: [NEW]}}, env: {TOKEN: "${{ secrets[matrix.name] }}"}}}' }
        @{ Case = 'runner outputs with another step changed'; Before = 'jobs: {build: {runs-on: "${{ needs.setup.outputs.runner }}", steps: [{run: "echo old"}]}}'; After = 'jobs: {build: {runs-on: "${{ needs.setup.outputs.runner }}", steps: [{run: "echo new"}]}}' }
        @{ Case = 'an unchanged secret reference'; Before = "name: Old`nenv: {TOKEN: `"`${{ secrets.TOKEN }}`"}"; After = "name: New`nenv: {TOKEN: `"`${{ secrets.TOKEN }}`"}" }
        @{ Case = 'only a comment changed'; Before = 'jobs: {build: {runs-on: "${{ matrix.os }}"}}'; After = "# comment`njobs: {build: {runs-on: `"`${{ matrix.os }}`"}}" }
        @{ Case = 'an expression only in base'; Before = 'jobs: {build: {runs-on: "${{ matrix.os }}"}}'; After = 'jobs: {build: {runs-on: ubuntu-latest}}' }
        @{ Case = 'an expression only in head'; Before = 'jobs: {build: {runs-on: ubuntu-latest}}'; After = 'jobs: {build: {runs-on: "${{ matrix.os }}"}}' }
        @{ Case = 'a secret moved between existing steps'; Before = 'jobs: {build: {steps: [{id: audit, run: "echo audit", env: {TOKEN: "${{ secrets.DEPLOY_TOKEN }}"}}, {id: publish, run: "echo publish"}]}}'; After = 'jobs: {build: {steps: [{id: audit, run: "echo audit"}, {id: publish, run: "echo publish", env: {TOKEN: "${{ secrets.DEPLOY_TOKEN }}"}}]}}' }
    ) {
        $stub.Contents[$baseKey] = $Before
        $stub.Contents[$headKey] = $After

        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        $result.details.github.sensitiveLines | Should -Be @("$($file.filename): comparison unavailable: Workflow sensitive YAML expressions require acknowledgement.")
    }

    # Deliberately malformed or unsupported YAML must never prove unchanged settings.
    It 'G10 fails closed for <Case> on <Side>' -ForEach @(
        foreach ($side in @('base', 'head')) {
            @{ Case = 'malformed flow YAML'; Side = $side; Content = 'permissions: {'; Error = 'comparison unavailable' }
            @{ Case = 'duplicate keys'; Side = $side; Content = "permissions: read-all`npermissions: write-all"; Error = 'comparison unavailable' }
            @{ Case = 'multiple documents'; Side = $side; Content = "permissions: read-all`n---`npermissions: write-all"; Error = 'exactly one document' }
            @{ Case = 'a scalar root'; Side = $side; Content = 'not-a-mapping'; Error = 'mapping root' }
            @{ Case = 'an empty document'; Side = $side; Content = ''; Error = 'exactly one document' }
            @{ Case = 'an anchor'; Side = $side; Content = 'permissions: &p {contents: write}'; Error = 'anchors' }
            @{ Case = 'an alias'; Side = $side; Content = 'permissions: *p'; Error = 'aliases' }
            @{ Case = 'a merge key'; Side = $side; Content = "defaults: &p {contents: write}`npermissions: {<<: *p}"; Error = 'anchors' }
            @{ Case = 'more than 100 nesting levels'; Side = $side; Content = 'permissions: ' + ('{x: ' * 100) + 'read' + ('}' * 100); Error = 'nesting exceeds 100 levels' }
            @{ Case = 'a non-scalar mapping key'; Side = $side; Content = "? [permissions, contents]`n: read"; Error = 'non-scalar mapping key' }
        }
    ) {
        $stub.Contents[$baseKey] = 'permissions: read-all'
        $stub.Contents[$headKey] = 'permissions: read-all'
        $key = if ($Side -eq 'base') { $baseKey } else { $headKey }
        $stub.Contents[$key] = $Content

        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        ($result.details.github.sensitiveLines -join "`n") | Should -Match $Error
    }

    It 'G10 rejects the documented unsupported content variant <Variant>' -ForEach @(
        @{ Variant = 'directory' }
        @{ Variant = 'symlink' }
        @{ Variant = 'submodule' }
    ) {
        $response = Get-GitHubApiFixture -Name "repos/get-content.$Variant"
        $stub.Responses['/contents/'] = ConvertTo-Json -InputObject $response -Depth 50

        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        ($result.details.github.sensitiveLines -join "`n") | Should -Match 'not a file object|not an inline base64 file'
    }

    It 'G10 rejects <Case> from the content API' -ForEach @(
        @{ Case = 'an unavailable large file'; Set = @{ encoding = 'none'; content = '' }; Error = 'not an inline base64 file' }
        @{ Case = 'another path'; Set = @{ path = 'README.md' }; Error = 'Content path does not match' }
        # Deliberately invalid API data: each case changes one field of a documented file response.
        @{ Case = 'unknown type'; Set = @{ type = 'unknown' }; Error = 'not an inline base64 file' }
        @{ Case = 'type in another case'; Set = @{ type = 'FILE' }; Error = 'not an inline base64 file' }
        @{ Case = 'encoding in another case'; Set = @{ encoding = 'BASE64' }; Error = 'not an inline base64 file' }
        @{ Case = 'path in another case'; Set = @{ path = '.github/WORKFLOWS/ci.yml' }; Error = 'Content path does not match' }
        @{ Case = 'missing encoding'; Set = @{ encoding = $null }; Error = 'not an inline base64 file' }
        @{ Case = 'missing content'; Set = @{ content = $null }; Error = 'not an inline base64 file' }
        @{ Case = 'invalid base64'; Set = @{ content = '***' }; Error = 'comparison unavailable' }
        @{ Case = 'invalid UTF-8'; Set = @{ content = '/w==' }; Error = 'comparison unavailable' }
    ) {
        $setValues = @{ path = $file.filename; content = 'e30=' }
        foreach ($key in $Set.Keys) { $setValues[$key] = $Set[$key] }
        $response = Get-GitHubApiFixture -Name 'repos/get-content.file' -Set $setValues
        $stub.Responses['/contents/'] = ConvertTo-Json -InputObject $response -Depth 50

        $result = Invoke-ScenarioGate -Stub $stub

        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        ($result.details.github.sensitiveLines -join "`n") | Should -Match $Error
    }

    It 'G10 fails closed when the contents API is unreadable' {
        $stub.Failures['/contents/'] = 'HTTP 403'
        $result = Invoke-ScenarioGate -Stub $stub
        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        ($result.details.github.sensitiveLines -join "`n") | Should -Match 'HTTP 403'
    }

    It 'G10 rejects the optional content API field <Field>' -ForEach @(
        @{ Field = 'target'; Fixture = 'repos/get-content.symlink' }
        @{ Field = 'submodule_git_url'; Fixture = 'repos/get-content.submodule' }
    ) {
        $response = Get-GitHubApiFixture -Name 'repos/get-content.file' -Set @{ path = $file.filename; content = 'e30=' }
        # content-file documents these optional fields as well as the separate symlink/submodule variants.
        $response[$Field] = (Get-GitHubApiFixture -Name $Fixture)[$Field]
        $stub.Responses['/contents/'] = ConvertTo-Json -InputObject $response -Depth 50
        $result = Invoke-ScenarioGate -Stub $stub
        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        ($result.details.github.sensitiveLines -join "`n") | Should -Match 'submodule or symlink'
    }

    It 'G10 handles <Case> without trusting an absent patch' -ForEach @(
        @{ Case = 'an added workflow'; Status = 'added'; Previous = '.github/workflows/ci.yml'; Name = '.github/workflows/ci.yml'; Expected = $true; Reads = 1 }
        @{ Case = 'a removed workflow'; Status = 'removed'; Previous = '.github/workflows/ci.yml'; Name = '.github/workflows/ci.yml'; Expected = $true; Reads = 1 }
        @{ Case = 'a modified workflow'; Status = 'modified'; Previous = '.github/workflows/ci.yml'; Name = '.github/workflows/ci.yml'; Expected = $false; Reads = 2 }
        @{ Case = 'a changed workflow'; Status = 'changed'; Previous = '.github/workflows/ci.yml'; Name = '.github/workflows/ci.yml'; Expected = $false; Reads = 2 }
        @{ Case = 'an unchanged workflow'; Status = 'unchanged'; Previous = '.github/workflows/ci.yml'; Name = '.github/workflows/ci.yml'; Expected = $false; Reads = 2 }
        @{ Case = 'a rename inside workflows'; Status = 'renamed'; Previous = '.github/workflows/old.yaml'; Name = '.github/workflows/ci.yml'; Expected = $false; Reads = 2 }
        @{ Case = 'activation by rename'; Status = 'renamed'; Previous = 'docs/ci.yml'; Name = '.github/workflows/ci.yml'; Expected = $true; Reads = 2 }
        @{ Case = 'deactivation by rename'; Status = 'renamed'; Previous = '.github/workflows/ci.yml'; Name = 'docs/ci.yml'; Expected = $true; Reads = 2 }
        @{ Case = 'a rename from an inactive extension'; Status = 'renamed'; Previous = '.github/workflows/ci.txt'; Name = '.github/workflows/ci.yml'; Expected = $true; Reads = 2 }
        @{ Case = 'a rename to an inactive extension'; Status = 'renamed'; Previous = '.github/workflows/ci.yml'; Name = '.github/workflows/ci.txt'; Expected = $true; Reads = 2 }
        @{ Case = 'a rename from an action'; Status = 'renamed'; Previous = '.github/actions/setup/action.yml'; Name = '.github/workflows/ci.yml'; Expected = $true; Reads = 2 }
        @{ Case = 'a copied workflow'; Status = 'copied'; Previous = '.github/workflows/old.yml'; Name = '.github/workflows/ci.yml'; Expected = $true; Reads = 2 }
    ) {
        $file.status = $Status
        $file.previous_filename = $Previous
        $file.filename = $Name
        $result = Invoke-ScenarioGate -Stub $stub
        $codes = @(Get-ReasonCode $result)
        if ($Expected) { $codes | Should -Be @('fail:workflow-permissions-changed') }
        else { $codes | Should -Be @() }
        $requests = @($stub.Calls | Where-Object { $_[-1] -match '/contents/' } | ForEach-Object { $_[-1] })
        $requests.Count | Should -Be $Reads
        if ($Status -ne 'added') { $requests[0] | Should -Be "repos/$repository/contents/${Previous}?ref=$($stub.PullRequest.baseRefOid)" }
        if ($Status -ne 'removed') { $requests[-1] | Should -Be "repos/$repository/contents/${Name}?ref=$($stub.PullRequest.headRefOid)" }
    }

    # Deliberately invalid diff-entry fields, changed independently from the shared contract fixture.
    It 'G10 rejects <Case> in the file list' -ForEach @(
        @{ Case = 'an unknown status'; Status = 'unknown'; Previous = '.github/workflows/ci.yml'; Error = 'Unsupported file status' }
        @{ Case = 'a missing status'; Status = $null; Previous = '.github/workflows/ci.yml'; Error = 'Unsupported file status' }
        @{ Case = 'a rename without a source'; Status = 'renamed'; Previous = ''; Error = 'no previous filename' }
        @{ Case = 'a copy without a source'; Status = 'copied'; Previous = $null; Error = 'no previous filename' }
    ) {
        $file.status = $Status
        $file.previous_filename = $Previous
        $result = Invoke-ScenarioGate -Stub $stub
        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        ($result.details.github.sensitiveLines -join "`n") | Should -Match $Error
    }

    It 'G10 rejects a moving <Ref> across the SHA-pinned content reads' -ForEach @(
        @{ Ref = 'headRefOid' }
        @{ Ref = 'baseRefOid' }
    ) {
        Mock -ModuleName MergeGate Invoke-MergeGateGh {
            $response = Invoke-MergeGateStub -Stub $stub -Arguments $Arguments
            if ($Arguments[-1] -match '/contents/') { $stub.PullRequest[$Ref] = 'a' * 40 }
            return $response
        }
        $result = Invoke-ScenarioGate -Stub $stub
        Get-ReasonCode $result | Should -Be @('fail:evaluation-error')
        $result.reasons[0].message | Should -Match 'head or base changed'
    }

    It 'G10 detects changed settings in an action document' {
        $file.filename = '.github/actions/setup/action.yml'
        $stub.Contents["$($stub.PullRequest.baseRefOid)/$($file.filename)"] = 'runs: {using: composite, steps: [{env: {TOKEN: "${{ secrets.OLD }}"}}]}'
        $stub.Contents["$($stub.PullRequest.headRefOid)/$($file.filename)"] = 'runs: {using: composite, steps: [{env: {TOKEN: "${{ secrets.NEW }}"}}]}'
        $result = Invoke-ScenarioGate -Stub $stub
        Get-ReasonCode $result | Should -Be @('fail:workflow-permissions-changed')
        $result.details.github.sensitiveLines | Should -Be @("$($file.filename): comparison unavailable: Workflow sensitive YAML expressions require acknowledgement.")
    }
}

Describe 'Merge gate fails closed' {
    BeforeEach {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        Mock -ModuleName MergeGate Invoke-MergeGateGh { Invoke-MergeGateStub -Stub $stub -Arguments $Arguments }
    }

    It 'fails with evaluation-error (exit 5) when <Case>' -ForEach @(
        @{ Case = 'the check run request fails'; Failures = @{ 'check-runs' = 'HTTP 502' }; Responses = @{} }
        @{ Case = 'gh is not authenticated'; Failures = @{ 'graphql' = 'gh auth login required' }; Responses = @{} }
        @{ Case = 'the workflow run response is not JSON'; Failures = @{}; Responses = @{ 'actions/runs' = '<html>502</html>' } }
        @{ Case = 'the GraphQL response has errors'; Failures = @{}; Responses = @{ 'graphql' = '{"data":null,"errors":[{"message":"Something went wrong"}]}' } }
        @{ Case = 'the compare response has no behind_by'; Failures = @{}; Responses = @{ 'compare' = '{"status":"ahead"}' } }
        # Intentionally invalid: a list endpoint answering with an object.
        @{ Case = 'the file list is not a list'; Failures = @{}; Responses = @{ 'pulls/78/files' = '{"message":"Not Found"}' } }
        @{ Case = 'the pull request does not exist'; Failures = @{}; Responses = @{ 'graphql' = '{"data":{"repository":{"pullRequest":null}}}' } }
    ) {
        $stub.Failures = $Failures
        $stub.Responses = $Responses
        $result = Invoke-ScenarioGate -Stub $stub

        $result.verdict | Should -Be 'fail'
        $result.exitCode | Should -Be 5
        Get-ReasonCode $result | Should -Be @('fail:evaluation-error')
    }

    It 'fails with evaluation-error when the check run pages do not reach total_count' {
        $stub.CheckRuns.total_count = $stub.CheckRuns.check_runs.Count + 1
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 5
    }

    It 'fails with evaluation-error when the workflow runs overflow the page limit' {
        $template = $stub.WorkflowRuns.workflow_runs[0]
        $stub.WorkflowRuns.workflow_runs = @(1..1001 | ForEach-Object { $template })
        $stub.WorkflowRuns.total_count = 1001
        $result = Invoke-ScenarioGate -Stub $stub

        $result.exitCode | Should -Be 5
        $result.reasons[0].message | Should -Match 'more than 10 pages'
    }

    It 'fails with evaluation-error when the pull request has more reviews than one page' {
        $stub.PullRequest.reviews.totalCount = 101
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 5
    }

    It 'fails with evaluation-error when the review threads do not match totalCount' {
        $stub.PullRequest.reviewThreads.totalCount = 1
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 5
    }

    It 'fails with evaluation-error when a check run belongs to another commit' {
        $stub.CheckRuns.check_runs[0].head_sha = Get-OtherSha
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 5
    }

    It 'fails with evaluation-error when the pull request body is <Case>' -ForEach @(
        @{ Case = 'null'; Remove = $false }
        @{ Case = 'missing'; Remove = $true }
    ) {
        if ($Remove) { $stub.PullRequest.Remove('body') } else { $stub.PullRequest.body = $null }
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 5
    }

    It 'fails with evaluation-error when the timeline has more events than one page' {
        $stub.PullRequest.timelineItems.pageInfo.hasPreviousPage = $true
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 5
    }

    It 'fails with evaluation-error when a required status checks rule has no strict policy' {
        $rules = Get-GitHubApiFixture -Name 'repos/get-branch-rules.merge-gate-required-check'
        $rules[1].parameters.Remove('strict_required_status_checks_policy')
        $stub.Rules = $rules
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 5
    }

    It 'fails with evaluation-error when the pull request has no mergeable state' {
        $stub.PullRequest.mergeable = $null
        (Invoke-ScenarioGate -Stub $stub).exitCode | Should -Be 5
    }

    It 'fails with invalid-input (exit 4) for <Case>' -ForEach @(
        @{ Case = 'a repository without owner'; Parameters = @{ Repository = 'devsecops-platform' } }
        @{ Case = 'a repository with a space'; Parameters = @{ Repository = 'msucharda/devsecops platform' } }
        @{ Case = 'a pull request number 0'; Parameters = @{ Pr = 0 } }
        @{ Case = 'a short expected head'; Parameters = @{ ExpectedHeadSha = '5a86d28' } }
        @{ Case = 'a non-hex acknowledgement'; Parameters = @{ AcknowledgeWorkflowChanges = 'z' * 40 } }
    ) {
        $result = Invoke-ScenarioGate -Stub $stub -Parameters $Parameters

        $result.exitCode | Should -Be 4
        Get-ReasonCode $result | Should -Be @('fail:invalid-input')
        $stub.Calls.Count | Should -Be 0
    }
}

Describe 'Merge gate repository and gh call' {
    It 'parses <Repository>' -ForEach @(
        @{ Repository = 'msucharda/devsecops-platform'; HostName = 'github.com'; Slug = 'msucharda/devsecops-platform' }
        @{ Repository = 'example.ghe.com/example-platform/instance'; HostName = 'example.ghe.com'; Slug = 'example-platform/instance' }
    ) {
        InModuleScope MergeGate -Parameters $_ {
            $target = ConvertTo-MergeGateTarget -Repository $Repository
            $target.Host | Should -Be $HostName
            $target.Slug | Should -Be $Slug
            $target.Repository | Should -Be "$HostName/$Slug"
        }
    }

    It 'calls gh with the GHE host and without GH_TOKEN for a GHE.com repository' {
        InModuleScope MergeGate {
            $env:GH_TOKEN = 'github-com-token'
            try {
                Mock gh { $script:seenToken = $env:GH_TOKEN; $script:seenArguments = $args; $global:LASTEXITCODE = 0; '{"total_count":0,"check_runs":[]}' }
                $target = ConvertTo-MergeGateTarget -Repository 'example.ghe.com/example-platform/instance'
                $null = Invoke-MergeGateRest -Target $target -Path 'repos/example-platform/instance/commits/x/check-runs'
                $script:seenToken | Should -BeNullOrEmpty
                $script:seenArguments | Should -Contain 'example.ghe.com'
                $script:seenArguments | Should -Contain 'X-GitHub-Api-Version: 2026-03-10'
                $env:GH_TOKEN | Should -Be 'github-com-token'
            }
            finally { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
        }
    }

    It 'throws when gh exits with an error' {
        InModuleScope MergeGate {
            Mock gh { $global:LASTEXITCODE = 1; [System.Management.Automation.ErrorRecord]::new([Exception]::new('HTTP 404'), 'gh', 'NotSpecified', $null) }
            $target = ConvertTo-MergeGateTarget -Repository 'msucharda/devsecops-platform'
            { Invoke-MergeGateGh -Target $target -Arguments @('api', '--method', 'GET', 'repos/x') } | Should -Throw '*exit code 1*HTTP 404*'
        }
    }
}

Describe 'Merge gate read-only guard' {
    It 'allows <Case>' -ForEach @(
        @{ Case = 'a REST GET'; Arguments = @('api', '--method', 'GET', '--hostname', 'github.com', '-H', 'Accept: application/vnd.github+json', 'repos/o/r/pulls/1/files') }
        @{ Case = 'a GraphQL query'; Arguments = @('api', 'graphql', '-f', 'query=query($owner: String!) { viewer { login } }', '--hostname', 'github.com', '-f', 'owner=o', '-F', 'number=1') }
    ) {
        InModuleScope MergeGate -Parameters $_ { { Assert-MergeGateReadRequest -Arguments $Arguments } | Should -Not -Throw }
    }

    It 'refuses <Case>' -ForEach @(
        @{ Case = 'gh pr merge'; Arguments = @('pr', 'merge', '78', '--squash') }
        @{ Case = 'an api call with too few arguments'; Arguments = @('api', '--method', 'GET') }
        @{ Case = 'a REST POST'; Arguments = @('api', '--method', 'POST', '--hostname', 'github.com', 'repos/o/r/pulls/1/merge') }
        @{ Case = 'a REST call without method'; Arguments = @('api', '--hostname', 'github.com', 'repos/o/r', 'x') }
        @{ Case = 'a REST GET with a body field'; Arguments = @('api', '--method', 'GET', '--hostname', 'github.com', '-f', 'a=b', 'repos/o/r') }
        @{ Case = 'a GraphQL mutation'; Arguments = @('api', 'graphql', '-f', 'query=mutation { mergePullRequest(input: {}) { clientMutationId } }') }
        @{ Case = 'a GraphQL query with a mutation'; Arguments = @('api', 'graphql', '-f', 'query=query { a } mutation { b }') }
        @{ Case = 'a GraphQL query read from a file'; Arguments = @('api', 'graphql', '-F', 'query=@mutation.graphql', '--hostname', 'github.com') }
        @{ Case = 'a GraphQL query as a typed field'; Arguments = @('api', 'graphql', '-F', 'query=query { viewer { login } }', '--hostname', 'github.com') }
        @{ Case = 'a GraphQL request whose first field is not the query'; Arguments = @('api', 'graphql', '-f', 'owner=o', '-f', 'query=mutation { a }') }
        @{ Case = 'another gh command with GET-like arguments'; Arguments = @('run', '--method', 'GET', '--hostname', 'github.com') }
        @{ Case = 'a REST call with -X instead of --method'; Arguments = @('api', '-X', 'GET', '--hostname', 'github.com', 'repos/o/r') }
    ) {
        InModuleScope MergeGate -Parameters $_ { { Assert-MergeGateReadRequest -Arguments $Arguments } | Should -Throw '*refused*' }
    }
}

Describe 'Merge gate check functions' {
    It 'G1 state <State> merged=<Merged> expectMerged=<ExpectMerged> -> <Expected>' -ForEach @(
        @{ State = 'OPEN'; Merged = $false; ExpectMerged = $false; Expected = @() }
        @{ State = 'CLOSED'; Merged = $false; ExpectMerged = $false; Expected = @('fail:pr-closed') }
        @{ State = 'MERGED'; Merged = $true; ExpectMerged = $false; Expected = @('already-merged') }
        @{ State = 'MERGED'; Merged = $true; ExpectMerged = $true; Expected = @('already-merged') }
        @{ State = 'MERGED'; Merged = $false; ExpectMerged = $false; Expected = @('fail:pr-state-unknown') }
        @{ State = 'open'; Merged = $false; ExpectMerged = $false; Expected = @('fail:pr-state-unknown') }
        @{ State = ''; Merged = $false; ExpectMerged = $false; Expected = @('fail:pr-state-unknown') }
        @{ State = 'OPEN'; Merged = $false; ExpectMerged = $true; Expected = @('fail:not-merged') }
        @{ State = 'CLOSED'; Merged = $false; ExpectMerged = $true; Expected = @('fail:not-merged') }
    ) {
        InModuleScope MergeGate -Parameters $_ {
            @(Get-MergeGateStateFinding -PullRequest @{ state = $State; merged = $Merged } -ExpectMerged:$ExpectMerged) | Should -Be $Expected
        }
    }

    It 'G2 isDraft=<Draft> -> <Expected>' -ForEach @(
        @{ Draft = $false; Expected = @() }
        @{ Draft = $true; Expected = @('fail:draft') }
        @{ Draft = $null; Expected = @('fail:draft') }
    ) {
        InModuleScope MergeGate -Parameters $_ { @(Get-MergeGateDraftFinding -PullRequest @{ isDraft = $Draft }) | Should -Be $Expected }
    }

    It 'G3 expected head <Case>' -ForEach @(
        @{ Case = 'equal'; Expected = 'a' * 40; Result = @() }
        @{ Case = 'not given'; Expected = ''; Result = @() }
        @{ Case = 'different'; Expected = 'b' * 40; Result = @('fail:head-moved') }
    ) {
        InModuleScope MergeGate -Parameters $_ { @(Get-MergeGateHeadFinding -HeadSha ('a' * 40) -ExpectedHeadSha $Expected) | Should -Be $Result }
    }

    It 'G4 run state <Status>/<Conclusion> -> <Expected>' -ForEach @(
        @{ Status = 'queued'; Conclusion = $null; Expected = 'pending' }
        @{ Status = 'in_progress'; Conclusion = $null; Expected = 'pending' }
        @{ Status = 'waiting'; Conclusion = $null; Expected = 'pending' }
        @{ Status = 'requested'; Conclusion = $null; Expected = 'pending' }
        @{ Status = 'pending'; Conclusion = $null; Expected = 'pending' }
        @{ Status = 'completed'; Conclusion = 'success'; Expected = 'success' }
        @{ Status = 'completed'; Conclusion = 'skipped'; Expected = 'success' }
        @{ Status = 'completed'; Conclusion = 'neutral'; Expected = 'success' }
        @{ Status = 'completed'; Conclusion = 'failure'; Expected = 'failure' }
        @{ Status = 'completed'; Conclusion = 'cancelled'; Expected = 'failure' }
        @{ Status = 'completed'; Conclusion = 'timed_out'; Expected = 'failure' }
        @{ Status = 'completed'; Conclusion = 'action_required'; Expected = 'failure' }
        @{ Status = 'completed'; Conclusion = 'startup_failure'; Expected = 'failure' }
        @{ Status = 'completed'; Conclusion = 'stale'; Expected = 'failure' }
        @{ Status = 'completed'; Conclusion = $null; Expected = 'failure' }
        @{ Status = 'completed'; Conclusion = 'Success'; Expected = 'failure' }
        @{ Status = 'Completed'; Conclusion = 'success'; Expected = 'failure' }
        @{ Status = 'Queued'; Conclusion = $null; Expected = 'failure' }
        @{ Status = $null; Conclusion = 'success'; Expected = 'failure' }
    ) {
        InModuleScope MergeGate -Parameters $_ { Get-MergeGateRunState -Status $Status -Conclusion $Conclusion | Should -Be $Expected }
    }

    It 'G4 recognizes the Copilot run: <Case>' -ForEach @(
        @{ Case = 'Copilot check run'; Kind = 'CheckRun'; Run = @{ name = 'copilot-pull-request-reviewer' }; Expected = $true }
        @{ Case = 'check run with another case'; Kind = 'CheckRun'; Run = @{ name = 'Copilot-Pull-Request-Reviewer' }; Expected = $false }
        @{ Case = 'other check run'; Kind = 'CheckRun'; Run = @{ name = 'Platform tools' }; Expected = $false }
        @{ Case = 'Copilot workflow run'; Kind = 'WorkflowRun'; Run = @{ name = 'Running Copilot Code Review'; event = 'dynamic' }; Expected = $true }
        @{ Case = 'workflow named like Copilot on push'; Kind = 'WorkflowRun'; Run = @{ name = 'Running Copilot Code Review'; event = 'push' }; Expected = $false }
        @{ Case = 'other dynamic workflow'; Kind = 'WorkflowRun'; Run = @{ name = 'Code scanning AI findings on PR #87'; event = 'dynamic' }; Expected = $false }
        @{ Case = 'dynamic workflow with another case'; Kind = 'WorkflowRun'; Run = @{ name = 'running copilot code review'; event = 'dynamic' }; Expected = $false }
        @{ Case = 'Copilot workflow with another event case'; Kind = 'WorkflowRun'; Run = @{ name = 'Running Copilot Code Review'; event = 'Dynamic' }; Expected = $false }
    ) {
        InModuleScope MergeGate -Parameters $_ { Test-MergeGateCopilotRun -Run $Run -Kind $Kind | Should -Be $Expected }
    }

    Context 'G4 check finding' {
        BeforeAll {
            $now = [DateTimeOffset]::Parse('2026-10-22T10:00:00Z')
            $green = @{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }
        }

        It 'G4 <Case> -> <Expected>' -ForEach @(
            @{ Case = 'green run'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @() }
            @{ Case = 'failed workflow run'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'failure' }); Checks = @(); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:check-failed:Source CI') }
            @{ Case = 'running workflow run'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'in_progress'; conclusion = $null }); Checks = @(); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('pending:checks-pending:Source CI') }
            @{ Case = 'failed check run'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(@{ name = 'Terraform'; status = 'completed'; conclusion = 'timed_out' }); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:check-failed:Terraform') }
            @{ Case = 'queued check run'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(@{ name = 'Terraform'; status = 'queued'; conclusion = $null }); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('pending:checks-pending:Terraform') }
            @{ Case = 'failed Copilot check run is left to G6'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(@{ name = 'copilot-pull-request-reviewer'; status = 'completed'; conclusion = 'failure' }); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @() }
            @{ Case = 'running Copilot workflow is left to G6'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }, @{ name = 'Running Copilot Code Review'; event = 'dynamic'; status = 'in_progress'; conclusion = $null }); Checks = @(); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @() }
            @{ Case = 'failed commit status'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(@{ context = 'ci/legacy'; state = 'failure' }); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:check-failed:ci/legacy') }
            @{ Case = 'error commit status'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(@{ context = 'ci/legacy'; state = 'error' }); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:check-failed:ci/legacy') }
            @{ Case = 'pending commit status'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(@{ context = 'ci/legacy'; state = 'pending' }); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('pending:checks-pending:ci/legacy') }
            @{ Case = 'successful commit status'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(@{ context = 'ci/legacy'; state = 'success' }); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @() }
            @{ Case = 'expected workflow missing after the grace period'; Runs = @(); Checks = @(); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:required-check-missing:Source CI') }
            @{ Case = 'expected workflow missing within the grace period'; Runs = @(); Checks = @(); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:50:00Z'; Expected = @('pending:required-check-missing:Source CI') }
            @{ Case = 'expected workflow missing without a push time'; Runs = @(); Checks = @(); Statuses = @(); Required = @(); Pushed = $null; Expected = @('fail:required-check-missing:Source CI') }
            @{ Case = 'expected workflow only on push'; Runs = @(@{ name = 'Source CI'; event = 'push'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:required-check-missing:Source CI') }
            @{ Case = 'expected workflow with another case'; Runs = @(@{ name = 'source ci'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(); Required = @(); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:required-check-missing:Source CI') }
            @{ Case = 'required context missing'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(); Required = @('copilot-pull-request-reviewer'); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:required-check-missing:copilot-pull-request-reviewer') }
            @{ Case = 'required context reported by a check run'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(@{ name = 'Platform tools'; status = 'completed'; conclusion = 'success' }); Statuses = @(); Required = @('Platform tools'); Pushed = '2026-10-22T09:00:00Z'; Expected = @() }
            @{ Case = 'required context reported by a status'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(); Statuses = @(@{ context = 'ci/legacy'; state = 'success' }); Required = @('ci/legacy'); Pushed = '2026-10-22T09:00:00Z'; Expected = @() }
            @{ Case = 'required context with another case'; Runs = @(@{ name = 'Source CI'; event = 'pull_request'; status = 'completed'; conclusion = 'success' }); Checks = @(@{ name = 'platform tools'; status = 'completed'; conclusion = 'success' }); Statuses = @(@{ context = 'Ci/Legacy'; state = 'success' }); Required = @('Platform tools', 'ci/legacy'); Pushed = '2026-10-22T09:00:00Z'; Expected = @('fail:required-check-missing:Platform tools', 'fail:required-check-missing:ci/legacy') }
        ) {
            $parameters = @{ WorkflowRuns = $Runs; CheckRuns = $Checks; Statuses = $Statuses; RequiredChecks = @($Required | ForEach-Object { @{ context = $_ } }); PushedAt = $Pushed; Now = $now }
            InModuleScope MergeGate -Parameters @{ Parameters = $parameters; Expected = $Expected } {
                @(Get-MergeGateCheckFinding @Parameters -ExpectedWorkflows @('Source CI') -GraceMinutes 15) | Should -Be $Expected
            }
        }
    }

    It 'G5 thread resolved=<Resolved> -> <Expected>' -ForEach @(
        @{ Resolved = $true; Expected = @() }
        @{ Resolved = $false; Expected = @('fail:unresolved-threads') }
        @{ Resolved = $null; Expected = @('fail:unresolved-threads') }
    ) {
        InModuleScope MergeGate -Parameters $_ {
            @(Get-MergeGateThreadFinding -Threads @(@{ isResolved = $true }, @{ isResolved = $Resolved; isOutdated = $true })) | Should -Be $Expected
        }
    }

    It 'G6 counts a review by <Case> as Copilot: <Expected>' -ForEach @(
        @{ Case = 'the GraphQL Copilot login'; Login = 'copilot-pull-request-reviewer'; Body = 'review'; Submitted = '2026-10-22T09:00:00Z'; Expected = $true }
        @{ Case = 'the REST Copilot login'; Login = 'copilot-pull-request-reviewer[bot]'; Body = 'review'; Submitted = '2026-10-22T09:00:00Z'; Expected = $true }
        @{ Case = 'the Copilot comment login'; Login = 'Copilot'; Body = 'review'; Submitted = '2026-10-22T09:00:00Z'; Expected = $true }
        @{ Case = 'a user'; Login = 'msucharda'; Body = 'review'; Submitted = '2026-10-22T09:00:00Z'; Expected = $false }
        @{ Case = 'a login with another case'; Login = 'Copilot-Pull-Request-Reviewer'; Body = 'review'; Submitted = '2026-10-22T09:00:00Z'; Expected = $false }
        @{ Case = 'a missing author'; Login = $null; Body = 'review'; Submitted = '2026-10-22T09:00:00Z'; Expected = $false }
        @{ Case = 'a pending review without submittedAt'; Login = 'copilot-pull-request-reviewer'; Body = 'review'; Submitted = $null; Expected = $false }
        @{ Case = 'the job-not-started notice'; Login = 'copilot-pull-request-reviewer'; Body = 'The job was not started because a GitHub Actions budget is preventing further use.'; Submitted = '2026-10-22T09:00:00Z'; Expected = $false }
    ) {
        InModuleScope MergeGate -Parameters $_ {
            Test-MergeGateCopilotReview -Review @{ author = @{ login = $Login }; body = $Body; submittedAt = $Submitted } | Should -Be $Expected
        }
    }

    Context 'G6 Copilot finding' {
        BeforeAll {
            $now = [DateTimeOffset]::Parse('2026-10-22T10:00:00Z')
            function Get-CopilotState {
                param($Rounds = 1, $LastReviewAt = '2026-10-22T09:30:00Z', $LastRequestAt = '2026-10-22T09:20:00Z', [bool] $ReviewedHead = $true, [object[]] $CheckRuns = @())
                @{
                    Rounds = $Rounds
                    LastReviewAt = if ($LastReviewAt) { [DateTimeOffset]::Parse($LastReviewAt) } else { $null }
                    LastRequestAt = if ($LastRequestAt) { [DateTimeOffset]::Parse($LastRequestAt) } else { $null }
                    ReviewedHead = $ReviewedHead
                    CheckRuns = $CheckRuns
                }
            }
        }

        It 'G6 <Case> -> <Expected>' -ForEach @(
            @{ Case = 'review of the head after the request'; State = @{}; Options = @{}; Expected = @() }
            @{ Case = 'request newer than the review'; State = @{ LastRequestAt = '2026-10-22T09:40:00Z' }; Options = @{}; Expected = @('pending:copilot-review-in-progress') }
            @{ Case = 'request in the same second as the review'; State = @{ LastRequestAt = '2026-10-22T09:30:00Z' }; Options = @{}; Expected = @() }
            @{ Case = 'request without any review'; State = @{ Rounds = 0; LastReviewAt = $null; ReviewedHead = $false }; Options = @{}; Expected = @('pending:copilot-review-in-progress') }
            @{ Case = 'Copilot check run in progress'; State = @{ CheckRuns = @(@{ status = 'in_progress'; completed_at = $null }) }; Options = @{}; Expected = @('pending:copilot-review-in-progress') }
            @{ Case = 'Copilot check run queued'; State = @{ CheckRuns = @(@{ status = 'queued'; completed_at = $null }) }; Options = @{}; Expected = @('pending:copilot-review-in-progress') }
            @{ Case = 'Copilot check run with an unknown status case'; State = @{ CheckRuns = @(@{ status = 'Completed'; completed_at = '2026-10-22T08:00:00Z' }) }; Options = @{}; Expected = @('pending:copilot-review-in-progress') }
            @{ Case = 'Copilot check run completed recently without a head review'; State = @{ ReviewedHead = $false; CheckRuns = @(@{ status = 'completed'; completed_at = '2026-10-22T09:20:00Z' }) }; Options = @{}; Expected = @('pending:copilot-review-in-progress') }
            @{ Case = 'Copilot check run completed without completed_at'; State = @{ ReviewedHead = $false; CheckRuns = @(@{ status = 'completed'; completed_at = $null }) }; Options = @{}; Expected = @('pending:copilot-review-in-progress') }
            @{ Case = 'Copilot check run completed long ago without a head review'; State = @{ ReviewedHead = $false; CheckRuns = @(@{ status = 'completed'; completed_at = '2026-10-22T09:10:00Z' }) }; Options = @{}; Expected = @() }
            @{ Case = 'Copilot check run completed recently with a head review'; State = @{ CheckRuns = @(@{ status = 'completed'; completed_at = '2026-10-22T09:50:00Z' }) }; Options = @{}; Expected = @() }
            @{ Case = 'no review and no request'; State = @{ Rounds = 0; LastReviewAt = $null; LastRequestAt = $null; ReviewedHead = $false }; Options = @{}; Expected = @('fail:copilot-review-missing') }
            @{ Case = 'no review and no request when not required'; State = @{ Rounds = 0; LastReviewAt = $null; LastRequestAt = $null; ReviewedHead = $false }; Options = @{ RequireReview = $false }; Expected = @() }
            @{ Case = 'review without request record'; State = @{ LastRequestAt = $null }; Options = @{}; Expected = @() }
            @{ Case = 'stale review with RequireOnHead'; State = @{ ReviewedHead = $false }; Options = @{ RequireOnHead = $true }; Expected = @('fail:copilot-review-stale') }
            @{ Case = 'head review with RequireOnHead'; State = @{}; Options = @{ RequireOnHead = $true }; Expected = @() }
            @{ Case = 'stale review without RequireOnHead'; State = @{ ReviewedHead = $false }; Options = @{}; Expected = @() }
        ) {
            $copilot = Get-CopilotState @State
            InModuleScope MergeGate -Parameters @{ Copilot = $copilot; Options = $Options; Expected = $Expected; Now = $now } {
                @(Get-MergeGateCopilotFinding -Copilot $Copilot -Now $Now -PostGraceMinutes 45 @Options) | Should -Be $Expected
            }
        }
    }

    It 'G7 mergeable=<Mergeable> status=<Status> others=<Others> -> <Expected>' -ForEach @(
        @{ Mergeable = 'MERGEABLE'; Status = 'CLEAN'; Others = $false; Draft = $false; Expected = @() }
        @{ Mergeable = 'MERGEABLE'; Status = 'HAS_HOOKS'; Others = $false; Draft = $false; Expected = @() }
        @{ Mergeable = 'MERGEABLE'; Status = 'BEHIND'; Others = $false; Draft = $false; Expected = @() }
        @{ Mergeable = 'MERGEABLE'; Status = 'UNSTABLE'; Others = $false; Draft = $false; Expected = @() }
        @{ Mergeable = 'CONFLICTING'; Status = 'CLEAN'; Others = $false; Draft = $false; Expected = @('fail:conflict') }
        @{ Mergeable = 'MERGEABLE'; Status = 'DIRTY'; Others = $false; Draft = $false; Expected = @('fail:conflict') }
        @{ Mergeable = 'UNKNOWN'; Status = 'CLEAN'; Others = $false; Draft = $false; Expected = @('pending:mergeability-unknown') }
        @{ Mergeable = 'MERGEABLE'; Status = 'UNKNOWN'; Others = $false; Draft = $false; Expected = @('pending:mergeability-unknown') }
        @{ Mergeable = 'mergeable'; Status = 'CLEAN'; Others = $false; Draft = $false; Expected = @('fail:mergeability-unrecognized') }
        @{ Mergeable = 'MERGEABLE'; Status = 'clean'; Others = $false; Draft = $false; Expected = @('fail:mergeability-unrecognized') }
        @{ Mergeable = 'MERGEABLE'; Status = 'BLOCKED'; Others = $false; Draft = $false; Expected = @('fail:blocked-by-rules') }
        @{ Mergeable = 'MERGEABLE'; Status = 'BLOCKED'; Others = $true; Draft = $false; Expected = @() }
        @{ Mergeable = 'MERGEABLE'; Status = 'DRAFT'; Others = $true; Draft = $true; Expected = @() }
        @{ Mergeable = 'MERGEABLE'; Status = 'DRAFT'; Others = $false; Draft = $false; Expected = @('fail:mergeability-unrecognized') }
        @{ Mergeable = 'MERGEABLE'; Status = 'draft'; Others = $true; Draft = $true; Expected = @('fail:mergeability-unrecognized') }
        @{ Mergeable = 'MERGEABLE'; Status = 'MERGED'; Others = $true; Draft = $true; Expected = @('fail:mergeability-unrecognized') }
    ) {
        InModuleScope MergeGate -Parameters $_ {
            @(Get-MergeGateMergeFinding -PullRequest @{ mergeable = $Mergeable; mergeStateStatus = $Status; isDraft = $Draft } -OtherFindings $Others) | Should -Be $Expected
        }
    }

    It 'G7 fails a merge queue, which would merge later without the gate' {
        InModuleScope MergeGate {
            @(Get-MergeGateMergeFinding -PullRequest @{ mergeable = 'MERGEABLE'; mergeStateStatus = 'CLEAN'; isDraft = $false } -OtherFindings $false -MergeQueue $true) | Should -Be @('fail:merge-queue-unsupported')
            (Get-MergeGateRuleSummary -Rules (Get-GitHubApiFixture -Name 'repos/get-branch-rules.merge-queue')).MergeQueue | Should -BeTrue
            (Get-MergeGateRuleSummary -Rules (Get-GitHubApiFixture -Name 'repos/get-branch-rules.merge-gate')).MergeQueue | Should -BeFalse
        }
    }

    It 'G8 behind=<Behind> requireUpToDate=<Require> strict=<Strict> -> <Expected>' -ForEach @(
        @{ Behind = 0; Require = $true; Strict = $true; Expected = @() }
        @{ Behind = 3; Require = $false; Strict = $false; Expected = @() }
        @{ Behind = 3; Require = $true; Strict = $false; Expected = @('fail:behind-base') }
        @{ Behind = 3; Require = $false; Strict = $true; Expected = @('fail:behind-base') }
    ) {
        InModuleScope MergeGate -Parameters $_ { @(Get-MergeGateBaseFinding -BehindBy $Behind -RequireUpToDate:$Require -StrictPolicy $Strict) | Should -Be $Expected }
    }

    It 'G9 treats the section <Content> as empty: <Expected>' -ForEach @(
        @{ Content = ''; Expected = $true }
        @{ Content = "`n`n`u{017D}`u{00E1}dn`u{00E9}`n"; Expected = $true }
        @{ Content = "`n- `u{017D}`u{00E1}dn`u{00E9}.`n"; Expected = $true }
        @{ Content = 'None'; Expected = $true }
        @{ Content = '-'; Expected = $true }
        @{ Content = "<!-- write `u{017D}`u{00E1}dn`u{00E9} when there are none -->`n"; Expected = $true }
        @{ Content = "`n1. Should the gate fail on decisions?`n"; Expected = $false }
        @{ Content = "`u{017D}`u{00E1}dn`u{00E9}, ale ov`u{011B}`u{0159} limit"; Expected = $false }
    ) {
        InModuleScope MergeGate -Parameters $_ { Test-MergeGateEmptySection -Content $Content | Should -Be $Expected }
    }

    It 'G9 body <Case> -> <Expected>' -ForEach @(
        @{ Case = 'without sections'; Body = "## Zm`u{011B}ny`n- a"; Expected = @() }
        @{ Case = 'with open questions'; Body = "## Otev`u{0159}en`u{00E9} ot`u{00E1}zky`n1. M`u{00E1} gate `u{010D}ekat?`n## Testy`nok"; Expected = @('fail:open-questions') }
        @{ Case = 'with an English heading and suffix'; Body = "### Open questions (for the user)`n- Which cap?"; Expected = @('fail:open-questions') }
        @{ Case = 'with a lower-case heading'; Body = "## otev`u{0159}en`u{00E9} ot`u{00E1}zky`n- Pro`u{010D}?"; Expected = @('fail:open-questions') }
        @{ Case = 'with the Czech none'; Body = "## Otev`u{0159}en`u{00E9} ot`u{00E1}zky`n`u{017D}`u{00E1}dn`u{00E9}`n## Testy`n- x"; Expected = @() }
        @{ Case = 'with an empty section before the next heading'; Body = "## Otev`u{0159}en`u{00E9} ot`u{00E1}zky`n`n## Testy`n- x"; Expected = @() }
        @{ Case = 'with open live criteria only'; Body = "## Otev`u{0159}en`u{00E1} `u{017E}iv`u{00E1} krit`u{00E9}ria`n- Spustit bootstrap"; Expected = @() }
        @{ Case = 'with a marker of 2 open questions'; Body = "text`n<!-- merge-gate: open-questions=2 -->"; Expected = @('fail:open-questions') }
        @{ Case = 'with a marker of 0 open questions'; Body = "text`n<!-- merge-gate: open-questions=0 -->"; Expected = @() }
        @{ Case = 'with a question in a subsection'; Body = "## Otev`u{0159}en`u{00E9} ot`u{00E1}zky`n### P`u{0159}`u{00ED}stup`nM`u{00E1} workflow dostat z`u{00E1}pis?`n## Testy`n- x"; Expected = @('fail:open-questions') }
        @{ Case = 'with an empty section followed by a deeper heading of another section'; Body = "## Otev`u{0159}en`u{00E9} ot`u{00E1}zky`n`u{017D}`u{00E1}dn`u{00E9}`n## Testy`n### Detail`n- x"; Expected = @() }
        @{ Case = 'with user decisions'; Body = "## Rozhodnut`u{00ED} u`u{017E}ivatele`n- D1"; Expected = @() }
    ) {
        InModuleScope MergeGate -Parameters $_ { @(Get-MergeGateBodyFinding -Body $Body) | Should -Be $Expected }
    }

    It 'G9 warns about decisions in <Case>: <Expected>' -ForEach @(
        @{ Case = 'a body without decisions'; Body = "## Zm`u{011B}ny`n- a"; Expected = $false }
        @{ Case = 'unaccepted user decisions'; Body = "## Rozhodnut`u{00ED} u`u{017E}ivatele`n- D1"; Expected = $true }
        @{ Case = 'unaccepted decisions for the user'; Body = "## Rozhodnut`u{00ED} pro u`u{017E}ivatele`n- D1"; Expected = $true }
        @{ Case = 'unverified acceptance marker'; Body = "## Rozhodnut`u{00ED} u`u{017E}ivatele`n- D1`n<!-- merge-gate: decisions-accepted msucharda 2026-10-22 -->"; Expected = $true }
        @{ Case = 'an upper-case acceptance marker'; Body = "## Rozhodnut`u{00ED} u`u{017E}ivatele`n- D1`n<!-- MERGE-GATE: DECISIONS-ACCEPTED msucharda 2026-10-22 -->"; Expected = $true }
        @{ Case = 'an acceptance marker without date'; Body = "## Rozhodnut`u{00ED} u`u{017E}ivatele`n- D1`n<!-- merge-gate: decisions-accepted msucharda -->"; Expected = $true }
    ) {
        InModuleScope MergeGate -Parameters $_ { Test-MergeGateDecisionsUnconfirmed -Body $Body | Should -Be $Expected }
    }

    It 'G10 treats <Path> as a workflow path: <Expected>' -ForEach @(
        @{ Path = '.github/workflows/ci.yml'; Expected = $true }
        @{ Path = '.github/actions/setup/action.yml'; Expected = $true }
        @{ Path = '.github/agents/ci-runner.agent.md'; Expected = $false }
        @{ Path = 'templates/instance/.github/workflows/deploy.yml'; Expected = $false }
        @{ Path = 'docs/permissions.md'; Expected = $false }
    ) {
        InModuleScope MergeGate -Parameters $_ { Test-MergeGateWorkflowPath -Path $Path | Should -Be $Expected }
    }

    It 'G10 finding <Case>' -ForEach @(
        @{ Case = 'without sensitive lines'; Lines = @(); Ack = ''; Expected = @() }
        @{ Case = 'without acknowledgement'; Lines = @('x: +permissions:'); Ack = ''; Expected = @('fail:workflow-permissions-changed') }
        @{ Case = 'acknowledged for the head'; Lines = @('x: +permissions:'); Ack = 'a' * 40; Expected = @() }
        @{ Case = 'acknowledged for another head'; Lines = @('x: +permissions:'); Ack = 'b' * 40; Expected = @('fail:workflow-permissions-changed') }
    ) {
        InModuleScope MergeGate -Parameters $_ { @(Get-MergeGateWorkflowFinding -SensitiveLines $Lines -HeadSha ('a' * 40) -AcknowledgedSha $Ack) | Should -Be $Expected }
    }

    It 'G10 classifies renamed and other .github files' {
        InModuleScope MergeGate {
            Mock Get-MergeGateWorkflowContent { 'name: CI' }
            $change = Get-MergeGateGitHubChange -Files @(
                @{ filename = 'docs/ci.yml'; previous_filename = '.github/workflows/ci.yml'; status = 'renamed' }
                @{ filename = '.github/agents/ci-runner.agent.md'; patch = '+permissions: x' }
                @{ filename = 'templates/instance/.github/workflows/deploy.yml'; patch = '+permissions: write-all' }
            ) -Target (ConvertTo-MergeGateTarget -Repository 'owner/repo') -BaseSha ('b' * 40) -HeadSha ('a' * 40)
            $change.WorkflowFiles | Should -Be @('docs/ci.yml')
            $change.SensitiveLines[0] | Should -Be 'docs/ci.yml: renamed from .github/workflows/ci.yml'
            $change.OtherGitHubFiles | Should -Be @('.github/agents/ci-runner.agent.md')
            $change.TemplateWorkflowFiles | Should -Be @('templates/instance/.github/workflows/deploy.yml')
        }
    }

    It 'verdict of <Case> -> <Expected>' -ForEach @(
        @{ Case = 'no reasons'; Statuses = @(); Expected = 'pass' }
        @{ Case = 'a pending reason'; Statuses = @('pending'); Expected = 'pending' }
        @{ Case = 'a fail and a pending reason'; Statuses = @('pending', 'fail'); Expected = 'fail' }
        @{ Case = 'an unknown status'; Statuses = @('warn'); Expected = 'fail' }
    ) {
        InModuleScope MergeGate -Parameters $_ {
            Get-MergeGateVerdict -Reasons @($Statuses | ForEach-Object { [pscustomobject]@{ status = $_ } }) | Should -Be $Expected
        }
    }
}

Describe 'Invoke-GatedMerge' {
    BeforeEach {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        Mock -ModuleName MergeGate Invoke-MergeGateGh { Invoke-MergeGateStub -Stub $stub -Arguments $Arguments }
        Mock -ModuleName MergeGate Wait-MergeGateInterval {}
        $head = '5a86d28aa232fff72af137c29c1abd9e75f398a3'
        $merge = @{ Repository = $repository; Pr = 78; ExpectedHeadSha = $head; Reason = 'user: merge #78'; Now = $stub.Now }
    }

    It 'squash-merges #78 pinned to the evaluated head and verifies the rule suite' {
        $result = Invoke-GatedMerge @merge

        $result.action | Should -Be 'merged'
        $result.exitCode | Should -Be 0
        $result.consent | Should -Be 'user: merge #78'
        $result.gate.verdict | Should -Be 'pass'
        $result.postVerify.verified | Should -BeTrue
        $result.postVerify.ruleSuiteResult | Should -Be 'pass'
        $result.mergeCommit | Should -Be $stub.MergeCommit
        $mergeCalls = @($stub.Calls | Where-Object { $_[0] -eq 'pr' })
        $mergeCalls.Count | Should -Be 1
        $mergeCalls[0] | Should -Be @('pr', 'merge', '78', '--repo', "github.com/$repository", '--squash', '--match-head-commit', $head)
    }


    It 'does not merge when the gate fails' {
        $stub = Initialize-MergeGateStub -Scenario pr-70
        $merge.Pr = 70; $merge.ExpectedHeadSha = $stub.PullRequest.headRefOid; $merge.Now = $stub.Now
        $result = Invoke-GatedMerge @merge

        $result.action | Should -Be 'none'
        $result.reason | Should -Be 'gate-fail'
        $result.exitCode | Should -Be 1
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' }).Count | Should -Be 0
    }

    It 'does not merge when the head moved' {
        $merge.ExpectedHeadSha = 'c' * 40
        $result = Invoke-GatedMerge @merge

        $result.exitCode | Should -Be 1
        (Get-ReasonCode $result.gate) | Should -Be @('fail:head-moved')
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' }).Count | Should -Be 0
    }

    It 'returns pending without merging when the gate stays pending' {
        $stub = Initialize-MergeGateStub -Scenario pr-60
        $merge.Pr = 60; $merge.ExpectedHeadSha = $stub.PullRequest.headRefOid; $merge.Now = $stub.Now
        $result = Invoke-GatedMerge @merge

        $result.exitCode | Should -Be 2
        $result.reason | Should -Be 'gate-pending'
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' }).Count | Should -Be 0
    }

    It 'evaluates again while pending and merges after the gate passes' {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $sourceCi = @($stub.WorkflowRuns.workflow_runs | Where-Object { $_.name -eq 'Source CI' -and $_.event -eq 'pull_request' })[0]
        $sourceCi.status = 'in_progress'
        $script:clockCalls = 0
        Mock -ModuleName MergeGate Get-MergeGateClock { $script:clockCalls++; [DateTimeOffset]::Parse('2026-10-22T10:30:00Z').AddMinutes($script:clockCalls) }
        Mock -ModuleName MergeGate Wait-MergeGateInterval { $sourceCi.status = 'completed' }

        $result = Invoke-GatedMerge @merge -WaitPendingMinutes 5

        $result.exitCode | Should -Be 0
        Should -Invoke -ModuleName MergeGate Wait-MergeGateInterval -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
    }

    It 'reports already-merged for #75 without merging again' {
        $stub = Initialize-MergeGateStub -Scenario pr-75
        Add-MergeGateStubRuleSuite -Stub $stub -AfterSha $stub.PullRequest.mergeCommit.oid -Result 'pass'
        $merge.Pr = 75; $merge.ExpectedHeadSha = $stub.PullRequest.headRefOid; $merge.Now = $stub.Now
        $result = Invoke-GatedMerge @merge

        $result.action | Should -Be 'none'
        $result.reason | Should -Be 'already-merged'
        $result.exitCode | Should -Be 3
        $result.mergeCommit | Should -Be $stub.PullRequest.mergeCommit.oid
        $result.postVerify.verified | Should -BeTrue
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' }).Count | Should -Be 0
    }

    It 'verifies the evaluated base after a lost merge response of a retargeted pull request' {
        Mock -ModuleName MergeGate Invoke-MergeGateGh {
            $response = Invoke-MergeGateStub -Stub $stub -Arguments $Arguments
            if ($Arguments[0] -eq 'pr') {
                $stub.PullRequest.baseRefName = 'release'
                throw 'gh pr merge failed with exit code 1: connection reset'
            }
            $response
        }
        $result = Invoke-GatedMerge @merge

        $stub.Merges | Should -Be 1
        $result.reason | Should -Be 'already-merged'
        $result.postVerify.verified | Should -BeFalse
        $result.exitCode | Should -Be 5
    }

    It 'fails the verification of an already merged pull request without a passing rule suite (exit 5)' {
        $stub = Initialize-MergeGateStub -Scenario pr-75
        Add-MergeGateStubRuleSuite -Stub $stub -AfterSha $stub.PullRequest.mergeCommit.oid -Result 'bypass'
        $merge.Pr = 75; $merge.ExpectedHeadSha = $stub.PullRequest.headRefOid; $merge.Now = $stub.Now
        $result = Invoke-GatedMerge @merge

        $result.reason | Should -Be 'already-merged'
        $result.postVerify.ruleSuiteResult | Should -Be 'bypass'
        $result.exitCode | Should -Be 5
    }

    It 'evaluates once more and does not retry when GitHub refuses the merge' {
        $stub.Failures = @{ '^pr merge' = 'Required status check is expected.' }
        $result = Invoke-GatedMerge @merge

        $result.action | Should -Be 'none'
        $result.reason | Should -Match '^merge-refused'
        $result.exitCode | Should -Be 1
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' }).Count | Should -Be 1
        @($stub.Calls | Where-Object { $_[1] -eq 'graphql' }).Count | Should -Be 4
    }

    It 'fails the post-merge verification (exit 5) when the merge bypassed the rules' {
        $stub.SuiteResult = 'bypass'
        $result = Invoke-GatedMerge @merge

        $result.action | Should -Be 'merged'
        $result.postVerify.verified | Should -BeFalse
        $result.postVerify.ruleSuiteResult | Should -Be 'bypass'
        $result.exitCode | Should -Be 5
    }

    It 'fails the post-merge verification when no rule suite appears' {
        $stub.Responses = @{ 'rule-suites' = '[]' }
        $result = Invoke-GatedMerge @merge

        $result.postVerify.ruleSuiteResult | Should -Be 'not-found'
        $result.exitCode | Should -Be 5
        Should -Invoke -ModuleName MergeGate Wait-MergeGateInterval -Times 3 -Exactly
    }

    It 'refuses <Case> with exit code 4' -ForEach @(
        @{ Case = 'an empty reason'; Change = @{ Reason = ' ' } }
        @{ Case = 'an empty expected head'; Change = @{ ExpectedHeadSha = '' } }
        @{ Case = 'an invalid repository'; Change = @{ Repository = 'x' } }
    ) {
        $parameters = $merge.Clone()
        foreach ($key in $Change.Keys) { $parameters[$key] = $Change[$key] }
        $result = Invoke-GatedMerge @parameters

        $result.exitCode | Should -Be 4
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' }).Count | Should -Be 0
    }

    It 'allows a merge only for a pass on the expected head: <Case>' -ForEach @(
        @{ Case = 'pass on the head'; Gate = @{ verdict = 'pass'; exitCode = 0; headSha = 'a' * 40 }; Expected = $true }
        @{ Case = 'pending'; Gate = @{ verdict = 'pending'; exitCode = 2; headSha = 'a' * 40 }; Expected = $false }
        @{ Case = 'pass with an error exit code'; Gate = @{ verdict = 'pass'; exitCode = 5; headSha = 'a' * 40 }; Expected = $false }
        @{ Case = 'pass on another head'; Gate = @{ verdict = 'pass'; exitCode = 0; headSha = 'b' * 40 }; Expected = $false }
        @{ Case = 'pass in another case'; Gate = @{ verdict = 'Pass'; exitCode = 0; headSha = 'a' * 40 }; Expected = $false }
        @{ Case = 'pass on an upper-case head'; Gate = @{ verdict = 'pass'; exitCode = 0; headSha = 'A' * 40 }; Expected = $false }
    ) {
        InModuleScope MergeGate -Parameters $_ { Test-MergeGateMergeAllowed -Gate $Gate -ExpectedHeadSha ('a' * 40) | Should -Be $Expected }
    }

    It 'verifies the merge: <Case>' -ForEach @(
        @{ Case = 'merged with a passing rule suite'; State = @{ state = 'MERGED'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'pass' }; Expected = $true }
        @{ Case = 'a bypassed rule suite'; State = @{ state = 'MERGED'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'bypass' }; Expected = $false }
        @{ Case = 'a failed rule suite'; State = @{ state = 'MERGED'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'fail' }; Expected = $false }
        @{ Case = 'a rule suite in another case'; State = @{ state = 'MERGED'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'Pass' }; Expected = $false }
        @{ Case = 'a rule suite of another commit'; State = @{ state = 'MERGED'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'b' * 40; result = 'pass' }; Expected = $false }
        @{ Case = 'a rule suite of an upper-case commit'; State = @{ state = 'MERGED'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'A' * 40; result = 'pass' }; Expected = $false }
        @{ Case = 'an open pull request'; State = @{ state = 'OPEN'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'pass' }; Expected = $false }
        @{ Case = 'a merged state in another case'; State = @{ state = 'merged'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'pass' }; Expected = $false }
        @{ Case = 'merged=false'; State = @{ state = 'MERGED'; merged = $false; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'pass' }; Expected = $false }
        @{ Case = 'no rule suite'; State = @{ state = 'MERGED'; merged = $true; mergeCommit = @{ oid = 'a' * 40 } }; Suite = $null; Expected = $false }
        @{ Case = 'a retargeted pull request'; State = @{ state = 'MERGED'; merged = $true; baseRefName = 'release'; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'pass' }; Expected = $false }
        @{ Case = 'a base in another case'; State = @{ state = 'MERGED'; merged = $true; baseRefName = 'Main'; mergeCommit = @{ oid = 'a' * 40 } }; Suite = @{ after_sha = 'a' * 40; result = 'pass' }; Expected = $false }
        @{ Case = 'no state'; State = $null; Suite = @{ after_sha = 'a' * 40; result = 'pass' }; Expected = $false }
    ) {
        InModuleScope MergeGate -Parameters $_ {
            if ($State -and -not $State.Contains('baseRefName')) { $State['baseRefName'] = 'main' }
            Test-MergeGatePostMerge -State $State -Suite $Suite -BaseRef 'main' | Should -Be $Expected
        }
    }
}

Describe 'Merge gate scripts' {
    It 'Test-MergeGate.ps1 writes only JSON to the output and exits with the input error code' {
        $script = Join-Path $PSScriptRoot '../agents/Test-MergeGate.ps1'
        $output = & pwsh -NoProfile -File $script -Repository 'not a repository' -Pr 1 -Now '2026-10-22T10:00:00Z' 2>$null
        $LASTEXITCODE | Should -Be 4
        ($output -join "`n" | ConvertFrom-Json).reasons[0].code | Should -Be 'invalid-input'
    }

    It 'Invoke-GatedMerge.ps1 exits with the input error code before any API call' {
        $script = Join-Path $PSScriptRoot '../agents/Invoke-GatedMerge.ps1'
        $output = & pwsh -NoProfile -File $script -Repository 'msucharda/devsecops-platform' -Pr 1 -ExpectedHeadSha 'x' -Reason 'test' 2>$null
        $LASTEXITCODE | Should -Be 4
        ($output -join "`n" | ConvertFrom-Json).gate.reasons[0].code | Should -Be 'invalid-input'
    }
}
