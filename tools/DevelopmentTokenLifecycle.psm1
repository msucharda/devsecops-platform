#Requires -Version 7.4
Set-StrictMode -Version Latest
$script:developmentContextFields = @(
    'apiUrl', 'repository', 'referenceOwner', 'organization', 'appId', 'installationId', 'runId', 'runAttempt',
    'workflowRevision', 'baselineRevision', 'candidateRevision', 'authorizationRevision', 'authorizationBlob',
    'snapshotSha256', 'publicKeyArtifactId', 'publicKeyArtifactDigest', 'publicKeySha256'
)

function Get-DevelopmentProtocolDigest {
    param([string] $Value)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Value))).ToLowerInvariant()
}

# security-check: development-protocol-unique-fields
function Assert-DevelopmentProtocolFieldUniqueness {
    param([Text.Json.JsonElement] $Element)
    if ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Object) {
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $Element.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { throw 'Development protocol contains duplicate fields.' }
            Assert-DevelopmentProtocolFieldUniqueness -Element $property.Value
        }
    }
    elseif ($Element.ValueKind -eq [Text.Json.JsonValueKind]::Array) {
        foreach ($value in $Element.EnumerateArray()) { Assert-DevelopmentProtocolFieldUniqueness -Element $value }
    }
}

# security-check: development-protocol-object
function Read-DevelopmentProtocolObject {
    param([string] $Json, [string[]] $Fields)
    if ([Text.Encoding]::UTF8.GetByteCount($Json) -gt 1048576) { throw 'Development protocol object exceeds the size bound.' }
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        $root = $document.RootElement
        Assert-DevelopmentProtocolFieldUniqueness -Element $root
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Development protocol value must be an object.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $root.EnumerateObject()) {
            if ($property.Name -cnotin $Fields -or -not $seen.Add($property.Name)) {
                throw 'Development protocol object contains unknown or duplicate fields.'
            }
        }
        if ($seen.Count -ne $Fields.Count) { throw 'Development protocol object is incomplete.' }
        return ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate
    }
    finally { $document.Dispose() }
}

# security-check: development-token-context
function New-DevelopmentTokenContext {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs only a canonical in-memory context.')]
    [CmdletBinding()]
    param([Parameter(Mandatory)][Collections.IDictionary] $Value)
    $valueJson = ConvertTo-Json -InputObject $Value -Depth 10 -Compress
    $record = Read-DevelopmentProtocolObject -Json $valueJson -Fields $script:developmentContextFields
    $ordered = [ordered]@{}
    foreach ($field in $script:developmentContextFields) {
        if ($record[$field] -isnot [string]) { throw "Development token context requires string '$field'." }
        $ordered[$field] = $record[$field]
    }
    if ($record.apiUrl -cnotmatch '^https://[a-z0-9][a-z0-9.-]*[a-z0-9]\z') { throw 'Invalid development token API origin.' }
    if ($record.repository -cnotmatch '^[a-z0-9][a-z0-9-]*/[A-Za-z0-9_.-]+\z') { throw 'Invalid development token repository.' }
    foreach ($field in @('referenceOwner', 'organization')) {
        if ($record[$field] -cnotmatch '^[a-z0-9][a-z0-9-]*\z') { throw "Invalid development token '$field'." }
    }
    if ($record.repository.Split('/')[0] -cne $record.referenceOwner -or $record.organization -ceq $record.referenceOwner) {
        throw 'Development token must target a non-reference organization of this reference repository.'
    }
    foreach ($field in @('appId', 'installationId', 'runId', 'publicKeyArtifactId')) {
        if ($record[$field] -cnotmatch '^[1-9][0-9]{0,18}\z') { throw "Invalid development token '$field'." }
    }
    if ($record.runAttempt -cne '1') { throw 'Development token issuance requires fresh run attempt 1.' }
    foreach ($field in @('workflowRevision', 'baselineRevision', 'candidateRevision', 'authorizationRevision', 'authorizationBlob')) {
        if ($record[$field] -cnotmatch '^[a-f0-9]{40}\z') { throw "Invalid development token '$field'." }
    }
    foreach ($field in @('snapshotSha256', 'publicKeyArtifactDigest', 'publicKeySha256')) {
        if ($record[$field] -cnotmatch '^[a-f0-9]{64}\z') { throw "Invalid development token '$field'." }
    }
    return ConvertTo-Json -InputObject $ordered -Compress
}

function New-DevelopmentTokenJournal {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs only an empty in-memory journal.')]
    [CmdletBinding()]
    param()
    return '{"version":1,"records":[]}'
}

