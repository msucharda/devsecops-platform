#Requires -Version 7.4
<#
.SYNOPSIS
Weakens every marked security check and verifies that its configured tests fail for each mutant.

.DESCRIPTION
Functions marked with '# security-check: <name>' are configured in tools/tests/security-checks.psd1.
Each mutant changes one guard condition, logical operand, boolean result or case-sensitive comparison so that the
check accepts more input. Worker processes run the configured tests in their own copy of the repository.
A surviving mutant without an exception, an error, a failed baseline, an unfinished job or a stale exception fails the run.
Baseline and mutant execution each receive their own time budget; preparation and cleanup do not consume either budget.
Identical test selections share one baseline. The report records phase wall time, queue size and completed worker time.

.EXAMPLE
./tools/Invoke-MutationTests.ps1 -Shard 0/4 -ThrottleLimit 4 -ReportPath ./artifacts/mutation-report.json
Runs one deterministic shard of whole checks. All shards together cover the same inventory as an unsharded invocation.

.EXAMPLE
./tools/Invoke-MutationTests.ps1 -MergeReport $paths -ShardCount 4 -ReportPath ./artifacts/mutation-report.json
Validates all shard reports against the current inventory, rejects missing or duplicate results and reapplies exceptions.
#>
[CmdletBinding(DefaultParameterSetName = 'Run')]
param(
    [string] $RepoPath = (Split-Path $PSScriptRoot -Parent),
    [string] $ConfigurationPath = (Join-Path $PSScriptRoot 'tests/security-checks.psd1'),
    [Parameter(ParameterSetName = 'Run')][string[]] $Check,
    # Zero-based index/count. Whole checks stay together so their baselines run only in one shard.
    [ValidatePattern('^(0|[1-9][0-9]*)/([1-9][0-9]*)$')]
    [Parameter(ParameterSetName = 'Run')][string] $Shard,
    [Parameter(Mandatory, ParameterSetName = 'Merge')]
    [AllowEmptyCollection()][string[]] $MergeReport,
    [Parameter(ParameterSetName = 'Merge')][ValidateRange(1, 64)][int] $ShardCount = 4,
    [ValidateRange(1, 64)][int] $ThrottleLimit = [Math]::Max(1, [Environment]::ProcessorCount),
    [Parameter(ParameterSetName = 'Run')][ValidateRange(1, 7200)][int] $TimeoutSeconds = 480,
    [Parameter(ParameterSetName = 'Run')][ValidateRange(1, 7200)][int] $BaselineTimeoutSeconds = 480,
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

$started = [Diagnostics.Stopwatch]::StartNew()
$RepoPath = (Resolve-Path -LiteralPath $RepoPath).Path
$configuration = Import-PowerShellDataFile -LiteralPath $ConfigurationPath
$markers = @(Get-SecurityCheckMarker -RepoPath $RepoPath)
Assert-SecurityCheckConfiguration -Marker $markers -Configuration $configuration
$inventory = @(Get-SecurityCheckMutant -RepoPath $RepoPath -Marker $markers)
$inventoryText = ConvertTo-Json -InputObject @($inventory | Sort-Object Id | Select-Object Id, Check, File, Text) -Depth 4 -Compress
$inventoryHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes(
            $inventoryText + (Get-Content -LiteralPath $ConfigurationPath -Raw)
        )))
