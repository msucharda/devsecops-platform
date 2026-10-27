BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiConcurrency.psm1') -Force
    $modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../LocalCiConcurrency.psm1'))
}

Describe 'Local CI worktree lock and machine queue' {
    It 'refuses a concurrent worktree run without touching its TEMP' {
        $state = Join-Path $TestDrive 'worktree-lock'
        $lease = Enter-LocalCiWorktreeLock -RepositoryRoot (Join-Path $TestDrive 'repo') -StateRoot $state
        try {
            { Enter-LocalCiWorktreeLock -RepositoryRoot (Join-Path $TestDrive 'repo') -StateRoot $state } |
                Should -Throw '*Another*worktree*'
            $other = Enter-LocalCiWorktreeLock -RepositoryRoot (Join-Path $TestDrive 'other') -StateRoot $state
            $other.Dispose()
        }
        finally { $lease.Dispose() }
    }

    It 'persists an explicit machine budget and releases the machine lease' {
        $state = Join-Path $TestDrive 'budget'
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 2 -WaitSeconds 2
        $lease.WorkerBudget | Should -Be 2
        Exit-LocalCiMachineQueue -Lease $lease
        $next = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 2
        try { $next.WorkerBudget | Should -Be 2 }
        finally { Exit-LocalCiMachineQueue -Lease $next }
    }

    It 'times out without claiming success when another run owns the machine budget' {
        $state = Join-Path $TestDrive 'timeout'
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 2
        try {
            { Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 1 } |
                Should -Throw '*Timed out*queue*'
        }
        finally { Exit-LocalCiMachineQueue -Lease $lease }
        @(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count | Should -Be 0
    }

    It 'rejects invalid persisted queue state: <Case>' -ForEach @(
        @{ Case = 'negative counter'; Configuration = '{"NextTicket":-1,"WorkerBudget":4}' }
        @{ Case = 'string counter'; Configuration = '{"NextTicket":"1","WorkerBudget":4}' }
        @{ Case = 'zero budget'; Configuration = '{"NextTicket":0,"WorkerBudget":0}' }
        @{ Case = 'excessive budget'; Configuration = '{"NextTicket":0,"WorkerBudget":65}' }
        @{ Case = 'string budget'; Configuration = '{"NextTicket":0,"WorkerBudget":"4"}' }
        @{ Case = 'array root'; Configuration = '[{"NextTicket":0,"WorkerBudget":4}]' }
    ) {
        $state = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $state
        $Configuration | Set-Content (Join-Path $state 'configuration.json')
        { Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 1 } | Should -Throw '*Invalid CI queue*'
        @(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count | Should -Be 0
    }

    It 'preserves an unexpected queue file and fails instead of deleting it' {
        $state = Join-Path $TestDrive 'foreign-file'
        $queue = Join-Path $state 'queue'
        $null = New-Item -ItemType Directory -Path $queue
        $foreign = Join-Path $queue 'unrelated.json'
        'preserve' | Set-Content $foreign
        { Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 1 } | Should -Throw '*Unexpected file*'
        (Get-Content $foreign -Raw).Trim() | Should -BeExactly 'preserve'
    }

    It 'recovers locks and a queued ticket after abrupt process exit' {
        $state = Join-Path $TestDrive 'abrupt'
        $script = Join-Path $TestDrive 'abrupt.ps1'
        @"
Import-Module '$($modulePath.Replace("'", "''"))'
`$lock = Enter-LocalCiWorktreeLock -RepositoryRoot '$($TestDrive.Replace("'", "''"))' -StateRoot '$($state.Replace("'", "''"))'
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -WaitSeconds 2
[Environment]::Exit(99)
"@ | Set-Content $script
        & ([Environment]::ProcessPath) -NoProfile -File $script
        $LASTEXITCODE | Should -Be 99
        $lock = Enter-LocalCiWorktreeLock -RepositoryRoot $TestDrive -StateRoot $state
        $lease = $null
        try {
            $lease = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 3
            $lease.WorkerBudget | Should -Be 4
        }
        finally {
            if ($lease) { Exit-LocalCiMachineQueue -Lease $lease }
            $lock.Dispose()
        }
    }

    It 'admits independent processes in ticket order without overlapping heavy runs' {
        $state = Join-Path $TestDrive 'fifo'
        $order = Join-Path $TestDrive 'order.txt'
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 3
        $children = [Collections.Generic.List[Diagnostics.Process]]::new()
        try {
            foreach ($number in 1, 2) {
                $script = Join-Path $TestDrive "waiter-$number.ps1"
                @"
Import-Module '$($modulePath.Replace("'", "''"))'
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -WaitSeconds 20
try {
    [IO.File]::AppendAllText('$($order.Replace("'", "''"))', '$number-start' + [Environment]::NewLine)
    Start-Sleep -Milliseconds 200
    [IO.File]::AppendAllText('$($order.Replace("'", "''"))', '$number-end' + [Environment]::NewLine)
} finally { Exit-LocalCiMachineQueue -Lease `$lease }
"@ | Set-Content $script
                $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
                $start.UseShellExecute = $false
                foreach ($argument in '-NoProfile', '-File', $script) { $start.ArgumentList.Add($argument) }
                $children.Add([Diagnostics.Process]::Start($start))
                $watch = [Diagnostics.Stopwatch]::StartNew()
                while (@(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count -lt ($number + 1)) {
                    if ($watch.Elapsed.TotalSeconds -gt 10) { throw 'Child did not enter the fixture queue.' }
                    Start-Sleep -Milliseconds 50
                }
            }
            Exit-LocalCiMachineQueue -Lease $lease
            $lease = $null
            foreach ($child in $children) {
                $child.WaitForExit(20000) | Should -BeTrue
                $child.ExitCode | Should -Be 0
            }
            @(Get-Content $order) | Should -BeExactly @('1-start', '1-end', '2-start', '2-end')
        }
        finally {
            if ($lease) { Exit-LocalCiMachineQueue -Lease $lease }
            foreach ($child in $children) {
                if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
                $child.Dispose()
            }
        }

    }

    It 'removes the pending ticket when a pipeline stops in a still-live host' {
        $state = Join-Path $TestDrive 'pipeline-stop'
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 3
        $engine = [powershell]::Create()
        try {
            $null = $engine.AddScript("Import-Module '$($modulePath.Replace("'", "''"))'; Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -WaitSeconds 20")
            $operation = $engine.BeginInvoke()
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (@(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count -lt 2) {
                if ($watch.Elapsed.TotalSeconds -gt 10) { throw 'Runspace did not enter the fixture queue.' }
                Start-Sleep -Milliseconds 50
            }
            $engine.Stop()
            $stopped = $false
            try { $null = $engine.EndInvoke($operation) }
            catch [System.Management.Automation.PipelineStoppedException] { $stopped = $true }
            $stopped | Should -BeTrue
            Exit-LocalCiMachineQueue -Lease $lease
            $lease = $null
            $next = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 2
            Exit-LocalCiMachineQueue -Lease $next
            @(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count | Should -Be 0
        }
        finally {
            $engine.Dispose()
            if ($lease) { Exit-LocalCiMachineQueue -Lease $lease }
        }
    }
}