# security-check: development-token-journal
function Read-DevelopmentTokenJournal {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Json)
    $journal = Read-DevelopmentProtocolObject -Json $Json -Fields @('version', 'records')
    if ($journal.version -isnot [long] -or $journal.version -ne 1 -or $journal.records -isnot [Collections.IList] -or
        $journal.records.Count -gt 256) { throw 'Unsupported development token journal schema or record count.' }
    $fields = @(
        'event', 'context', 'previousHead', 'envelope', 'issuanceProbeStatus', 'revokeStatus', 'negativeStatus',
        'retirementRunId', 'proofKind', 'activeInstallationId'
    )
    $phase = 'clear'
    $lastContext = ''
    $envelope = ''
    $contextDigest = ''
    $repository = ''
    $origin = ''
    $seenRuns = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($record in $journal.records) {
        $entry = Read-DevelopmentProtocolObject -Json (ConvertTo-Json $record -Depth 10 -Compress) -Fields $fields
        foreach ($field in @('event', 'context', 'previousHead', 'envelope', 'retirementRunId', 'proofKind', 'activeInstallationId')) {
            if ($entry[$field] -isnot [string]) { throw "Development token journal requires string '$field'." }
        }
        if ($entry.previousHead -cnotmatch '^[a-f0-9]{40}\z') { throw 'Invalid development token journal parent.' }
        if ($entry.revokeStatus -isnot [long] -or $entry.negativeStatus -isnot [long] -or
            $entry.issuanceProbeStatus -isnot [long]) { throw 'Invalid token lifecycle status types.' }
        $contextValue = Read-DevelopmentProtocolObject -Json $entry.context -Fields $script:developmentContextFields
        $canonical = New-DevelopmentTokenContext -Value $contextValue
        if ($canonical -cne $entry.context) { throw 'Development token journal requires the canonical immutable context.' }
        if ($repository -and ($repository -cne $contextValue.repository -or $origin -cne $contextValue.apiUrl)) {
            throw 'Development token journal origin or repository changed.'
        }
        $repository = $contextValue.repository
        $origin = $contextValue.apiUrl
        if ($entry.event -ceq 'pending') {
            if ($phase -cnotin @('clear', 'retired') -or -not $seenRuns.Add($contextValue.runId)) {
                throw 'Unfinished or repeated issuance blocks another development candidate.'
            }
            $lastContext = $entry.context
            $contextDigest = Get-DevelopmentProtocolDigest -Value $lastContext
            $envelope = ''
        }
        elseif ($entry.event -ceq 'issued') {
            if ($phase -cne 'pending' -or $entry.context -cne $lastContext -or $entry.issuanceProbeStatus -ne 200) {
                throw 'Issued token requires matching pending intent and observed GET /installation/repositories 200.'
            }
            $null = Read-DevelopmentTokenEnvelope -Envelope $entry.envelope -ContextSha256 $contextDigest
            $envelope = $entry.envelope
        }
        elseif ($entry.event -ceq 'retired') {
            if ($phase -cne 'issued' -or $entry.context -cne $lastContext -or
                $entry.negativeStatus -ne 401 -or
                $entry.retirementRunId -cnotmatch '^[1-9][0-9]{0,18}\z') {
                throw 'Retirement requires the exact known issuance and direct negative 401.'
            }
            if ($entry.proofKind -ceq 'revoked') {
                if ($entry.revokeStatus -ne 204 -or $entry.activeInstallationId -cne '') {
                    throw 'Revoked retirement requires observed DELETE 204 and direct GET 401.'
                }
            }
            elseif ($entry.proofKind -ceq 'already-invalid') {
                if ($entry.revokeStatus -ne 0 -or $entry.activeInstallationId -cne $contextValue.installationId) {
                    throw 'Already-invalid retirement requires unknown prior revoke outcome and the exact active installation.'
                }
            }
            else { throw 'Unsupported development token retirement proof kind.' }
        }
        else { throw 'Unknown development token journal event.' }
        if ($entry.event -cne 'issued' -and $entry.envelope -cne '') { throw 'Only issued records may contain an encrypted token.' }
        if ($entry.event -cne 'retired' -and
            ($entry.revokeStatus -ne 0 -or $entry.negativeStatus -ne 0 -or $entry.retirementRunId -cne '' -or
                $entry.proofKind -cne '' -or $entry.activeInstallationId -cne '')) {
            throw 'Only retired records may contain retirement evidence.'
        }
        if ($entry.event -cne 'issued' -and $entry.issuanceProbeStatus -ne 0) { throw 'Only issued records may contain issuance evidence.' }
        $phase = $entry.event
    }
    return @{
        Phase = $phase; Context = $lastContext; ContextSha256 = $contextDigest
        Envelope = $envelope; Records = $journal.records
    }
}

