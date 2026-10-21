#Requires -Version 7.4
<#
.SYNOPSIS
Weakens every marked security check and verifies that its configured tests fail for each mutant.

.DESCRIPTION
Functions marked with '# security-check: <name>' are configured in tools/tests/security-checks.psd1.
Each mutant changes one guard condition, logical operand, boolean result or case-sensitive comparison so that the
check accepts more input. Worker processes run the configured tests in their own copy of the repository.
A surviving mutant without an exception, an error, a failed baseline, an unfinished job or a stale exception fails the run.
#>
[CmdletBinding()]
param(
    [string] $RepoPath = (Split-Path $PSScriptRoot -Parent),
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot 'tests/security-checks.psd1'),
    [string[]] $Check,
    [ValidateRange(1, 64)][int] $ThrottleLimit = [Math]::Max(1, [Environment]::ProcessorCount),
    [ValidateRange(60, 7200)][int] $TimeoutSeconds = 480,
    [string] $ReportPath = (Join-Path ([IO.Path]::GetTempPath()) 'security-check-mutation.json')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$InformationPreference = 'Continue'
# A failed run must not leave the report of an earlier successful run behind.
$ReportPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($ReportPath)
try { Remove-Item -LiteralPath $ReportPath -Force -ErrorAction Stop }
catch [System.Management.Automation.ItemNotFoundException] { $null = $_ }
catch { throw "The previous mutation report $ReportPath could not be removed: $($_.Exception.Message)" }
if (Test-Path -LiteralPath $ReportPath) { throw "The previous mutation report $ReportPath could not be removed." }
Import-Module (Join-Path $PSScriptRoot 'MutationTesting.psm1') -Force

$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$configuration = Import-PowerShellDataFile -LiteralPath $ConfigurationPath
$markers = @(Get-SecurityCheckMarker -RepoPath $RepoPath)
Assert-SecurityCheckConfiguration -Marker $markers -Configuration $configuration
$inventory = @(Get-SecurityCheckMutant -RepoPath $RepoPath -Marker $markers)
$mutants = $inventory
if ($Check) {
    $unknown = @($Check | Where-Object { $_ -cnotin $markers.Name })
    if ($unknown.Count -gt 0) { throw "Unknown security checks: $($unknown -join ', ')." }
    $markers = @($markers | Where-Object { $_.Name -cin $Check })
    $mutants = @($inventory | Where-Object { $_.Check -cin $Check })
}
$testsByCheck = @{}
foreach ($item in @($configuration['Checks'])) { $testsByCheck[$item['Name']] = @($item['Tests']) }
$workerScript = Join-Path $PSScriptRoot 'tests/Invoke-MutationWorker.ps1'
$work = Join-Path ([IO.Path]::GetTempPath()) "security-check-mutation-$([guid]::NewGuid().ToString('N'))"
$deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
$started = [Diagnostics.Stopwatch]::StartNew()

