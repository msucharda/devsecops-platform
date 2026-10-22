BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')
    $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Wait-PullRequestChecks.ps1'
    $sha = '6dcb09b5b57875f334f61aebed695e2e4193db5e'
    $arguments = @{ Pr = 1347; Repository = 'demo-platform/devsecops'; ApiUrl = 'https://api.contoso.ghe.com'; MaxSeconds = 60; IntervalSeconds = 20 }

    function New-CheckRun {
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
        }
        $api.Checks['check_runs'] = @(New-CheckRun -Name 'Platform tools' -Id 10)
        $api.Checks['total_count'] = 1
        $api.Requested['users'] = @()

        Mock Get-Date { $api.Now }
        Mock Start-Sleep { $api.Sleeps.Add($Seconds); $api.Now = $api.Now.AddSeconds($Seconds) }
        Mock Invoke-WebRequest {
            $api.Requests.Add([pscustomobject]@{ Uri = $Uri; Headers = $Headers; TimeoutSec = $ConnectionTimeoutSeconds; At = $api.Now })
            if ($api.Hang) {
                $api.Now = $api.Now.AddSeconds($ConnectionTimeoutSeconds)
                throw 'The request was canceled due to the configured HttpClient.Timeout.'
            }
            $api.Now = $api.Now.AddSeconds(1)
            $path = ([uri] $Uri).AbsolutePath
            $body = switch -Regex ($path) {
                '/pulls/1347$' { $api.Pull }
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
        $api.Checks['check_runs'] = @((New-CheckRun -Name 'Platform tools' -Id 10), (New-CheckRun -Name 'Lint' -Conclusion $Conclusion -Id 11))
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
        @{ Conclusion = 'stale' }
        @{ Conclusion = 'Success' }
        @{ Conclusion = $null }
    ) {
        $api.Checks['check_runs'] = @((New-CheckRun -Name 'Platform tools' -Id 10), (New-CheckRun -Name 'Terraform (modules/a)' -Conclusion $Conclusion -Id 11))
        $api.Checks['total_count'] = 2

        $output = & $script @arguments

        $output | Should -BeExactly 'failed: Terraform (modules/a); copilot: reviewed (rounds 1)'

        $LASTEXITCODE | Should -Be 1
    }

    It 'reports failed early while other jobs still run' {
        $api.Checks['check_runs'] = @((New-CheckRun -Name 'Platform tools' -Conclusion 'failure' -Id 10), (New-CheckRun -Name 'Mutation' -Status 'in_progress' -Conclusion $null -Id 11))
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

    It 'uses the latest check run of a rerun job' {
        $api.Checks['check_runs'] = @((New-CheckRun -Name 'Platform tools' -Conclusion 'failure' -Id 10), (New-CheckRun -Name 'Platform tools' -Id 12))
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
                $api.Checks['check_runs'] = @((New-CheckRun -Name 'Platform tools' -Id 10), (New-CheckRun -Name 'Mutation' -Status 'queued' -Conclusion $null -Id 11))
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
        $api.Checks['check_runs'] = @((New-CheckRun -Name 'Platform tools' -Id 10), (New-CheckRun -Name 'Mutation' -Status 'in_progress' -Conclusion $null -Id 11))
        $api.Checks['total_count'] = 2

        & $script @arguments | Should -BeExactly 'pending 1/2; copilot: reviewed (rounds 1)'
    }

    It 'never sends a request or sleeps past -MaxSeconds' {
        $api.Checks['check_runs'] = @(New-CheckRun -Name 'Mutation' -Status 'in_progress' -Conclusion $null -Id 11)
        $started = $api.Now
        $deadline = $started.AddSeconds(45)

        & $script @arguments -MaxSeconds 45 -IntervalSeconds 7 | Out-Null

        $LASTEXITCODE | Should -Be 2
        foreach ($request in $api.Requests) { $request.At.AddSeconds($request.TimeoutSec) | Should -BeLessOrEqual $deadline }
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

    It 'reads every page of check runs' {
        $api.Checks['check_runs'] = @(1..100 | ForEach-Object { New-CheckRun -Name "job $_" -Id $_ })
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
