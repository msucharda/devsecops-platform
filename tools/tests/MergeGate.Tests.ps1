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
        ($result.reasons[0].evidence.sensitiveLines -join "`n") | Should -Match 'release\.yml: \+.*id-token: write'
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
        @{ Repository = 'sucharda.ghe.com/slzdso-platform/instance'; HostName = 'sucharda.ghe.com'; Slug = 'slzdso-platform/instance' }
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
                $target = ConvertTo-MergeGateTarget -Repository 'sucharda.ghe.com/slzdso-platform/instance'
                $null = Invoke-MergeGateRest -Target $target -Path 'repos/slzdso-platform/instance/commits/x/check-runs'
                $script:seenToken | Should -BeNullOrEmpty
                $script:seenArguments | Should -Contain 'sucharda.ghe.com'
                $script:seenArguments | Should -Contain 'X-GitHub-Api-Version: 2026-03-10'
                $env:GH_TOKEN | Should -Be 'github-com-token'
            }
            finally { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
        }
    }

    It 'throws when gh exits with an error' {
        InModuleScope MergeGate {
            Mock gh { $global:LASTEXITCODE = 1; Write-Error 'HTTP 404' 2>&1 }
            $target = ConvertTo-MergeGateTarget -Repository 'msucharda/devsecops-platform'
            { Invoke-MergeGateGh -Target $target -Arguments @('api', '--method', 'GET', 'repos/x') } | Should -Throw '*exit code 1*'
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
            $parameters = @{ WorkflowRuns = $Runs; CheckRuns = $Checks; Statuses = $Statuses; RequiredContexts = $Required; PushedAt = $Pushed; Now = $now }
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
        @{ Case = 'with user decisions'; Body = "## Rozhodnut`u{00ED} u`u{017E}ivatele`n- D1"; Expected = @() }
    ) {
        InModuleScope MergeGate -Parameters $_ { @(Get-MergeGateBodyFinding -Body $Body) | Should -Be $Expected }
    }

    It 'G9 warns about decisions in <Case>: <Expected>' -ForEach @(
        @{ Case = 'a body without decisions'; Body = "## Zm`u{011B}ny`n- a"; Expected = $false }
        @{ Case = 'unaccepted user decisions'; Body = "## Rozhodnut`u{00ED} u`u{017E}ivatele`n- D1"; Expected = $true }
        @{ Case = 'unaccepted decisions for the user'; Body = "## Rozhodnut`u{00ED} pro u`u{017E}ivatele`n- D1"; Expected = $true }
        @{ Case = 'accepted user decisions'; Body = "## Rozhodnut`u{00ED} u`u{017E}ivatele`n- D1`n<!-- merge-gate: decisions-accepted msucharda 2026-10-22 -->"; Expected = $false }
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

    It 'G10 sensitive lines of <Case>' -ForEach @(
        @{ Case = 'an added permission'; File = @{ filename = '.github/workflows/release.yml'; patch = "@@ -1,2 +1,3 @@`n on: push`n+permissions:`n+  id-token: write" }; Expected = @('.github/workflows/release.yml: +permissions:', '.github/workflows/release.yml: +  id-token: write') }
        @{ Case = 'a removed trigger'; File = @{ filename = '.github/workflows/ci.yml'; patch = "@@ -1,2 +1,1 @@`n-on: pull_request_target`n jobs:" }; Expected = @('.github/workflows/ci.yml: -on: pull_request_target') }
        @{ Case = 'unchanged context lines'; File = @{ filename = '.github/workflows/ci.yml'; patch = "@@ -1,2 +1,3 @@`n permissions:`n   contents: read`n+      - run: echo" }; Expected = @() }
        @{ Case = 'a missing patch'; File = @{ filename = '.github/workflows/big.yml' }; Expected = @('.github/workflows/big.yml: patch unavailable') }
        @{ Case = 'an empty patch'; File = @{ filename = '.github/workflows/renamed.yml'; patch = '' }; Expected = @('.github/workflows/renamed.yml: patch unavailable') }
    ) {
        InModuleScope MergeGate -Parameters $_ { @(Get-MergeGateSensitiveLine -File $File) | Should -Be $Expected }
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
            $change = Get-MergeGateGitHubChange -Files @(
                @{ filename = 'docs/ci.yml'; previous_filename = '.github/workflows/ci.yml'; status = 'renamed' }
                @{ filename = '.github/agents/ci-runner.agent.md'; patch = '+permissions: x' }
                @{ filename = 'templates/instance/.github/workflows/deploy.yml'; patch = '+permissions: write-all' }
            )
            $change.WorkflowFiles | Should -Be @('docs/ci.yml')
            $change.SensitiveLines | Should -Be @('docs/ci.yml: patch unavailable')
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

    It 'passes --delete-branch on request' {
        $result = Invoke-GatedMerge @merge -DeleteBranch

        $result.exitCode | Should -Be 0
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' })[0][-1] | Should -Be '--delete-branch'
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
        $stub.RuleSuites.Add(@{ id = 1; after_sha = $stub.PullRequest.mergeCommit.oid; ref = 'refs/heads/main'; result = 'pass' })
        $merge.Pr = 75; $merge.ExpectedHeadSha = $stub.PullRequest.headRefOid; $merge.Now = $stub.Now
        $result = Invoke-GatedMerge @merge

        $result.action | Should -Be 'none'
        $result.reason | Should -Be 'already-merged'
        $result.exitCode | Should -Be 3
        $result.mergeCommit | Should -Be $stub.PullRequest.mergeCommit.oid
        $result.postVerify.verified | Should -BeTrue
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' }).Count | Should -Be 0
    }

    It 'evaluates once more and does not retry when GitHub refuses the merge' {
        $stub.Failures = @{ '^pr merge' = 'Required status check is expected.' }
        $result = Invoke-GatedMerge @merge

        $result.action | Should -Be 'none'
        $result.reason | Should -Match '^merge-refused'
        $result.exitCode | Should -Be 1
        @($stub.Calls | Where-Object { $_[0] -eq 'pr' }).Count | Should -Be 1
        @($stub.Calls | Where-Object { $_[1] -eq 'graphql' }).Count | Should -Be 2
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
        @{ Case = 'no state'; State = $null; Suite = @{ after_sha = 'a' * 40; result = 'pass' }; Expected = $false }
    ) {
        InModuleScope MergeGate -Parameters $_ { Test-MergeGatePostMerge -State $State -Suite $Suite | Should -Be $Expected }
    }
}

Describe 'Merge gate scripts' {
    It 'Test-MergeGate.ps1 writes only JSON to the output and exits with the input error code' {
        $script = Join-Path $PSScriptRoot '../agents/Test-MergeGate.ps1'
        $output = & pwsh -NoProfile -File $script -Repository 'not a repository' -Pr 1 2>$null
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
