BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiConcurrency.psm1') -Force
    $modulePath = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../LocalCiConcurrency.psm1'))
    function Start-QueueFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Starts an isolated test process whose caller owns cleanup.')]
        [CmdletBinding()]
        param([string] $Script, [string] $Name)
        $path = Join-Path $TestDrive "$Name.ps1"
        Set-Content -LiteralPath $path -Value "`$ErrorActionPreference = 'Stop'`n$Script"
        $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $start.UseShellExecute = $false
        foreach ($argument in '-NoProfile', '-File', $path) { $start.ArgumentList.Add($argument) }
        return [Diagnostics.Process]::Start($start)
    }

    function Wait-QueueFixture {
        param([scriptblock] $Condition)
        $watch = [Diagnostics.Stopwatch]::StartNew()
        while (-not (& $Condition)) {
            if ($watch.Elapsed.TotalSeconds -gt 15) { throw 'Queue fixture did not reach its synchronization point.' }
            Start-Sleep -Milliseconds 50
        }
    }
}

Describe 'Local CI default worker budget' {
    It 'reserves half the logical processors, capped at four and rounded down: <Processors>' -ForEach @(
        @{ Processors = 1; Expected = 1 }
        @{ Processors = 2; Expected = 1 }
        @{ Processors = 3; Expected = 1 }
        @{ Processors = 4; Expected = 2 }
        @{ Processors = 6; Expected = 3 }
        @{ Processors = 8; Expected = 4 }
        @{ Processors = 32; Expected = 4 }
    ) {
        Get-LocalCiDefaultWorkerBudget -LogicalProcessorCount $Processors | Should -Be $Expected
    }
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
        try { $lease.WorkerBudget | Should -Be (Get-LocalCiDefaultWorkerBudget) }
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
            $lease.WorkerBudget | Should -Be (Get-LocalCiDefaultWorkerBudget)
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

    It 'allocates N slots atomically and never admits more than the shared budget' {
        $state = Join-Path $TestDrive 'slots'
        $first = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 3 -Slots 2 -WaitSeconds 2
        $second = $null
        try {
            $first.Slots | Should -Be 2
            $first.SlotHandles.Count | Should -Be 2
            $second = Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 2
            $second.Slots | Should -Be 1
            { Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 1 } | Should -Throw '*Timed out*'
            Exit-LocalCiMachineQueue -Lease $first
            $first = $null
            $replacement = Enter-LocalCiMachineQueue -StateRoot $state -Slots 2 -WaitSeconds 2
            try { $replacement.Slots | Should -Be 2 }
            finally { Exit-LocalCiMachineQueue -Lease $replacement }
        }
        finally {
            if ($first) { Exit-LocalCiMachineQueue -Lease $first }
            if ($second) { Exit-LocalCiMachineQueue -Lease $second }
        }
    }

    It 'rejects a request exceeding the budget without leaking its ticket or any slots' {
        $state = Join-Path $TestDrive 'oversized'
        { Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 2 -Slots 3 -WaitSeconds 2 } |
            Should -Throw '*Requested 3 CI slots*budget 2*'
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 2 -Slots 2 -WaitSeconds 2
        try { $lease.Slots | Should -Be 2 }
        finally { Exit-LocalCiMachineQueue -Lease $lease }
        @(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count | Should -Be 0
    }

    It 'caps a planned fan-out against the persisted budget only when requested' {
        $state = Join-Path $TestDrive 'capped'
        $initial = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 2 -WaitSeconds 2
        Exit-LocalCiMachineQueue -Lease $initial
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -Slots 5 -CapToBudget -WaitSeconds 2
        try {
            $lease.Slots | Should -Be 2
            $lease.SlotHandles.Count | Should -Be 2
            $lease.WorkerBudget | Should -Be 2
        }
        finally { Exit-LocalCiMachineQueue -Lease $lease }
        $smaller = Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -CapToBudget -WaitSeconds 2
        try { $smaller.Slots | Should -Be 1 }
        finally { Exit-LocalCiMachineQueue -Lease $smaller }
    }

    It 'does not lower a live machine budget or release partially reserved slots to a caller' {
        $state = Join-Path $TestDrive 'resize'
        $first = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 3 -Slots 1 -WaitSeconds 2
        $second = Enter-LocalCiMachineQueue -StateRoot $state -Slots 2 -WaitSeconds 2
        try {
            Exit-LocalCiMachineQueue -Lease $first
            $first = $null
            { Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 1 -Slots 1 -WaitSeconds 1 } |
                Should -Throw '*Timed out*'
            # The live allocation includes slot indices above the requested smaller budget.
            $spare = Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 2
            try { $spare.WorkerBudget | Should -Be 3 }
            finally { Exit-LocalCiMachineQueue -Lease $spare }
            Exit-LocalCiMachineQueue -Lease $second
            $second = $null
            $resized = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 1 -WaitSeconds 2
            try { $resized.WorkerBudget | Should -Be 1; $resized.Slots | Should -Be 1 }
            finally { Exit-LocalCiMachineQueue -Lease $resized }
        }
        finally {
            if ($first) { Exit-LocalCiMachineQueue -Lease $first }
            if ($second) { Exit-LocalCiMachineQueue -Lease $second }
        }
    }

    It 'admits another process into spare capacity but never lets a smaller request overtake the FIFO head' {
        $state = Join-Path $TestDrive 'weighted-fifo'
        $holder = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 3 -Slots 1 -WaitSeconds 2
        $children = [Collections.Generic.List[Diagnostics.Process]]::new()
        try {
            $overlap = Join-Path $TestDrive 'overlap'
            $release = Join-Path $TestDrive 'release-overlap'
            $children.Add((Start-QueueFixture -Name 'overlap' -Script @"
Import-Module '$($modulePath.Replace("'", "''"))'
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -Slots 2 -WaitSeconds 15
try {
    'ready' | Set-Content '$overlap'
    while (-not (Test-Path '$release')) { Start-Sleep -Milliseconds 50 }
} finally { Exit-LocalCiMachineQueue -Lease `$lease }
"@))
            Wait-QueueFixture { Test-Path $overlap }
            { Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 1 } | Should -Throw '*Timed out*'
            'release' | Set-Content $release
            $children[0].WaitForExit(15000) | Should -BeTrue
            $children[0].ExitCode | Should -Be 0

            foreach ($request in @(@{ Name = 'large'; Slots = 3 }, @{ Name = 'small'; Slots = 1 })) {
                $name = $request.Name
                $children.Add((Start-QueueFixture -Name $name -Script @"
Import-Module '$($modulePath.Replace("'", "''"))'
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -Slots $($request.Slots) -WaitSeconds 15
try {
    'ready' | Set-Content '$(Join-Path $TestDrive "$name-ready")'
    while (-not (Test-Path '$(Join-Path $TestDrive "$name-release")')) { Start-Sleep -Milliseconds 50 }
} finally { Exit-LocalCiMachineQueue -Lease `$lease }
"@))
                $count = $children.Count - 1
                Wait-QueueFixture {
                    @(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count -eq $count
                }
            }
            Test-Path (Join-Path $TestDrive 'small-ready') | Should -BeFalse
            Exit-LocalCiMachineQueue -Lease $holder
            $holder = $null
            Wait-QueueFixture { Test-Path (Join-Path $TestDrive 'large-ready') }
            Test-Path (Join-Path $TestDrive 'small-ready') | Should -BeFalse
            'release' | Set-Content (Join-Path $TestDrive 'large-release')
            Wait-QueueFixture { Test-Path (Join-Path $TestDrive 'small-ready') }
            'release' | Set-Content (Join-Path $TestDrive 'small-release')
            foreach ($child in $children) {
                $child.WaitForExit(15000) | Should -BeTrue
                $child.ExitCode | Should -Be 0
            }
        }
        finally {
            if ($holder) { Exit-LocalCiMachineQueue -Lease $holder }
            foreach ($child in $children) {
                if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
                $child.Dispose()
            }
        }
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

    It 'keeps the pre-slot queue reader compatible and excludes its whole-machine lease' {
        $state = Join-Path $TestDrive 'serial-compatibility'
        $lease = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 2 -Slots 1 -WaitSeconds 2
        $waiting = Join-Path $TestDrive 'serial-waiting'
        $ready = Join-Path $TestDrive 'serial-ready'
        $release = Join-Path $TestDrive 'serial-release'
        $child = Start-QueueFixture -Name 'serial-compatibility' -Script @"
Import-Module '$($modulePath.Replace("'", "''"))'
& (Get-Module LocalCiConcurrency) {
    # Serial queue contract from 30851a79e011a7910a0bb0442a4dc9b1d5142990:
    # validate every pending filename before trying the exclusive whole-machine lock.
    `$watch = [Diagnostics.Stopwatch]::StartNew()
    `$handle = `$null
    do {
        `$guard = Open-LocalCiExclusiveFile (Join-Path '$state' 'admission.lock')
        if (`$guard) {
            try {
                `$pending = @(Get-ChildItem -LiteralPath (Join-Path '$state' 'queue') -Filter '*.json' -File)
                `$unexpected = @(`$pending | Where-Object Name -CNotMatch '^\d{20}-[0-9a-f]{32}\.json$')
                if (`$unexpected.Count -gt 0) { throw 'Unexpected file in the CI queue.' }
                'waiting' | Set-Content '$waiting'
                `$handle = Open-LocalCiExclusiveFile (Join-Path '$state' 'running.lock')
            } finally { `$guard.Dispose() }
        }
        if (`$handle) {
            try {
                'ready' | Set-Content '$ready'
                while (-not (Test-Path '$release')) { Start-Sleep -Milliseconds 50 }
            } finally { `$handle.Dispose() }
            return
        }
        Start-Sleep -Milliseconds 50
    } while (`$watch.Elapsed.TotalSeconds -lt 15)
    throw 'Serial queue timed out.'
}
"@
        try {
            Wait-QueueFixture { (Test-Path $waiting) -or $child.HasExited }
            $child.HasExited | Should -BeFalse
            Test-Path $ready | Should -BeFalse
            Exit-LocalCiMachineQueue -Lease $lease
            $lease = $null
            Wait-QueueFixture { Test-Path $ready }
            { Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 1 } | Should -Throw '*Timed out*'
            'release' | Set-Content $release
            $child.WaitForExit(15000) | Should -BeTrue
            $child.ExitCode | Should -Be 0
        }
        finally {
            if ($lease) { Exit-LocalCiMachineQueue -Lease $lease }
            if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
            $child.Dispose()
        }
    }

    It 'recovers all slots after abrupt termination between <Stage>' -ForEach @(
        @{ Stage = 'counter persistence and ticket creation'; Cut = 'counter' }
        @{ Stage = 'first and last slot acquisition'; Cut = 'slot-01.lock' }
        @{ Stage = 'last slot acquisition and admission publication'; Cut = 'slot-03.lock' }
        @{ Stage = 'admission publication and caller cleanup'; Cut = 'admitted' }
    ) {
        $state = Join-Path $TestDrive "cut-$Cut"
        $initial = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 3 -WaitSeconds 2
        Exit-LocalCiMachineQueue -Lease $initial
        $child = Start-QueueFixture -Name "cut-$Cut" -Script @"
Import-Module '$($modulePath.Replace("'", "''"))'
& (Get-Module LocalCiConcurrency) {
    # Inject process death at filesystem boundaries; do not run catch/finally cleanup.
    `$script:originalOpen = (Get-Command Open-LocalCiExclusiveFile).ScriptBlock
    `$script:originalWrite = (Get-Command Write-LocalCiQueueState).ScriptBlock
    function script:Open-LocalCiExclusiveFile {
        param([string] `$Path, [switch] `$Shared)
        `$result = & `$script:originalOpen @PSBoundParameters
        if (`$result -and [IO.Path]::GetFileName(`$Path) -ceq '$Cut') { [Environment]::Exit(99) }
        return `$result
    }
    function script:Write-LocalCiQueueState {
        param([string] `$Path, [hashtable] `$State)
        & `$script:originalWrite @PSBoundParameters
        if ('$Cut' -ceq 'counter') { [Environment]::Exit(99) }
    }
}
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -Slots 3 -WaitSeconds 3
if ('$Cut' -ceq 'admitted') { [Environment]::Exit(99) }
throw 'The interruption point was not reached.'
"@
        try {
            $child.WaitForExit(15000) | Should -BeTrue
            $child.ExitCode | Should -Be 99
            $recovered = Enter-LocalCiMachineQueue -StateRoot $state -Slots 3 -WaitSeconds 3
            try { $recovered.Slots | Should -Be 3 }
            finally { Exit-LocalCiMachineQueue -Lease $recovered }
            @(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count | Should -Be 0
            @(Get-ChildItem (Join-Path $state 'active') -Filter '*.json').Count | Should -Be 0
        }
        finally {
            if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
            $child.Dispose()
        }
    }

    It 'removes an abruptly abandoned FIFO head without letting the following request bypass it while alive' {
        $state = Join-Path $TestDrive 'dead-head'
        $holder = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 2 -Slots 1 -WaitSeconds 2
        $child = Start-QueueFixture -Name 'dead-head' -Script @"
Import-Module '$($modulePath.Replace("'", "''"))'
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -Slots 2 -WaitSeconds 30
try { throw 'A blocked head must not be admitted.' }
finally { Exit-LocalCiMachineQueue -Lease `$lease }
"@
        try {
            Wait-QueueFixture {
                @(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count -eq 1
            }
            { Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 1 } | Should -Throw '*Timed out*'
            $child.Kill()
            $child.WaitForExit(5000) | Should -BeTrue
            $next = Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 3
            try { $next.Slots | Should -Be 1 }
            finally { Exit-LocalCiMachineQueue -Lease $next }
        }
        finally {
            if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
            $child.Dispose()
            Exit-LocalCiMachineQueue -Lease $holder
        }
    }

    It 'recovers a committed budget change when the process dies before publishing admission' {
        $state = Join-Path $TestDrive 'resize-abrupt'
        $initial = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 3 -WaitSeconds 2
        Exit-LocalCiMachineQueue -Lease $initial
        $child = Start-QueueFixture -Name 'resize-abrupt' -Script @"
Import-Module '$($modulePath.Replace("'", "''"))'
& (Get-Module LocalCiConcurrency) {
    `$script:originalWrite = (Get-Command Write-LocalCiQueueState).ScriptBlock
    function script:Write-LocalCiQueueState {
        param([string] `$Path, [hashtable] `$State)
        & `$script:originalWrite @PSBoundParameters
        if (`$State.WorkerBudget -eq 2) { [Environment]::Exit(99) }
    }
}
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -WorkerBudget 2 -Slots 2 -WaitSeconds 3
throw 'The budget persistence interruption point was not reached.'
"@
        try {
            $child.WaitForExit(15000) | Should -BeTrue
            $child.ExitCode | Should -Be 99
            $next = Enter-LocalCiMachineQueue -StateRoot $state -WaitSeconds 3
            try { $next.WorkerBudget | Should -Be 2; $next.Slots | Should -Be 2 }
            finally { Exit-LocalCiMachineQueue -Lease $next }
        }
        finally {
            if (-not $child.HasExited) { $child.Kill($true); $child.WaitForExit() }
            $child.Dispose()
        }
    }

    It 'cleans up a caught I/O failure after acquiring only part of a slot request' {
        $state = Join-Path $TestDrive 'partial-error'
        $initial = Enter-LocalCiMachineQueue -StateRoot $state -WorkerBudget 2 -WaitSeconds 2
        Exit-LocalCiMachineQueue -Lease $initial
        $blocked = Join-Path $state 'slot-02.lock'
        Remove-Item -LiteralPath $blocked
        $null = New-Item -ItemType Directory -Path $blocked
        { Enter-LocalCiMachineQueue -StateRoot $state -Slots 2 -WaitSeconds 2 } | Should -Throw
        Remove-Item -LiteralPath $blocked
        $next = Enter-LocalCiMachineQueue -StateRoot $state -Slots 2 -WaitSeconds 2
        try { $next.Slots | Should -Be 2 }
        finally { Exit-LocalCiMachineQueue -Lease $next }
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

    It 'preserves an unexpected <Directory> file and fails instead of deleting it' -ForEach @(
        @{ Directory = 'queue' }
        @{ Directory = 'active' }
    ) {
        $state = Join-Path $TestDrive "foreign-$Directory"
        $queue = Join-Path $state $Directory
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
            $lease.WorkerBudget | Should -Be (Get-LocalCiDefaultWorkerBudget)
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
                while (@(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count -lt $number) {
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
`$lease = Enter-LocalCiMachineQueue -StateRoot '$($state.Replace("'", "''"))' -WorkerBudget 3 -Slots 2 -WaitSeconds 3
Enable-LocalCiLeaseInheritance -Handle (@(`$worktree, `$lease.Handle, `$lease.TicketHandle) + `$lease.SlotHandles)
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
                $spare = Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 2
                try {
                    { Enter-LocalCiMachineQueue -StateRoot $state -Slots 1 -WaitSeconds 1 } | Should -Throw '*Timed out*'
                }
                finally { Exit-LocalCiMachineQueue -Lease $spare }
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
            while (@(Get-ChildItem (Join-Path $state 'queue') -Filter '*.json').Count -lt 1) {
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
