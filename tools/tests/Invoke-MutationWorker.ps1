#Requires -Version 7.4
<#
.SYNOPSIS
Runs mutation jobs in one process: writes each mutant into the repository copy, runs the configured tests and restores the file.

.DESCRIPTION
Each job holds the check, the file, the mutated text (null for a baseline) and the Pester tests. Before every job the worker
removes the modules loaded from the copy so that the tests import the current file. Results are appended as JSON lines,
so a killed worker keeps the results of finished jobs.
Worker dependencies are verified from the runner's tools directory, independently of the repository under test.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RepoPath,
    [Parameter(Mandatory)][string] $JobsPath,
    [Parameter(Mandatory)][string] $ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$toolsPath = Split-Path $PSScriptRoot -Parent
Import-Module (Join-Path $toolsPath 'ToolDependencies.psm1')
Import-Module (Get-ToolDependencyPath -Name Pester -ToolsPath $toolsPath)
$env:PSModulePath = "$(Join-Path $toolsPath 'vendor')$([IO.Path]::PathSeparator)$env:PSModulePath"

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$prefix = $RepoPath.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
$jobs = @(Get-Content -LiteralPath $JobsPath -Raw | ConvertFrom-Json -AsHashtable)
foreach ($job in $jobs) {
    $clock = [Diagnostics.Stopwatch]::StartNew()
    $result = [ordered]@{ Id = $job['Id']; Passed = 0; Failed = 0; Errors = 0; Failures = @(); Seconds = 0 }
    $target = Join-Path $RepoPath $job['File']
    $original = [IO.File]::ReadAllBytes($target)
    try {
        Get-Module | Where-Object {
            $_.Path -and $_.Path.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase) -and
            $_.Path -notlike "$(Join-Path $RepoPath 'tools/.dependencies')$([IO.Path]::DirectorySeparatorChar)*" -and
            $_.Path -notlike "$(Join-Path $RepoPath 'tools/vendor')$([IO.Path]::DirectorySeparatorChar)*"
        } | Remove-Module -Force
        if ($null -ne $job['Text']) { [IO.File]::WriteAllText($target, $job['Text'], [Text.UTF8Encoding]::new($false)) }
        foreach ($test in @($job['Tests'])) {
            if ($null -eq $job['Text']) {
                # Baseline: every pattern must select a test on its own, so an obsolete pattern cannot hide behind another one.
                foreach ($pattern in @($test['FullName'])) {
                    $discovery = New-PesterConfiguration
                    $discovery.Run.Path = Join-Path $RepoPath $test['Path']
                    $discovery.Run.PassThru = $true
                    $discovery.Run.SkipRun = $true
                    $discovery.Filter.FullName = [string[]] @($pattern)
                    $discovery.Output.Verbosity = 'None'
                    $found = Invoke-Pester -Configuration $discovery
                    if (@($found.Tests | Where-Object ShouldRun).Count -eq 0) {
                        $result.Errors += 1
                        $result.Failures += @("No test in $($test['Path']) matched $pattern.")
                    }
                }
            }
            $configuration = New-PesterConfiguration
            $configuration.Run.Path = Join-Path $RepoPath $test['Path']
            $configuration.Run.PassThru = $true
            $configuration.Run.SkipRemainingOnFailure = 'Run'
            $configuration.Filter.FullName = [string[]] @($test['FullName'])
            $configuration.Output.Verbosity = 'None'
            $run = Invoke-Pester -Configuration $configuration
            $result.Passed += $run.PassedCount
            $result.Failed += $run.FailedCount
            $result.Errors += $run.FailedContainersCount + $run.FailedBlocksCount
            $result.Failures += @($run.Failed | Select-Object -First 1 | ForEach-Object { $_.ExpandedPath })
            if ($run.FailedCount -gt 0) { break }
            if ($run.PassedCount -eq 0) {
                $result.Errors += 1
                $result.Failures += @("No test in $($test['Path']) matched $(@($test['FullName']) -join ', ').")
            }
        }
    }
    catch {
        $result.Errors += 1
        $result.Failures += @($_.Exception.Message)
    }
    finally {
        [IO.File]::WriteAllBytes($target, $original)
    }
    $result.Seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 1)
    Add-Content -LiteralPath $ResultPath -Value (ConvertTo-Json -InputObject $result -Depth 5 -Compress)
}
