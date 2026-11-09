#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $RecordPath,
    [switch] $RequireComplete
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$record = Get-Content -LiteralPath $RecordPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
if ($record -isnot [Collections.IDictionary] -or $record['version'] -ne 1 -or
    $record['state'] -cnotin @('inProgress', 'interrupted', 'reverted', 'completed')) {
    throw 'Cycle record requires version 1 and an explicit lifecycle state.'
}

function Get-CycleTimestamp {
    param([AllowNull()][object] $Value, [string] $Label)
    if ($Value -is [DateTime] -and $Value.Kind -ne [DateTimeKind]::Unspecified) { return [DateTimeOffset] $Value }
    $timestamp = [DateTimeOffset]::MinValue
    if ($Value -isnot [string] -or -not [DateTimeOffset]::TryParseExact($Value, 'o',
        [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::None, [ref] $timestamp)) {
        throw "Cycle $Label requires an explicit round-trip timestamp with offset."
    }
    return $timestamp
}

function Assert-CycleText {
    param([AllowNull()][object] $Value, [string] $Label)
    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) { throw "Cycle record requires $Label." }
}

function Get-CycleLiveMilestone {
    param([Collections.IDictionary] $Value, [string] $Label)
    $timestamp = Get-CycleTimestamp $Value['at'] "$Label.at"
    Assert-CycleText $Value['evidenceUrl'] "$Label.evidenceUrl"
    if ($Value['revision'] -cne $candidate['revision'] -or $Value['digest'] -cne $candidate['digest'] -or
        $Value['result'] -cnotin @('passed', 'failed')) {
        throw 'Live result must identify the exact candidate and its observed passed or failed result.'
    }
    return $timestamp
}

$candidate = $record['candidate']
if ($candidate -isnot [Collections.IDictionary]) { throw 'Cycle record requires a candidate object.' }
foreach ($key in @('baselineRelease', 'pullRequest', 'approvalUrl', 'approvedBy', 'change')) {
    Assert-CycleText $candidate[$key] "candidate.$key"
}
foreach ($key in @('baseRevision', 'revision')) {
    if ($candidate[$key] -isnot [string] -or $candidate[$key] -cnotmatch '^[a-f0-9]{40}\z') {
        throw "Cycle candidate.$key requires a full SHA."
    }
}
if ($candidate['digest'] -isnot [string] -or $candidate['digest'] -cnotmatch '^[a-f0-9]{64}\z') {
    throw 'Cycle candidate.digest requires a SHA256.'
}
$plan = $record['verificationPlan']
if ($plan -isnot [Collections.IDictionary]) { throw 'Cycle record requires a verification plan.' }
foreach ($key in @('bootstrap', 'teardown', 'recovery', 'acceptanceMilestone')) {
    if ($plan[$key] -isnot [bool]) { throw "Cycle verificationPlan.$key requires an explicit impact decision." }
}
Assert-CycleText $plan['rationale'] 'verificationPlan.rationale'
$destructiveRequired = $plan['bootstrap'] -or $plan['teardown'] -or $plan['recovery'] -or $plan['acceptanceMilestone']
if ($destructiveRequired) {
    Assert-CycleText $plan['destructiveScenario'] 'verificationPlan.destructiveScenario'
    if ($plan['destructiveStatus'] -cnotin @('unverified', 'passed')) { throw 'Destructive verification must remain explicitly unverified or passed.' }
    if ($plan['destructiveStatus'] -ceq 'passed') {
        Assert-CycleText $plan['destructiveApprovalUrl'] 'verificationPlan.destructiveApprovalUrl'
        Assert-CycleText $plan['destructiveEvidenceUrl'] 'verificationPlan.destructiveEvidenceUrl'
    }
}

