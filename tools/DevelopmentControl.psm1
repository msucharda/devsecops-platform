#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'DevelopmentTokenLifecycle.psm1')
$script:absentControlRef = [object]::new()

# security-check: development-control-http
function Invoke-DevelopmentControlRead {
    param([string] $Uri, [Collections.IDictionary] $Request, [switch] $AllowAbsent)
    $response = Invoke-WebRequest -Uri $Uri @Request
    if ($AllowAbsent -and $response.StatusCode -eq 404) { return $script:absentControlRef }
    if ($response.StatusCode -ne 200) { throw "Cannot read protected control state: HTTP $($response.StatusCode)." }
    return ConvertFrom-Json -InputObject ([string] $response.Content) -AsHashtable -NoEnumerate
}

# security-check: development-control-reference
function Get-DevelopmentControlRevision {
    param([AllowNull()][object] $Value, [string] $ExpectedRef)
    if ($Value -isnot [Collections.IDictionary] -or $Value['ref'] -isnot [string] -or $Value['ref'] -cne $ExpectedRef -or
        $Value['object'] -isnot [Collections.IDictionary] -or
        $Value['object']['type'] -isnot [string] -or $Value['object']['type'] -cne 'commit' -or
        $Value['object']['sha'] -isnot [string] -or $Value['object']['sha'] -cnotmatch '^[a-f0-9]{40}\z') {
        throw 'Invalid protected control ref; require the exact ref and full commit SHA.'
    }
    return $Value['object']['sha']
}

# security-check: development-control-tree
function Get-DevelopmentControlFileSha {
    param([AllowNull()][object] $Tree, [string] $Path = 'development-control.json')
    if ($Tree -isnot [Collections.IDictionary] -or $Tree['truncated'] -isnot [bool] -or
        $Tree['truncated'] -or $Tree['tree'] -isnot [Collections.IList]) {
        throw 'A complete control tree is required.'
    }
    $entries = @($Tree['tree'] | Where-Object {
        $_ -is [Collections.IDictionary] -and $_['path'] -is [string] -and $_['path'] -ceq $Path
    })
    if ($entries.Count -ne 1 -or $entries[0]['type'] -isnot [string] -or $entries[0]['type'] -cne 'blob' -or
        $entries[0]['mode'] -isnot [string] -or $entries[0]['mode'] -cne '100644' -or
        $entries[0]['sha'] -isnot [string] -or $entries[0]['sha'] -cnotmatch '^[a-f0-9]{40}\z') {
        throw "Exactly one regular control file '$Path' is required; links, executable files, directories and submodules are unsupported."
    }
    return $entries[0]['sha']
}

# security-check: development-control-file
function Read-DevelopmentControlFile {
    param([AllowNull()][object] $File, [string] $ExpectedSha, [string] $Path = 'development-control.json', [long] $MaximumBytes = 65536)
    if ($File -isnot [Collections.IDictionary] -or $File['type'] -isnot [string] -or $File['type'] -cne 'file' -or
        $File['name'] -isnot [string] -or $File['name'] -cne $Path -or
        $File['path'] -isnot [string] -or $File['path'] -cne $Path -or
        $File['sha'] -isnot [string] -or $File['sha'] -cne $ExpectedSha -or
        $File['encoding'] -isnot [string] -or $File['encoding'] -cne 'base64' -or
        $File['size'] -isnot [long] -or $File['size'] -le 0 -or $File['size'] -gt $MaximumBytes -or
        $File['content'] -isnot [string]) {
        throw 'Invalid protected control content; require the exact regular file, Git object, base64 encoding and bounded size.'
    }
    $bytes = [Convert]::FromBase64String($File['content'])
    if ($bytes.Length -ne $File['size']) { throw 'Protected control content size does not match the response.' }
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

# security-check: development-control-document
function ConvertFrom-DevelopmentControl {
    param([string] $Json)
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Control document must be an object.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $root.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { throw 'Control document contains duplicate fields.' }
        }
        $version = [Text.Json.JsonElement]::new()
        if (-not $root.TryGetProperty('version', [ref] $version)) { throw "Control document requires 'version'." }
        if ($version.GetRawText() -cnotin @('1', '2')) {
            throw 'Unsupported control document version.'
        }
        $values = @{ Version = [int] $version.GetRawText() }
        foreach ($field in @('reference', 'source', 'approval', 'disposition')) {
            $value = [Text.Json.JsonElement]::new()
            if (-not $root.TryGetProperty($field, [ref] $value)) { throw "Control document requires '$field'." }
            if ($value.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw "Control document requires string '$field'." }
            $values[$field] = $value.GetString()
        }
        return $values
    }
    finally { $document.Dispose() }
}

