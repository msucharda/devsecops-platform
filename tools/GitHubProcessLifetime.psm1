Set-StrictMode -Version Latest

function Initialize-GitHubUnixProcessGroupType {
    if ('DevSecOps.GitHub.ProcessGroup' -as [type]) { return }
    Add-Type -TypeDefinition @'
using System;
using System.ComponentModel;
using System.Diagnostics;
using System.Runtime.InteropServices;
using System.Threading;
namespace DevSecOps.GitHub {
    public static class ProcessGroup {
        static Timer watchdog;
        static Process parent;
        static DateTime deadline;
        static int originalGroup;
        [DllImport("libc", SetLastError = true)]
        static extern int setpgid(int process, int group);
        [DllImport("libc")]
        static extern int getpgrp();
        [DllImport("libc")]
        static extern int getpid();
        [DllImport("libc", SetLastError = true)]
        static extern int kill(int process, int signal);
        public static bool Create() {
            int previous = getpgrp();
            if (previous == getpid() || setpgid(0, 0) != 0) return false;
            originalGroup = previous;
            return true;
        }
        public static void Kill(int process) {
            if (kill(-process, 9) == 0) return;
            int error = Marshal.GetLastWin32Error();
            if (error != 3) throw new Win32Exception(error);
        }
        public static void Complete() {
            if (originalGroup <= 0) throw new InvalidOperationException("The worker does not own a process group.");
            int ownedGroup = Environment.ProcessId;
            if (setpgid(0, originalGroup) != 0) {
                int error = Marshal.GetLastWin32Error();
                Kill(ownedGroup);
                throw new Win32Exception(error);
            }
            Kill(ownedGroup);
        }
        public static void Watch(long deadlineUtcTicks, int parentProcessId) {
            deadline = new DateTime(deadlineUtcTicks, DateTimeKind.Utc);
            parent = Process.GetProcessById(parentProcessId);
            watchdog = new Timer(CheckLifetime, null, TimeSpan.Zero, TimeSpan.FromMilliseconds(50));
        }
        static void CheckLifetime(object state) {
            bool stop;
            try { stop = DateTime.UtcNow >= deadline || parent.HasExited; }
            catch (InvalidOperationException) { stop = true; }
            catch (Win32Exception) { stop = true; }
            if (!stop) return;
            if (!OperatingSystem.IsWindows()) Kill(Environment.ProcessId);
            Environment.Exit(124);
        }
    }
}
'@
}

function Invoke-GitHubWindowsWorkerLifetime {
    Import-Module (Join-Path $PSScriptRoot 'LocalCiConcurrency.psm1')
    Initialize-LocalCiWorkerLifetime
}

function Invoke-GitHubUnixProcessGroupCreate {
    Initialize-GitHubUnixProcessGroupType
    return [DevSecOps.GitHub.ProcessGroup]::Create()
}

function Invoke-GitHubUnixProcessGroupKill {
    param([int] $ProcessId)
    Initialize-GitHubUnixProcessGroupType
    [DevSecOps.GitHub.ProcessGroup]::Kill($ProcessId)
}

function Invoke-GitHubWorkerWatchdog {
    param([long] $DeadlineUtcTicks, [int] $ParentProcessId)
    Initialize-GitHubUnixProcessGroupType
    [DevSecOps.GitHub.ProcessGroup]::Watch($DeadlineUtcTicks, $ParentProcessId)
}

function Start-GitHubHostWorkerWatchdog {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Internal lifetime enforcement must not be skipped by WhatIf.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $DeadlineUtcTicks,
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $ParentProcessId
    )
    Invoke-GitHubWorkerWatchdog -DeadlineUtcTicks $DeadlineUtcTicks -ParentProcessId $ParentProcessId
}

# security-check: github-worker-lifetime
function Initialize-GitHubHostWorkerLifetime {
    [CmdletBinding()]
    param([bool] $Windows = $IsWindows)

    if ($Windows) { Invoke-GitHubWindowsWorkerLifetime; return }
    if (-not (Invoke-GitHubUnixProcessGroupCreate)) { throw 'Cannot create the GitHub CLI worker process group.' }
}

function Stop-GitHubHostProcessGroup {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Mandatory owned-process cleanup must not be skipped by WhatIf.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $ProcessId,
        [bool] $Windows = $IsWindows
    )

    if (-not $Windows) { Invoke-GitHubUnixProcessGroupKill -ProcessId $ProcessId }
}

function Complete-GitHubHostWorkerLifetime {
    [CmdletBinding()]
    param()

    if (-not $IsWindows) { [DevSecOps.GitHub.ProcessGroup]::Complete() }
}

Export-ModuleMember -Function Initialize-GitHubHostWorkerLifetime, Stop-GitHubHostProcessGroup, Start-GitHubHostWorkerWatchdog, Complete-GitHubHostWorkerLifetime
