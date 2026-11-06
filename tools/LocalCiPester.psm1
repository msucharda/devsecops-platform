#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Read-LocalCiPesterXml {
    param([string] $Path)
    $settings = [Xml.XmlReaderSettings]::new()
    $settings.DtdProcessing = [Xml.DtdProcessing]::Prohibit
    $reader = [Xml.XmlReader]::Create($Path, $settings)
    try {
        $document = [Xml.XmlDocument]::new()
        $document.XmlResolver = $null
        $document.Load($reader)
        return ,$document
    }
    finally { $reader.Dispose() }
}

function Get-LocalCiPesterShard {
    <#
    .SYNOPSIS
    Assigns each selected file exactly once using latest local durations, then repository estimates.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string[]] $Path,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int] $ShardCount
    )
    $files = [Collections.Generic.SortedSet[string]]::new(
        $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($item in $Path) {
        $fullPath = [IO.Path]::GetFullPath([IO.Path]::Combine($RepositoryRoot, $item))
        if (-not (Test-Path -LiteralPath $fullPath -PathType Leaf) -or $fullPath -notlike '*.Tests.ps1') {
            throw "Pester selection must contain existing test files: '$item'."
        }
        $null = $files.Add([IO.Path]::GetRelativePath($RepositoryRoot, $fullPath).Replace('\', '/'))
    }
    if ($files.Count -eq 0) { throw 'Pester selection is empty.' }
    $estimates = Import-PowerShellDataFile (Join-Path $RepositoryRoot 'tools/pester-durations.psd1')
    $local = @{}
    # Recent partial selections supplement one another. Only timings are reused, never a pass result.
    $history = @(Get-ChildItem -LiteralPath (Join-Path $RepositoryRoot 'artifacts/local-ci/pester') -Filter 'pester.xml' -Recurse -File -ErrorAction SilentlyContinue)
    $latest = Join-Path $RepositoryRoot 'artifacts/pester.xml'
    if (Test-Path -LiteralPath $latest -PathType Leaf) { $history += Get-Item -LiteralPath $latest }
    foreach ($report in ($history | Sort-Object LastWriteTimeUtc -Descending | Select-Object -First 10)) {
        try {
            $xml = Read-LocalCiPesterXml -Path $report.FullName
            foreach ($suite in $xml.SelectNodes('//test-suite')) {
                $name = $suite.GetAttribute('name')
                if ($name -notlike '*.Tests.ps1') { continue }
                $key = [IO.Path]::GetRelativePath($RepositoryRoot, [IO.Path]::GetFullPath($name)).Replace('\', '/')
                $seconds = 0.0
                if (-not $local.ContainsKey($key) -and [double]::TryParse($suite.GetAttribute('time'),
                        [Globalization.NumberStyles]::Float, [Globalization.CultureInfo]::InvariantCulture, [ref] $seconds) -and
                    [double]::IsFinite($seconds) -and $seconds -gt 0) { $local[$key] = $seconds }
            }
        }
        catch { Write-Verbose "Ignoring unusable Pester timing history '$($report.FullName)': $_" }
    }
    $weighted = @($files | ForEach-Object {
        $leaf = [IO.Path]::GetFileName($_)
        $seconds = if ($local.ContainsKey($_)) { $local[$_] }
        elseif ($estimates.ContainsKey($leaf)) { [double] $estimates[$leaf] }
        else { 1.0 }
        if (-not [double]::IsFinite($seconds) -or $seconds -le 0) { $seconds = 1.0 }
        [pscustomobject]@{ Path = $_; Seconds = $seconds }
    } | Sort-Object -Property Seconds -Descending -Stable)
    $count = [Math]::Min($ShardCount, $files.Count)
    $shards = @(for ($index = 0; $index -lt $count; $index++) {
        [pscustomobject]@{ Index = $index; Path = [Collections.Generic.List[string]]::new(); Seconds = 0.0 }
    })
    foreach ($file in $weighted) {
        $target = $shards[0]
        foreach ($candidate in $shards) { if ($candidate.Seconds -lt $target.Seconds) { $target = $candidate } }
        $target.Path.Add($file.Path)
        $target.Seconds += $file.Seconds
    }
    foreach ($shard in $shards) {
        [pscustomobject]@{ Index = $shard.Index; Path = $shard.Path.ToArray(); Seconds = $shard.Seconds }
    }
}

# security-check: local-ci-pester-case
function Test-LocalCiPesterCase {
    param([Xml.XmlElement] $Case)
    $executed = $Case.GetAttribute('executed')
    $result = $Case.GetAttribute('result')
    return ($executed -ceq 'True' -and $result -cin @('Success', 'Inconclusive')) -or
        ($executed -ceq 'False' -and $result -ceq 'Ignored')
}

# security-check: local-ci-pester-result
function Read-LocalCiPesterShardResult {
    param([object[]] $Shard, [string] $RepositoryRoot)

    if ($Shard.Count -eq 0) { throw 'No Pester shard results were supplied.' }
    $seen = [Collections.Generic.HashSet[string]]::new(
        $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    foreach ($item in $Shard) {
        if ($item.ExitCode -ne 0) { throw "Pester shard failed (exit $($item.ExitCode)): $($item.ResultPath)" }
        if (-not (Test-Path -LiteralPath $item.ResultPath -PathType Leaf)) { throw "Missing Pester shard XML: $($item.ResultPath)" }
        $xml = Read-LocalCiPesterXml -Path $item.ResultPath
        $root = $xml.SelectSingleNode('/test-results')
        $suite = $xml.SelectSingleNode('/test-results/test-suite')
        if ($null -eq $suite) { throw "Invalid Pester shard XML: $($item.ResultPath)" }
        $counters = @{}
        foreach ($key in 'total', 'errors', 'failures', 'not-run', 'inconclusive', 'ignored', 'skipped', 'invalid') {
            $value = 0L
            if (-not [long]::TryParse($root.GetAttribute($key), [ref] $value) -or $value -lt 0) {
                throw "Invalid Pester shard counter '$key': $($item.ResultPath)"
            }
            $counters[$key] = $value
        }
        $seconds = 0.0
        if (-not [double]::TryParse($suite.GetAttribute('time'), [Globalization.NumberStyles]::Float,
                [Globalization.CultureInfo]::InvariantCulture, [ref] $seconds) -or
            -not [double]::IsFinite($seconds) -or $seconds -lt 0) { throw 'Invalid Pester shard duration.' }
        if ($suite.GetAttribute('result') -cnotin @('Success', 'Ignored', 'Inconclusive') -or $suite.GetAttribute('success') -cne 'True') {
            throw "Invalid Pester shard suite outcome (Failed: $($counters.failures))."
        }
        $actual = @($suite.SelectNodes('results/test-suite') | ForEach-Object {
            [IO.Path]::GetFullPath([IO.Path]::Combine($RepositoryRoot, $_.GetAttribute('name')))
        })
        $expected = @($item.Path | ForEach-Object { [IO.Path]::GetFullPath([IO.Path]::Combine($RepositoryRoot, $_)) })
        if ($expected.Count -eq 0) { throw 'Pester shard file coverage has an empty selection.' }
        $difference = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual -CaseSensitive:(!$IsWindows))
        if ($difference.Count -gt 0) {
            throw "Pester shard file coverage does not match its selection: $($item.ResultPath)"
        }
        foreach ($file in $actual) { if (-not $seen.Add($file)) { throw "Pester file ran in more than one shard: $file" } }
        if ($counters.errors -gt 0 -or $counters.failures -gt 0 -or $counters.invalid -gt 0 -or $counters.total -eq 0) {
            throw "Pester shard counters report failure: Errors: $($counters.errors), Failed: $($counters.failures), Invalid: $($counters.invalid), Total: $($counters.total)."
        }
        $cases = @($suite.SelectNodes('.//test-case'))
        foreach ($case in $cases) {
            if (-not (Test-LocalCiPesterCase -Case $case)) { throw "Pester shard has inconsistent test results (possibly no passing executed tests): $($item.ResultPath)" }
        }
        if ($counters.total -ne $cases.Count) { throw "Pester shard counter 'total' does not match its test cases." }
        foreach ($fileSuite in $suite.SelectNodes('results/test-suite')) {
            if ($fileSuite.SelectNodes('.//test-case').Count -eq 0) {
                throw "Pester shard file coverage has no test cases for '$($fileSuite.GetAttribute('name'))'."
            }
        }
        $inconclusive = @($cases | Where-Object { $_.GetAttribute('result') -ceq 'Inconclusive' }).Count
        $skipped = @($cases | Where-Object { $_.GetAttribute('result') -ceq 'Ignored' }).Count
        if ($counters.inconclusive -ne $inconclusive) { throw "Pester shard counter 'inconclusive' does not match its test cases." }
        if ($counters.skipped -ne $skipped) { throw "Pester shard counter 'skipped' does not match its test cases." }
        # Pester 5.7.1 excludes NotRun tests from XML and always emits ignored=0.
        if ($counters.ignored -ne 0) { throw "Pester shard counter 'ignored' must be zero." }
        $successes = @($cases | Where-Object { $_.GetAttribute('executed') -ceq 'True' -and $_.GetAttribute('result') -ceq 'Success' }).Count
        if ($successes -eq 0) { throw "Pester shard has no passing executed tests: $($item.ResultPath)" }
        [pscustomobject]@{ Xml = $xml; Counters = $counters; Seconds = $seconds; Passed = $successes }
    }
}

function Move-LocalCiPesterArtifact {
    param([string] $Source, [string] $Destination)
    [IO.File]::Move($Source, $Destination, $true)
}

function Merge-LocalCiPesterResult {
    <#
    .SYNOPSIS
    Merges fresh NUnit reports, checking process outcomes and exact file coverage before publishing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Shard,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $OutputPath
    )
    $messages = [Collections.Generic.List[string]]::new()
    $code = 0
    $merged = $null
    $totals = @{ total = 0L; errors = 0L; failures = 0L; 'not-run' = 0L; inconclusive = 0L; ignored = 0L; skipped = 0L; invalid = 0L }
    $duration = 0.0
    $passed = 0
    $staging = "$OutputPath.new"
    try {
        Remove-Item -LiteralPath $OutputPath, $staging -Force -ErrorAction SilentlyContinue
        foreach ($report in @(Read-LocalCiPesterShardResult -Shard $Shard -RepositoryRoot $RepositoryRoot)) {
            $xml = $report.Xml
            $suite = $xml.SelectSingleNode('/test-results/test-suite')
            foreach ($key in @($totals.Keys)) { $totals[$key] += $report.Counters[$key] }
            $duration += $report.Seconds
            $passed += $report.Passed
            if ($null -eq $merged) {
                $merged = $xml.CloneNode($true)
                $merged.SelectSingleNode('/test-results/test-suite/results').RemoveAll()
            }
            foreach ($fileSuite in $suite.SelectNodes('results/test-suite')) {
                $null = $merged.SelectSingleNode('/test-results/test-suite/results').AppendChild($merged.ImportNode($fileSuite, $true))
            }
        }
        $root = $merged.SelectSingleNode('/test-results')
        foreach ($key in $totals.Keys) { $root.SetAttribute($key, $totals[$key].ToString([Globalization.CultureInfo]::InvariantCulture)) }
        $suite = $merged.SelectSingleNode('/test-results/test-suite')
        $suite.SetAttribute('time', $duration.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture))
        $suite.SetAttribute('result', $(if ($code -ne 0) { 'Failure' } elseif ($totals.ignored -gt 0) { 'Ignored' }
            elseif ($totals.inconclusive -gt 0) { 'Inconclusive' } else { 'Success' }))
        $suite.SetAttribute('success', $(if ($code -eq 0) { 'True' } else { 'False' }))
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath -Parent)
        $merged.Save($staging)
        Move-LocalCiPesterArtifact -Source $staging -Destination $OutputPath
        $messages.Add("Tests Passed: $passed, Failed: $($totals.failures), Skipped: $($totals.skipped), Inconclusive: $($totals.inconclusive), NotRun: $($totals.'not-run')")
    }
    catch { $code = 1; $messages.Add($_.Exception.Message) }
    finally { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ ExitCode = $code; Output = $messages.ToArray() }
}