# security-check: development-control-journal
function Read-DevelopmentControlJournal {
    param(
        [Collections.IDictionary] $Tree, [int] $Version, [string] $Root, [string] $Revision,
        [Collections.IDictionary] $Request, [string] $ApiUrl, [string] $Repository
    )
    $path = 'development-token-journal.json'
    $entries = @($Tree['tree'] | Where-Object {
        $_ -is [Collections.IDictionary] -and $_['path'] -is [string] -and $_['path'] -ceq $path
    })
    if ($Version -eq 1) {
        if ($entries.Count -ne 0) { throw 'A token lifecycle journal requires protected control document v2.' }
        return @{ Phase = 'absent'; Json = '' }
    }
    $sha = Get-DevelopmentControlFileSha -Tree $Tree -Path $path
    $file = Invoke-DevelopmentControlRead -Uri "$Root/contents/${path}?ref=$Revision" -Request $Request
    $json = Read-DevelopmentControlFile -File $file -ExpectedSha $sha -Path $path -MaximumBytes 1048576
    $journal = Read-DevelopmentTokenJournal -Json $json
    if ($journal.Context -cne '') {
        $contextValue = ConvertFrom-Json -InputObject $journal.Context -AsHashtable -NoEnumerate
        if ($contextValue.apiUrl -cne $ApiUrl -or $contextValue.repository -cne $Repository) {
            throw 'Protected token journal origin or repository does not match this control ref.'
        }
    }
    return @{ Phase = $journal.Phase; Json = $json }
}

# security-check: development-control-stability
function Assert-DevelopmentControlStability {
    param([string] $Before, [string] $After)
    if ($Before -cne $After) { throw 'Protected control ref changed during inspection; start a fresh dispatch.' }
}

# security-check: development-control-protection
function Get-DevelopmentControlProtectionId {
    param([AllowNull()][object] $Rules)
    if ($Rules -isnot [Collections.IList]) { throw 'Control ref requires enterprise update and deletion rules.' }
    $updates = [Collections.Generic.HashSet[long]]::new()
    $deletions = [Collections.Generic.HashSet[long]]::new()
    foreach ($rule in $Rules) {
        if ($rule -isnot [Collections.IDictionary] -or $rule['type'] -isnot [string] -or
            $rule['ruleset_id'] -isnot [long] -or $rule['ruleset_id'] -le 0) { continue }
        if ($rule['type'] -ceq 'update') { $null = $updates.Add($rule['ruleset_id']) }
        if ($rule['type'] -ceq 'deletion') { $null = $deletions.Add($rule['ruleset_id']) }
    }
    if (-not $updates.Overlaps($deletions)) { throw 'Control ref requires enterprise update and deletion rules from one active enterprise ruleset.' }
    return @($updates | Where-Object { $deletions.Contains($_) } | Sort-Object)
}

