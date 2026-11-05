#Requires -Version 7.4
Set-StrictMode -Version Latest

function New-LocalCiTiming {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates only an in-memory timing record.')]
    [CmdletBinding()]
    param(
        [long] $StartedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp(),
        [datetimeoffset] $StartedAt = [datetimeoffset]::UtcNow
    )

    return @{
        StartedTimestamp = $StartedTimestamp
        StartedAt = $StartedAt.ToUniversalTime().ToString('o')
        Phase = 'Startup'
        PhaseStart = 0.0
        Phases = [Collections.Generic.List[object]]::new()
    }
}

function Set-LocalCiTimingPhase {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Updates only an in-memory timing record.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Timing,
        [Parameter(Mandatory)][string] $Name
    )

    $elapsed = [Diagnostics.Stopwatch]::GetElapsedTime($Timing.StartedTimestamp).TotalSeconds
    $Timing.Phases.Add([pscustomobject]@{
        Name = $Timing.Phase
        StartSeconds = $Timing.PhaseStart
        Seconds = $elapsed - $Timing.PhaseStart
    })
    $Timing.Phase = $Name
    $Timing.PhaseStart = $elapsed
}

function Move-LocalCiTimingArtifact {
    param([string] $Source, [string] $Destination)
    [IO.File]::Move($Source, $Destination, $true)
}

function Save-LocalCiTiming {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Timing,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][ValidateSet('Changed', 'Full', 'Plan')][string] $Mode,
        [Parameter(Mandatory)][int] $ExitCode
    )

    $staging = "$Path.new"
    Remove-Item -LiteralPath $Path, $staging -Force -ErrorAction SilentlyContinue
    Set-LocalCiTimingPhase -Timing $Timing -Name 'Complete'
    $summary = [ordered]@{
        Schema = 1
        StartedAt = $Timing.StartedAt
        Mode = $Mode
        Status = if ($ExitCode -eq 0) { 'passed' } else { 'failed' }
        ExitCode = $ExitCode
        TotalSeconds = $Timing.PhaseStart
        Phases = $Timing.Phases.ToArray()
    }
    if ($Timing.ContainsKey('MachineQueue')) { $summary.MachineQueue = $Timing.MachineQueue }
    if ($Timing.ContainsKey('PesterShards')) { $summary.PesterShards = $Timing.PesterShards }
    if ($Timing.ContainsKey('Steps')) { $summary.Steps = $Timing.Steps }
    try {
        $summary | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $staging -Encoding utf8NoBOM
        Move-LocalCiTimingArtifact -Source $staging -Destination $Path
    }
    finally { Remove-Item -LiteralPath $staging -Force -ErrorAction SilentlyContinue }
}

Export-ModuleMember -Function New-LocalCiTiming, Set-LocalCiTimingPhase, Save-LocalCiTiming
