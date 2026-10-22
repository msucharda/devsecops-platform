BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../agents/MergeGate.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'MergeGateStub.psm1') -Force
    $shard = Get-InterruptionShard
}

Describe 'Gated merge interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $plan = Get-InterruptionPlan
        $state = @{ Stub = Initialize-MergeGateStub -Scenario pr-78 }
        # gh pr merge is the only write. GitHub refuses a second merge of a merged pull request, and the gate reports
        # already-merged before any merge call, so a rerun cannot merge twice.
        Mock -ModuleName MergeGate Invoke-MergeGateGh {
            if ($Arguments[0] -ne 'pr') { return Invoke-MergeGateStub -Stub $state.Stub -Arguments $Arguments }
            Invoke-InterruptionStep -Plan $plan -Request "gh $($Arguments[0..1] -join ' ')" -Identity "merge $($Arguments[2])" -Apply {
                Invoke-MergeGateStub -Stub $state.Stub -Arguments $Arguments
            } -Interrupt {
                throw 'gh pr merge failed with exit code 1: Injected interruption.'
            }
        }
        Mock -ModuleName MergeGate Wait-MergeGateInterval {}
        $reset = { $state.Stub = Initialize-MergeGateStub -Scenario pr-78 }
        # The gate keeps no local state.
        $captureLocal = { $null }
        $restoreLocal = { param($Text) $null = $Text }
        $snapshot = {
            $pullRequest = $state.Stub.PullRequest
            @{ state = $pullRequest.state; merged = $pullRequest.merged; mergeCommit = $pullRequest.mergeCommit; merges = $state.Stub.Merges }
        }
        $merge = @{ Repository = 'msucharda/devsecops-platform'; Pr = 78; ExpectedHeadSha = '5a86d28aa232fff72af137c29c1abd9e75f398a3'; Reason = 'harness'; Now = '2026-10-22T10:26:36Z' }
    }

    It 'recovers from an interruption of the merge' {
        $run = {
            $result = Invoke-GatedMerge @merge
            if ($result['exitCode'] -notin @(0, 3)) { throw "Invoke-GatedMerge ended with exit code $($result['exitCode']): $($result['reason'])" }
            if ($result['exitCode'] -eq 3 -and -not $result['postVerify']['verified']) { throw 'The rerun did not verify the merge.' }
        }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Invoke-GatedMerge' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
