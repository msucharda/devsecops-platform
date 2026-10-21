#Requires -Version 7.4
Set-StrictMode -Version Latest

<#
Interruption harness for state-changing tools.

A test stub routes every mutating request through Invoke-InterruptionStep. Invoke-InterruptionMatrix
runs the tool once to count the mutating steps, then for every step and every kind:
  BeforeApply  - the request fails before the stub applies it (the run ends between step k-1 and k);
  LoseResponse - the stub applies the request and the response is lost (the run ends between step k and k+1).
After each interrupted run it runs the tool again and requires that the rerun succeeds, that the
snapshot of the stub state equals the reference snapshot and that no creation was applied more often
than in the reference run.
#>

function Get-InterruptionPlan {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param()

    return @{
        Target = 0
        Kind = 'None'
        Step = 0
        Injected = $false
        Requests = [System.Collections.Generic.List[string]]::new()
        Applied = [System.Collections.Generic.List[string]]::new()
    }
}

function Clear-InterruptionPlan {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Plan,
        [int] $Target = 0,
        [ValidateSet('None', 'BeforeApply', 'LoseResponse')][string] $Kind = 'None'
    )

    $Plan.Target = $Target
    $Plan.Kind = $Kind
    $Plan.Step = 0
    $Plan.Injected = $false
    $Plan.Requests.Clear()
    $Plan.Applied.Clear()
}

function Invoke-InterruptionStep {
    <#
    Runs one mutating request of a stub. Apply changes the stub state and returns the response.
    Interrupt returns the response of an interrupted request (for example HTTP 503 or a thrown exception).
    Identity names a created object whose repeated creation the API does not reject; the matrix
    reports it as a duplicate when it is applied more often than in the reference run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Plan,
        [Parameter(Mandatory)][string] $Request,
        [Parameter(Mandatory)][scriptblock] $Apply,
        [Parameter(Mandatory)][scriptblock] $Interrupt,
        [string] $Identity
    )

    $Plan.Step++
    $Plan.Requests.Add($Request)
    # The interrupted run has ended: retries and later requests of the same run must not reach the stub.
    if ($Plan.Injected -and $Plan.Kind -ne 'None') { return & $Interrupt }
    $inject = $Plan.Kind -ne 'None' -and $Plan.Step -eq $Plan.Target
    if ($inject -and $Plan.Kind -eq 'BeforeApply') {
        $Plan.Injected = $true
        return & $Interrupt
    }
    $response = & $Apply
    $succeeded = $true
    if ($null -ne $response -and $response.PSObject.Properties['StatusCode']) {
        $succeeded = [int] $response.StatusCode -ge 200 -and [int] $response.StatusCode -lt 300
    }
    if ($Identity -and $succeeded) { $Plan.Applied.Add($Identity) }
    if ($inject) {
        $Plan.Injected = $true
        return & $Interrupt
    }
    return $response
}

function ConvertTo-InterruptionCanonicalValue {
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($Value -is [System.Collections.IDictionary]) {
        $keys = [string[]] @($Value.Keys | ForEach-Object { [string] $_ })
        [Array]::Sort($keys, [System.StringComparer]::Ordinal)
        $sorted = [ordered]@{}
        foreach ($key in $keys) { $sorted[$key] = ConvertTo-InterruptionCanonicalValue -Value $Value[$key] }
        return $sorted
    }
    if ($Value -is [System.Collections.IList]) {
        return , @(foreach ($item in $Value) { ConvertTo-InterruptionCanonicalValue -Value $item })
    }
    return $Value
}

function ConvertTo-InterruptionSnapshotLine {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [AllowNull()] $Value,
        [string] $Path = '$'
    )

    if ($Value -is [System.Collections.IDictionary]) {
        if ($Value.Count -eq 0) { return "$Path = {}" }
        foreach ($key in $Value.Keys) { ConvertTo-InterruptionSnapshotLine -Value $Value[$key] -Path "$Path.$key" }
        return
    }
    if ($Value -is [System.Collections.IList]) {
        if ($Value.Count -eq 0) { return "$Path = []" }
        for ($index = 0; $index -lt $Value.Count; $index++) { ConvertTo-InterruptionSnapshotLine -Value $Value[$index] -Path "$Path[$index]" }
        return
    }
    return "$Path = $(ConvertTo-Json -InputObject $Value -Compress -Depth 2)"
}

function Get-InterruptionSnapshot {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([Parameter(Mandatory)][scriptblock] $Snapshot)

    $value = & $Snapshot
    return [string[]] @(ConvertTo-InterruptionSnapshotLine -Value (ConvertTo-InterruptionCanonicalValue -Value $value))
}

