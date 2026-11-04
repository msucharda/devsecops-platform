BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $publisher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Publish-DriftIssue.ps1'
    $shard = Get-InterruptionShard
}

Describe 'Clean drift issue interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $reportPath = Join-Path $TestDrive 'clean.md'
        [IO.File]::WriteAllText($reportPath, "<!-- platform-drift-report -->`nNo drift detected. Run: https://github.example.test/runs/7`n")
        $arguments = @{
            ReportPath = $reportPath
            Outcome = 'Clean'
            TokensJson = '{"platform":"issue-token"}'
            AppSlug = 'octoapp'
            Repository = 'platform/instance'
            ApiUrl = 'https://api.example.test'
        }
        $plan = Get-InterruptionPlan
        $cloud = @{ issue = $null; comments = [Collections.Generic.List[object]]::new() }
        $reset = {
            $cloud.issue = (Get-GitHubApiFixture -Name issues/list-for-repo.issue -Set @{
                '0.number' = 9; '0.body' = "<!-- platform-drift-report -->`nprevious"
                '0.user.login' = 'octoapp[bot]'; '0.user.type' = 'Bot'
            })[0]
            $cloud.comments.Clear()
        }
        Mock Invoke-RestMethod {
            param($Uri, $Method, $Body)
            if ($Method -eq 'GET') {
                if ($Uri -like '*/issues?state=open&per_page=100&page=1' -and $cloud.issue.state -ceq 'open') { return , @($cloud.issue) }
                if ($Uri -like '*/issues/9/comments?per_page=100&page=1') { return , @($cloud.comments.ToArray()) }
                return , @()
            }
            $request = $Body | ConvertFrom-Json -AsHashtable
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
}
