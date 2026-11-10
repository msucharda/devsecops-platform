#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PublicationWitness.psm1')
Import-Module (Join-Path $PSScriptRoot 'PublicationAttestation.psm1')

# security-check: platform-release-source-policy
function Get-PlatformReleaseSourcePolicy {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $SourcePath)

    $source = Get-Item -LiteralPath $SourcePath -ErrorAction Stop
    if (-not $source.PSIsContainer) { throw 'Platform release source must be a directory.' }
    $declarations = @(Get-ChildItem -LiteralPath $source.FullName -Force |
        Where-Object { $_.Name -ieq 'release-source-policy.json' })
    if ($declarations.Count -eq 0) {
        return [pscustomobject]@{ Line = 'main'; Ref = 'refs/heads/main'; PublisherAppId = $null }
    }
    if ($declarations.Count -ne 1) { throw 'Ambiguous platform release source declaration.' }
    $file = $declarations[0]
    if ($file.Name -cne 'release-source-policy.json' -or $file.PSIsContainer -or
        ($file.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
        throw 'Platform release source declaration must be a regular, exactly named file.'
    }
    try { $document = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($file.FullName)) }
    catch [Text.Json.JsonException] { throw 'Invalid platform release source declaration JSON.' }
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Platform release source declaration must be an object.'
        }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $root.EnumerateObject()) {
            if (@('schemaVersion', 'line', 'publisherAppId') -cnotcontains $property.Name -or -not $seen.Add($property.Name)) {
                throw 'Invalid platform release source declaration fields.'
            }
        }
        if (-not $seen.Contains('schemaVersion') -or -not $seen.Contains('line')) {
            throw 'Missing platform release source declaration fields.'
        }
        if ($root.GetProperty('schemaVersion').GetRawText() -cne '1') {
            throw 'Invalid platform release source declaration schemaVersion.'
        }
        if ($root.GetProperty('line').ValueKind -ne [Text.Json.JsonValueKind]::String) {
            throw 'Invalid platform release source declaration line type.'
        }
        $line = $root.GetProperty('line').GetString()
        if ($line -cnotin @('main', 'ghe-publication')) {
            throw 'Invalid platform release source declaration line.'
        }
        if ($line -ceq 'main') {
            if ($seen.Count -ne 2) { throw 'The main source declaration cannot pin a publisher App.' }
            return [pscustomobject]@{ Line = 'main'; Ref = 'refs/heads/main'; PublisherAppId = $null }
        }
        if (-not $seen.Contains('publisherAppId')) { throw 'Missing platform release source publisherAppId.' }
        $publisher = $root.GetProperty('publisherAppId')
        [long] $appId = 0
        if ($publisher.ValueKind -ne [Text.Json.JsonValueKind]::Number -or
            -not $publisher.TryGetInt64([ref] $appId) -or $appId -le 0) {
            throw 'Invalid platform release source publisherAppId.'
        }
        [pscustomobject]@{ Line = $line; Ref = 'refs/heads/source-publication/v1'; PublisherAppId = $appId }
    }
    finally { $document.Dispose() }
}