# security-check: development-token-capacity
function Add-DevelopmentTokenJournalEvent {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Json,
        [Parameter(Mandatory)][Alias('Event')][ValidateSet('pending', 'issued', 'retired')][string] $JournalEvent,
        [Parameter(Mandatory)][string] $Context,
        [Parameter(Mandatory)][string] $PreviousHead,
        [string] $Envelope = '',
        [int] $IssuanceProbeStatusCode = 0,
        [int] $RevokeStatusCode = 0,
        [int] $NegativeStatusCode = 0,
        [string] $RetirementRunId = '',
        [string] $ProofKind = '',
        [string] $ActiveInstallationId = ''
    )
    $before = Read-DevelopmentTokenJournal -Json $Json
    $record = [ordered]@{
        event = $JournalEvent; context = $Context; previousHead = $PreviousHead; envelope = $Envelope
        issuanceProbeStatus = $IssuanceProbeStatusCode; revokeStatus = $RevokeStatusCode; negativeStatus = $NegativeStatusCode
        retirementRunId = $RetirementRunId; proofKind = $ProofKind; activeInstallationId = $ActiveInstallationId
    }
    $after = ConvertTo-Json -Depth 10 -Compress -InputObject ([ordered]@{
        version = 1; records = @($before.Records) + @($record)
    })
    if ($JournalEvent -ceq 'pending') {
        # Reserve both remaining records and the maximum escaped envelope before minting.
        if ($before.Records.Count + 3 -gt 256 -or
            [Text.Encoding]::UTF8.GetByteCount($after) + 4 * $Context.Length + 2 * 16384 + 4096 -gt 1048576) {
            throw 'Insufficient protected journal capacity before mint; no new issuance is permitted.'
        }
    }
    $null = Read-DevelopmentTokenJournal -Json $after
    return $after
}

# security-check: development-token-key
function Get-DevelopmentRecoveryKey {
    param([string] $RecoveryKey, [string] $ContextSha256)
    if ($ContextSha256 -cnotmatch '^[a-f0-9]{64}\z') { throw 'A canonical immutable context digest is required.' }
    $bytes = [Convert]::FromBase64String($RecoveryKey)
    if ($bytes.Length -ne 32 -or [Convert]::ToBase64String($bytes) -cne $RecoveryKey) {
        [Array]::Clear($bytes)
        throw 'A canonical 32-byte purpose-only recovery key is required.'
    }
    return ,$bytes
}

function Get-DevelopmentRecoveryKeyId {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RecoveryKey)
    $bytes = Get-DevelopmentRecoveryKey -RecoveryKey $RecoveryKey -ContextSha256 ('0' * 64)
    try { return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant() }
    finally { [Array]::Clear($bytes) }
}

# security-check: development-token-value
function Assert-DevelopmentLeafToken {
    param([string] $Token)
    if ($Token -cnotmatch '^[!-~]{1,4096}\z') { throw 'A bounded ASCII installation token is required.' }
}

function Protect-DevelopmentLeafToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Token,
        [Parameter(Mandatory)][string] $RecoveryKey,
        [Parameter(Mandatory)][string] $ContextSha256
    )
    Assert-DevelopmentLeafToken -Token $Token
    $key = Get-DevelopmentRecoveryKey -RecoveryKey $RecoveryKey -ContextSha256 $ContextSha256
    $plain = [Text.Encoding]::UTF8.GetBytes($Token)
    $cipher = [byte[]]::new($plain.Length)
    $nonce = [Security.Cryptography.RandomNumberGenerator]::GetBytes(12)
    $tag = [byte[]]::new(16)
    $aes = [Security.Cryptography.AesGcm]::new($key, 16)
    try {
        $aes.Encrypt($nonce, $plain, $cipher, $tag, [Text.Encoding]::ASCII.GetBytes($ContextSha256))
        return ConvertTo-Json -Compress -InputObject ([ordered]@{
            version = 1; contextSha256 = $ContextSha256
            keySha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($key)).ToLowerInvariant()
            tokenSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($plain)).ToLowerInvariant()
            nonce = [Convert]::ToBase64String($nonce)
            ciphertext = [Convert]::ToBase64String($cipher)
            tag = [Convert]::ToBase64String($tag)
        })
    }
    finally {
        $aes.Dispose()
        [Array]::Clear($key)
        [Array]::Clear($plain)
    }
}

