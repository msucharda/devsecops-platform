BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiTiming.psm1') -Force
}

Describe 'Local CI timing artifact' {
    It 'recovers a partial timing staging write with <Termination>' -ForEach @(
        @{ Termination = 'Error' }, @{ Termination = 'Abrupt' }
    ) {
        $path = Join-Path $TestDrive "partial-$Termination.timings.json"
        $boundaryState = @{ Interrupt = $true; Path = $null; Content = '{"Schema":' }
        Mock Set-Content -ModuleName LocalCiTiming {
            param($LiteralPath, $Value)
            if (-not $boundaryState.Interrupt) { [IO.File]::WriteAllText($LiteralPath, [string] $Value); return }
            [IO.File]::WriteAllText($LiteralPath, $boundaryState.Content)
            $boundaryState.Path = $LiteralPath
            throw 'Interrupted staging write'
        }

        { Save-LocalCiTiming -Timing (New-LocalCiTiming) -Path $path -Mode Changed -ExitCode 0 } |
            Should -Throw '*Interrupted staging write*'

        Test-Path -LiteralPath $path | Should -BeFalse
        Test-Path -LiteralPath "$path.new" | Should -BeFalse
        if ($Termination -eq 'Abrupt') { [IO.File]::WriteAllText($boundaryState.Path, $boundaryState.Content) }
        $boundaryState.Interrupt = $false

        Save-LocalCiTiming -Timing (New-LocalCiTiming) -Path $path -Mode Changed -ExitCode 0

        (Get-Content $path -Raw | ConvertFrom-Json).Status | Should -BeExactly 'passed'
        Test-Path -LiteralPath "$path.new" | Should -BeFalse
    }

    It 'recovers timing publication interrupted <Boundary> with <Termination>' -ForEach @(
        @{ Boundary = 'BeforeApply'; Termination = 'Error' }
        @{ Boundary = 'BeforeApply'; Termination = 'Abrupt' }
        @{ Boundary = 'LoseResponse'; Termination = 'Error' }
        @{ Boundary = 'LoseResponse'; Termination = 'Abrupt' }
    ) {
        $path = Join-Path $TestDrive "$Boundary-$Termination.timings.json"
        Set-Content -LiteralPath $path -Value 'Stale successful timing'
        $boundaryState = @{ Interrupt = $true; Staging = $null; Final = $null; Boundary = $Boundary }
        Mock Move-LocalCiTimingArtifact -ModuleName LocalCiTiming {
            param($Source, $Destination)
            if (-not $boundaryState.Interrupt) { [IO.File]::Move($Source, $Destination, $true); return }
            if ($boundaryState.Boundary -eq 'LoseResponse') { [IO.File]::Move($Source, $Destination, $true) }
            $boundaryState.Staging = if (Test-Path $Source) { [IO.File]::ReadAllText($Source) } else { $null }
            $boundaryState.Final = if (Test-Path $Destination) { [IO.File]::ReadAllText($Destination) } else { $null }
            throw 'Publication interrupted'
        }

        { Save-LocalCiTiming -Timing (New-LocalCiTiming) -Path $path -Mode Changed -ExitCode 1 } |
            Should -Throw '*Publication interrupted*'

        Test-Path -LiteralPath "$path.new" | Should -BeFalse
        if ($Boundary -eq 'BeforeApply') {
            Test-Path -LiteralPath $path | Should -BeFalse
            ($boundaryState.Staging | ConvertFrom-Json).Status | Should -BeExactly 'failed'
        }
        else { (Get-Content $path -Raw | ConvertFrom-Json).Status | Should -BeExactly 'failed' }
        if ($Termination -eq 'Abrupt') {
            # Restore the filesystem snapshot from the boundary, discarding finally's cleanup.
            if ($null -ne $boundaryState.Staging) { [IO.File]::WriteAllText("$path.new", $boundaryState.Staging) }
            if ($null -ne $boundaryState.Final) { [IO.File]::WriteAllText($path, $boundaryState.Final) }
        }
        $boundaryState.Interrupt = $false

        Save-LocalCiTiming -Timing (New-LocalCiTiming) -Path $path -Mode Changed -ExitCode 0

        (Get-Content $path -Raw | ConvertFrom-Json).Status | Should -BeExactly 'passed'
        Test-Path -LiteralPath "$path.new" | Should -BeFalse
    }

    It 'persists shard wall times, counts and per-file durations without truncating nested records' {
        $timing = New-LocalCiTiming
        $timing.PesterShards = @(
            @{ Index = 0; FileCount = 1; Seconds = 2.5; PesterSeconds = 1.25; OverheadSeconds = 1.25
                Files = @(@{ Path = 'tools/tests/A.Tests.ps1'; Seconds = 1.25 }) }
        )
        $timing.Steps = @(@{ Name = 'Run Pester'; StartSeconds = 1; Seconds = 2.5; ExitCode = 0 })
        $path = Join-Path $TestDrive 'shards.timings.json'

        Save-LocalCiTiming -Timing $timing -Path $path -Mode Changed -ExitCode 0

        $summary = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $summary.PesterShards[0].Seconds | Should -Be 2.5
        $summary.PesterShards[0].FileCount | Should -Be 1
        $summary.PesterShards[0].Files[0].Path | Should -BeExactly 'tools/tests/A.Tests.ps1'
        $summary.PesterShards[0].Files[0].Seconds | Should -Be 1.25
        $summary.Steps[0].Name | Should -BeExactly 'Run Pester'
        $summary.Steps[0].Seconds | Should -Be 2.5
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