function Invoke-WorkerBatch {
    <#
    .SYNOPSIS
    Runs one job list per worker copy in parallel processes and returns one result per job; unfinished jobs have no counts.
    #>
    param([Parameter(Mandatory)][string] $Phase, [Parameter(Mandatory)][object[]] $Assignment)

    $running = foreach ($slot in $Assignment) {
        if (@($slot.Jobs).Count -eq 0) { continue }
        $jobsPath = Join-Path $work "$Phase-$($slot.Index)-jobs.json"
        $resultPath = Join-Path $work "$Phase-$($slot.Index)-results.jsonl"
        ConvertTo-Json -InputObject @($slot.Jobs) -Depth 6 | Set-Content -LiteralPath $jobsPath
        # Start-Process joins the arguments with spaces, so paths are quoted to keep their boundaries.
        $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', "`"$workerScript`"", '-RepoPath', "`"$($slot.Copy)`"", '-JobsPath', "`"$jobsPath`"", '-ResultPath', "`"$resultPath`"")
        $process = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -NoNewWindow `
            -RedirectStandardOutput (Join-Path $work "$Phase-$($slot.Index)-out.txt") -RedirectStandardError (Join-Path $work "$Phase-$($slot.Index)-err.txt") `
            -ArgumentList $arguments
        [pscustomobject]@{ Slot = $slot; Process = $process; ResultPath = $resultPath }
    }
    foreach ($worker in @($running)) {
        $remaining = [int] [Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
        if (-not $worker.Process.WaitForExit($remaining)) {
            $worker.Process.Kill($true)
            $worker.Process.WaitForExit()
        }
        $finished = @{}
        if (Test-Path -LiteralPath $worker.ResultPath) {
            foreach ($line in @(Get-Content -LiteralPath $worker.ResultPath)) {
                $record = $line | ConvertFrom-Json -AsHashtable
                $finished[$record['Id']] = $record
            }
        }
        foreach ($job in @($worker.Slot.Jobs)) {
            [pscustomobject]@{ Job = $job; Result = $finished[$job['Id']] }
        }
    }
}

function Get-JobStatus {
    param($Result)

    Get-MutationJobStatus -Result $Result
}

try {
    $workers = [Math]::Max(1, [Math]::Min($ThrottleLimit, $mutants.Count))
    $sources = @(Get-ChildItem -LiteralPath $RepoPath -Force | Where-Object Name -cne '.git')
    $slots = @(foreach ($index in 1..$workers) {
            $copy = Join-Path $work "worker-$index"
            $null = New-Item -ItemType Directory -Path $copy -Force
            foreach ($item in $sources) { Copy-Item -LiteralPath $item.FullName -Destination $copy -Recurse -Force }
            [pscustomobject]@{ Index = $index; Copy = $copy; Jobs = [Collections.Generic.List[object]]::new(); Load = 0.0 }
        })

    Write-Information "Baseline: $($markers.Count) security checks with $workers workers."
    $position = 0
    foreach ($marker in $markers) {
        $slots[$position % $workers].Jobs.Add(@{ Id = "baseline:$($marker.Name)"; File = $marker.File; Text = $null; Tests = $testsByCheck[$marker.Name] })
        $position++
    }
    $baselineSeconds = @{}
    $baselineProblems = @(foreach ($item in @(Invoke-WorkerBatch -Phase baseline -Assignment $slots)) {
            $name = $item.Job['Id'].Substring('baseline:'.Length)
            $status, $detail = Get-JobStatus -Result $item.Result
            if ($status -ne 'Survived') { "The baseline of $name is not green: $status. $detail" }
            else {
                $baselineSeconds[$name] = [double] $item.Result['Seconds']
                Write-Information ("  {0}: {1} tests passed in {2:N1} s." -f $name, $item.Result['Passed'], $item.Result['Seconds'])
            }
        })
    if ($baselineProblems.Count -gt 0) { throw ($baselineProblems -join [Environment]::NewLine) }

    # Longest processing time first: each mutant goes to the worker with the lowest expected load.
    foreach ($slot in $slots) { $slot.Jobs.Clear(); $slot.Load = 0.0 }
    foreach ($mutant in @($mutants | Sort-Object { $baselineSeconds[$_.Check] } -Descending)) {
        $slot = $slots | Sort-Object Load, Index | Select-Object -First 1
        $slot.Jobs.Add(@{ Id = $mutant.Id; File = $mutant.File; Text = $mutant.Text; Tests = $testsByCheck[$mutant.Check] })
        $slot.Load += $baselineSeconds[$mutant.Check]
    }
    Write-Information "Mutants: $($mutants.Count)."
    $byId = @{}
    foreach ($mutant in $mutants) { $byId[$mutant.Id] = $mutant }
    $results = @(foreach ($item in @(Invoke-WorkerBatch -Phase mutant -Assignment $slots)) {
            $mutant = $byId[$item.Job['Id']]
            $status, $detail = Get-JobStatus -Result $item.Result
            [pscustomobject]@{
                Id = $mutant.Id; Check = $mutant.Check; File = $mutant.File; Line = $mutant.Line; Kind = $mutant.Kind
                Description = $mutant.Description; Status = $status; Detail = $detail
                Seconds = if ($item.Result) { $item.Result['Seconds'] } else { $null }
            }
        })
}
finally {
    # Antivirus scanners can hold files of the finished workers for a moment.
    foreach ($attempt in 1..5) {
        try { Remove-Item -LiteralPath $work -Recurse -Force; break }
        catch {
            if ($attempt -eq 5) { Write-Warning "The mutation work folder $work was not removed: $($_.Exception.Message)" }
            else { Start-Sleep -Seconds 2 }
        }
    }
}

$exceptions = @($configuration['Exceptions'])
# Exceptions of unselected checks are dropped; an exception that matches no generated mutant stays and fails as stale.
if ($Check) { $exceptions = @(Select-MutationException -Exception $exceptions -Inventory $inventory -Check $Check) }
$resolved = Resolve-MutationResult -Result $results -Exception $exceptions
$summary = @($resolved.Results | Group-Object Check | Sort-Object Name | ForEach-Object {
        [pscustomobject]@{
            Check = $_.Name
            Mutants = $_.Count
            Killed = @($_.Group | Where-Object Status -eq 'Killed').Count
            Survived = @($_.Group | Where-Object Status -eq 'Survived').Count
            Excepted = @($_.Group | Where-Object Status -eq 'Excepted').Count
            Errors = @($_.Group | Where-Object Status -eq 'Error').Count
        }
    })
$report = [ordered]@{
    seconds = [Math]::Round($started.Elapsed.TotalSeconds)
    workers = $workers
    summary = $summary
    mutants = $resolved.Results
    problems = $resolved.Problems
}
New-Item -ItemType Directory -Path (Split-Path -Parent $ReportPath) -Force | Out-Null
ConvertTo-Json -InputObject $report -Depth 6 | Set-Content -LiteralPath $ReportPath
$summary | Format-Table -AutoSize | Out-String | Write-Information
Write-Information "Report: $ReportPath ($($report.seconds) s)."
if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @('## Security check mutation testing', '', '| Check | Mutants | Killed | Survived | Excepted | Errors |', '|---|---|---|---|---|---|')
    $lines += @($summary | ForEach-Object { "| $($_.Check) | $($_.Mutants) | $($_.Killed) | $($_.Survived) | $($_.Excepted) | $($_.Errors) |" })
    $lines += @(foreach ($item in @($resolved.Results | Where-Object Status -eq 'Excepted')) { "- Excepted: ``$($item.Id)`` ($($item.Issue))" })
    $lines | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}
if ($resolved.Problems.Count -gt 0) {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        foreach ($item in @($resolved.Results | Where-Object Status -in @('Survived', 'Error'))) {
            Write-Information "::error file=$($item.File),line=$($item.Line)::$($item.Status) mutant $($item.Id)"
        }
    }
    throw ('Mutation testing failed:' + [Environment]::NewLine + ($resolved.Problems -join [Environment]::NewLine))
}
