#Requires -Version 7.4
<#
.SYNOPSIS
Internal worker that owns a GitHub CLI command's process lifetime before starting it.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $FilePath,
    [Parameter(Mandatory)][string] $ArgumentsJson,
    [Parameter(Mandatory)][long] $DeadlineUtcTicks,
    [Parameter(Mandatory)][int] $ParentProcessId
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'GitHubProcessLifetime.psm1')
Initialize-GitHubHostWorkerLifetime
Start-GitHubHostWorkerWatchdog -DeadlineUtcTicks $DeadlineUtcTicks -ParentProcessId $ParentProcessId
[string[]] $nativeArguments = [System.Text.Json.JsonSerializer]::Deserialize[string[]]($ArgumentsJson)
$start = [Diagnostics.ProcessStartInfo]::new()
$start.FileName = $FilePath
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($argument in $nativeArguments) { $start.ArgumentList.Add($argument) }
$owner = $null
$process = $null
try {
    if ($IsWindows) {
        Import-Module (Join-Path $PSScriptRoot 'GitHubWindowsProcess.psm1')
        $owner = Start-GitHubWindowsJobProcess -FilePath $FilePath -Arguments $nativeArguments
        $process = $owner
        $stdout = $owner.StandardOutput.CopyToAsync([Console]::OpenStandardOutput())
        $stderr = $owner.StandardError.CopyToAsync([Console]::OpenStandardError())
    }
    else {
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        $null = $process.Start()
        $stdout = $process.StandardOutput.BaseStream.CopyToAsync([Console]::OpenStandardOutput())
        $stderr = $process.StandardError.BaseStream.CopyToAsync([Console]::OpenStandardError())
    }
    $process.WaitForExit()
    $null = $stdout.GetAwaiter().GetResult()
    $null = $stderr.GetAwaiter().GetResult()
    $exitCode = $process.ExitCode
}
catch {
    if (-not $IsWindows) { Stop-GitHubHostProcessGroup -ProcessId $PID }
    throw
}
finally {
    try {
        if ($null -ne $owner) { $owner.Dispose() }
        elseif ($null -ne $process) { $process.Dispose() }
    }
    finally { Complete-GitHubHostWorkerLifetime }
}
exit $exitCode