$merging = $PSCmdlet.ParameterSetName -eq 'Merge'
$workers = 0
$phases = [ordered]@{}
$executionProblem = $null
if ($merging) {
    if ($MergeReport.Count -ne $ShardCount) { throw "Expected $ShardCount mutation shard reports, received $($MergeReport.Count)." }
    $expected = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($mutant in $inventory) { $expected.Add($mutant.Id, $mutant) }
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $seenShards = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $results = @(foreach ($path in $MergeReport) {
            $inputReport = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            if ($inputReport['inventoryHash'] -cne $inventoryHash) { throw "Mutation inventory differs in report '$path'." }
            $validShards = @(0..($ShardCount - 1) | ForEach-Object { "$_/$ShardCount" })
            if ($inputReport['shard'] -cnotin $validShards -or -not $seenShards.Add($inputReport['shard'])) {
                throw "Invalid or duplicate mutation shard in report '$path'."
            }
            if (-not $inputReport.Contains('problems') -or $null -eq $inputReport['problems'] -or @($inputReport['problems']).Count -gt 0) {
                throw "Mutation shard report '$path' contains problems or has no problem list."
            }
            if (-not $inputReport.Contains('mutants') -or @($inputReport['mutants']).Count -eq 0) {
                throw "Mutation shard report '$path' has no mutant results."
            }
            foreach ($record in $inputReport['mutants']) {
                $id = $record['Id']
                if (-not $id -or -not $expected.ContainsKey($id)) { throw "Unexpected mutant '$id' in report '$path'." }
                if (-not $seen.Add($id)) { throw "Duplicate mutant '$id' in shard reports." }
                foreach ($property in 'Check', 'File', 'Line', 'Kind', 'Description') {
                    if ([string] $record[$property] -cne [string] $expected[$id].$property) { throw "Mutant '$id' has invalid $property in report '$path'." }
                }
                if ($record['Status'] -cnotin @('Killed', 'Survived', 'Excepted', 'Error')) {
                    throw "Mutant '$id' has an unknown status in report '$path'."
                }
                # Reapply exceptions from this checkout instead of trusting a shard's exemption.
                if ($record['Status'] -ceq 'Excepted') { $record['Status'] = 'Survived' }
                [pscustomobject] $record
            }
        })
    if ($seen.Count -ne $expected.Count) { throw "Incomplete mutation reports: $($seen.Count) of $($expected.Count) mutants." }
    $phases['aggregation'] = @{ seconds = [Math]::Round($started.Elapsed.TotalSeconds, 2) }
}
else {
    $mutants = $inventory
    if ($Check) {
        $unknown = @($Check | Where-Object { $_ -cnotin $markers.Name })
        if ($unknown.Count -gt 0) { throw "Unknown security checks: $($unknown -join ', ')." }
        $markers = @($markers | Where-Object { $_.Name -cin $Check })
        $mutants = @($inventory | Where-Object { $_.Check -cin $Check })
    }
    if ($Shard) {
        $parts = $Shard.Split('/')
        $shardIndex = [int]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture)
        $shardCount = [int]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
        if ($shardIndex -ge $shardCount) { throw "Shard index must be smaller than count: '$Shard'." }
        if ($markers.Count -lt $shardCount) { throw "Cannot split $($markers.Count) security checks into $shardCount nonempty shards." }
        $loads = [int[]]::new($shardCount)
        $selected = [Collections.Generic.List[string]]::new()
        $weighted = @($markers | ForEach-Object {
                [pscustomobject]@{ Name = $_.Name; Weight = [Math]::Max(1, @($mutants | Where-Object Check -CEQ $_.Name).Count) }
            } | Sort-Object -Property @{ Expression = 'Weight'; Descending = $true }, Name)
        foreach ($item in $weighted) {
            $target = 0
            for ($candidate = 1; $candidate -lt $shardCount; $candidate++) {
                if ($loads[$candidate] -lt $loads[$target]) { $target = $candidate }
            }
            $loads[$target] += $item.Weight
            if ($target -eq $shardIndex) { $selected.Add($item.Name) }
        }
        $markers = @($markers | Where-Object { $_.Name -cin $selected })
        $mutants = @($mutants | Where-Object { $_.Check -cin $selected })
        Write-Information "Mutation shard ${Shard}: $($markers.Count) checks, $($mutants.Count) mutants."
    }
    $testsByCheck = @{}
    foreach ($item in @($configuration['Checks'])) { $testsByCheck[$item['Name']] = @($item['Tests']) }
    $phases['discovery'] = @{ seconds = [Math]::Round($started.Elapsed.TotalSeconds, 2) }
    $workerScript = Join-Path $PSScriptRoot 'tests/Invoke-MutationWorker.ps1'
    $work = Join-Path ([IO.Path]::GetTempPath()) "security-check-mutation-$([guid]::NewGuid().ToString('N'))"

    function Invoke-WorkerBatch {
        <#
    .SYNOPSIS
    Runs one job list per worker copy in parallel processes and returns one result per job; unfinished jobs have no counts.
    #>
        param(
            [Parameter(Mandatory)][string] $Phase,
            [Parameter(Mandatory)][object[]] $Assignment,
            [Parameter(Mandatory)][int] $BudgetSeconds
        )

        $clock = [Diagnostics.Stopwatch]::StartNew()
        $deadline = [DateTime]::UtcNow.AddSeconds($BudgetSeconds)
        $jobCount = @($Assignment.Jobs).Count
        $completed = 0
        $workerSeconds = 0.0
        $longestWorkerSeconds = 0.0
        $running = [Collections.Generic.List[object]]::new()
        try {
            foreach ($slot in $Assignment) {
                if (@($slot.Jobs).Count -eq 0) { continue }
                $jobsPath = Join-Path $work "$Phase-$($slot.Index)-jobs.json"
                $resultPath = Join-Path $work "$Phase-$($slot.Index)-results.jsonl"
                ConvertTo-Json -InputObject @($slot.Jobs) -Depth 6 | Set-Content -LiteralPath $jobsPath
                # Start-Process joins the arguments with spaces, so paths are quoted to keep their boundaries.
                $arguments = @('-NoLogo', '-NoProfile', '-NonInteractive', '-File', "`"$workerScript`"", '-RepoPath', "`"$($slot.Copy)`"", '-JobsPath', "`"$jobsPath`"", '-ResultPath', "`"$resultPath`"")
                $process = Start-Process -FilePath (Get-Process -Id $PID).Path -PassThru -NoNewWindow `
                    -RedirectStandardOutput (Join-Path $work "$Phase-$($slot.Index)-out.txt") -RedirectStandardError (Join-Path $work "$Phase-$($slot.Index)-err.txt") `
                    -ArgumentList $arguments
                $running.Add([pscustomobject]@{ Slot = $slot; Process = $process; ResultPath = $resultPath })
            }
            foreach ($worker in $running) {
                $remaining = [int] [Math]::Max(0, ($deadline - [DateTime]::UtcNow).TotalMilliseconds)
                $timedOut = -not $worker.Process.WaitForExit($remaining)
                if ($timedOut) {
                    $worker.Process.Kill($true)
                    $worker.Process.WaitForExit()
                }
                elseif ($worker.Process.ExitCode -ne 0) {
                    $errorPath = Join-Path $work "$Phase-$($worker.Slot.Index)-err.txt"
                    throw "Mutation $Phase worker $($worker.Slot.Index) exited with code $($worker.Process.ExitCode): $(Get-Content -LiteralPath $errorPath -Raw)"
                }
                $finished = @{}
                if (Test-Path -LiteralPath $worker.ResultPath) {
                    foreach ($line in @(Get-Content -LiteralPath $worker.ResultPath)) {
                        $record = $line | ConvertFrom-Json -AsHashtable
                        if ($record['Id'] -cnotin @($worker.Slot.Jobs.Id) -or $finished.ContainsKey($record['Id'])) {
                            throw "Mutation $Phase worker returned an unexpected or duplicate job '$($record['Id'])'."
                        }
                        $finished[$record['Id']] = $record
                    }
                }
                $completed += $finished.Count
                $slotSeconds = 0.0
                foreach ($record in $finished.Values) { $slotSeconds += [double] $record['Seconds'] }
                $workerSeconds += $slotSeconds
                $longestWorkerSeconds = [Math]::Max($longestWorkerSeconds, $slotSeconds)
                foreach ($job in @($worker.Slot.Jobs)) {
                    [pscustomobject]@{ Job = $job; Result = $finished[$job['Id']] }
                }
            }
        }
        finally {
            foreach ($worker in $running) {
                if (-not $worker.Process.HasExited) { $worker.Process.Kill($true); $worker.Process.WaitForExit() }
                $worker.Process.Dispose()
            }
            $phases[$Phase] = [ordered]@{
                seconds = [Math]::Round($clock.Elapsed.TotalSeconds, 2)
                budgetSeconds = $BudgetSeconds
                jobs = $jobCount
                completed = $completed
                unfinished = $jobCount - $completed
                queued = [Math]::Max(0, $jobCount - $running.Count)
                workerSeconds = [Math]::Round($workerSeconds, 2)
                longestWorkerSeconds = [Math]::Round($longestWorkerSeconds, 2)
            }
        }
    }

    function Get-JobStatus {
        param($Result)

        Get-MutationJobStatus -Result $Result
    }

    try {
        $preparation = [Diagnostics.Stopwatch]::StartNew()
        $workers = [Math]::Max(1, [Math]::Min($ThrottleLimit, $mutants.Count))
        $sources = @(Get-ChildItem -LiteralPath $RepoPath -Force | Where-Object Name -cne '.git')
        $slots = @(foreach ($index in 1..$workers) {
                $copy = Join-Path $work "worker-$index"
                $null = New-Item -ItemType Directory -Path $copy -Force
                foreach ($item in $sources) { Copy-Item -LiteralPath $item.FullName -Destination $copy -Recurse -Force }
                [pscustomobject]@{ Index = $index; Copy = $copy; Jobs = [Collections.Generic.List[object]]::new(); Load = 0.0 }
            })
        $phases['preparation'] = @{ seconds = [Math]::Round($preparation.Elapsed.TotalSeconds, 2) }

        $groups = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
        foreach ($marker in @($markers | Sort-Object Name)) {
            $selection = @(foreach ($test in @($testsByCheck[$marker.Name] | Sort-Object { $_['Path'] })) {
                    [ordered]@{ Path = $test['Path']; FullName = @($test['FullName'] | Sort-Object -CaseSensitive) }
                })
            $key = ConvertTo-Json -InputObject $selection -Depth 4 -Compress
            if (-not $groups.ContainsKey($key)) {
                $groups.Add($key, @{ Id = "baseline:$($marker.Name)"; File = $marker.File; Text = $null; Tests = $selection; Checks = [Collections.Generic.List[string]]::new() })
            }
            $groups[$key].Checks.Add($marker.Name)
        }
        Write-Information "Baseline: $($groups.Count) test selections for $($markers.Count) security checks with $workers workers."
        $position = 0
        foreach ($group in $groups.Values) {
            $slots[$position % $workers].Jobs.Add($group)
            $position++
        }
        $baselineSeconds = @{}
        $baselineProblems = @(foreach ($item in @(Invoke-WorkerBatch -Phase baseline -Assignment $slots -BudgetSeconds $BaselineTimeoutSeconds)) {
                $name = $item.Job['Checks'] -join ', '
                $status, $detail = Get-JobStatus -Result $item.Result
                if ($status -ne 'Survived') { "The baseline of $name is not green: $status. $detail" }
                else {
                    foreach ($checkName in $item.Job['Checks']) { $baselineSeconds[$checkName] = [double] $item.Result['Seconds'] }
                    Write-Information ("  {0}: {1} tests passed in {2:N1} s." -f $name, $item.Result['Passed'], $item.Result['Seconds'])
                }
            })
        if ($baselineProblems.Count -gt 0) { throw ($baselineProblems -join [Environment]::NewLine) }

        # Longest processing time first: each mutant goes to the worker with the lowest expected load.
        foreach ($slot in $slots) { $slot.Jobs.Clear(); $slot.Load = 0.0 }
        foreach ($mutant in @($mutants | Sort-Object -Stable { $baselineSeconds[$_.Check] } -Descending)) {
            $slot = $slots | Sort-Object Load, Index | Select-Object -First 1
            $slot.Jobs.Add(@{ Id = $mutant.Id; File = $mutant.File; Text = $mutant.Text; Tests = $testsByCheck[$mutant.Check] })
            $slot.Load += $baselineSeconds[$mutant.Check]
        }
        Write-Information "Mutants: $($mutants.Count)."
        $byId = @{}
        foreach ($mutant in $mutants) { $byId[$mutant.Id] = $mutant }
        $results = @(foreach ($item in @(Invoke-WorkerBatch -Phase mutant -Assignment $slots -BudgetSeconds $TimeoutSeconds)) {
                $mutant = $byId[$item.Job['Id']]
                $status, $detail = Get-JobStatus -Result $item.Result
                [pscustomobject]@{
                    Id = $mutant.Id; Check = $mutant.Check; File = $mutant.File; Line = $mutant.Line; Kind = $mutant.Kind
                    Description = $mutant.Description; Status = $status; Detail = $detail
                    Seconds = if ($item.Result) { $item.Result['Seconds'] } else { $null }
                }
            })
    }
    catch {
        $failure = $_.Exception.Message
        $executionProblem = $failure
        $results = @($mutants | ForEach-Object {
                [pscustomobject]@{
                    Id = $_.Id; Check = $_.Check; File = $_.File; Line = $_.Line; Kind = $_.Kind
                    Description = $_.Description; Status = 'Error'; Detail = $failure; Seconds = $null
                }
            })
    }
    finally {
        $cleanup = [Diagnostics.Stopwatch]::StartNew()
        # Antivirus scanners can hold files of the finished workers for a moment.
        foreach ($attempt in 1..5) {
            try { Remove-Item -LiteralPath $work -Recurse -Force; break }
            catch {
                if ($attempt -eq 5) { Write-Warning "The mutation work folder $work was not removed: $($_.Exception.Message)" }
                else { Start-Sleep -Seconds 2 }
            }
        }
        $phases['cleanup'] = @{ seconds = [Math]::Round($cleanup.Elapsed.TotalSeconds, 2) }
    }
}

$exceptions = @($configuration['Exceptions'])
# Exceptions of unselected checks are dropped; an exception that matches no generated mutant stays and fails as stale.
if ($Check -or $Shard) { $exceptions = @(Select-MutationException -Exception $exceptions -Inventory $inventory -Check @($markers.Name)) }
$resolved = Resolve-MutationResult -Result $results -Exception $exceptions
$problems = @($resolved.Problems)
if ($executionProblem) { $problems += $executionProblem }
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
    shard = $Shard
    inventoryHash = $inventoryHash
    phases = $phases
    summary = $summary
    mutants = $resolved.Results
    problems = $problems
}
New-Item -ItemType Directory -Path (Split-Path -Parent $ReportPath) -Force | Out-Null
ConvertTo-Json -InputObject $report -Depth 6 | Set-Content -LiteralPath $ReportPath
$summary | Format-Table -AutoSize | Out-String | Write-Information
Write-Information "Report: $ReportPath ($($report.seconds) s)."
foreach ($phase in $phases.Keys) { Write-Information ("  {0}: {1:N2} s." -f $phase, $phases[$phase].seconds) }
if ($env:GITHUB_STEP_SUMMARY) {
    $lines = @('## Security check mutation testing', '', '| Check | Mutants | Killed | Survived | Excepted | Errors |', '|---|---|---|---|---|---|')
    $lines += @($summary | ForEach-Object { "| $($_.Check) | $($_.Mutants) | $($_.Killed) | $($_.Survived) | $($_.Excepted) | $($_.Errors) |" })
    $lines += @(foreach ($item in @($resolved.Results | Where-Object Status -eq 'Excepted')) { "- Excepted: ``$($item.Id)`` ($($item.Issue))" })
    $lines | Add-Content -LiteralPath $env:GITHUB_STEP_SUMMARY
}
if ($problems.Count -gt 0) {
    if ($env:GITHUB_ACTIONS -eq 'true') {
        foreach ($item in @($resolved.Results | Where-Object Status -in @('Survived', 'Error'))) {
            Write-Information "::error file=$($item.File),line=$($item.Line)::$($item.Status) mutant $($item.Id)"
        }
    }
    throw ('Mutation testing failed:' + [Environment]::NewLine + ($problems -join [Environment]::NewLine))
}
