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

function Merge-LocalCiPesterResult {
    <#
    .SYNOPSIS
    Merges fresh NUnit reports, checking process outcomes and exact file coverage before publishing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Shard,
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $OutputPath
    )
    $messages = [Collections.Generic.List[string]]::new()
    $code = 0
    $merged = $null
    $totals = @{ total = 0L; errors = 0L; failures = 0L; 'not-run' = 0L; inconclusive = 0L; ignored = 0L; skipped = 0L; invalid = 0L }
    $duration = 0.0
    $passed = 0
    $seen = [Collections.Generic.HashSet[string]]::new(
        $(if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }))
    $staging = "$OutputPath.new"
    try {
        Remove-Item -LiteralPath $OutputPath -Force -ErrorAction SilentlyContinue
        if ($Shard.Count -eq 0) { throw 'No Pester shard results were supplied.' }
        foreach ($item in $Shard) {
            if ($item.ExitCode -ne 0) { $code = 1; $messages.Add("Pester shard failed (exit $($item.ExitCode)): $($item.ResultPath)") }
            if (-not (Test-Path -LiteralPath $item.ResultPath -PathType Leaf)) { throw "Missing Pester shard XML: $($item.ResultPath)" }
            $xml = Read-LocalCiPesterXml -Path $item.ResultPath
            $root = $xml.SelectSingleNode('/test-results')
            $suite = $xml.SelectSingleNode('/test-results/test-suite')
            if ($null -eq $root -or $null -eq $suite) { throw "Invalid Pester shard XML: $($item.ResultPath)" }
            foreach ($key in @($totals.Keys)) {
                $value = 0L
                if (-not [long]::TryParse($root.GetAttribute($key), [ref] $value) -or $value -lt 0) {
                    throw "Invalid Pester shard counter '$key': $($item.ResultPath)"
                }
                $totals[$key] += $value
            }
            $seconds = 0.0
            if (-not [double]::TryParse($suite.GetAttribute('time'), [Globalization.NumberStyles]::Float,
                    [Globalization.CultureInfo]::InvariantCulture, [ref] $seconds) -or
                -not [double]::IsFinite($seconds) -or $seconds -lt 0) { throw 'Invalid Pester shard duration.' }
            $duration += $seconds
            if ($suite.GetAttribute('result') -cnotin @('Success', 'Ignored') -or $suite.GetAttribute('success') -cne 'True') { $code = 1 }
            $actual = @($suite.SelectNodes('results/test-suite') | ForEach-Object {
                [IO.Path]::GetFullPath([IO.Path]::Combine($RepositoryRoot, $_.GetAttribute('name')))
            })
            $expected = @($item.Path | ForEach-Object { [IO.Path]::GetFullPath([IO.Path]::Combine($RepositoryRoot, $_)) })
            $difference = @(Compare-Object -ReferenceObject $expected -DifferenceObject $actual -CaseSensitive:(!$IsWindows))
            if ($expected.Count -eq 0 -or $actual.Count -ne $expected.Count -or $difference.Count -gt 0) {
                throw "Pester shard file coverage does not match its selection: $($item.ResultPath)"
            }
            foreach ($file in $actual) { if (-not $seen.Add($file)) { throw "Pester file ran in more than one shard: $file" } }
            $cases = @($suite.SelectNodes('.//test-case'))
            $badCases = @($cases | Where-Object {
                $_.GetAttribute('executed') -ceq 'True' -and $_.GetAttribute('result') -cnotin @('Success', 'Inconclusive')
            })
            if ($badCases.Count -gt 0) { $code = 1; $messages.Add("Pester shard has inconsistent or failed test results: $($item.ResultPath)") }
            $successes = @($cases | Where-Object { $_.GetAttribute('executed') -ceq 'True' -and $_.GetAttribute('result') -ceq 'Success' }).Count
            if ($successes -eq 0) { $code = 1; $messages.Add("Pester shard has no passing executed tests: $($item.ResultPath)") }
            $passed += $successes
            if ($null -eq $merged) {
                $merged = $xml
                $merged.SelectSingleNode('/test-results/test-suite/results').RemoveAll()
            }
            # Clone before clearing the first report's results.
            if ($xml -eq $merged) {
                $xml = Read-LocalCiPesterXml -Path $item.ResultPath
                $suite = $xml.SelectSingleNode('/test-results/test-suite')
            }
            foreach ($fileSuite in $suite.SelectNodes('results/test-suite')) {
                $null = $merged.SelectSingleNode('/test-results/test-suite/results').AppendChild($merged.ImportNode($fileSuite, $true))
            }
        }
        if ($totals.errors -gt 0 -or $totals.failures -gt 0 -or $totals.invalid -gt 0 -or $totals.total -eq 0) { $code = 1 }
        $root = $merged.SelectSingleNode('/test-results')
        foreach ($key in $totals.Keys) { $root.SetAttribute($key, $totals[$key].ToString([Globalization.CultureInfo]::InvariantCulture)) }
        $suite = $merged.SelectSingleNode('/test-results/test-suite')
        $suite.SetAttribute('time', $duration.ToString('0.####', [Globalization.CultureInfo]::InvariantCulture))
        $suite.SetAttribute('result', $(if ($code -ne 0) { 'Failure' } elseif ($totals.ignored -gt 0) { 'Ignored' } else { 'Success' }))
        $suite.SetAttribute('success', $(if ($code -eq 0) { 'True' } else { 'False' }))
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $OutputPath -Parent)
        $merged.Save($staging)
        [IO.File]::Move($staging, $OutputPath, $true)
        $messages.Add("Tests Passed: $passed, Failed: $($totals.failures), Skipped: $($totals.skipped), Inconclusive: $($totals.inconclusive), NotRun: $($totals.'not-run')")
    }
    catch { $code = 1; $messages.Add($_.Exception.Message) }
    finally { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
    return [pscustomobject]@{ ExitCode = $code; Output = $messages.ToArray() }
}

