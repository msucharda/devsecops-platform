BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $publisher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Publish-DriftIssue.ps1'
    $shard = Get-InterruptionShard
}

Describe 'Clean drift issue interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $reportPath = Join-Path $TestDrive 'clean.md'
        $metadata = '<!-- platform-drift-run:platform/instance/.github/workflows/drift.yml@refs/heads/main|'
        [IO.File]::WriteAllText($reportPath, "<!-- platform-drift-report -->`n${metadata}21 -->`nRevision: ``$('a' * 40)```nNo drift detected. Run: https://github.example.test/runs/7`n")
        $arguments = @{
            ReportPath = $reportPath
            Outcome = 'Clean'
            TokensJson = '{"platform":"issue-token"}'
            AppSlug = 'octoapp'
            Repository = 'platform/instance'
            ApiUrl = 'https://api.example.test'
            ContentsToken = 'read-token'
        }
        $plan = Get-InterruptionPlan
        $cloud = @{ issue = $null; comments = [Collections.Generic.List[object]]::new(); legacy = $false }
        $reset = {
            $previous = if ($cloud.legacy) { 'previous' } else { "${metadata}20 -->`nprevious" }
            $cloud.issue = (Get-GitHubApiFixture -Name issues/list-for-repo.issue -Set @{
                '0.number' = 9; '0.body' = "<!-- platform-drift-report -->`n$previous"
                '0.user.login' = 'octoapp[bot]'; '0.user.type' = 'Bot'
            })[0]
            $cloud.comments.Clear()
        }
        Mock Invoke-RestMethod {
            param($Uri, $Method, $Body)
            if ($Method -eq 'GET') {
                if ($Uri -like '*/git/ref/heads/main') {
                    return Get-GitHubApiFixture -Name git/get-ref -Set @{ ref = 'refs/heads/main'; 'object.sha' = ('a' * 40) }
                }
                if ($Uri -like '*/issues?state=open&per_page=100&page=1' -and $null -ne $cloud.issue -and $cloud.issue.state -ceq 'open') { return , @($cloud.issue) }
                if ($Uri -like '*/issues?state=closed&per_page=100&page=1' -and $null -ne $cloud.issue -and $cloud.issue.state -ceq 'closed') { return , @($cloud.issue) }
                if ($Uri -like '*/issues/9/comments?per_page=100&page=1') { return , @($cloud.comments.ToArray()) }
                return , @()
            }
            $request = $Body | ConvertFrom-Json -AsHashtable
            if ($Method -eq 'POST' -and $Uri -like '*/issues') {
                return Invoke-InterruptionStep -Plan $plan -Request 'POST drift issue' -Identity 'drift issue' -Apply {
                    $cloud.issue = Get-GitHubApiFixture -Name issues/create -Set @{
                        number = 9; body = $request.body; 'user.login' = 'octoapp[bot]'; 'user.type' = 'Bot'
                    }
                    return $cloud.issue
                } -Interrupt { throw 'Injected interruption.' }
            }
            if ($Method -eq 'POST' -and $Uri -like '*/issues/9/comments') {
                return Invoke-InterruptionStep -Plan $plan -Request 'POST clean comment' -Identity 'clean comment' -Apply {
                    $comment = Get-GitHubApiFixture -Name issues/create-comment -Set @{
                        body = $request.body; 'user.login' = 'octoapp[bot]'; 'user.type' = 'Bot'
                    }
                    $cloud.comments.Add($comment)
                    return $comment
                } -Interrupt { throw 'Injected interruption.' }
            }
            if ($Method -eq 'PATCH' -and $Uri -like '*/issues/9') {
                return Invoke-InterruptionStep -Plan $plan -Request 'PATCH close issue' -Apply {
                    $cloud.issue.state = $request.state
                    return Get-GitHubApiFixture -Name issues/update -Set @{ number = 9; state = $request.state }
                } -Interrupt { throw 'Injected interruption.' }
            }
            throw "Unexpected GitHub API request: $Method $Uri"
        }
        $run = { $null = & $publisher @arguments 6>$null }
        $snapshot = {
            @{
                state = $cloud.issue.state
                comments = @($cloud.comments | ForEach-Object { $_.body })
            }
        }
        # Recovery uses the repository issue and comment markers; there is no local progress file.
        $captureLocal = { $null }
        $restoreLocal = { param($State) $null = $State }
    }

    It 'recovers without duplicate comments at every write boundary' {
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
                -CaptureLocal $captureLocal -RestoreLocal $restoreLocal -ShardByInterruption @shard)

        $report = Format-InterruptionResult -Name 'Publish-DriftIssue.ps1 (clean)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'recovers the manual-closure comment without closing a legacy issue' {
        $cloud.legacy = $true
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
                -CaptureLocal $captureLocal -RestoreLocal $restoreLocal -ShardByInterruption @shard)

        $report = Format-InterruptionResult -Name 'Publish-DriftIssue.ps1 (legacy)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'fails closed without duplicate comments when a lost POST is listed with a null author' {
        & $reset
        Clear-InterruptionPlan -Plan $plan -Target 1 -Kind LoseResponse
        { & $run } | Should -Throw '*Injected interruption*'
        $cloud.comments.Count | Should -Be 1
        # Documented nullable user variant; the successful POST response was not received.
        $cloud.comments[0].user = $null
        Clear-InterruptionPlan -Plan $plan

        { & $run } | Should -Throw '*Cannot verify the author of an existing clean-result comment*'
        $cloud.comments.Count | Should -Be 1
        $cloud.issue.state | Should -BeExactly 'open'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'does not recreate resolved drift when an interrupted old report resumes after a newer clean run' {
        & $reset
        $cloud.issue = $null
        $oldReport = "<!-- platform-drift-report -->`n${metadata}20 -->`nRevision: ``$('a' * 40)```nDrift detected."
        $cleanReport = [IO.File]::ReadAllText($reportPath)
        $arguments.Outcome = 'Report'
        [IO.File]::WriteAllText($reportPath, $oldReport)
        Clear-InterruptionPlan -Plan $plan -Target 1 -Kind LoseResponse
        { & $run } | Should -Throw '*Injected interruption*'
        $cloud.issue.state | Should -BeExactly 'open'

        Clear-InterruptionPlan -Plan $plan
        $arguments.Outcome = 'Clean'
        [IO.File]::WriteAllText($reportPath, $cleanReport)
        & $run
        $cloud.issue.state | Should -BeExactly 'closed'

        $arguments.Outcome = 'Report'
        [IO.File]::WriteAllText($reportPath, $oldReport)
        { & $run } | Should -Throw '*report was already resolved*'
        $cloud.issue.state | Should -BeExactly 'closed'
        $cloud.comments.Count | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/issues' }
    }
}