# security-check: development-token-envelope
function Read-DevelopmentTokenEnvelope {
    param([string] $Envelope, [string] $ContextSha256, [byte[]] $Key)
    if ($Envelope.Length -gt 16384) { throw 'Encrypted token envelope exceeds the size bound.' }
    $document = [Text.Json.JsonDocument]::Parse($Envelope)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Encrypted token envelope must be an object.' }
        $fields = @('version', 'contextSha256', 'keySha256', 'tokenSha256', 'nonce', 'ciphertext', 'tag')
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($property in $root.EnumerateObject()) {
            if ($property.Name -cnotin $fields -or -not $seen.Add($property.Name)) {
                throw 'Encrypted token envelope contains unknown or duplicate fields.'
            }
        }
        if ($seen.Count -ne $fields.Count) { throw 'Encrypted token envelope is incomplete.' }
        if ($root.GetProperty('version').GetRawText() -cne '1') { throw 'Unsupported encrypted token envelope version.' }
        foreach ($field in $fields | Where-Object { $_ -cne 'version' }) {
            if ($root.GetProperty($field).ValueKind -ne [Text.Json.JsonValueKind]::String) {
                throw 'Encrypted token envelope fields must be strings.'
            }
        }
        $value = ConvertFrom-Json -InputObject $Envelope -AsHashtable -NoEnumerate
        if ($value.contextSha256 -cne $ContextSha256) { throw 'Encrypted token context does not match.' }
        if ($value.keySha256 -cnotmatch '^[a-f0-9]{64}\z') { throw 'Invalid recovery key digest.' }
        if ($null -ne $Key) {
            $keyDigest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($Key)).ToLowerInvariant()
            if ($value.keySha256 -cne $keyDigest) { throw 'The purpose-only recovery key does not match.' }
        }
        if ($value.tokenSha256 -cnotmatch '^[a-f0-9]{64}\z') { throw 'Invalid encrypted token digest.' }
        $decoded = @{}
        foreach ($field in @('nonce', 'ciphertext', 'tag')) {
            $decoded[$field] = [Convert]::FromBase64String($value[$field])
            if ([Convert]::ToBase64String($decoded[$field]) -cne $value[$field]) {
                throw 'Encrypted token fields must use canonical base64.'
            }
        }
        if ($decoded.nonce.Length -ne 12 -or $decoded.tag.Length -ne 16 -or
            $decoded.ciphertext.Length -lt 1 -or $decoded.ciphertext.Length -gt 4096) {
            throw 'Invalid encrypted token field lengths.'
        }
        $decoded.TokenSha256 = $value.tokenSha256
        return $decoded
    }
    finally { $document.Dispose() }
}

function Unprotect-DevelopmentLeafToken {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Envelope,
        [Parameter(Mandatory)][string] $RecoveryKey,
        [Parameter(Mandatory)][string] $ContextSha256
    )
    $key = Get-DevelopmentRecoveryKey -RecoveryKey $RecoveryKey -ContextSha256 $ContextSha256
    $plain = $null
    $aes = $null
    try {
        $value = Read-DevelopmentTokenEnvelope -Envelope $Envelope -ContextSha256 $ContextSha256 -Key $key
        $plain = [byte[]]::new($value.ciphertext.Length)
        $aes = [Security.Cryptography.AesGcm]::new($key, 16)
        $aes.Decrypt($value.nonce, $value.ciphertext, $value.tag, $plain, [Text.Encoding]::ASCII.GetBytes($ContextSha256))
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($plain)).ToLowerInvariant()
        Assert-DevelopmentRecoveredTokenDigest -Actual $digest -Expected $value.TokenSha256
        $token = [Text.UTF8Encoding]::new($false, $true).GetString($plain)
        Assert-DevelopmentLeafToken -Token $token
        return $token
    }
    finally {
        if ($aes) { $aes.Dispose() }
        [Array]::Clear($key)
        if ($null -ne $plain) { [Array]::Clear($plain) }
    }
}

# security-check: development-token-recovered-digest
function Assert-DevelopmentRecoveredTokenDigest {
    param([string] $Actual, [string] $Expected)
    if ($Actual -cne $Expected) { throw 'Recovered installation token digest does not match.' }
}

Export-ModuleMember -Function Protect-DevelopmentLeafToken, Unprotect-DevelopmentLeafToken,
    New-DevelopmentTokenContext, New-DevelopmentTokenJournal, Read-DevelopmentTokenJournal, Add-DevelopmentTokenJournalEvent,
    Get-DevelopmentRecoveryKeyId