# security-check: development-control-ruleset
function Test-DevelopmentControlRuleset {
    param([AllowNull()][object] $Ruleset, [long] $ExpectedId)
    if ($Ruleset -isnot [Collections.IDictionary] -or $Ruleset['id'] -isnot [long] -or
        $Ruleset['id'] -ne $ExpectedId -or $Ruleset['source_type'] -isnot [string] -or
        $Ruleset['source_type'] -cnotin @('Repository', 'Organization', 'Enterprise')) {
        throw 'Invalid enterprise control ruleset identity.'
    }
    if ($Ruleset['source_type'] -cne 'Enterprise') { return $false }
    if ($Ruleset['target'] -isnot [string] -or $Ruleset['target'] -cne 'branch' -or
        $Ruleset['enforcement'] -isnot [string] -or $Ruleset['enforcement'] -cne 'active' -or
        $Ruleset['rules'] -isnot [Collections.IList]) {
        throw 'An active enterprise branch control ruleset is required.'
    }
    $update = $false
    $deletion = $false
    foreach ($rule in $Ruleset['rules']) {
        if ($rule -isnot [Collections.IDictionary] -or $rule['type'] -isnot [string]) { continue }
        if ($rule['type'] -ceq 'update') {
            if ($rule['parameters'] -isnot [Collections.IDictionary] -or
                $rule['parameters']['update_allows_fetch_and_merge'] -isnot [bool] -or
                $rule['parameters']['update_allows_fetch_and_merge']) {
                throw 'The enterprise control ruleset must explicitly forbid upstream fetch-and-merge updates.'
            }
            $update = $true
        }
        if ($rule['type'] -ceq 'deletion') { $deletion = $true }
    }
    if (-not $update -or -not $deletion) { throw 'The enterprise control ruleset must restrict update and deletion.' }
    return $true
}

# security-check: development-control-snapshot
function Read-DevelopmentControl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $ReadToken,
        [switch] $AllowAbsent
    )

    $headers = @{
        Authorization = "Bearer $ReadToken"; Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2026-03-10'
    }
    $request = @{
        Headers = $headers; Method = 'GET'; MaximumRedirection = 0; TimeoutSec = 60
        MaximumRetryCount = 0; SkipHttpErrorCheck = $true
    }
    $root = "$($ApiUrl.TrimEnd('/'))/repos/$Repository"
    $main = Invoke-DevelopmentControlRead -Uri "$root/git/ref/heads/main" -Request $request
    $null = Get-DevelopmentControlRevision -Value $main -ExpectedRef refs/heads/main
    $reference = Invoke-DevelopmentControlRead -Uri "$root/git/ref/heads/platform-control" -Request $request -AllowAbsent:$AllowAbsent
    if ([object]::ReferenceEquals($reference, $script:absentControlRef)) { return $null }
    $revision = Get-DevelopmentControlRevision -Value $reference -ExpectedRef refs/heads/platform-control
    $tree = Invoke-DevelopmentControlRead -Uri "$root/git/trees/$revision" -Request $request
    $sha = Get-DevelopmentControlFileSha -Tree $tree
    $file = Invoke-DevelopmentControlRead -Uri "$root/contents/development-control.json?ref=$revision" -Request $request
    $state = ConvertFrom-DevelopmentControl -Json (Read-DevelopmentControlFile -File $file -ExpectedSha $sha)
    $journal = Read-DevelopmentControlJournal -Tree $tree -Version $state.Version -Root $root -Revision $revision -Request $request `
        -ApiUrl ($ApiUrl.TrimEnd('/')) -Repository $Repository
    $again = Invoke-DevelopmentControlRead -Uri "$root/git/ref/heads/platform-control" -Request $request
    Assert-DevelopmentControlStability -Before $revision -After (Get-DevelopmentControlRevision -Value $again -ExpectedRef refs/heads/platform-control)
    $rules = Invoke-DevelopmentControlRead -Uri "$root/rules/branches/platform-control?per_page=100&page=1" -Request $request
    $protectionIds = @(Get-DevelopmentControlProtectionId -Rules $rules)
    $protected = $false
    foreach ($id in $protectionIds) {
        $ruleset = Invoke-DevelopmentControlRead -Uri "$root/rulesets/${id}?includes_parents=true" -Request $request
        if (Test-DevelopmentControlRuleset -Ruleset $ruleset -ExpectedId $id) { $protected = $true }
    }
    if (-not $protected) { throw 'Control ref requires enterprise update and deletion rules from one active enterprise ruleset.' }
    return @{
        Reference = $state['reference']; Source = $state['source']
        Approval = $state['approval']; Disposition = $state['disposition']
        ControlRevision = $revision
        ControlVersion = $state.Version; ControlBlobSha = $sha
        TokenJournalPhase = $journal.Phase; TokenJournal = $journal.Json
    }
}

# security-check: development-control-write-http
function Invoke-DevelopmentControlWrite {
    param([string] $Uri, [string] $Method, [Collections.IDictionary] $Value, [string] $WriterToken, [int] $ExpectedStatus)
    $response = Invoke-WebRequest -Uri $Uri -Method $Method -Headers @{
        Authorization = "Bearer $WriterToken"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10'
    } -ContentType 'application/json' -Body (ConvertTo-Json -InputObject $Value -Depth 20 -Compress) `
        -MaximumRedirection 0 -MaximumRetryCount 0 -TimeoutSec 60 -SkipHttpErrorCheck
    if ($response.StatusCode -ne $ExpectedStatus) { throw "Protected journal write failed: HTTP $($response.StatusCode); do not mint or hand off a token." }
    return ConvertFrom-Json -InputObject ([string] $response.Content) -AsHashtable -NoEnumerate
}

