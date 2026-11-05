#Requires -Version 7.4
Set-StrictMode -Version Latest

function Invoke-LocalCiStepSchedule {
    <#
    .SYNOPSIS
    Runs groups of CI steps within a granted process-slot budget and returns buffered per-step results.
    .DESCRIPTION
    Steps in a group share one child process. Groups may overlap; each reserves Slots (default one).
    The caller owns the machine lease and must keep it, including inherited Linux handles, until this returns.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Group,
        [Parameter(Mandatory)][ValidateRange(1, 64)][int] $Slots,
        [Parameter(Mandatory)][string] $WorkingDirectory,
        [Parameter(Mandatory)][string] $TempPath,
        [long] $StartedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
    )

    $workerBody = @'
param([string] $DefinitionPath, [string] $ResultPath, [long] $StartedTimestamp)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$definition = Get-Content -LiteralPath $DefinitionPath -Raw | ConvertFrom-Json
$results = [Collections.Generic.List[object]]::new()
foreach ($step in $definition.Steps) {
    $start = [Diagnostics.Stopwatch]::GetTimestamp()
    $output = [Collections.Generic.List[string]]::new()
    $text = [Text.StringBuilder]::new()
    $global:LASTEXITCODE = 0
    $code = 0
    try {
        & ([scriptblock]::Create($step.Script)) *>&1 | ForEach-Object {
            $null = $text.Append(("$_" -replace '\x1b\[[0-9;]*[A-Za-z]', ''))
            $noNewLine = $_ -is [Management.Automation.InformationRecord] -and
                $_.MessageData -is [Management.Automation.HostInformationMessage] -and $_.MessageData.NoNewLine
            if (-not $noNewLine) { $null = $text.AppendLine() }
        }
        $code = $LASTEXITCODE
    }
    catch {
        $null = $text.AppendLine($_.Exception.Message)
        $code = 1
    }
    if ($text.Length) {
        $output.AddRange([string[]] [regex]::Split($text.ToString().TrimEnd([char[]] "`r`n"), '\r?\n'))
    }
    $results.Add([pscustomobject]@{
        Name = $step.Name
        ExitCode = $code
        StartSeconds = [Diagnostics.Stopwatch]::GetElapsedTime($StartedTimestamp, $start).TotalSeconds
        Seconds = [Diagnostics.Stopwatch]::GetElapsedTime($start).TotalSeconds
        Output = $output.ToArray()
    })
    ConvertTo-Json -InputObject $results.ToArray() -Depth 6 |
        Set-Content -LiteralPath $ResultPath -Encoding utf8NoBOM
}
if (@($results | Where-Object ExitCode -NE 0).Count) { exit 1 }
exit 0
'@
    $directory = Join-Path $TempPath "steps-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
    $null = New-Item -ItemType Directory -Path $directory
    $workerPath = Join-Path $directory 'worker.ps1'
    Set-Content -LiteralPath $workerPath -Value $workerBody -Encoding utf8NoBOM
    $pending = [Collections.Generic.Queue[object]]::new()
    $running = [Collections.Generic.List[object]]::new()
    $completed = @{}
    $index = 0
    foreach ($definition in $Group) {
        $weight = if ($definition.Contains('Slots')) { [int] $definition.Slots } else { 1 }
        if ($weight -lt 1 -or $weight -gt $Slots) { throw "Step group needs $weight slots; only $Slots granted." }
        $pending.Enqueue(@{ Index = $index++; Definition = $definition; Slots = $weight })
    }
    try {
        while ($pending.Count -or $running.Count) {
            $used = 0
            foreach ($child in $running) { $used += $child.Slots }
            while ($pending.Count -and $used + $pending.Peek().Slots -le $Slots) {
                $child = $pending.Dequeue()
                $child.Temp = Join-Path $directory ([string] $child.Index)
                $null = New-Item -ItemType Directory -Path $child.Temp
                $inputPath = Join-Path $child.Temp 'input.json'
                $child.ResultPath = Join-Path $child.Temp 'results.json'
                $child.Definition | ConvertTo-Json -Depth 6 | Set-Content -LiteralPath $inputPath -Encoding utf8NoBOM
                $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
                $start.UseShellExecute = $false
                $start.WorkingDirectory = $WorkingDirectory
                $start.RedirectStandardOutput = $true
                $start.RedirectStandardError = $true
                foreach ($name in 'TEMP', 'TMP', 'TMPDIR') { $start.Environment[$name] = $child.Temp }
                $start.Environment['LOCAL_CI_WORKER_BUDGET'] = [string] $child.Slots
                foreach ($argument in '-NoProfile', '-NonInteractive', '-File', $workerPath,
                    '-DefinitionPath', $inputPath, '-ResultPath', $child.ResultPath, '-StartedTimestamp', [string] $StartedTimestamp) {
                    $start.ArgumentList.Add($argument)
                }
                $child.Start = [Diagnostics.Stopwatch]::GetTimestamp()
                try {
                    $child.Process = [Diagnostics.Process]::Start($start)
                    $running.Add($child)
                    $child.Stdout = $child.Process.StandardOutput.ReadToEndAsync()
                    $child.Stderr = $child.Process.StandardError.ReadToEndAsync()
                    $used += $child.Slots
                }
                catch {
                    $message = $_.Exception.Message
                    $completed[$child.Index] = @($child.Definition.Steps | ForEach-Object {
                        [pscustomobject]@{
                            Name = $_.Name; ExitCode = 1
                            Seconds = [Diagnostics.Stopwatch]::GetElapsedTime($child.Start).TotalSeconds
                            StartSeconds = [Diagnostics.Stopwatch]::GetElapsedTime($StartedTimestamp, $child.Start).TotalSeconds
                            Output = @("Cannot start step process: $message")
                        }
                    })
                }
            }
            foreach ($child in @($running.ToArray())) {
                if (-not $child.Process.HasExited) { continue }
                $child.Process.WaitForExit()
                $processOutput = ($child.Stdout.GetAwaiter().GetResult() + $child.Stderr.GetAwaiter().GetResult()).Trim()
                $records = @(try { Get-Content -LiteralPath $child.ResultPath -Raw -ErrorAction Stop | ConvertFrom-Json }
                    catch { $processOutput += "`nCannot read step results: $($_.Exception.Message)" })
                $items = [Collections.Generic.List[object]]::new()
                for ($stepIndex = 0; $stepIndex -lt $child.Definition.Steps.Count; $stepIndex++) {
                    $step = $child.Definition.Steps[$stepIndex]
                    $record = if ($stepIndex -lt $records.Count) { $records[$stepIndex] } else { $null }
                    $valid = $null -ne $record -and
                        @('Name', 'ExitCode', 'Seconds', 'StartSeconds', 'Output' | Where-Object { $_ -notin $record.PSObject.Properties.Name }).Count -eq 0
                    if ($valid) {
                        $valid = $record.Name -ceq $step.Name -and $record.ExitCode -is [long] -and
                            $record.Seconds -ge 0 -and $record.StartSeconds -ge 0 -and $record.Output -is [array]
                    }
                    if (-not $valid) {
                        $record = [pscustomobject]@{
                            Name = $step.Name; ExitCode = 1
                            StartSeconds = [Diagnostics.Stopwatch]::GetElapsedTime($StartedTimestamp, $child.Start).TotalSeconds
                            Seconds = [Diagnostics.Stopwatch]::GetElapsedTime($child.Start).TotalSeconds
                            Output = @("Step process did not return a valid result (exit $($child.Process.ExitCode)).", $processOutput)
                        }
                    }
                    $items.Add($record)
                }
                if ($child.Process.ExitCode -ne 0 -and @($items | Where-Object ExitCode -NE 0).Count -eq 0) {
                    $items[$items.Count - 1].ExitCode = 1
                    $items[$items.Count - 1].Output += "Step process failed after reporting results: $processOutput"
                }
                $completed[$child.Index] = $items.ToArray()
                $child.Process.Dispose()
                $null = $running.Remove($child)
            }
            if ($running.Count) { Start-Sleep -Milliseconds 20 }
        }
        for ($groupIndex = 0; $groupIndex -lt $Group.Count; $groupIndex++) { $completed[$groupIndex] }
    }
    finally {
        foreach ($child in $running) {
            try {
                if (-not $child.Process.HasExited) { $child.Process.Kill($true) }
                $child.Process.WaitForExit()
            }
            finally { $child.Process.Dispose() }
        }
    }
}

Export-ModuleMember -Function Invoke-LocalCiStepSchedule
