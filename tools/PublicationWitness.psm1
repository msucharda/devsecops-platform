#Requires -Version 7.4
Set-StrictMode -Version Latest

# security-check: platform-publication-witness
function Assert-PlatformPublicationWitness {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Check,
        [Parameter(Mandatory)][long] $PublisherAppId,
        [Parameter(Mandatory)][string] $Commit,
        [switch] $AllowAdmission
    )

    if ($Commit -cnotmatch '\A[0-9a-f]{40}\z') {
        throw 'Invalid publication witness expected commit.'
    }
    if ($PublisherAppId -le 0 -or $Check -isnot [Collections.IDictionary] -or $Check['app'] -isnot [Collections.IDictionary] -or
        ($Check['app']['id'] -isnot [long] -and $Check['app']['id'] -isnot [int]) -or
        $Check['app']['id'] -ne $PublisherAppId) {
        throw 'The publication witness does not belong to the pinned publisher App.'
    }
    if (($Check['id'] -isnot [long] -and $Check['id'] -isnot [int]) -or $Check['id'] -le 0) {
        throw 'Invalid publication witness check id.'
    }
    $envelope = @{ name = 'GHE accepted source'; status = 'completed'; conclusion = 'success'; head_sha = $Commit }
    foreach ($field in $envelope.get_Keys()) {
        if ($Check[$field] -isnot [string] -or $Check[$field] -cne $envelope[$field]) {
            throw "Invalid publication witness check $field."
        }
    }
    if ($Check['output'] -isnot [Collections.IDictionary] -or $Check['output']['summary'] -isnot [string]) {
        throw 'Invalid publication witness summary JSON type.'
    }
    try { $document = [Text.Json.JsonDocument]::Parse($Check['output']['summary']) }
    catch [Text.Json.JsonException] { throw 'Invalid publication witness summary JSON.' }
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'The publication witness summary must be an object.'
        }
        $fields = @('schemaVersion', 'kind', 'phase', 'ref', 'commit', 'receiptSha256')
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $document.RootElement.EnumerateObject()) {
            if ($fields -cnotcontains $property.Name -or -not $seen.Add($property.Name)) {
                throw 'Invalid publication witness payload fields.'
            }
        }
        if ($seen.Count -ne $fields.Count) {
            throw 'Invalid publication witness payload fields.'
        }
        if ($document.RootElement.GetProperty('schemaVersion').GetRawText() -cne '1') {
            throw 'Invalid publication witness schemaVersion.'
        }
        foreach ($field in @('kind', 'phase', 'ref', 'commit', 'receiptSha256')) {
            if ($document.RootElement.GetProperty($field).ValueKind -ne [Text.Json.JsonValueKind]::String) {
                throw "Invalid publication witness $field type."
            }
        }
        $witness = $document.RootElement.GetRawText() | ConvertFrom-Json -AsHashtable -NoEnumerate
        $values = @{ kind = 'platform-source-publication'; ref = 'refs/heads/source-publication/v1'; commit = $Commit }
        foreach ($field in $values.get_Keys()) {
            if ($witness[$field] -cne $values[$field]) {
                throw "Invalid publication witness $field."
            }
        }
        if ($witness['phase'] -cnotin @('admitted', 'published')) {
            throw 'Invalid publication witness phase.'
        }
        if ($witness['receiptSha256'] -cnotmatch '\A[0-9a-f]{64}\z') {
            throw 'Invalid publication witness receiptSha256.'
        }
        if ($Check['external_id'] -isnot [string] -or $Check['external_id'] -cne "platform-source-publication/v1:$($witness['receiptSha256'])") {
            throw 'Invalid publication witness external_id.'
        }
        if (-not $AllowAdmission -and $witness['phase'] -ceq 'admitted') {
            throw 'The publication witness is not published.'
        }
        $witness
    }
    finally { $document.Dispose() }
}

# security-check: platform-publication-check-selection
function Get-PlatformPublicationWitness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $CheckRuns,
        [Parameter(Mandatory)][long] $PublisherAppId,
        [Parameter(Mandatory)][string] $Commit,
        [switch] $AllowAdmission
    )

    if ($CheckRuns -isnot [Collections.IDictionary]) {
        throw 'Invalid publication check list object.'
    }
    if ($CheckRuns['check_runs'] -isnot [Collections.IList]) {
        throw 'Invalid publication check list check_runs array.'
    }
    if (($CheckRuns['total_count'] -isnot [long] -and $CheckRuns['total_count'] -isnot [int]) -or
        $CheckRuns['total_count'] -ne $CheckRuns['check_runs'].Count) {
        throw 'Invalid or incomplete publication check list.'
    }
    $ids = [Collections.Generic.HashSet[long]]::new()
    foreach ($check in $CheckRuns['check_runs']) {
        if ($check -isnot [Collections.IDictionary] -or
            ($check['id'] -isnot [long] -and $check['id'] -isnot [int]) -or
            $check['id'] -le 0 -or -not $ids.Add($check['id'])) {
            throw 'Invalid or duplicate ID in publication check list.'
        }
    }
    $witnessChecks = @($CheckRuns['check_runs'] | Where-Object {
        $_['name'] -ieq 'GHE accepted source' -and $_['app'] -is [Collections.IDictionary] -and $_['app']['id'] -eq $PublisherAppId
    })
    if ($witnessChecks.Count -ne 1) {
        throw 'Missing or ambiguous publication witness checks.'
    }
    $witness = Assert-PlatformPublicationWitness -Check $witnessChecks[0] -PublisherAppId $PublisherAppId -Commit $Commit -AllowAdmission:$AllowAdmission
    [pscustomobject]@{ Check = $witnessChecks[0]; Witness = $witness }
}

