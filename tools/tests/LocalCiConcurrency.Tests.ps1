BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiConcurrency.psm1') -Force
    $modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../LocalCiConcurrency.psm1'))
}

Describe 'Local CI worker lifetime' {
    BeforeEach {
        Mock Invoke-LocalCiWindowsJobCreate -ModuleName LocalCiConcurrency {
            [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new([IntPtr] 1, $false)
        }
        Mock Invoke-LocalCiWindowsJobLimit -ModuleName LocalCiConcurrency { $true }
        Mock Invoke-LocalCiWindowsJobAssign -ModuleName LocalCiConcurrency { $true }
    }

    It 'attaches a dedicated Windows worker after configuring kill-on-close' {
        { Initialize-LocalCiWorkerLifetime -Windows $true } | Should -Not -Throw
        Should -Invoke Invoke-LocalCiWindowsJobLimit -ModuleName LocalCiConcurrency -Times 1 -Exactly
        Should -Invoke Invoke-LocalCiWindowsJobAssign -ModuleName LocalCiConcurrency -Times 1 -Exactly
    }

    It 'does not invoke Windows APIs on another platform' {
        Initialize-LocalCiWorkerLifetime -Windows $false
        Should -Invoke Invoke-LocalCiWindowsJobCreate -ModuleName LocalCiConcurrency -Times 0 -Exactly
    }

    It 'fails closed when job creation returns null' {
        Mock Invoke-LocalCiWindowsJobCreate -ModuleName LocalCiConcurrency { $null }
        { Initialize-LocalCiWorkerLifetime -Windows $true } | Should -Throw '*Cannot create*'
        Should -Invoke Invoke-LocalCiWindowsJobAssign -ModuleName LocalCiConcurrency -Times 0 -Exactly
    }

    It 'fails closed when job creation returns an invalid handle' {
        Mock Invoke-LocalCiWindowsJobCreate -ModuleName LocalCiConcurrency {
            [Microsoft.Win32.SafeHandles.SafeWaitHandle]::new([IntPtr]::Zero, $false)
        }
        { Initialize-LocalCiWorkerLifetime -Windows $true } | Should -Throw '*Cannot create*'
    }

    It 'fails closed when kill-on-close cannot be configured' {
        Mock Invoke-LocalCiWindowsJobLimit -ModuleName LocalCiConcurrency { $false }
        { Initialize-LocalCiWorkerLifetime -Windows $true } | Should -Throw '*Cannot configure*'
        Should -Invoke Invoke-LocalCiWindowsJobAssign -ModuleName LocalCiConcurrency -Times 0 -Exactly
    }

    It 'fails closed when the worker cannot join its lifetime job' {
        Mock Invoke-LocalCiWindowsJobAssign -ModuleName LocalCiConcurrency { $false }
        { Initialize-LocalCiWorkerLifetime -Windows $true } | Should -Throw '*Cannot attach*'
    }
}

Describe 'Local CI lease inheritance' {
    BeforeEach {
        $handles = @(
            [IO.File]::Open((Join-Path $TestDrive 'inherit-one'), [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
            [IO.File]::Open((Join-Path $TestDrive 'inherit-two'), [IO.FileMode]::Create, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        )
        Mock Invoke-LocalCiUnixLeaseInheritance -ModuleName LocalCiConcurrency { $true }
    }

    AfterEach { foreach ($handle in $handles) { $handle.Dispose() } }

    It 'preserves every lease in Linux children' {
        Enable-LocalCiLeaseInheritance -Handle $handles -Linux $true
        Should -Invoke Invoke-LocalCiUnixLeaseInheritance -ModuleName LocalCiConcurrency -Times 2 -Exactly
    }

    It 'fails closed when a lease cannot be inherited' {
        Mock Invoke-LocalCiUnixLeaseInheritance -ModuleName LocalCiConcurrency { $false }
        { Enable-LocalCiLeaseInheritance -Handle $handles -Linux $true } | Should -Throw '*Cannot preserve*lease*'
    }

    It 'does not invoke Linux descriptor APIs on another platform' {
        Enable-LocalCiLeaseInheritance -Handle $handles -Linux $false
        Should -Invoke Invoke-LocalCiUnixLeaseInheritance -ModuleName LocalCiConcurrency -Times 0 -Exactly
    }
}

Describe 'Local CI worktree lock and machine queue' {
    BeforeAll {
        git -C $TestDrive init --quiet
        if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize the isolated worktree-lock fixture.' }
    }

    It 'recognizes its ticket through a differently cased Windows state-root path' -Skip:(-not $IsWindows) {
        $state = Join-Path $TestDrive 'MixedCaseQueue'
        $null = New-Item -ItemType Directory -Path $state
        $lease = Enter-LocalCiMachineQueue -StateRoot $state.ToUpperInvariant() -WaitSeconds 2
        try { $lease.WorkerBudget | Should -Be 4 }
        finally { Exit-LocalCiMachineQueue -Lease $lease }
    }

    It 'keeps the worktree lease independent of a different machine queue root' {
        $lease = Enter-LocalCiWorktreeLock -RepositoryRoot $TestDrive
        $otherQueue = $null
        try {
            Test-Path -LiteralPath (Join-Path $TestDrive '.git/local-ci.lock') | Should -BeTrue
            $otherQueue = Enter-LocalCiMachineQueue -StateRoot (Join-Path $TestDrive 'other-machine') -WaitSeconds 2
            { Enter-LocalCiWorktreeLock -RepositoryRoot $TestDrive } | Should -Throw '*owns this worktree*'
        }
        finally {
            if ($otherQueue) { Exit-LocalCiMachineQueue -Lease $otherQueue }
            $lease.Dispose()
        }
    }

    It 'normalizes state-root aliases before comparing a ticket with its directory entry' {
        $state = Join-Path $TestDrive 'unused/../canonical-queue'
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 2
        try {
            $lease.Ticket | Should -Be ([IO.Path]::GetFullPath($lease.Ticket))
            $lease.WorkerBudget | Should -Be 4
        }
        finally { Exit-LocalCiMachineQueue -Lease $lease }
        @(Get-ChildItem (Join-Path $TestDrive 'canonical-queue/queue') -Filter '*.json').Count | Should -Be 0
    }

    It 'refuses a concurrent worktree run without touching its TEMP' {
        foreach ($name in 'repo', 'other') {
            $null = New-Item -ItemType Directory -Path (Join-Path $TestDrive $name)
            git -C (Join-Path $TestDrive $name) init --quiet
            if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize the isolated worktree-lock fixture.' }
        }
        $lease = Enter-LocalCiWorktreeLock -RepositoryRoot (Join-Path $TestDrive 'repo')
        try {
            { Enter-LocalCiWorktreeLock -RepositoryRoot (Join-Path $TestDrive 'repo') } |
                Should -Throw '*Another*worktree*'
            $other = Enter-LocalCiWorktreeLock -RepositoryRoot (Join-Path $TestDrive 'other')
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
`$lock = Enter-LocalCiWorktreeLock -RepositoryRoot '$($TestDrive.Replace("'", "''"))'
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -WaitSeconds 2
[Environment]::Exit(99)
"@ | Set-Content $script
        & ([Environment]::ProcessPath) -NoProfile -File $script
        $LASTEXITCODE | Should -Be 99
        $lock = Enter-LocalCiWorktreeLock -RepositoryRoot $TestDrive
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

    It 'releases the worktree even when another process reopens the closed ticket' {
        $state = Join-Path $TestDrive 'ticket-release'
        $worktree = Enter-LocalCiWorktreeLock -RepositoryRoot $TestDrive
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 3
        $ready = Join-Path $TestDrive 'ticket-ready'
        $release = Join-Path $TestDrive 'ticket-release-signal'
        $script = Join-Path $TestDrive 'ticket-holder.ps1'
        @"
`$handle = [IO.File]::Open('$($lease.Ticket.Replace("'", "''"))', [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
try {
    'ready' | Set-Content '$($ready.Replace("'", "''"))'
    while (-not (Test-Path '$($release.Replace("'", "''"))')) { Start-Sleep -Milliseconds 50 }
} finally { `$handle.Dispose() }
"@ | Set-Content $script
        $lease.TicketHandle.Dispose()
        $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $start.UseShellExecute = $false
        foreach ($argument in '-NoProfile', '-File', $script) { $start.ArgumentList.Add($argument) }
        $child = [Diagnostics.Process]::Start($start)
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path $ready)) {
                if ($watch.Elapsed.TotalSeconds -gt 10) { throw 'Ticket holder did not start.' }
                Start-Sleep -Milliseconds 50
            }
            try { { Exit-LocalCiMachineQueue -Lease $lease } | Should -Not -Throw }
            finally { $worktree.Dispose() }
            $next = Enter-LocalCiWorktreeLock -RepositoryRoot $TestDrive
            $next.Dispose()
        }
        finally {
            'release' | Set-Content $release
            if (-not $child.WaitForExit(5000)) { $child.Kill($true); $child.WaitForExit() }
            $child.Dispose()
            $worktree.Dispose()
        }
    }

    It 'keeps admission owned until an abruptly ended worker has no executing child' {
        $state = Join-Path $TestDrive 'child-lifetime'
        $ready = Join-Path $TestDrive 'child-lifetime-ready.json'
        $script = Join-Path $TestDrive 'lifetime-worker.ps1'
        @"
Import-Module '$($modulePath.Replace("'", "''"))'
Initialize-LocalCiWorkerLifetime
`$worktree = Enter-LocalCiWorktreeLock -RepositoryRoot '$($TestDrive.Replace("'", "''"))'
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -WaitSeconds 3
Enable-LocalCiLeaseInheritance -Handle @(`$worktree, `$lease.Handle, `$lease.TicketHandle)
`$start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
`$start.UseShellExecute = `$false
foreach (`$argument in '-NoProfile', '-Command', 'Start-Sleep -Seconds 120') { `$start.ArgumentList.Add(`$argument) }
`$child = [Diagnostics.Process]::Start(`$start)
[IO.File]::WriteAllText('$($ready.Replace("'", "''")).tmp', (@{ Child = `$child.Id } | ConvertTo-Json))
[IO.File]::Move('$($ready.Replace("'", "''")).tmp', '$($ready.Replace("'", "''"))')
Start-Sleep -Seconds 120
"@ | Set-Content $script
        $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $start.UseShellExecute = $false
        foreach ($argument in '-NoProfile', '-File', $script) { $start.ArgumentList.Add($argument) }
        $worker = [Diagnostics.Process]::Start($start)
        $child = $null
        try {
            $watch = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path $ready)) {
                if ($worker.HasExited -or $watch.Elapsed.TotalSeconds -gt 15) { throw 'Lifetime worker did not start.' }
                Start-Sleep -Milliseconds 50
            }
            $child = [Diagnostics.Process]::GetProcessById((Get-Content $ready -Raw | ConvertFrom-Json).Child)
            $worker.Kill()
            $worker.WaitForExit(5000) | Should -BeTrue
            if ($IsWindows) { $child.WaitForExit(5000) | Should -BeTrue }
            else {
                { Enter-LocalCiWorktreeLock -RepositoryRoot $TestDrive } | Should -Throw '*owns this worktree*'
                { Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 1 } | Should -Throw '*Timed out*'
                $child.Kill($true)
                $child.WaitForExit(5000) | Should -BeTrue
            }
            $nextWorktree = Enter-LocalCiWorktreeLock -RepositoryRoot $TestDrive
            try {
                $next = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 3
                Exit-LocalCiMachineQueue -Lease $next
            }
            finally { $nextWorktree.Dispose() }
        }
        finally {
            if (-not $worker.HasExited) { $worker.Kill($true); $worker.WaitForExit() }
            if ($child -and -not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
            if ($child) { $child.Dispose() }
            $worker.Dispose()
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
