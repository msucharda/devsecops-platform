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
    if ($IsLinux) {
        Initialize-LocalCiJobType
        $handle = [DevSecOps.LocalCi.ProcessJob]::OpenUnixLock($Path)
        if ($null -eq $handle) { return $null }
        return [IO.FileStream]::new($handle, [IO.FileAccess]::ReadWrite)
    }
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
        [Parameter(Mandatory)][string] $RepositoryRoot
    )
    $metadata = @(& git -C $RepositoryRoot rev-parse --path-format=absolute --git-path local-ci.lock 2>&1)
    if ($LASTEXITCODE -ne 0 -or $metadata.Count -ne 1) { throw "Cannot locate the worktree lock: $($metadata -join ' ')" }
    $lease = Open-LocalCiExclusiveFile ([IO.Path]::GetFullPath([string] $metadata[0]))
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
    $StateRoot = [IO.Path]::GetFullPath($ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($StateRoot))
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
                    $ticketHandle = if ($IsLinux) { Open-LocalCiExclusiveFile -Path $ticket }
                    else { [IO.FileStream]::new($ticket, [IO.FileMode]::CreateNew, [IO.FileAccess]::ReadWrite,
                        [IO.FileShare]::Delete, 4096, [IO.FileOptions]::DeleteOnClose) }
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
                    if ($entry.Name -cne [IO.Path]::GetFileName($ticket)) { break }
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
            try { if ($null -ne $handle) { $handle.Dispose() } }
            finally {
                if ($null -ne $ticketHandle) { $ticketHandle.Dispose() }
                if ($IsLinux -and $ticket) { [IO.File]::Delete($ticket) }
            }
        }
    }
}

function Exit-LocalCiMachineQueue {
    [CmdletBinding()]
    param([Parameter(Mandatory)][object] $Lease)
    # Keep the ticket visible until the handle is released; the next live ticket cannot jump the queue.
    try { $Lease.Handle.Dispose() }
    finally {
        $Lease.TicketHandle.Dispose()
        if ($IsLinux) { [IO.File]::Delete($Lease.Ticket) }
    }
}