# security-check: development-control-writer
function Read-DevelopmentTokenWriteContext {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $ReadToken,
        [Parameter(Mandatory)][AllowEmptyString()][string] $WriterToken,
        [Parameter(Mandatory)][string] $RecoveryKey,
        [Parameter(Mandatory)][string] $Context,
        [Parameter(Mandatory)][string] $ExpectedHead,
        [Parameter(Mandatory)][string] $ExpectedControlBlobSha
    )
    if ([string]::IsNullOrWhiteSpace($WriterToken)) { throw 'An explicit protected control-ref writer is required before minting or handoff.' }
    $null = Get-DevelopmentRecoveryKeyId -RecoveryKey $RecoveryKey
    $contextValue = ConvertFrom-Json -InputObject $Context -AsHashtable -NoEnumerate
    $canonical = New-DevelopmentTokenContext -Value $contextValue
    if ($canonical -cne $Context -or $contextValue.apiUrl -cne $ApiUrl.TrimEnd('/') -or
        $contextValue.repository -cne $Repository -or $contextValue.authorizationBlob -cne $ExpectedControlBlobSha -or
        $ExpectedHead -cnotmatch '^[a-f0-9]{40}\z') {
        throw 'Protected journal write requires the exact canonical context, origin, repository, authorization blob and head.'
    }
    $before = Read-DevelopmentControl -ApiUrl $ApiUrl -Repository $Repository -ReadToken $ReadToken
    if ($before.ControlVersion -ne 2) { throw 'New token issuance requires protected control document v2; downgrade is forbidden.' }
    if ($before.ControlRevision -cne $ExpectedHead -or $before.ControlBlobSha -cne $ExpectedControlBlobSha) {
        throw 'Protected control head or authorization blob changed; do not adopt a newer head.'
    }
    return @{ Control = $before; Value = $contextValue }
}

