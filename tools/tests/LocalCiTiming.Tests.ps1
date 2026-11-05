BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiTiming.psm1') -Force
}

Describe 'Local CI timing artifact' {
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
