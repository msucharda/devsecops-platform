[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SnapshotCommand,
    [Parameter(Mandatory)][string] $ArgumentsPath,
    [Parameter(Mandatory)][ValidateSet('first', 'second')][string] $Mode,
    [Parameter(Mandatory)][string] $SyncRoot
)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Wait-PublisherMarker {
    param([string] $Name)
    $timer = [Diagnostics.Stopwatch]::StartNew()
    while (-not [IO.File]::Exists((Join-Path $SyncRoot $Name))) {
        if ($timer.Elapsed.TotalSeconds -ge 45) { throw "Publisher barrier timed out: $Name" }
        Start-Sleep -Milliseconds 20
    }
}

$arguments = Get-Content -LiteralPath $ArgumentsPath -Raw | ConvertFrom-Json -AsHashtable
if ($Mode -ceq 'first') {
    $move = @(Select-String -LiteralPath $SnapshotCommand -SimpleMatch '[IO.Directory]::Move($staging, $Destination)')
    if ($move.Count -ne 1) { throw 'Fixture requires one atomic snapshot publication boundary.' }
    $global:fixtureSnapshotSyncRoot = $SyncRoot
    $breakpoint = Set-PSBreakpoint -Script $SnapshotCommand -Line $move[0].LineNumber -Action {
        [IO.File]::WriteAllText((Join-Path $global:fixtureSnapshotSyncRoot 'first-staged'), '')
        $timer = [Diagnostics.Stopwatch]::StartNew()
        while (-not [IO.File]::Exists((Join-Path $global:fixtureSnapshotSyncRoot 'release-first'))) {
            if ($timer.Elapsed.TotalSeconds -ge 45) { throw 'First publisher release timed out.' }
            Start-Sleep -Milliseconds 20
        }
    }
    try { $null = & $SnapshotCommand @arguments }
    finally { Remove-PSBreakpoint -Breakpoint $breakpoint }
    [IO.File]::WriteAllText((Join-Path $SyncRoot 'first-complete'), '')
}
else {
    try {
        $null = & $SnapshotCommand @arguments
        throw 'Competing publisher unexpectedly bypassed the held file lease.'
    }
    catch {
        if ($_.Exception.Message -notlike '*.lock*') { throw }
    }
    [IO.File]::WriteAllText((Join-Path $SyncRoot 'second-blocked'), '')
    Wait-PublisherMarker -Name first-complete
    try {
        $null = & $SnapshotCommand @arguments
        throw 'Competing publisher unexpectedly replaced the completed snapshot.'
    }
    catch {
        if ($_.Exception.Message -notlike '*differs from the authorized source or provenance*') { throw }
    }
    [IO.File]::WriteAllText((Join-Path $SyncRoot 'second-complete'), '')
}
