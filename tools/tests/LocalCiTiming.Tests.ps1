BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiTiming.psm1') -Force
}

Describe 'Local CI timing artifact' {
    It 'persists shard wall times, counts and per-file durations without truncating nested records' {
        $timing = New-LocalCiTiming
        $timing.PesterShards = @(
            @{ Index = 0; FileCount = 1; Seconds = 2.5; PesterSeconds = 1.25; OverheadSeconds = 1.25
                Files = @(@{ Path = 'tools/tests/A.Tests.ps1'; Seconds = 1.25 }) }
        )
        $path = Join-Path $TestDrive 'shards.timings.json'

        Save-LocalCiTiming -Timing $timing -Path $path -Mode Changed -ExitCode 0

        $summary = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $summary.PesterShards[0].Seconds | Should -Be 2.5
        $summary.PesterShards[0].FileCount | Should -Be 1
        $summary.PesterShards[0].Files[0].Path | Should -BeExactly 'tools/tests/A.Tests.ps1'
        $summary.PesterShards[0].Files[0].Seconds | Should -Be 1.25
    }

    It 'persists queue admission details alongside the measured queue phase' {
        $timing = New-LocalCiTiming
        Set-LocalCiTimingPhase -Timing $timing -Name 'Machine queue'
        Set-LocalCiTimingPhase -Timing $timing -Name 'Preflight'
        $timing.MachineQueue = @{ Slots = 2; WorkerBudget = 3; WaitSeconds = 0.125 }
        $path = Join-Path $TestDrive 'queue.timings.json'

        Save-LocalCiTiming -Timing $timing -Path $path -Mode Changed -ExitCode 0

        $summary = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $summary.MachineQueue.Slots | Should -Be 2
        $summary.MachineQueue.WorkerBudget | Should -Be 3
        $summary.MachineQueue.WaitSeconds | Should -Be 0.125
        @($summary.Phases.Name) | Should -Contain 'Machine queue'
    }

    It 'writes versioned non-overlapping phases covering the complete measured run' {
        $timing = New-LocalCiTiming
        Start-Sleep -Milliseconds 30
        Set-LocalCiTimingPhase -Timing $timing -Name 'Worktree lock'
        Start-Sleep -Milliseconds 30
        Set-LocalCiTimingPhase -Timing $timing -Name 'Machine queue'
        Set-LocalCiTimingPhase -Timing $timing -Name 'Result persistence'
        $path = Join-Path $TestDrive 'run.timings.json'

        Save-LocalCiTiming -Timing $timing -Path $path -Mode Changed -ExitCode 0

        $summary = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $summary.Schema | Should -Be 1
        $summary.Mode | Should -BeExactly 'Changed'
        $summary.ExitCode | Should -Be 0
        $summary.Status | Should -BeExactly 'passed'
        Get-Content -LiteralPath $path -Raw | Should -Match '"StartedAt":\s*"[^"]+\+00:00"'
        @($summary.Phases.Name) | Should -BeExactly @('Startup', 'Worktree lock', 'Machine queue', 'Result persistence')
        $summary.TotalSeconds | Should -BeGreaterThan 0.05
        $cursor = 0.0
        foreach ($phase in $summary.Phases) {
            $phase.StartSeconds | Should -Be $cursor
            $phase.Seconds | Should -BeGreaterOrEqual 0
            $cursor += $phase.Seconds
        }

        [Math]::Abs($cursor - $summary.TotalSeconds) | Should -BeLessThan 0.001
    }
}
