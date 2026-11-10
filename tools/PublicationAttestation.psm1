#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PublicationWitness.psm1')

# security-check: platform-attestation-verification
function Invoke-PlatformArtifactAttestation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $BundlePath,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][string] $SignerWorkflow,
        [Parameter(Mandatory)][string] $PredicateType
    )

    $saved = @{}
    foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_HOST', 'GH_CONFIG_DIR')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        [Environment]::SetEnvironmentVariable($name, $null)
    }
    try {
        $env:GH_CONFIG_DIR = Join-Path (Split-Path (Resolve-Path -LiteralPath $BundlePath).Path -Parent) ".gh-attestation-$([guid]::NewGuid().ToString('N'))"
        # Exact SAN pins the workflow and tag; gh forbids combining it with --signer-workflow.
        $output = & gh attestation verify $ArchivePath --bundle $BundlePath --hostname github.com --repo $Repository `
            --source-ref "refs/tags/$Tag" --source-digest $Commit --signer-digest $Commit `
            --cert-identity "https://github.com/${SignerWorkflow}@refs/tags/$Tag" --cert-oidc-issuer https://token.actions.githubusercontent.com `
            --deny-self-hosted-runners --predicate-type $PredicateType --format json
        if ($LASTEXITCODE -ne 0) { throw 'Publication attestation signature or pinned signer policy verification failed.' }
        try { $document = [Text.Json.JsonDocument]::Parse(($output -join "`n")) }
        catch [Text.Json.JsonException] { throw 'Invalid attestation verification JSON output.' }
        try {
            $root = $document.RootElement
            if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $root.GetArrayLength() -ne 1) {
                throw 'Attestation verification must return exactly one verified statement.'
            }
            $result = $root[0]
            $verification = [Text.Json.JsonElement]::new()
            $statement = [Text.Json.JsonElement]::new()
            if ($result.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                -not $result.TryGetProperty('verificationResult', [ref] $verification) -or
                $verification.ValueKind -ne [Text.Json.JsonValueKind]::Object -or
                -not $verification.TryGetProperty('statement', [ref] $statement) -or
                $statement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
                throw 'Attestation verification returned no verified statement object.'
            }
            $type = [Text.Json.JsonElement]::new()
            if (-not $statement.TryGetProperty('_type', [ref] $type) -or
                $type.ValueKind -ne [Text.Json.JsonValueKind]::String -or $type.GetString() -cne 'https://in-toto.io/Statement/v1') {
                throw 'Invalid attestation statement schema.'
            }
            if (-not $statement.TryGetProperty('predicateType', [ref] $type) -or
                $type.ValueKind -ne [Text.Json.JsonValueKind]::String -or $type.GetString() -cne $PredicateType) {
                throw 'Invalid attestation predicate type.'
            }
            $subjects = [Text.Json.JsonElement]::new()
            if (-not $statement.TryGetProperty('subject', [ref] $subjects) -or
                $subjects.ValueKind -ne [Text.Json.JsonValueKind]::Array -or $subjects.GetArrayLength() -ne 1) {
                throw 'Invalid attestation archive subject inventory.'
            }
            $subject = $subjects[0].GetRawText() | ConvertFrom-Json -AsHashtable -NoEnumerate
            $digest = (Get-FileHash -LiteralPath $ArchivePath -Algorithm SHA256).Hash.ToLowerInvariant()
            if ($digest -ne $ArchiveSha256) { throw 'Archive bytes do not match the pinned archive digest.' }
            if ($subject -isnot [Collections.IDictionary] -or $subject['name'] -isnot [string] -or
                $subject['name'] -cne "platform-$Tag.zip" -or $subject['digest'] -isnot [Collections.IDictionary] -or
                $subject['digest']['sha256'] -isnot [string] -or $subject['digest']['sha256'] -cne $digest) {
                throw 'Invalid attestation archive subject name or digest.'
            }
            return $statement.Clone()
        }
        finally { $document.Dispose() }
    }
    finally {
        foreach ($name in $saved.get_Keys()) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}