function Initialize-LocalCiJobType {
    if ('DevSecOps.LocalCi.ProcessJob' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Runtime.InteropServices;
using Microsoft.Win32.SafeHandles;
namespace DevSecOps.LocalCi {
    public static class ProcessJob {
        [StructLayout(LayoutKind.Sequential)]
        struct BasicLimits {
            public long ProcessTime, JobTime;
            public uint Flags;
            public UIntPtr MinWorkingSet, MaxWorkingSet;
            public uint ActiveProcesses;
            public UIntPtr Affinity;
            public uint Priority, Scheduling;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct IoCounters {
            public ulong ReadOperations, WriteOperations, OtherOperations, ReadBytes, WriteBytes, OtherBytes;
        }
        [StructLayout(LayoutKind.Sequential)]
        struct ExtendedLimits {
            public BasicLimits Basic;
            public IoCounters Io;
            public UIntPtr ProcessMemory, JobMemory, PeakProcessMemory, PeakJobMemory;
        }
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern IntPtr CreateJobObjectW(IntPtr attributes, IntPtr name);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool SetInformationJobObject(SafeWaitHandle job, int informationClass, ref ExtendedLimits limits, uint length);
        [DllImport("kernel32.dll", SetLastError = true)]
        static extern bool AssignProcessToJobObject(SafeWaitHandle job, IntPtr process);
        [DllImport("kernel32.dll")]
        static extern IntPtr GetCurrentProcess();
        [DllImport("libc", SetLastError = true)]
        static extern int open([MarshalAs(UnmanagedType.LPUTF8Str)] string path, int flags, uint mode);
        [DllImport("libc", SetLastError = true)]
        static extern int flock(int descriptor, int operation);
        [DllImport("libc", SetLastError = true)]
        static extern int fcntl(int descriptor, int command, int argument);
        public static SafeWaitHandle Lifetime;
        public static SafeWaitHandle Create() {
            return new SafeWaitHandle(CreateJobObjectW(IntPtr.Zero, IntPtr.Zero), true);
        }
        public static bool Configure(SafeWaitHandle job) {
            var limits = new ExtendedLimits();
            limits.Basic.Flags = 0x2000; // JOB_OBJECT_LIMIT_KILL_ON_JOB_CLOSE
            return SetInformationJobObject(job, 9, ref limits, (uint)Marshal.SizeOf<ExtendedLimits>());
        }
        public static bool Assign(SafeWaitHandle job) {
            return AssignProcessToJobObject(job, GetCurrentProcess());
        }
        public static SafeFileHandle OpenUnixLock(string path) {
            const int readWrite = 2, create = 64, closeOnExec = 524288, exclusiveNonblocking = 6;
            int descriptor = open(path, readWrite | create | closeOnExec, 384);
            if (descriptor < 0) throw new Win32Exception(Marshal.GetLastWin32Error());
            var handle = new SafeFileHandle((IntPtr)descriptor, true);
            if (flock(descriptor, exclusiveNonblocking) != 0) {
                int error = Marshal.GetLastWin32Error();
                handle.Dispose();
                if (error == 11) return null; // Linux EWOULDBLOCK: another invocation owns the lease.
                throw new Win32Exception(error);
            }
            // Unlike File.Open's Unix sharing shim, closing this handle does not explicitly unlock inherited descriptions.
            return handle;
        }
        public static bool Inherit(SafeFileHandle handle) {
            int descriptor = handle.DangerousGetHandle().ToInt32();
            int flags = fcntl(descriptor, 1, 0); // F_GETFD
            return flags >= 0 && fcntl(descriptor, 2, flags & ~1) == 0; // F_SETFD, clear FD_CLOEXEC
        }
    }
}
'@
}

function Invoke-LocalCiWindowsJobCreate { return [DevSecOps.LocalCi.ProcessJob]::Create() }
function Invoke-LocalCiWindowsJobLimit { param($Job) return [DevSecOps.LocalCi.ProcessJob]::Configure($Job) }
function Invoke-LocalCiWindowsJobAssign { param($Job) return [DevSecOps.LocalCi.ProcessJob]::Assign($Job) }
function Invoke-LocalCiUnixLeaseInheritance { param($Handle) return [DevSecOps.LocalCi.ProcessJob]::Inherit($Handle.SafeFileHandle) }

# security-check: local-ci-lease-inheritance
function Enable-LocalCiLeaseInheritance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][IO.FileStream[]] $Handle, [bool] $Linux = $IsLinux)
    if (-not $Linux) { return }
    Initialize-LocalCiJobType
    foreach ($lease in $Handle) {
        if (-not (Invoke-LocalCiUnixLeaseInheritance -Handle $lease)) { throw 'Cannot preserve the local CI lease in child processes.' }
    }
}

# security-check: local-ci-worker-lifetime
function Initialize-LocalCiWorkerLifetime {
    [CmdletBinding()]
    param([bool] $Windows = $IsWindows)
    if (-not $Windows) { return }
    Initialize-LocalCiJobType
    $job = Invoke-LocalCiWindowsJobCreate
    $attached = $false
    try {
        if ($null -eq $job -or $job.IsInvalid) { throw 'Cannot create the local CI process-lifetime job.' }
        if (-not (Invoke-LocalCiWindowsJobLimit -Job $job)) { throw 'Cannot configure the local CI process-lifetime job.' }
        if (-not (Invoke-LocalCiWindowsJobAssign -Job $job)) { throw 'Cannot attach the local CI worker to its process-lifetime job.' }
        # The dedicated worker owns this handle until process exit; closing it kills all remaining descendants.
        [DevSecOps.LocalCi.ProcessJob]::Lifetime = $job
        $attached = $true
    }
    finally { if (-not $attached -and $null -ne $job) { $job.Dispose() } }
}

Export-ModuleMember -Function Get-LocalCiMachineStateRoot, Enter-LocalCiWorktreeLock, Enter-LocalCiMachineQueue,
    Exit-LocalCiMachineQueue, Initialize-LocalCiWorkerLifetime, Enable-LocalCiLeaseInheritance