# security-check: platform-publication-reconciliation
function Resolve-PlatformPublicationWitness {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $CheckRuns,
        [Parameter(Mandatory)][long] $CheckId,
        [Parameter(Mandatory)][long] $PublisherAppId,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][string] $ReceiptSha256,
        [AllowNull()][object] $Reference,
        [AllowNull()][object] $RuleSuite,
        [long] $RuleSuiteId,
        [long] $RulesetId,
        [long] $RepositoryId,
        [long] $ActorId,
        [string] $BeforeCommit
    )

    $selection = Get-PlatformPublicationWitness -CheckRuns $CheckRuns -PublisherAppId $PublisherAppId -Commit $Commit -AllowAdmission
    $witness = $selection.Witness
    if ($selection.Check['id'] -ne $CheckId) {
        throw 'The publication witness check ID differs from the persisted intent.'
    }
    if ($witness['receiptSha256'] -cne $ReceiptSha256) {
        throw 'The publication witness receipt differs from the persisted intent.'
    }
    $result = @{ Phase = $witness['phase']; CheckId = $CheckId; Disposition = 'unverified'; Requires = 'reference' }
    if ($null -eq $Reference) { return $result }
    if ($Reference -isnot [Collections.IDictionary] -or $Reference['object'] -isnot [Collections.IDictionary]) {
        throw 'Invalid publication reference shape.'
    }
    if ($Reference['ref'] -isnot [string] -or $Reference['ref'] -cne 'refs/heads/source-publication/v1') {
        throw 'Invalid publication reference ref.'
    }
    $objectFields = @{ type = 'commit'; sha = $Commit }
    foreach ($field in $objectFields.get_Keys()) {
        if ($Reference['object'][$field] -isnot [string] -or $Reference['object'][$field] -cne $objectFields[$field]) {
            throw "Invalid publication reference object.$field."
        }
    }
    $result.Requires = 'rule-suite'
    if ($null -eq $RuleSuite) { return $result }
    if ($RuleSuite -isnot [Collections.IDictionary]) {
        throw 'Invalid publication rule suite shape.'
    }
    $suiteIds = @{ id = $RuleSuiteId; actor_id = $ActorId; repository_id = $RepositoryId }
    foreach ($field in $suiteIds.get_Keys()) {
        if ($suiteIds[$field] -le 0 -or ($RuleSuite[$field] -isnot [long] -and $RuleSuite[$field] -isnot [int]) -or
            $RuleSuite[$field] -ne $suiteIds[$field]) {
            throw "Invalid publication rule suite $field."
        }
    }
    if ($BeforeCommit -cnotmatch '\A[0-9a-f]{40}\z') {
        throw 'Invalid publication expected before commit.'
    }
    $suiteValues = @{
        before_sha = $BeforeCommit; after_sha = $Commit; ref = 'refs/heads/source-publication/v1'
        result = 'pass'
    }
    foreach ($field in $suiteValues.get_Keys()) {
        if ($RuleSuite[$field] -isnot [string] -or $RuleSuite[$field] -cne $suiteValues[$field]) {
            throw "Invalid publication rule suite $field."
        }
    }
    $evaluationResult = $RuleSuite['evaluation_result']
    if ($null -ne $evaluationResult -and ($evaluationResult -isnot [string] -or
            $evaluationResult -cnotin @('pass', 'fail', 'bypass'))) {
        throw 'Invalid publication rule suite evaluation_result.'
    }
    if ($RuleSuite['rule_evaluations'] -isnot [Collections.IList] -or $RuleSuite['rule_evaluations'].Count -eq 0) {
        throw 'Missing publication rule suite evaluations.'
    }
    $publicationEvaluations = 0
    foreach ($evaluation in $RuleSuite['rule_evaluations']) {
        if ($evaluation -isnot [Collections.IDictionary]) {
            throw 'Invalid publication rule suite evaluation shape.'
        }
        if ($evaluation['enforcement'] -isnot [string] -or $evaluation['enforcement'] -cnotin @('active', 'evaluate', 'deleted ruleset')) {
            throw 'Invalid publication rule suite evaluation enforcement.'
        }
        if ($evaluation['result'] -isnot [string] -or $evaluation['result'] -cnotin @('pass', 'fail')) {
            throw 'Invalid publication rule suite evaluation result.'
        }
        if ($evaluation['enforcement'] -ceq 'active' -and $evaluation['result'] -ceq 'fail') {
            throw 'A publication rule suite active evaluation did not pass.'
        }
        $source = $evaluation['rule_source']
        if ($evaluation['enforcement'] -ceq 'active' -and $source -is [Collections.IDictionary] -and
            $source['type'] -is [string] -and $source['type'] -ceq 'ruleset' -and
            ($source['id'] -is [long] -or $source['id'] -is [int]) -and $source['id'] -gt 0 -and
            $source['id'] -eq $RulesetId -and $evaluation['rule_type'] -is [string] -and
            $evaluation['rule_type'] -ceq 'required_status_checks') {
            $publicationEvaluations++
        }
    }
    if ($publicationEvaluations -ne 1) {
        throw 'Missing or ambiguous active publication check rule evaluation.'
    }
    # The API does not document a mapping from suite metadata IDs to the persisted check-run ID.
    $result.Requires = 'protected-check-binding'
    return $result
}

Export-ModuleMember -Function Assert-PlatformPublicationWitness, Get-PlatformPublicationWitness, Resolve-PlatformPublicationWitness