# security-check: platform-attested-publication-predicate
function Get-PlatformPublicationAttestation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $BundlePath,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][long] $PublisherAppId,
        [Parameter(Mandatory)][string] $SignerWorkflow
    )

    $statement = Invoke-PlatformArtifactAttestation -ArchivePath $ArchivePath -ArchiveSha256 $ArchiveSha256 -BundlePath $BundlePath -Repository $Repository `
        -Tag $Tag -Commit $Commit -SignerWorkflow $SignerWorkflow `
        -PredicateType 'https://github.com/msucharda/devsecops-platform/attestations/source-publication/v1'
    $root = [Text.Json.JsonElement]::new()
    if (-not $statement.TryGetProperty('predicate', [ref] $root) -or $root.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
        throw 'Publication attestation predicate must be an object.'
    }
    $fields = @('schemaVersion', 'kind', 'phase', 'repository', 'ref', 'commit', 'publisherAppId', 'checkId', 'context', 'externalId', 'receiptSha256')
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($property in $root.EnumerateObject()) {
        if ($fields -cnotcontains $property.Name -or -not $seen.Add($property.Name)) {
            throw 'Invalid publication attestation predicate fields.'
        }
    }
    if ($seen.Count -ne $fields.Count) { throw 'Missing publication attestation predicate fields.' }
    $predicate = $root.GetRawText() | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($predicate['repository'] -isnot [string] -or $predicate['repository'] -cne $Repository) {
        throw 'Invalid publication attestation predicate repository.'
    }
    $summary = [ordered]@{}
    foreach ($field in @('schemaVersion', 'kind', 'phase', 'ref', 'commit', 'receiptSha256')) {
        $summary[$field] = $predicate[$field]
    }
    # This reconstructs the signed historical assertion, not a current check-runs API response.
    $snapshot = @{
        app = @{ id = $predicate['publisherAppId'] }; id = $predicate['checkId']
        name = $predicate['context']; status = 'completed'; conclusion = 'success'; head_sha = $predicate['commit']
        external_id = $predicate['externalId']; output = @{ summary = ($summary | ConvertTo-Json -Compress) }
    }
    $null = Assert-PlatformPublicationWitness -Check $snapshot -PublisherAppId $PublisherAppId -Commit $Commit
    return $predicate
}

function Get-PlatformBuildProvenance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][ValidatePattern('\A[0-9a-f]{64}\z')][string] $ArchiveSha256,
        [Parameter(Mandatory)][string] $BundlePath,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][string] $SignerWorkflow
    )

    Invoke-PlatformArtifactAttestation -ArchivePath $ArchivePath -ArchiveSha256 $ArchiveSha256 -BundlePath $BundlePath -Repository $Repository `
        -Tag $Tag -Commit $Commit -SignerWorkflow $SignerWorkflow -PredicateType 'https://slsa.dev/provenance/v1'
}

# security-check: platform-retained-attestation-assets
function Get-PlatformReleaseEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Release,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $Directory,
        [ValidateSet('Provenance', 'Publication')][ValidateNotNullOrEmpty()][string[]] $Kind = @('Provenance', 'Publication'),
        [Collections.IDictionary] $Headers = @{}
    )

    if ($Release['tag_name'] -isnot [string] -or $Release['tag_name'] -cne $Tag -or
        $Release['assets'] -isnot [Collections.IList]) {
        throw 'Invalid retained attestation release identity or asset inventory.'
    }
    $downloadHeaders = @{ Accept = 'application/octet-stream'; 'X-GitHub-Api-Version' = '2026-03-10' }
    foreach ($key in $Headers.get_Keys()) { $downloadHeaders[$key] = $Headers[$key] }
    $downloadHeaders.Accept = 'application/octet-stream'
    $paths = [ordered]@{}
    foreach ($itemKind in $Kind) {
        $name = "platform-$Tag.$($itemKind.ToLowerInvariant()).sigstore.json"
        $assets = @($Release['assets'] | Where-Object { $_ -is [Collections.IDictionary] -and $_['name'] -ieq $name })
        if ($assets.Count -ne 1) { throw "Release requires exactly one retained $itemKind attestation asset." }
        $asset = $assets[0]
        if ($asset['name'] -isnot [string] -or $asset['name'] -cne $name -or
            ($asset['id'] -isnot [int] -and $asset['id'] -isnot [long]) -or $asset['id'] -le 0 -or
            $asset['state'] -isnot [string] -or $asset['state'] -cne 'uploaded' -or
            $asset['digest'] -isnot [string] -or $asset['digest'] -cnotmatch '\Asha256:[0-9a-f]{64}\z') {
            throw "Invalid retained $itemKind attestation asset metadata."
        }
        $path = Join-Path $Directory "$($itemKind.ToLowerInvariant()).sigstore.json"
        $null = Invoke-WebRequest -Uri "https://api.github.com/repos/$Repository/releases/assets/$($asset['id'])" `
            -Headers $downloadHeaders -OutFile $path
        if ((Get-Item -LiteralPath $path).Length -gt 16MB) { throw 'Retained attestation bundle exceeds 16 MiB.' }
        $digest = 'sha256:' + (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        if ($digest -cne $asset['digest']) { throw "Retained $itemKind attestation asset digest mismatch." }
        $paths[$itemKind] = $path
    }
    return $paths
}

Export-ModuleMember -Function Get-PlatformPublicationAttestation, Get-PlatformBuildProvenance, Get-PlatformReleaseEvidence