function Invoke-LocalCiPesterProcess {
    param([string] $RepositoryRoot, [string[]] $Path, [string] $ResultPath, [string] $TempPath)
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
    $start.Environment['LOCAL_CI_WORKER_BUDGET'] = '1'
    return [Diagnostics.Process]::Start($start)
}

function Invoke-LocalCiPester {
    <#
    .SYNOPSIS
    Runs selected files in granted process slots and returns one native-style outcome and merged artifacts/pester.xml.
    .DESCRIPTION
    The caller owns machine/worktree leases and enables Linux handle inheritance before calling.
    TempPath must be inside the caller's validated private TEMP. This function never acquires additional slots.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string[]] $Path,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int] $ShardCount,
        [Parameter(Mandatory)][string] $TempPath,
        [ValidateRange(1, 86400)][int] $TimeoutSeconds = 900
    )
    $outputPath = Join-Path $RepositoryRoot 'artifacts/pester.xml'
    $messages = [Collections.Generic.List[string]]::new()
    $workers = [Collections.Generic.List[object]]::new()
    $run = Join-Path $RepositoryRoot "artifacts/local-ci/pester/$([guid]::NewGuid().ToString('N'))"
    $code = 1
    try {
        try { $plan = @(Get-LocalCiPesterShard -RepositoryRoot $RepositoryRoot -Path $Path -ShardCount $ShardCount) }
        finally { Remove-Item -LiteralPath $outputPath -Force -ErrorAction SilentlyContinue }
        $null = New-Item -ItemType Directory -Force -Path $run
        foreach ($shard in $plan) {
            $worker = [pscustomobject]@{
                Index = $shard.Index; FileCount = $shard.Path.Count; EstimatedSeconds = $shard.Seconds
                Seconds = 0.0; PesterSeconds = $null; OverheadSeconds = $null; Files = @(); StartedAt = $null
                Path = $shard.Path; ResultPath = Join-Path $run "$($shard.Index).xml"
                LogPath = Join-Path $run "$($shard.Index).log"; Process = $null
                Stdout = $null; Stderr = $null; Watch = [Diagnostics.Stopwatch]::StartNew(); ExitCode = 1
            }
            $workers.Add($worker)
            try {
                $directory = Join-Path $TempPath "p$($shard.Index)"
                $null = New-Item -ItemType Directory -Force -Path $directory
                $worker.Process = Invoke-LocalCiPesterProcess -RepositoryRoot $RepositoryRoot -Path $shard.Path -ResultPath $worker.ResultPath -TempPath $directory
                $worker.StartedAt = $worker.Process.StartTime.ToUniversalTime()
                $worker.Process.EnableRaisingEvents = $true
                $worker.Stdout = $worker.Process.StandardOutput.ReadToEndAsync()
                $worker.Stderr = $worker.Process.StandardError.ReadToEndAsync()
                $messages.Add("Pester shard $($shard.Index): $($shard.Path.Count) files; estimated $($shard.Seconds)s; XML $($worker.ResultPath)")
            }
            catch { $messages.Add("Cannot start Pester shard $($shard.Index): $($_.Exception.Message)") }
        }
        foreach ($worker in $workers) {
            if ($null -eq $worker.Process) { continue }
            $remaining = [int] [Math]::Max(0, ($TimeoutSeconds - $worker.Watch.Elapsed.TotalSeconds) * 1000)
            if (-not $worker.Process.HasExited -and -not $worker.Process.WaitForExit($remaining)) {
                $messages.Add("Pester shard timed out after $TimeoutSeconds seconds: $($worker.ResultPath)")
                $worker.Process.Kill($true)
                $worker.Process.WaitForExit()
            }
            else { $worker.ExitCode = $worker.Process.ExitCode }
            $worker.Seconds = ($worker.Process.ExitTime.ToUniversalTime() - $worker.StartedAt).TotalSeconds
            $text = $worker.Stdout.GetAwaiter().GetResult() + $worker.Stderr.GetAwaiter().GetResult()
            Set-Content -LiteralPath $worker.LogPath -Value $text -Encoding utf8NoBOM
            $messages.AddRange([string[]] ($text -split '\r?\n' | ForEach-Object { $_ -replace '\x1b\[[0-9;]*[A-Za-z]', '' }))
            try {
                $xml = Read-LocalCiPesterXml -Path $worker.ResultPath
                $suite = $xml.SelectSingleNode('/test-results/test-suite')
                $worker.PesterSeconds = [double]::Parse($suite.GetAttribute('time'), [Globalization.CultureInfo]::InvariantCulture)
                $worker.OverheadSeconds = [Math]::Max(0, $worker.Seconds - $worker.PesterSeconds)
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
        Shards = @($workers | Select-Object Index, FileCount, EstimatedSeconds, Seconds, PesterSeconds, OverheadSeconds, Path, ResultPath, LogPath, ExitCode, Files)
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
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes((@{
        RepositoryRoot = $RepositoryRoot; Path = $Path; ShardCount = $count
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
    return @{ Slots = $count; Steps = @(@{ Name = 'Run Pester'; Script = $script }) }
}

Export-ModuleMember -Function Get-LocalCiPesterShard, Merge-LocalCiPesterResult, Invoke-LocalCiPester, Get-LocalCiPesterStepGroup