function Invoke-LocalCiPesterProcess {
    param([string] $RepositoryRoot, [string[]] $Path, [string] $ResultPath, [string] $TempPath, [int] $WorkerSlots)
    $parameters = @{ CI = $true; Path = $Path; ResultPath = $ResultPath }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($parameters | ConvertTo-Json -Compress)))
    $runner = (Join-Path $RepositoryRoot 'tools/Invoke-Tests.ps1').Replace("'", "''")
    $command = "`$ErrorActionPreference = 'Stop'; `$p = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json -AsHashtable; & '$runner' @p; if (Test-Path variable:\LASTEXITCODE) { exit `$LASTEXITCODE }"
    $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
    $start.UseShellExecute = $false
    $start.WorkingDirectory = $RepositoryRoot
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in '-NoProfile', '-NonInteractive', '-OutputFormat', 'Text', '-EncodedCommand',
        [Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command))) { $start.ArgumentList.Add($argument) }
    foreach ($name in 'TEMP', 'TMP', 'TMPDIR') { $start.Environment[$name] = $TempPath }
    $start.Environment['LOCAL_CI_WORKER_BUDGET'] = [string] $WorkerSlots
    return [Diagnostics.Process]::Start($start)
}

function Invoke-LocalCiPester {
    <#
    .SYNOPSIS
    Runs selected files in granted process slots and returns one native-style outcome and merged artifacts/pester.xml.
    .DESCRIPTION
    The caller owns machine/worktree leases and enables Linux handle inheritance before calling.
    TempPath must be inside the caller's validated private TEMP. This function never acquires additional slots.
    A shard containing a nested-process suite reserves the complete granted share for its children.
    Peer shards wait until that reservation is released; ordinary shards reserve one slot each.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string[]] $Path,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int] $ShardCount,
        [Parameter(Mandatory)][string] $TempPath,
        [ValidateRange(1, 64)][int] $WorkerSlots = $ShardCount,
        [ValidateRange(1, 86400)][int] $TimeoutSeconds = 900
    )
    $outputPath = Join-Path $RepositoryRoot 'artifacts/pester.xml'
    $messages = [Collections.Generic.List[string]]::new()
    $workers = [Collections.Generic.List[object]]::new()
    $active = [Collections.Generic.Queue[object]]::new()
    $run = Join-Path $RepositoryRoot "artifacts/local-ci/pester/$([guid]::NewGuid().ToString('N'))"
    $code = 1
    try {
        try { $plan = @(Get-LocalCiPesterShard -RepositoryRoot $RepositoryRoot -Path $Path -ShardCount $ShardCount) }
        finally { Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue }
        $null = New-Item -ItemType Directory -Force -Path $run
        foreach ($shard in $plan) {
            $nested = @($shard.Path | Where-Object { [IO.Path]::GetFileName($_) -in @(
                'InstanceSetupManualSteps.Tests.ps1', 'LocalCiPester.Tests.ps1', 'LocalCiGate.Unit.Tests.ps1'
            ) }).Count -gt 0
            $worker = [pscustomobject]@{
                Index = $shard.Index; FileCount = $shard.Path.Count; EstimatedSeconds = $shard.Seconds
                Slots = if ($nested) { $WorkerSlots } else { 1 }
                Seconds = 0.0; PesterSeconds = $null; OverheadSeconds = $null; Files = @(); StartedAt = $null
                Path = $shard.Path; ResultPath = Join-Path $run "$($shard.Index).xml"
                LogPath = Join-Path $run "$($shard.Index).log"; Process = $null
                Stdout = $null; Stderr = $null; Watch = [Diagnostics.Stopwatch]::new(); ExitCode = 1
            }
            $workers.Add($worker)
        }
        $next = 0
        $used = 0
        while ($next -lt $workers.Count -or $active.Count) {
            while ($next -lt $workers.Count -and $used + $workers[$next].Slots -le $WorkerSlots) {
                $worker = $workers[$next++]
                $worker.Watch.Start()
                try {
                    $directory = Join-Path $TempPath "p$($worker.Index)"
                    $null = New-Item -ItemType Directory -Force -Path $directory
                    $worker.Process = Invoke-LocalCiPesterProcess -RepositoryRoot $RepositoryRoot -Path $worker.Path -ResultPath $worker.ResultPath -TempPath $directory -WorkerSlots $worker.Slots
                    $worker.StartedAt = $worker.Process.StartTime.ToUniversalTime()
                    $worker.Process.EnableRaisingEvents = $true
                    $worker.Stdout = $worker.Process.StandardOutput.ReadToEndAsync()
                    $worker.Stderr = $worker.Process.StandardError.ReadToEndAsync()
                    $used += $worker.Slots
                    $active.Enqueue($worker)
                    $messages.Add("Pester shard $($worker.Index): $($worker.Path.Count) files; slots $($worker.Slots); estimated $($worker.EstimatedSeconds)s; XML $($worker.ResultPath)")
                }
                catch { $messages.Add("Cannot start Pester shard $($worker.Index): $($_.Exception.Message)") }
            }
            if ($active.Count -eq 0) { continue }
            $worker = $active.Dequeue()
            $remaining = [int] [Math]::Max(0, ($TimeoutSeconds - $worker.Watch.Elapsed.TotalSeconds) * 1000)
            $timedOut = -not $worker.Process.HasExited -and -not $worker.Process.WaitForExit($remaining)
            if ($timedOut) {
                $worker.Process.Kill($true)
                $worker.Process.WaitForExit()
            }
            $worker.Seconds = ($worker.Process.ExitTime.ToUniversalTime() - $worker.StartedAt).TotalSeconds
            if ($timedOut -or $worker.Seconds -gt $TimeoutSeconds) {
                $messages.Add("Pester shard timed out after $TimeoutSeconds seconds: $($worker.ResultPath)")
            }
            else { $worker.ExitCode = $worker.Process.ExitCode }
            $text = $worker.Stdout.GetAwaiter().GetResult() + $worker.Stderr.GetAwaiter().GetResult()
            Set-Content -LiteralPath $worker.LogPath -Value $text -Encoding utf8NoBOM
            $messages.AddRange([string[]] ($text -split '\r?\n' | ForEach-Object { $_ -replace '\x1b\[[0-9;]*[A-Za-z]', '' }))
            try {
                $xml = Read-LocalCiPesterXml -Path $worker.ResultPath
                $suite = $xml.SelectSingleNode('/test-results/test-suite')
                $worker.PesterSeconds = [double]::Parse($suite.GetAttribute('time'), [Globalization.CultureInfo]::InvariantCulture)
                $worker.OverheadSeconds = [Math]::Max(0.0, $worker.Seconds - $worker.PesterSeconds)
                $worker.Files = @($suite.SelectNodes('results/test-suite') | ForEach-Object {
                    [pscustomobject]@{
                        Path = [IO.Path]::GetRelativePath($RepositoryRoot, [IO.Path]::GetFullPath(
                            [IO.Path]::Combine($RepositoryRoot, $_.GetAttribute('name')))).Replace('\', '/')
                        Seconds = [double]::Parse($_.GetAttribute('time'), [Globalization.CultureInfo]::InvariantCulture)
                    }
                })
            }
            catch { $messages.Add("Pester shard $($worker.Index) timing unavailable: $($_.Exception.Message)") }
            $messages.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture,
                'Pester shard {0} completed: {1} files; wall {2:F4}s; Pester {3:F4}s; overhead {4:F4}s; estimated {5:F4}s',
                $worker.Index, $worker.FileCount, $worker.Seconds, $worker.PesterSeconds, $worker.OverheadSeconds, $worker.EstimatedSeconds))
            foreach ($file in $worker.Files) {
                $messages.Add([string]::Format([Globalization.CultureInfo]::InvariantCulture,
                    'Pester file [shard {0}]: {1} [{2:F4}s]', $worker.Index, $file.Path, $file.Seconds))
            }
            $used -= $worker.Slots
        }
        $merged = Merge-LocalCiPesterResult -Shard $workers.ToArray() -RepositoryRoot $RepositoryRoot -OutputPath $outputPath
        $messages.AddRange([string[]] $merged.Output)
        $code = $merged.ExitCode
        if (Test-Path -LiteralPath $outputPath -PathType Leaf) { Copy-Item -LiteralPath $outputPath -Destination (Join-Path $run 'pester.xml') }
    }
    catch {
        Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue
        $messages.Add($_.Exception.Message)
        $code = 1
    }
    finally {
        foreach ($worker in $workers) {
            if ($null -eq $worker.Process) { continue }
            try {
                if (-not $worker.Process.HasExited) { $worker.Process.Kill($true); $worker.Process.WaitForExit() }
            }
            finally { $worker.Process.Dispose() }
        }
    }
    return [pscustomobject]@{
        ExitCode = $code; Output = $messages.ToArray()
        Shards = @($workers | Select-Object Index, Slots, FileCount, EstimatedSeconds, Seconds, PesterSeconds, OverheadSeconds, Path, ResultPath, LogPath, ExitCode, Files)
    }
}