# security-check: development-control-issuance
function Write-DevelopmentTokenEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $ReadToken,
        [Parameter(Mandatory)][AllowEmptyString()][string] $WriterToken,
        [Parameter(Mandatory)][string] $RecoveryKey,
        [Parameter(Mandatory)][Alias('Event')][ValidateSet('pending', 'issued')][string] $JournalEvent,
        [Parameter(Mandatory)][string] $Context,
        [Parameter(Mandatory)][string] $ExpectedHead,
        [Parameter(Mandatory)][string] $ExpectedControlBlobSha,
        [string] $Envelope = ''
    )
    $snapshot = Read-DevelopmentTokenWriteContext -ApiUrl $ApiUrl -Repository $Repository -ReadToken $ReadToken `
        -WriterToken $WriterToken -RecoveryKey $RecoveryKey -Context $Context -ExpectedHead $ExpectedHead -ExpectedControlBlobSha $ExpectedControlBlobSha
    $before = $snapshot.Control
    $contextValue = $snapshot.Value
    if ($JournalEvent -ceq 'pending' -and $contextValue.authorizationRevision -cne $ExpectedHead) {
        throw 'A new pending intent must bind its original exact authorization head.'
    }
    if ($JournalEvent -ceq 'issued') {
        $journalState = Read-DevelopmentTokenJournal -Json $before.TokenJournal
        if ($journalState.Phase -cne 'pending' -or $journalState.Context -cne $Context) {
            throw 'Issued token has no matching pending intent.'
        }
        $leaf = Unprotect-DevelopmentLeafToken -Envelope $Envelope -RecoveryKey $RecoveryKey -ContextSha256 $journalState.ContextSha256
        try {
            $probe = Invoke-WebRequest -Uri "$($contextValue.apiUrl)/installation/repositories" -Method GET -Headers @{
                Authorization = "Bearer $leaf"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10'
            } -MaximumRedirection 0 -MaximumRetryCount 0 -TimeoutSec 60 -SkipHttpErrorCheck
            if ($probe.StatusCode -ne 200) { throw 'The exact issued leaf must authenticate at GET /installation/repositories before persistence or handoff.' }
        }
        finally { $leaf = $null }
    }
    $probeStatus = if ($JournalEvent -ceq 'issued') { 200 } else { 0 }
    $json = Add-DevelopmentTokenJournalEvent -Json $before.TokenJournal -Event $JournalEvent -Context $Context `
        -PreviousHead $ExpectedHead -Envelope $Envelope -IssuanceProbeStatusCode $probeStatus
    return Write-DevelopmentControlJournal -ApiUrl $ApiUrl -Repository $Repository -ReadToken $ReadToken `
        -WriterToken $WriterToken -ExpectedHead $ExpectedHead -ExpectedControlBlobSha $ExpectedControlBlobSha -Json $json
}

# security-check: development-token-retirement
function Complete-DevelopmentTokenRetirement {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $ReadToken,
        [Parameter(Mandatory)][AllowEmptyString()][string] $WriterToken,
        [Parameter(Mandatory)][string] $RecoveryKey,
        [Parameter(Mandatory)][string] $Context,
        [Parameter(Mandatory)][string] $ExpectedHead,
        [Parameter(Mandatory)][string] $ExpectedControlBlobSha,
        [Parameter(Mandatory)][AllowEmptyString()][string] $AppJwt,
        [Parameter(Mandatory)][string] $RetirementRunId
    )
    if ($RetirementRunId -cnotmatch '^[1-9][0-9]{0,18}\z') { throw 'Retirement requires an exact trusted recovery run ID.' }
    $snapshot = Read-DevelopmentTokenWriteContext -ApiUrl $ApiUrl -Repository $Repository -ReadToken $ReadToken `
        -WriterToken $WriterToken -RecoveryKey $RecoveryKey -Context $Context -ExpectedHead $ExpectedHead -ExpectedControlBlobSha $ExpectedControlBlobSha
    $journal = Read-DevelopmentTokenJournal -Json $snapshot.Control.TokenJournal
    if ($journal.Phase -cnotin @('issued', 'retired') -or $journal.Context -cne $Context) {
        throw 'Recovery requires the exact persisted known issued leaf; unknown pending issuance remains blocked.'
    }
    if ($journal.Phase -ceq 'retired') {
        return @{ ControlRevision = $ExpectedHead; ControlBlobSha = $ExpectedControlBlobSha; TokenJournalPhase = 'retired' }
    }
    $leaf = Unprotect-DevelopmentLeafToken -Envelope $journal.Envelope -RecoveryKey $RecoveryKey -ContextSha256 $journal.ContextSha256
    $revokeStatus = 0
    $activeInstallationId = ''
    $contextValue = $snapshot.Value
    $request = @{
        Headers = @{ Authorization = "Bearer $leaf"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
        MaximumRedirection = 0; MaximumRetryCount = 0; TimeoutSec = 60; SkipHttpErrorCheck = $true
    }
    try {
        $probeUri = "$($contextValue.apiUrl)/installation/repositories"
        $probe = Invoke-WebRequest -Uri $probeUri -Method GET @request
        if ($probe.StatusCode -eq 200) {
            $revoke = Invoke-WebRequest -Uri "$($contextValue.apiUrl)/installation/token" -Method DELETE @request
            if ($revoke.StatusCode -ne 204) { throw 'Token revocation requires documented DELETE 204; other responses are not success.' }
            $revokeStatus = 204
            $probe = Invoke-WebRequest -Uri $probeUri -Method GET @request
            if ($probe.StatusCode -ne 401) { throw 'Token retirement requires direct negative GET 401; expiry and other failures are not proof.' }
            $kind = 'revoked'
        }
        elseif ($probe.StatusCode -eq 401) {
            if ([string]::IsNullOrWhiteSpace($AppJwt)) { throw 'Already-invalid recovery requires an explicit App JWT without credential fallback.' }
            $appRequest = @{
                Headers = @{ Authorization = "Bearer $AppJwt"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
                Method = 'GET'; MaximumRedirection = 0; MaximumRetryCount = 0; TimeoutSec = 60; SkipHttpErrorCheck = $true
            }
            $installation = Invoke-DevelopmentControlRead -Uri "$($contextValue.apiUrl)/app/installations/$($contextValue.installationId)" -Request $appRequest
            Assert-DevelopmentActiveInstallation -Installation $installation -Context $contextValue
            $activeInstallationId = $contextValue.installationId
            $kind = 'already-invalid'
        }
        else { throw 'Token retirement requires direct negative GET 401 or an authenticated leaf that can be revoked; other statuses remain blocked.' }
        $json = Add-DevelopmentTokenJournalEvent -Json $snapshot.Control.TokenJournal -Event retired -Context $Context `
            -PreviousHead $ExpectedHead -RevokeStatusCode $revokeStatus -NegativeStatusCode 401 -RetirementRunId $RetirementRunId `
            -ProofKind $kind -ActiveInstallationId $activeInstallationId
        return Write-DevelopmentControlJournal -ApiUrl $ApiUrl -Repository $Repository -ReadToken $ReadToken `
            -WriterToken $WriterToken -ExpectedHead $ExpectedHead -ExpectedControlBlobSha $ExpectedControlBlobSha -Json $json
    }
    finally { $leaf = $null; $request.Headers.Clear() }
}

# security-check: development-token-active-installation
function Assert-DevelopmentActiveInstallation {
    param([AllowNull()][object] $Installation, [Collections.IDictionary] $Context)
    if ($Installation -isnot [Collections.IDictionary] -or $Installation['id'] -isnot [long] -or
        ([string] $Installation['id']) -cne $Context.installationId -or $Installation['app_id'] -isnot [long] -or
        ([string] $Installation['app_id']) -cne $Context.appId -or
        $Installation['target_type'] -isnot [string] -or $Installation['target_type'] -cne 'Organization' -or
        $Installation['account'] -isnot [Collections.IDictionary] -or $Installation['account']['type'] -isnot [string] -or
        $Installation['account']['type'] -cne 'Organization' -or $Installation['account']['login'] -isnot [string] -or
        $Installation['account']['login'].ToLowerInvariant() -cne $Context.organization -or
        -not $Installation.Contains('suspended_at') -or $null -ne $Installation['suspended_at'] -or
        -not $Installation.Contains('suspended_by') -or $null -ne $Installation['suspended_by']) {
        throw 'Already-invalid recovery requires the exact original active, unsuspended organization installation of the same App.'
    }
}

# security-check: development-control-append
function Write-DevelopmentControlJournal {
    param(
        [string] $ApiUrl, [string] $Repository, [string] $ReadToken, [string] $WriterToken,
        [string] $ExpectedHead, [string] $ExpectedControlBlobSha, [string] $Json
    )
    $root = "$($ApiUrl.TrimEnd('/'))/repos/$Repository"
    $request = @{
        Headers = @{ Authorization = "Bearer $ReadToken"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
        Method = 'GET'; MaximumRedirection = 0; MaximumRetryCount = 0; TimeoutSec = 60; SkipHttpErrorCheck = $true
    }
    $commit = Invoke-DevelopmentControlRead -Uri "$root/git/commits/$ExpectedHead" -Request $request
    if ($commit -isnot [Collections.IDictionary] -or $commit['sha'] -isnot [string] -or $commit['sha'] -cne $ExpectedHead -or
        $commit['tree'] -isnot [Collections.IDictionary] -or $commit['tree']['sha'] -isnot [string] -or
        $commit['tree']['sha'] -cnotmatch '^[a-f0-9]{40}\z') { throw 'Invalid canonical parent commit tree for journal append.' }
    $tree = Invoke-DevelopmentControlWrite -Uri "$root/git/trees" -Method POST -WriterToken $WriterToken -ExpectedStatus 201 -Value @{
        base_tree = $commit.tree.sha
        tree = @(@{ path = 'development-token-journal.json'; mode = '100644'; type = 'blob'; content = $Json })
    }
    if ($tree -isnot [Collections.IDictionary] -or $tree['sha'] -isnot [string] -or $tree['sha'] -cnotmatch '^[a-f0-9]{40}\z' -or
        (Get-DevelopmentControlFileSha -Tree $tree) -cne $ExpectedControlBlobSha) {
        throw 'Journal append changed the protected authorization blob or returned an invalid tree.'
    }
    $null = Get-DevelopmentControlFileSha -Tree $tree -Path 'development-token-journal.json'
    $message = 'Append protected development token lifecycle'
    $created = Invoke-DevelopmentControlWrite -Uri "$root/git/commits" -Method POST -WriterToken $WriterToken -ExpectedStatus 201 -Value @{
        message = $message; tree = $tree.sha; parents = @($ExpectedHead)
    }
    if ($created -isnot [Collections.IDictionary] -or $created['sha'] -isnot [string] -or $created['sha'] -cnotmatch '^[a-f0-9]{40}\z' -or
        $created['sha'] -ceq $ExpectedHead -or $created['tree'] -isnot [Collections.IDictionary] -or
        $created['tree']['sha'] -isnot [string] -or $created['tree']['sha'] -cne $tree.sha -or
        $created['parents'] -isnot [Collections.IList] -or $created['parents'].Count -ne 1 -or
        $created['parents'][0] -isnot [Collections.IDictionary] -or $created['parents'][0]['sha'] -isnot [string] -or
        $created['parents'][0]['sha'] -cne $ExpectedHead) {
        throw 'Journal append requires one new direct child of the exact acknowledged head.'
    }
    $fresh = Read-DevelopmentControl -ApiUrl $ApiUrl -Repository $Repository -ReadToken $ReadToken
    if ($fresh.ControlRevision -cne $ExpectedHead -or $fresh.ControlBlobSha -cne $ExpectedControlBlobSha) {
        throw 'Protected control changed before non-force journal append; foreign heads are not accepted.'
    }
    $updated = Invoke-DevelopmentControlWrite -Uri "$root/git/refs/heads/platform-control" -Method PATCH -WriterToken $WriterToken -ExpectedStatus 200 -Value @{
        sha = $created.sha; force = $false
    }
    if ((Get-DevelopmentControlRevision -Value $updated -ExpectedRef refs/heads/platform-control) -cne $created.sha) {
        throw 'Protected journal append did not acknowledge the exact new head.'
    }
    $after = Read-DevelopmentControl -ApiUrl $ApiUrl -Repository $Repository -ReadToken $ReadToken
    if ($after.ControlRevision -cne $created.sha -or $after.ControlBlobSha -cne $ExpectedControlBlobSha -or
        $after.TokenJournal -cne $Json) { throw 'Protected journal immutable readback differs from the acknowledged append.' }
    return @{
        ControlRevision = $after.ControlRevision; ControlBlobSha = $after.ControlBlobSha
        TokenJournalPhase = $after.TokenJournalPhase
    }
}

Export-ModuleMember -Function Read-DevelopmentControl, Write-DevelopmentTokenEvent, Complete-DevelopmentTokenRetirement