$ready = Get-CycleTimestamp $record['readyAt'] 'readyAt'
$firstLive = $null
$successfulLive = $null
$releaseVerified = $null
$approvalRemoved = $null
$missing = [Collections.Generic.List[string]]::new()
if ($null -ne $record['experiments']) {
    if ($record['experiments'] -isnot [Collections.IList]) { throw 'Cycle experiments must be a sequence.' }
    foreach ($experiment in $record['experiments']) {
        if ($experiment['kind'] -cnotin @('UI', 'API')) { throw 'Cycle experiment kind must identify UI or API.' }
        foreach ($key in @('approvalUrl', 'originalState', 'actual', 'evidenceUrl')) {
            Assert-CycleText $experiment[$key] "experiment.$key"
        }
        if ($experiment['objects'] -isnot [Collections.IList] -or $experiment['objects'].Count -eq 0) {
            throw 'Cycle experiment must identify every changed object.'
        }
        foreach ($object in $experiment['objects']) { Assert-CycleText $object 'experiment.objects' }
        if ($experiment['disposition'] -cnotin @('codified', 'reverted')) { $missing.Add('experiment.disposition') }
        else { Assert-CycleText $experiment['dispositionEvidenceUrl'] 'experiment.dispositionEvidenceUrl' }
    }
}
if ($record['state'] -ceq 'reverted') {
    Assert-CycleText $record['reversionEvidenceUrl'] 'reversionEvidenceUrl'
}
if ($null -ne $record['firstLive']) {
    $firstLive = Get-CycleLiveMilestone -Value $record['firstLive'] -Label firstLive
    if ($firstLive -lt $ready) { throw 'First live result precedes the prepared change.' }
    if ($record['firstLive']['result'] -ceq 'passed') { $successfulLive = $firstLive }
}
else { $missing.Add('firstLive') }
if ($null -ne $record['successfulLive']) {
    $successfulLive = Get-CycleLiveMilestone -Value $record['successfulLive'] -Label successfulLive
    if ($record['successfulLive']['result'] -cne 'passed' -or $null -eq $firstLive -or $successfulLive -lt $firstLive) {
        throw 'Successful live verification must be passed and follow the first live result without replacing it.'
    }
}
if ($null -ne $firstLive -and $null -eq $successfulLive) { $missing.Add('successfulLive') }
if ($null -ne $record['standardRelease']) {
    $release = $record['standardRelease']
    $releaseVerified = Get-CycleTimestamp $release['verifiedAt'] 'standardRelease.verifiedAt'
    foreach ($key in @('tag', 'sourcePullRequest', 'importPullRequest', 'evidenceUrl')) {
        Assert-CycleText $release[$key] "standardRelease.$key"
    }
    foreach ($key in @('platformRevision', 'instanceRevision')) {
        if ($release[$key] -isnot [string] -or $release[$key] -cnotmatch '^[a-f0-9]{40}\z') {
            throw "Cycle standardRelease.$key requires a full SHA."
        }
        if ($release['tag'] -ceq $candidate['baselineRelease'] -or
            $release['instanceRevision'] -cin @($candidate['baseRevision'], $candidate['revision'])) {
            throw 'Standard release adoption must be a new release and instance revision, not the baseline or development candidate.'
        }
    }
    if ($null -eq $successfulLive -or $releaseVerified -lt $successfulLive) {
        throw 'Standard release verification must follow successful live verification.'
    }
    foreach ($name in @('functional', 'forbidden', 'idempotence', 'drift')) {
        $scenario = $release['scenarios'][$name]
        if ($scenario -isnot [Collections.IDictionary]) { $missing.Add("standardRelease.scenarios.$name"); continue }
        if ($scenario['result'] -ceq 'notApplicable' -and $name -cne 'functional') {
            Assert-CycleText $scenario['reason'] "standardRelease.scenarios.$name.reason"
            continue
        }
        if ($scenario['result'] -cne 'passed') { $missing.Add("standardRelease.scenarios.$name"); continue }
        foreach ($key in @('scenario', 'expected', 'actual', 'evidenceUrl')) {
            Assert-CycleText $scenario[$key] "standardRelease.scenarios.$name.$key"
        }
        if ($name -ceq 'idempotence' -and $scenario['changes'] -ne 0) { throw 'Repeated apply must report zero changes.' }
        if ($name -ceq 'drift' -and $scenario['unexpectedDrift'] -isnot [bool]) { throw 'Drift result must explicitly report unexpectedDrift.' }
        if ($name -ceq 'drift' -and $scenario['unexpectedDrift']) { throw 'Unexpected drift cannot complete a cycle.' }
    }
}
else { $missing.Add('standardRelease') }
if ($record['state'] -ceq 'completed') {
    Assert-CycleText $record['dispositionEvidenceUrl'] 'dispositionEvidenceUrl'
    $approvalRemoved = Get-CycleTimestamp $record['approvalRemovedAt'] 'approvalRemovedAt'
    if ($null -eq $releaseVerified -or $approvalRemoved -lt $releaseVerified) {
        throw 'Development approval may be removed only after standard release verification.'
    }
}

