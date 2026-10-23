BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'DeadlineHttp.psm1')
    $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Wait-PullRequestChecks.ps1'
    $sha = '6dcb09b5b57875f334f61aebed695e2e4193db5e'
    $arguments = @{ Pr = 1347; Repository = 'demo-platform/devsecops'; ApiUrl = 'https://api.contoso.ghe.com'; MaxSeconds = 60; IntervalSeconds = 20 }

    function Get-CheckRunFixture {
        param([string] $Name, [string] $Status = 'completed', [AllowNull()][string] $Conclusion = 'success', [long] $Id = 4)
        $body = Get-GitHubApiFixture -Name checks/list-for-ref -Set @{
            'check_runs.0.name' = $Name; 'check_runs.0.status' = $Status; 'check_runs.0.conclusion' = $Conclusion
            'check_runs.0.id' = $Id; 'check_runs.0.head_sha' = $sha
        }
        return $body['check_runs'][0]
    }
}

Describe 'Wait-PullRequestChecks' {
    BeforeEach {
        $env:GH_TOKEN = 'ghs_pollingtoken'
        $api = @{
            Now = [datetime]::new(2026, 10, 22, 12, 0, 0, [DateTimeKind]::Utc)
            Pull = Get-GitHubApiFixture -Name pulls/get -Set @{ 'head.sha' = $sha; number = 1347 }
            Runs = Get-GitHubApiFixture -Name actions/list-workflow-runs-for-repo -Set @{
                'workflow_runs.0.name' = 'Source CI'; 'workflow_runs.0.status' = 'completed'; 'workflow_runs.0.conclusion' = 'success'
                'workflow_runs.0.head_sha' = $sha
            }
            Checks = Get-GitHubApiFixture -Name checks/list-for-ref
            Reviews = Get-GitHubApiFixture -Name pulls/list-reviews -Set @{
                '0.user.login' = 'copilot-pull-request-reviewer[bot]'; '0.user.type' = 'Bot'; '0.commit_id' = $sha; '0.state' = 'COMMENTED'
            }
            Requested = Get-GitHubApiFixture -Name pulls/list-requested-reviewers
            Requests = [System.Collections.Generic.List[object]]::new()
            Sleeps = [System.Collections.Generic.List[int]]::new()
            Status = 200
            Hang = $false
            PullReads = 0
            HeadSequence = [System.Collections.Generic.Queue[string]]::new()
            HangOnPullRead = $null
        }
        $api.Checks['check_runs'] = @(Get-CheckRunFixture -Name 'Platform tools' -Id 10)
        $api.Checks['total_count'] = 1
        $api.Requested['users'] = @()

        Mock Get-Date { $api.Now }
        Mock Start-Sleep { $api.Sleeps.Add($Seconds); $api.Now = $api.Now.AddSeconds($Seconds) }
        Mock Invoke-DeadlineHttpGet {
            $api.Requests.Add([pscustomobject]@{ Uri = [string] $Uri; Headers = $Headers; Deadline = $Deadline; At = $api.Now })
            if ($api.Hang) {
                # The request streams until the deadline cancels it.
                $api.Now = $Deadline
                return $null
            }
            $api.Now = $api.Now.AddSeconds(1)
            $path = ([uri] $Uri).AbsolutePath
            $body = switch -Regex ($path) {
                '/pulls/1347$' {
                    $api.PullReads++
                    if ($api.HeadSequence.Count -gt 0) { $api.Pull['head']['sha'] = $api.HeadSequence.Dequeue() }
                    if ($null -ne $api.HangOnPullRead -and $api.PullReads -ge $api.HangOnPullRead) { $api.Now = $Deadline; return $null }
                    $api.Pull
                }
                '/actions/runs$' { $api.Runs }
                '/check-runs$' { $api.Checks }
                '/reviews$' { , @($api.Reviews) }
                '/requested_reviewers$' { $api.Requested }
                default { throw "Unexpected request $Uri" }
            }
            [pscustomobject]@{ StatusCode = $api.Status; Content = (ConvertTo-Json -InputObject $body -Depth 100) }
        }
    }

    AfterEach {
        Remove-Item Env:GH_TOKEN -ErrorAction SilentlyContinue
    }

    It 'reports passed and the Copilot review of the head commit' {
        $output = & $script @arguments

        $output | Should -BeExactly 'passed; copilot: reviewed (rounds 1)'

        $LASTEXITCODE | Should -Be 0
        $api.Requests[0].Uri | Should -BeExactly 'https://api.contoso.ghe.com/repos/demo-platform/devsecops/pulls/1347'
        $api.Requests[0].Headers['X-GitHub-Api-Version'] | Should -BeExactly '2026-03-10'
        $api.Requests[0].Headers['Authorization'] | Should -BeExactly ('Bearer ' + 'ghs_pollingtoken')
        @($api.Requests.Uri) | Should -Contain "https://api.contoso.ghe.com/repos/demo-platform/devsecops/actions/runs?head_sha=$sha&per_page=100&page=1"
        @($api.Requests.Uri) | Should -Contain "https://api.contoso.ghe.com/repos/demo-platform/devsecops/commits/$sha/check-runs?per_page=100&page=1"
    }

    It 'treats the <Conclusion> conclusion as passed' -ForEach @(
        @{ Conclusion = 'neutral' }
        @{ Conclusion = 'skipped' }
    ) {
        $api.Checks['check_runs'] = @((Get-CheckRunFixture -Name 'Platform tools' -Id 10), (Get-CheckRunFixture -Name 'Lint' -Conclusion $Conclusion -Id 11))
        $api.Checks['total_count'] = 2

        $output = & $script @arguments

        $output | Should -BeLike 'passed;*'

        $LASTEXITCODE | Should -Be 0
    }

    It 'reports failed for the <Conclusion> conclusion of a job' -ForEach @(
        @{ Conclusion = 'failure' }
        @{ Conclusion = 'cancelled' }
        @{ Conclusion = 'timed_out' }
        @{ Conclusion = 'action_required' }
        # Intentionally invalid: values outside the documented conclusion enum must fail closed.
        @{ Conclusion = 'stale' }
        @{ Conclusion = 'Success' }
        @{ Conclusion = $null }
    ) {
        $api.Checks['check_runs'] = @((Get-CheckRunFixture -Name 'Platform tools' -Id 10), (Get-CheckRunFixture -Name 'Terraform (modules/a)' -Conclusion $Conclusion -Id 11))
        $api.Checks['total_count'] = 2

        $output = & $script @arguments

        $output | Should -BeExactly 'failed: Terraform (modules/a); copilot: reviewed (rounds 1)'

        $LASTEXITCODE | Should -Be 1
    }

    It 'reports failed early while other jobs still run' {
        $api.Checks['check_runs'] = @((Get-CheckRunFixture -Name 'Platform tools' -Conclusion 'failure' -Id 10), (Get-CheckRunFixture -Name 'Mutation' -Status 'in_progress' -Conclusion $null -Id 11))
        $api.Checks['total_count'] = 2
        $api.Runs['workflow_runs'][0]['status'] = 'in_progress'
        $api.Runs['workflow_runs'][0]['conclusion'] = $null

        $output = & $script @arguments

        $output | Should -BeLike 'failed: Platform tools;*'

        $LASTEXITCODE | Should -Be 1
    }

    It 'reports a failed workflow run that has no failed job' {
        $api.Runs['workflow_runs'][0]['conclusion'] = 'startup_failure'

        $output = & $script @arguments

        $output | Should -BeLike 'failed: workflow Source CI;*'

        $LASTEXITCODE | Should -Be 1
    }

    It 'keeps a failed check of another app or name case that a newer success could hide' -ForEach @(
        @{ Case = 'app' }
        @{ Case = 'case' }
    ) {
        $failedCheck = Get-CheckRunFixture -Name 'Lint' -Conclusion 'failure' -Id 10
        $passedCheck = Get-CheckRunFixture -Name 'Lint' -Id 12
        if ($Case -eq 'app') { $passedCheck['app']['id'] = 2 } else { $passedCheck['name'] = 'lint' }
        $api.Checks['check_runs'] = @($failedCheck, $passedCheck)
        $api.Checks['total_count'] = 2

        $output = & $script @arguments

        $output | Should -BeLike 'failed: Lint;*'
        $LASTEXITCODE | Should -Be 1
    }

    It 'ignores a run and its check runs that a newer run of the same workflow replaced' {
        $old = $api.Runs['workflow_runs'][0]
        $old['id'] = 100; $old['conclusion'] = 'cancelled'; $old['check_suite_id'] = 900
        $new = (Get-GitHubApiFixture -Name actions/list-workflow-runs-for-repo -Set @{
            'workflow_runs.0.id' = 101; 'workflow_runs.0.name' = 'Source CI'; 'workflow_runs.0.status' = 'completed'
            'workflow_runs.0.conclusion' = 'success'; 'workflow_runs.0.head_sha' = $sha; 'workflow_runs.0.check_suite_id' = 5
            'workflow_runs.0.workflow_id' = $old['workflow_id']; 'workflow_runs.0.event' = $old['event']
        })['workflow_runs'][0]
        $api.Runs['workflow_runs'] = @($old, $new)
        $api.Runs['total_count'] = 2
        $cancelled = Get-CheckRunFixture -Name 'Platform tools' -Conclusion 'cancelled' -Id 10
        $cancelled['check_suite']['id'] = 900
        $api.Checks['check_runs'] = @($cancelled, (Get-CheckRunFixture -Name 'Platform tools' -Id 11))
        $api.Checks['total_count'] = 2

        $output = & $script @arguments

        $output | Should -BeLike 'passed;*'
        $LASTEXITCODE | Should -Be 0
    }

    It 'still fails when the replacing run failed' {
        $old = $api.Runs['workflow_runs'][0]
        $old['id'] = 100
        $new = (Get-GitHubApiFixture -Name actions/list-workflow-runs-for-repo -Set @{
            'workflow_runs.0.id' = 101; 'workflow_runs.0.name' = 'Source CI'; 'workflow_runs.0.status' = 'completed'
            'workflow_runs.0.conclusion' = 'failure'; 'workflow_runs.0.head_sha' = $sha
            'workflow_runs.0.workflow_id' = $old['workflow_id']; 'workflow_runs.0.event' = $old['event']
        })['workflow_runs'][0]
        $api.Runs['workflow_runs'] = @($old, $new)
        $api.Runs['total_count'] = 2

        & $script @arguments | Should -BeLike 'failed: workflow Source CI;*'
        $LASTEXITCODE | Should -Be 1
    }

    It 'uses the latest check run of a rerun job' {
        $api.Checks['check_runs'] = @((Get-CheckRunFixture -Name 'Platform tools' -Conclusion 'failure' -Id 10), (Get-CheckRunFixture -Name 'Platform tools' -Id 12))
        $api.Checks['total_count'] = 2

        & $script @arguments | Should -BeLike 'passed;*'
        $LASTEXITCODE | Should -Be 0
    }

    It 'stays pending when <Label>' -ForEach @(
        @{ Label = 'a job still runs'; Case = 'job' }
        @{ Label = 'the workflow run is not completed'; Case = 'run' }
        @{ Label = 'no workflow run exists yet'; Case = 'norun' }
        @{ Label = 'no check run exists yet'; Case = 'nocheck' }
    ) {
        switch ($Case) {
            'job' {
                $api.Checks['check_runs'] = @((Get-CheckRunFixture -Name 'Platform tools' -Id 10), (Get-CheckRunFixture -Name 'Mutation' -Status 'queued' -Conclusion $null -Id 11))
                $api.Checks['total_count'] = 2
            }
            'run' { $api.Runs['workflow_runs'][0]['status'] = 'in_progress'; $api.Runs['workflow_runs'][0]['conclusion'] = $null }
            'norun' { $api.Runs['workflow_runs'] = @(); $api.Runs['total_count'] = 0 }
            'nocheck' { $api.Checks['check_runs'] = @(); $api.Checks['total_count'] = 0 }
        }
        $started = $api.Now

        $output = & $script @arguments

        $output | Should -BeLike 'pending *'

        $LASTEXITCODE | Should -Be 2
        ($api.Now - $started).TotalSeconds | Should -BeLessOrEqual 60
        $api.Sleeps.Count | Should -BeGreaterThan 0
    }

    It 'reports the counts of a pending run' {
        $api.Checks['check_runs'] = @((Get-CheckRunFixture -Name 'Platform tools' -Id 10), (Get-CheckRunFixture -Name 'Mutation' -Status 'in_progress' -Conclusion $null -Id 11))
        $api.Checks['total_count'] = 2

        & $script @arguments | Should -BeExactly 'pending 1/2; copilot: reviewed (rounds 1)'
    }

    It 'never sends a request or sleeps past -MaxSeconds' {
        $api.Checks['check_runs'] = @(Get-CheckRunFixture -Name 'Mutation' -Status 'in_progress' -Conclusion $null -Id 11)
        $started = $api.Now
        $deadline = $started.AddSeconds(45)

        & $script @arguments -MaxSeconds 45 -IntervalSeconds 7 | Out-Null

        $LASTEXITCODE | Should -Be 2
        foreach ($request in $api.Requests) { $request.Deadline | Should -BeLessOrEqual $deadline }
        $api.Now | Should -BeLessOrEqual $deadline
    }

    It 'returns pending when a request hangs until the deadline' {
        $api.Hang = $true
        $started = $api.Now

        $output = & $script @arguments -MaxSeconds 30

        $output | Should -BeLike 'pending *'

        $LASTEXITCODE | Should -Be 2
        ($api.Now - $started).TotalSeconds | Should -BeLessOrEqual 30
    }

    It 'polls again when the head changed while the checks were read' {
        $newSha = 'a0dcb09b5b57875f334f61aebed695e2e4193db5'
        $api.HeadSequence.Enqueue($sha)
        $api.HeadSequence.Enqueue($newSha)
        $api.HeadSequence.Enqueue($newSha)
        $api.HeadSequence.Enqueue($newSha)

        $output = & $script @arguments

        $output | Should -BeExactly 'passed; copilot: none for head (rounds 1)'
        $LASTEXITCODE | Should -Be 0
        $api.PullReads | Should -Be 4
        @($api.Requests.Uri | Where-Object { $_ -like "*/commits/$newSha/check-runs*" }).Count | Should -Be 1
    }

    It 'does not report the result of a replaced head when the next poll reaches the deadline' {
        $api.HeadSequence.Enqueue($sha)
        $api.HeadSequence.Enqueue('a0dcb09b5b57875f334f61aebed695e2e4193db5')
        $api.HangOnPullRead = 3

        $output = & $script @arguments

        $output | Should -BeExactly 'pending (head changed); copilot: unknown'
        $LASTEXITCODE | Should -Be 2
    }

    It 'returns pending when the head confirmation reaches the deadline' {
        $api.HangOnPullRead = 2

        $output = & $script @arguments

        $output | Should -BeExactly 'pending (head not confirmed); copilot: reviewed (rounds 1)'
        $LASTEXITCODE | Should -Be 2
    }

    It 'reads every page of check runs' {
        $api.Checks['check_runs'] = @(1..100 | ForEach-Object { Get-CheckRunFixture -Name "job $_" -Id $_ })
        $api.Checks['total_count'] = 101

        & $script @arguments | Out-Null

        @($api.Requests.Uri | Where-Object { $_ -like '*check-runs?per_page=100&page=2' }).Count | Should -Be 1
    }

    It 'reports the Copilot review as <Expected>' -ForEach @(
        @{ Case = 'older commit, requested'; Expected = 'copilot: requested (rounds 1)' }
        @{ Case = 'older commit'; Expected = 'copilot: none for head (rounds 1)' }
        @{ Case = 'other reviewer'; Expected = 'copilot: none for head (rounds 0)' }
        @{ Case = 'login in other case'; Expected = 'copilot: none for head (rounds 0)' }
        @{ Case = 'no review'; Expected = 'copilot: none for head (rounds 0)' }
    ) {
        switch ($Case) {
            'older commit, requested' {
                $api.Reviews[0]['commit_id'] = 'ecdd80bb57125d7ba9641ffaa4d7d2c19d3f3091'
                $api.Requested = Get-GitHubApiFixture -Name pulls/list-requested-reviewers -Set @{ 'users.0.login' = 'Copilot'; 'users.0.type' = 'Bot' }
            }
            'older commit' { $api.Reviews[0]['commit_id'] = 'ecdd80bb57125d7ba9641ffaa4d7d2c19d3f3091' }
            'other reviewer' { $api.Reviews[0]['user']['login'] = 'octocat' }
            'login in other case' { $api.Reviews[0]['user']['login'] = 'Copilot-Pull-Request-Reviewer[bot]' }
            'no review' { $api.Reviews = @() }
        }

        & $script @arguments | Should -BeExactly "passed; $Expected"
    }

    # Intentionally invalid responses: an HTTP error, a missing head SHA and a missing check_runs list.
    It 'exits with 3 on <Label>' -ForEach @(
        @{ Label = 'an HTTP error'; Case = 'http' }
        @{ Label = 'a pull request without head SHA'; Case = 'sha' }
        @{ Label = 'a check run list without check_runs'; Case = 'shape' }
    ) {
        switch ($Case) {
            'http' { $api.Status = 404 }
            'sha' { $api.Pull['head']['sha'] = '' }
            'shape' { $api.Checks.Remove('check_runs') }
        }

        $output = & $script @arguments

        $output | Should -BeLike 'error: *'

        $LASTEXITCODE | Should -Be 3
    }
}
