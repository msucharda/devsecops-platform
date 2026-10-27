#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LocalCiMachineStateRoot {
    [CmdletBinding()]
    param()
    $root = [Environment]::GetFolderPath('LocalApplicationData')
    if (-not $root) { throw 'Local application data is unavailable for the machine CI queue.' }
    return Join-Path $root 'devsecops-local-ci-machine'
}

function Open-LocalCiExclusiveFile {
    param([string] $Path)
    try { return [IO.File]::Open($Path, [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] {
        # Sharing violations are contention; permission, disk, and other I/O failures remain errors.
        if (($_.Exception.HResult -band 0xffff) -in @(11, 32, 33)) { return $null }
        throw
    }
}

function Enter-LocalCiWorktreeLock {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $StateRoot = (Get-LocalCiMachineStateRoot)
    )
    $directory = Join-Path $StateRoot 'worktrees'
    $null = New-Item -ItemType Directory -Force -Path $directory
    $identity = [IO.Path]::GetFullPath($RepositoryRoot).TrimEnd([IO.Path]::DirectorySeparatorChar)
    if ($IsWindows) { $identity = $identity.ToLowerInvariant() }
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity)))
    $lease = Open-LocalCiExclusiveFile (Join-Path $directory "$key.lock")
    if ($null -eq $lease) { throw "Another LocalCi run owns this worktree: $RepositoryRoot. Its TEMP was not touched." }
    try { return $lease }
    finally { if ($PSCmdlet.Stopping) { $lease.Dispose() } }
}

function Write-LocalCiQueueState {
    param([string] $Path, [hashtable] $State)
    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($State | ConvertTo-Json -Compress))
        [IO.File]::Move($temporary, $Path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

function Enter-LocalCiMachineQueue {
    [CmdletBinding()]
    param(
        [string] $StateRoot = (Get-LocalCiMachineStateRoot),
        # Zero uses the persisted machine setting; the first run defaults to four.
        [ValidateRange(0, 64)][int] $WorkerBudget = 0,
        [ValidateRange(1, 86400)][int] $WaitSeconds = 900
    )
    $queue = Join-Path $StateRoot 'queue'
    $null = New-Item -ItemType Directory -Force -Path $queue
    $configuration = Join-Path $StateRoot 'configuration.json'
    $ticket = $null
    $ticketHandle = $null
    $handle = $null
    $admitted = $false
    $watch = [Diagnostics.Stopwatch]::StartNew()
    try {
        while ($watch.Elapsed.TotalSeconds -lt $WaitSeconds) {
            $guard = Open-LocalCiExclusiveFile (Join-Path $StateRoot 'admission.lock')
            if ($null -eq $guard) { Start-Sleep -Milliseconds 100; continue }
            try {
                $state = if (Test-Path -LiteralPath $configuration) {
                    Get-Content -LiteralPath $configuration -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
                }
                else { @{ NextTicket = 0L; WorkerBudget = 4 } }
                if ($state -isnot [hashtable]) { throw 'Invalid CI queue configuration object.' }
                if ($state.NextTicket -isnot [long] -and $state.NextTicket -isnot [int]) { throw 'Invalid CI queue ticket counter.' }
                if ($state.NextTicket -lt 0 -or ($state.WorkerBudget -isnot [int] -and $state.WorkerBudget -isnot [long]) -or
                    $state.WorkerBudget -lt 1 -or $state.WorkerBudget -gt 64) { throw 'Invalid CI queue worker budget or counter.' }
                if ($null -eq $ticket) {
                    $state.NextTicket++
                    Write-LocalCiQueueState -Path $configuration -State $state
                    $ticket = Join-Path $queue ('{0:d20}-{1}.json' -f $state.NextTicket, [guid]::NewGuid().ToString('N'))
                    # The open handle owns the invocation, not the possibly long-lived interactive host PID.
                    $ticketHandle = [IO.File]::Open($ticket, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
                }
                $pending = @(Get-ChildItem -LiteralPath $queue -Filter '*.json' -File | Sort-Object Name)
                $unexpected = @($pending | Where-Object Name -CNotMatch '^\d{20}-[0-9a-f]{32}\.json$')
                if ($unexpected.Count -gt 0) { throw "Unexpected file in the CI queue: $($unexpected[0].Name)" }
                foreach ($entry in $pending) {
                    $orphan = Open-LocalCiExclusiveFile -Path $entry.FullName
                    if ($null -ne $orphan) {
                        $orphan.Dispose()
                        [IO.File]::Delete($entry.FullName)
                        continue
                    }
                    if ($entry.FullName -cne $ticket) { break }
                    $handle = Open-LocalCiExclusiveFile (Join-Path $StateRoot 'running.lock')
                    if ($null -eq $handle) { break }
                    try {
                        if ($WorkerBudget -gt 0) {
                            $state.WorkerBudget = $WorkerBudget
                            Write-LocalCiQueueState -Path $configuration -State $state
                        }
                        $admitted = $true
                        return [pscustomobject]@{ Handle = $handle; TicketHandle = $ticketHandle; Ticket = $ticket; WorkerBudget = [int] $state.WorkerBudget }
                    }
                    catch { $admitted = $false; throw }
                }
            }
            finally { $guard.Dispose() }
            Start-Sleep -Milliseconds 100
        }
        throw "Timed out waiting for the local CI machine queue after $WaitSeconds seconds."
    }
    finally {
        if (-not $admitted -or $PSCmdlet.Stopping) {
            if ($null -ne $handle) { $handle.Dispose() }
            if ($null -ne $ticketHandle) { $ticketHandle.Dispose() }
            if ($ticket) { [IO.File]::Delete($ticket) }
        }
    }
}

function Exit-LocalCiMachineQueue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Lease)
    # Keep the ticket visible until the handle is released; the next live ticket cannot jump the queue.
    $Lease.Handle.Dispose()
    $Lease.TicketHandle.Dispose()
    [IO.File]::Delete($Lease.Ticket)
}

Export-ModuleMember -Function Get-LocalCiMachineStateRoot, Enter-LocalCiWorktreeLock, Enter-LocalCiMachineQueue, Exit-LocalCiMachineQueue