$end = Get-CycleTimestamp $record['observedUntil'] 'observedUntil'
if ($end -lt $ready -or ($null -ne $releaseVerified -and $end -lt $releaseVerified) -or
    ($null -ne $firstLive -and $end -lt $firstLive) -or ($null -ne $successfulLive -and $end -lt $successfulLive) -or
    ($null -ne $approvalRemoved -and $end -lt $approvalRemoved)) {
    throw 'Cycle observedUntil precedes a recorded milestone.'
}
$breakdown = [ordered]@{
    readyToLive = [ordered]@{ work = 0.0; ci = 0.0; humanWait = 0.0 }
    liveToRelease = [ordered]@{ work = 0.0; ci = 0.0; humanWait = 0.0 }
}
if ($record['intervals'] -isnot [Collections.IList]) { throw 'Cycle intervals must be a chronological sequence.' }
$cursor = $ready
foreach ($interval in $record['intervals']) {
    if ($interval['kind'] -cnotin @('work', 'ci', 'humanWait')) { throw 'Cycle interval kind must distinguish work, ci and humanWait.' }
    $start = Get-CycleTimestamp $interval['start'] 'interval.start'
    $stop = Get-CycleTimestamp $interval['end'] 'interval.end'
    if ($start -ne $cursor -or $stop -le $start -or $stop -gt $end) { throw 'Cycle intervals must cover observed time without gaps or overlaps.' }
    $boundary = if ($null -eq $firstLive) { $end } else { $firstLive }
    $firstStop = if ($stop -lt $boundary) { $stop } else { $boundary }
    if ($firstStop -gt $start) { $breakdown.readyToLive[$interval['kind']] += ($firstStop - $start).TotalSeconds }
    if ($null -ne $firstLive) {
        $secondStart = if ($start -gt $firstLive) { $start } else { $firstLive }
        $secondEnd = if ($null -ne $releaseVerified -and $stop -gt $releaseVerified) { $releaseVerified } else { $stop }
        if ($secondEnd -gt $secondStart) { $breakdown.liveToRelease[$interval['kind']] += ($secondEnd - $secondStart).TotalSeconds }
    }
    $cursor = $stop
}
if ($cursor -ne $end) { throw 'Cycle intervals must cover observedUntil; missing time is not a measurement.' }
$complete = $record['state'] -ceq 'completed' -and $missing.Count -eq 0
if ($RequireComplete -and -not $complete) { throw "Cycle is not complete: state=$($record['state']); missing=$($missing -join ', ')." }
[pscustomobject]@{
    EvidenceComplete = $complete; State = $record['state']; Missing = @($missing)
    FirstLiveResult = if ($null -ne $firstLive) { $record['firstLive']['result'] } else { $null }
    ReadyToLiveSeconds = if ($null -ne $firstLive) { ($firstLive - $ready).TotalSeconds } else { $null }
    LiveToReleaseSeconds = if ($null -ne $releaseVerified) { ($releaseVerified - $firstLive).TotalSeconds } else { $null }
    BreakdownSeconds = $breakdown
    DestructiveVerification = if ($destructiveRequired) { $plan['destructiveStatus'] } else { 'notRequiredByImpactPlan' }
    EvidenceQualification = 'Validated record only; live receipts are reported, not independently verified by this tool.'
}