function Invoke-InterruptionMatrix {
    <#
    Reset restores the stub and the local state (inventory, state file) to the initial state.
    Run runs the tool once in a new process context. Recover runs after an interrupted run and
    receives its error record; it defaults to Run. Snapshot returns the comparable stub and local
    state; it must exclude values that legitimately differ between runs (generated IDs, timestamps).
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject[]])]
    param(
        [Parameter(Mandatory)][hashtable] $Plan,
        [Parameter(Mandatory)][scriptblock] $Reset,
        [Parameter(Mandatory)][scriptblock] $Run,
        [Parameter(Mandatory)][scriptblock] $Snapshot,
        [scriptblock] $Recover,
        [ValidateSet('BeforeApply', 'LoseResponse')][string[]] $Kind = @('BeforeApply', 'LoseResponse'),
        [ValidateRange(0, 1000)][int] $ShardIndex = 0,
        [ValidateRange(1, 1000)][int] $ShardCount = 1
    )

    if ($ShardIndex -ge $ShardCount) { throw "ShardIndex $ShardIndex must be lower than ShardCount $ShardCount." }

    if (-not $Recover) { $Recover = { param($InterruptedError) $null = $InterruptedError; & $Run }.GetNewClosure() }
    & $Reset
    Clear-InterruptionPlan -Plan $Plan
    $null = & $Run
    $reference = Get-InterruptionSnapshot -Snapshot $Snapshot
    $requests = [string[]] $Plan.Requests.ToArray()
    $referenceApplied = @{}
    foreach ($identity in $Plan.Applied) { $referenceApplied[$identity] = 1 + [int] $referenceApplied[$identity] }
    if ($requests.Count -eq 0) { throw 'The reference run made no mutating request. The stub does not route requests through Invoke-InterruptionStep.' }

    foreach ($kindName in $Kind) {
        for ($step = 1; $step -le $requests.Count; $step++) {
            if (($step - 1) % $ShardCount -ne $ShardIndex) { continue }
            & $Reset
            Clear-InterruptionPlan -Plan $Plan -Target $step -Kind $kindName
            $interruptedError = $null
            try { $null = & $Run }
            catch { $interruptedError = $_ }
            $injected = $Plan.Injected
            $Plan.Target = 0
            $Plan.Kind = 'None'
            $Plan.Injected = $false
            $rerunError = $null
            try { $null = & $Recover $interruptedError }
            catch { $rerunError = $_ }
            $state = Get-InterruptionSnapshot -Snapshot $Snapshot
            $applied = @{}
            foreach ($identity in $Plan.Applied) { $applied[$identity] = 1 + [int] $applied[$identity] }
            $duplicates = [string[]] @($applied.Keys | Where-Object { $applied[$_] -gt [int] $referenceApplied[$_] } | Sort-Object |
                ForEach-Object { "$_ ($($applied[$_])x, reference $([int] $referenceApplied[$_])x)" })
            $difference = [string[]] @(Compare-Object -ReferenceObject $reference -DifferenceObject $state -CaseSensitive |
                ForEach-Object { if ($_.SideIndicator -eq '<=') { "- $($_.InputObject)" } else { "+ $($_.InputObject)" } })
            $problems = [System.Collections.Generic.List[string]]::new()
            if (-not $injected) { $problems.Add('the interruption was not reached') }
            if ($rerunError) { $problems.Add("the rerun failed: $($rerunError.Exception.Message)") }
            if ($difference.Count -gt 0) { $problems.Add("the final state differs: $($difference -join '; ')") }
            if ($duplicates.Count -gt 0) { $problems.Add("duplicate creations: $($duplicates -join ', ')") }
            [pscustomobject]@{
                Step = $step
                Kind = $kindName
                Request = $requests[$step - 1]
                Interrupted = $null -ne $interruptedError
                Passed = $problems.Count -eq 0
                Problem = $problems -join '; '
            }
        }
    }
}

function Get-InterruptionShard {
    <#
    Reads INTERRUPTION_SHARD ('<index>/<count>', zero-based index) so that parallel CI jobs split the steps.
    An unset variable selects every step; a malformed value fails instead of silently testing nothing.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyString()][string] $Value = $env:INTERRUPTION_SHARD)

    if ([string]::IsNullOrEmpty($Value)) { return @{ ShardIndex = 0; ShardCount = 1 } }
    if ($Value -cnotmatch '^(?<index>0|[1-9][0-9]{0,2})/(?<count>[1-9][0-9]{0,2})$' -or [int] $Matches['index'] -ge [int] $Matches['count']) {
        throw "INTERRUPTION_SHARD '$Value' must be '<index>/<count>' with 0 <= index < count."
    }
    return @{ ShardIndex = [int] $Matches['index']; ShardCount = [int] $Matches['count'] }
}

function Format-InterruptionResult {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][pscustomobject[]] $Result
    )

    $failed = @($Result | Where-Object { -not $_.Passed })
    $steps = @($Result | Select-Object -ExpandProperty Step -Unique).Count
    $lines = @("Interruption harness $($Name): $steps mutating steps, $($Result.Count) interruptions, $($Result.Count - $failed.Count) passed, $($failed.Count) failed.")
    if ($Result.Count -eq 0) { $lines += '  The shard selected no step.' }
    foreach ($item in $failed) { $lines += "  step $($item.Step) $($item.Kind) $($item.Request): $($item.Problem)" }
    return $lines -join [Environment]::NewLine
}

Export-ModuleMember -Function Get-InterruptionPlan, Clear-InterruptionPlan, Invoke-InterruptionStep, Invoke-InterruptionMatrix, Get-InterruptionShard, Format-InterruptionResult