function Get-LocalCiPesterStepGroup {
    <#
    .SYNOPSIS
    Adapts the shard runner to one weighted scheduler group and persists its timing sidecar.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string[]] $Path,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int] $GrantedShardCount,
        [Parameter(Mandatory)][string] $TimingPath
    )
    $count = [Math]::Min($GrantedShardCount, $Path.Count)
    if ($count -lt 1) { throw 'Pester selection is empty.' }
    $nested = @($Path | Where-Object { [IO.Path]::GetFileName($_) -in @(
        'InstanceSetupManualSteps.Tests.ps1', 'LocalCiPester.Tests.ps1', 'LocalCiGate.Unit.Tests.ps1'
    ) }).Count -gt 0
    $slots = if ($nested) { $GrantedShardCount } else { $count }
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{
        RepositoryRoot = $RepositoryRoot; Path = $Path; ShardCount = $count; WorkerSlots = $slots
    } | ConvertTo-Json -Compress)))
    $module = (Join-Path $PSScriptRoot 'LocalCiPester.psm1').Replace("'", "''")
    $destination = $TimingPath.Replace("'", "''")
    $script = @"
Import-Module '$module'
`$parameters = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json -AsHashtable
`$parameters.TempPath = `$env:TEMP
`$result = Invoke-LocalCiPester @parameters
ConvertTo-Json -InputObject @(`$result.Shards) -Depth 6 | Set-Content -LiteralPath '$destination' -Encoding utf8NoBOM
`$result.Output
`$global:LASTEXITCODE = `$result.ExitCode
"@
    return @{ Slots = $slots; Steps = @(@{ Name = 'Run Pester'; Script = $script }) }
}

Export-ModuleMember -Function Get-LocalCiPesterShard, Merge-LocalCiPesterResult, Invoke-LocalCiPester, Get-LocalCiPesterStepGroup