# security-check: platform-publication-binding-rule
function Get-PublicationBindingRule {
    param([AllowNull()][object] $Rules, [long] $PublisherAppId)

    if ($PublisherAppId -le 0 -or $Rules -isnot [Collections.IList]) {
        throw 'Invalid active publication binding rules.'
    }
    $bindings = [Collections.Generic.List[object]]::new()
    foreach ($rule in $Rules) {
        if ($rule -isnot [Collections.IDictionary] -or $rule['type'] -isnot [string]) {
            throw 'Invalid publication binding rule shape.'
        }
        if ($rule['type'] -ine 'required_status_checks') { continue }
        $parameters = $rule['parameters']
        if ($parameters -isnot [Collections.IDictionary] -or $parameters['required_status_checks'] -isnot [Collections.IList]) {
            throw 'Invalid publication binding required checks.'
        }
        foreach ($check in $parameters['required_status_checks']) {
            if ($check -isnot [Collections.IDictionary] -or $check['context'] -isnot [string]) {
                throw 'Invalid publication binding check shape.'
            }
            if ($check['context'] -ieq 'GHE accepted source') {
                $bindings.Add(@{ Rule = $rule; Check = $check })
            }
        }
    }
    if ($bindings.Count -ne 1) { throw 'Missing or ambiguous active publication App binding.' }
    $binding = $bindings[0]
    if ($binding.Rule['type'] -cne 'required_status_checks' -or $binding.Check['context'] -cne 'GHE accepted source') {
        throw 'Invalid publication binding type or context.'
    }
    if (($binding.Check['integration_id'] -isnot [long] -and $binding.Check['integration_id'] -isnot [int]) -or
        $binding.Check['integration_id'] -ne $PublisherAppId) {
        throw 'Publication required check is not bound to the pinned App.'
    }
    $parameters = $binding.Rule['parameters']
    if ($parameters['strict_required_status_checks_policy'] -isnot [bool] -or
        -not $parameters['strict_required_status_checks_policy'] -or
        $parameters['do_not_enforce_on_create'] -isnot [bool] -or $parameters['do_not_enforce_on_create']) {
        throw 'Publication App binding must enforce strict checks, including ref creation.'
    }
    return $binding.Rule
}

# security-check: platform-published-source
function Assert-PlatformPublishedSource {
    [CmdletBinding(DefaultParameterSetName = 'Live')]
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][long] $PublisherAppId,
        [Parameter(Mandatory)][scriptblock] $Read,
        [Parameter(Mandatory, ParameterSetName = 'Attested')][string] $ArchivePath,
        [Parameter(Mandatory, ParameterSetName = 'Attested')][ValidatePattern('\A[0-9a-f]{64}\z')][string] $ArchiveSha256,
        [Parameter(Mandatory, ParameterSetName = 'Attested')][string] $ProvenanceBundlePath,
        [Parameter(Mandatory, ParameterSetName = 'Attested')][string] $PublicationBundlePath,
        [Parameter(Mandatory, ParameterSetName = 'Attested')][string] $Tag,
        [Parameter(Mandatory, ParameterSetName = 'Attested')][string] $SignerWorkflow
    )

    if ($Commit -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Invalid published source commit.' }
    $branchRules = [Collections.Generic.List[object]]::new()
    for ($page = 1; ; $page++) {
        if ($page -gt 100) { throw 'Publication binding rules pagination exceeds 100 pages.' }
        $part = & $Read "rules/branches/source-publication%2Fv1?per_page=100&page=$page"
        if ($part -isnot [Collections.IList] -or $part.Count -gt 100) {
            throw 'Invalid active publication binding rules pagination response.'
        }
        if ($part.Count -eq 0) { break }
        foreach ($rule in $part) { $branchRules.Add($rule) }
    }
    $binding = Get-PublicationBindingRule -Rules $branchRules -PublisherAppId $PublisherAppId
    $rulesetId = $binding['ruleset_id']
    if (($rulesetId -isnot [long] -and $rulesetId -isnot [int]) -or $rulesetId -le 0 -or
        $binding['ruleset_source_type'] -isnot [string] -or $binding['ruleset_source_type'] -cne 'Repository' -or
        $binding['ruleset_source'] -isnot [string] -or $binding['ruleset_source'] -ine $Repository) {
        throw 'Invalid publication binding ruleset source.'
    }
    $ruleset = & $Read "rulesets/$rulesetId"
    if ($ruleset -isnot [Collections.IDictionary] -or
        ($ruleset['id'] -isnot [long] -and $ruleset['id'] -isnot [int]) -or $ruleset['id'] -ne $rulesetId -or
        $ruleset['target'] -isnot [string] -or $ruleset['target'] -cne 'branch' -or
        $ruleset['enforcement'] -isnot [string] -or $ruleset['enforcement'] -cne 'active' -or
        $ruleset['source_type'] -isnot [string] -or $ruleset['source_type'] -cne 'Repository' -or
        $ruleset['source'] -isnot [string] -or $ruleset['source'] -ine $Repository) {
        throw 'Invalid active publication ruleset identity.'
    }
    $conditions = $ruleset['conditions']
    if ($conditions -isnot [Collections.IDictionary] -or $conditions['ref_name'] -isnot [Collections.IDictionary]) {
        throw 'Missing publication ruleset exact-ref selector.'
    }
    $selector = $conditions['ref_name']
    if ($selector['include'] -isnot [Collections.IList] -or $selector['include'].Count -ne 1 -or
        $selector['include'][0] -isnot [string] -or $selector['include'][0] -cne 'refs/heads/source-publication/v1' -or
        $selector['exclude'] -isnot [Collections.IList] -or $selector['exclude'].Count -ne 0) {
        throw 'Publication ruleset must target only the exact publication ref.'
    }
    $null = Get-PublicationBindingRule -Rules $ruleset['rules'] -PublisherAppId $PublisherAppId
    # Anonymous responses can omit this field. Omission is unknown, never an empty bypass list.
    if ($ruleset.Contains('bypass_actors')) {
        if ($ruleset['bypass_actors'] -isnot [Collections.IList]) { throw 'Malformed visible publication bypass list.' }
        foreach ($actor in $ruleset['bypass_actors']) {
            if ($actor -isnot [Collections.IDictionary] -or $actor['actor_type'] -isnot [string] -or
                $actor['actor_type'] -cnotin @('Integration', 'OrganizationAdmin', 'RepositoryRole', 'Team',
                    'DeployKey', 'EnterpriseOwner', 'EnterpriseRole', 'User')) {
                throw 'Malformed visible publication bypass actor type.'
            }
            $id = $actor['actor_id']
            if (($null -ne $id -and $id -isnot [long] -and $id -isnot [int]) -or
                ($actor['actor_type'] -cin @('Integration', 'RepositoryRole', 'Team', 'User') -and $id -le 0)) {
                throw 'Malformed visible publication bypass actor ID.'
            }
            if ($actor.Contains('bypass_mode') -and ($actor['bypass_mode'] -isnot [string] -or
                    $actor['bypass_mode'] -cnotin @('always', 'pull_request', 'exempt'))) {
                throw 'Malformed visible publication bypass mode.'
            }
            if ($actor['actor_type'] -ceq 'Integration' -and $id -eq $PublisherAppId) {
                throw 'The publisher App has a known publication ruleset bypass.'
            }
        }
    }
    $witnessEvidence = 'live-app-check'
    if ($PSCmdlet.ParameterSetName -ceq 'Attested') {
        $archiveLock = [IO.File]::Open($ArchivePath, [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::Read)
        try {
            $null = Get-PlatformBuildProvenance -ArchivePath $ArchivePath -ArchiveSha256 $ArchiveSha256 -BundlePath $ProvenanceBundlePath `
                -Repository $Repository -Tag $Tag -Commit $Commit -SignerWorkflow $SignerWorkflow
            $predicate = Get-PlatformPublicationAttestation -ArchivePath $ArchivePath -ArchiveSha256 $ArchiveSha256 -BundlePath $PublicationBundlePath `
                -Repository $Repository -Tag $Tag -Commit $Commit -SignerWorkflow $SignerWorkflow -PublisherAppId $PublisherAppId
            $selection = @{
                Check = @{ id = $predicate['checkId'] }
                Witness = @{ receiptSha256 = $predicate['receiptSha256'] }
            }
            $witnessEvidence = 'sigstore-publication-predicate'
        }
        finally { $archiveLock.Dispose() }
    }
    else {
        $allChecks = [Collections.Generic.List[object]]::new()
        $total = $null
        for ($page = 1; ; $page++) {
            if ($page -gt 100) { throw 'Publication check pagination exceeds 100 pages.' }
            $part = & $Read "commits/$Commit/check-runs?filter=all&per_page=100&page=$page"
            if ($part -isnot [Collections.IDictionary] -or
                ($part['total_count'] -isnot [long] -and $part['total_count'] -isnot [int]) -or $part['total_count'] -lt 0 -or
                $part['check_runs'] -isnot [Collections.IList] -or $part['check_runs'].Count -gt 100) {
                throw 'Invalid publication check pagination response.'
            }
            if ($null -eq $total) { $total = $part['total_count'] }
            if ($part['total_count'] -ne $total) { throw 'Publication check inventory changed during pagination.' }
            foreach ($check in $part['check_runs']) { $allChecks.Add($check) }
            if ($allChecks.Count -gt $total) { throw 'Publication check pagination exceeds its declared inventory.' }
            if ($allChecks.Count -eq $total) { break }
            if ($part['check_runs'].Count -eq 0) { throw 'Incomplete publication check pagination.' }
        }
        $selection = Get-PlatformPublicationWitness -CheckRuns @{ total_count = $total; check_runs = $allChecks } `
            -PublisherAppId $PublisherAppId -Commit $Commit
    }
    $reference = & $Read 'git/ref/heads/source-publication/v1'
    if ($reference -isnot [Collections.IDictionary] -or $reference['ref'] -isnot [string] -or
        $reference['ref'] -cne 'refs/heads/source-publication/v1' -or $reference['object'] -isnot [Collections.IDictionary] -or
        $reference['object']['type'] -isnot [string] -or $reference['object']['type'] -cne 'commit' -or
        $reference['object']['sha'] -isnot [string] -or $reference['object']['sha'] -cnotmatch '\A[0-9a-f]{40}\z') {
        throw 'Invalid published source reference.'
    }
    $tip = $reference['object']['sha']
    $comparison = & $Read "compare/$tip...${Commit}?per_page=1"
    if ($comparison -isnot [Collections.IDictionary] -or $comparison['status'] -isnot [string] -or
        $comparison['status'] -cnotin @('behind', 'identical') -or
        $comparison['merge_base_commit'] -isnot [Collections.IDictionary] -or
        $comparison['merge_base_commit']['sha'] -isnot [string] -or $comparison['merge_base_commit']['sha'] -cne $Commit) {
        throw 'Release commit is not independently verified on the publication ref.'
    }
    $after = & $Read 'git/ref/heads/source-publication/v1'
    if ($after -isnot [Collections.IDictionary] -or $after['ref'] -isnot [string] -or $after['ref'] -cne $reference['ref'] -or
        $after['object'] -isnot [Collections.IDictionary] -or $after['object']['type'] -isnot [string] -or
        $after['object']['type'] -cne 'commit' -or $after['object']['sha'] -isnot [string] -or $after['object']['sha'] -cne $tip) {
        throw 'Published source reference changed during verification.'
    }
    [pscustomobject]@{
        Ref = 'refs/heads/source-publication/v1'; Commit = $Commit; PublisherAppId = $PublisherAppId
        CheckId = $selection.Check['id']; ReceiptSha256 = $selection.Witness['receiptSha256']
        ProtectionEvidence = 'active-exact-ref-app-binding'; NoBypassEvidence = 'publisher-attested'
        WitnessEvidence = $witnessEvidence
    }
}

function New-PlatformPublicationPredicate {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs only an in-memory predicate from read-only verified source evidence.')]
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][long] $PublisherAppId,
        [Parameter(Mandatory)][scriptblock] $Read
    )

    $null = Assert-PlatformPublishedSource -Repository $Repository -Commit $Commit -PublisherAppId $PublisherAppId -Read $Read
    throw 'Publication operation binding is not verified; refusing to sign.'
}

Export-ModuleMember -Function Get-PlatformReleaseSourcePolicy, Assert-PlatformPublishedSource, New-PlatformPublicationPredicate
