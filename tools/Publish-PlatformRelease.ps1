#Requires -Version 7.4
<#
.SYNOPSIS
Publishes the attested platform ZIP as the GitHub release of an exact SemVer tag.
.DESCRIPTION
The release is created as a draft, receives exactly one asset whose GitHub digest matches the local file,
and is published only then. A rerun after any interruption resumes from the draft or confirms the published
release; it never changes a published release. Tags vMAJOR.MINOR.PATCH-rc.N publish prereleases that never
become the latest release.
REST API version 2026-03-10:
https://docs.github.com/en/enterprise-cloud@latest/rest/releases/releases
https://docs.github.com/en/enterprise-cloud@latest/rest/releases/assets
https://docs.github.com/en/enterprise-cloud@latest/rest/git/refs#get-a-reference
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][AllowEmptyString()][string] $Tag,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}$')][string] $Commit,
    [Parameter(Mandatory)][string] $AssetPath,
    [long] $PublisherAppId,
    [string] $ProvenanceBundlePath,
    [string] $PublicationBundlePath,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [string] $Token = $env:GITHUB_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-ReleaseField {
    param([AllowNull()] $Object, [Parameter(Mandatory)][string] $Name)
    if ($Object -is [Collections.IDictionary]) { if ($Object.Contains($Name)) { return $Object[$Name] }; return $null }
    if ($null -ne $Object -and $Object.PSObject.Properties[$Name]) { return $Object.$Name }
    return $null
}

function Invoke-ReleaseApi {
    param(
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $Uri,
        $Body,
        [string] $ContentType = 'application/json',
        [int[]] $Accept = @(200),
        [switch] $List
    )
    $request = @{ Method = $Method; Uri = $Uri; Headers = $headers; SkipHttpErrorCheck = $true }
    if ($null -ne $Body) {
        # Assign inside the branches: an if expression enumerates a byte[] into object[], which Invoke-WebRequest
        # sends as the text of decimal byte values instead of the binary file.
        if ($Body -is [byte[]]) { $request.Body = $Body } else { $request.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress }
        $request.ContentType = $ContentType
    }
    $response = Invoke-WebRequest @request
    $status = [int] $response.StatusCode
    if ($status -notin $Accept) {
        throw "GitHub API $Method $(([uri] $Uri).AbsolutePath) returned HTTP $status`: $($response.Content)"
    }
    $text = [string] $response.Content
    if ($List) {
        if ($text -cnotmatch '^\s*\[') { throw "GitHub API $Method $(([uri] $Uri).AbsolutePath) did not return a JSON array." }
        return , [object[]] @(ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100 -NoEnumerate | ForEach-Object { $_ })
    }
    if ([string]::IsNullOrEmpty($text)) { return $null }
    return , (ConvertFrom-Json -InputObject ([string] $response.Content) -AsHashtable -Depth 100)
}

# security-check: release-tag-commit
function Test-ReleaseTagCommit {
    # The tag must still point to the commit that was built and attested; a moved tag must not publish.
    param([AllowNull()] $Reference, [Parameter(Mandatory)][string] $Expected)
    $object = Get-ReleaseField $Reference 'object'
    if ((Get-ReleaseField $object 'type') -cne 'commit') { return $false }
    return (Get-ReleaseField $object 'sha') -ceq $Expected
}

# security-check: release-asset-digest
function Test-ReleaseAsset {
    # Only a completely uploaded asset with the exact name and the GitHub-computed digest of the local file counts.
    param([AllowNull()] $Asset, [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Digest)
    if ((Get-ReleaseField $Asset 'name') -cne $Name) { return $false }
    if ((Get-ReleaseField $Asset 'state') -cne 'uploaded') { return $false }
    return (Get-ReleaseField $Asset 'digest') -ceq $Digest
}

# security-check: release-asset-inventory
function Test-ReleaseAssetInventory {
    param([AllowNull()] $Release, [Collections.IDictionary] $Expected)
    $assets = $null
    if ($Release -is [Collections.IDictionary]) { $assets = $Release['assets'] }
    elseif ($null -ne $Release -and $Release.PSObject.Properties['assets']) { $assets = $Release.assets }
    if ($assets -isnot [Collections.IList] -or $assets.Count -ne $Expected.Count) { return $false }
    foreach ($key in $Expected.get_Keys()) {
        $matchingAssets = @($assets | Where-Object { (Get-ReleaseField $_ 'name') -ceq $key })
        if ($matchingAssets.Count -ne 1) { return $false }
        if (-not (Test-ReleaseAsset -Asset $matchingAssets[0] -Name $key -Digest $Expected[$key])) { return $false }
    }
    return $true
}

# security-check: release-published-state
function Test-PublishedRelease {
    param([AllowNull()] $Release, [Parameter(Mandatory)][string] $Tag, [Parameter(Mandatory)][bool] $Prerelease,
        [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Digest,
        [Collections.IDictionary] $Evidence = @{})
    if ((Get-ReleaseField $Release 'tag_name') -cne $Tag) { return $false }
    $draft = Get-ReleaseField $Release 'draft'
    if ($draft -isnot [bool] -or $draft) { return $false }
    $isPrerelease = Get-ReleaseField $Release 'prerelease'
    if ($isPrerelease -isnot [bool] -or $isPrerelease -ne $Prerelease) { return $false }
    $expected = [ordered]@{ $Name = $Digest }
    foreach ($key in $Evidence.get_Keys()) { $expected[$key] = $Evidence[$key] }
    return Test-ReleaseAssetInventory -Release $Release -Expected $expected
}

# security-check: release-retained-publication-binding
function Assert-RetainedReleaseEvidence {
    param(
        [Collections.IDictionary] $Release,
        [Collections.IDictionary] $Predicate,
        [string] $Directory,
        [long] $ExpectedReleaseId,
        [switch] $RequireComplete,
        [switch] $RequireDraft
    )
    if (($Release['id'] -isnot [int] -and $Release['id'] -isnot [long]) -or $Release['id'] -le 0 -or
        ($ExpectedReleaseId -gt 0 -and $Release['id'] -ne $ExpectedReleaseId)) {
        throw 'Release identity changed before finalization; nothing is finalized.'
    }
    if ($RequireDraft -and ($Release['draft'] -isnot [bool] -or -not $Release['draft'])) {
        throw 'Release draft state changed before finalization; retry to verify the existing release without modifying it.'
    }
    $digests = [ordered]@{}
    foreach ($kind in @('Provenance', 'Publication')) {
        $name = "platform-$Tag.$($kind.ToLowerInvariant()).sigstore.json"
        $candidates = @($Release['assets'] | Where-Object { (Get-ReleaseField $_ 'name') -ieq $name })
        if (-not $RequireComplete -and $candidates.Count -eq 0) { continue }
        if (-not $RequireComplete -and $candidates.Count -eq 1 -and (Get-ReleaseField $candidates[0] 'state') -cin @('open', 'starter')) { continue }
        $paths = Get-PlatformReleaseEvidence -Release $Release -Repository $Repository -Tag $Tag `
            -Directory $Directory -Kind $kind -Headers $headers
        $verify = @{
            ArchivePath = $AssetPath; ArchiveSha256 = $archiveSha256; BundlePath = $paths[$kind]
            Repository = $Repository; Tag = $Tag; Commit = $Commit; SignerWorkflow = "$Repository/.github/workflows/release.yml"
        }
        if ($kind -ceq 'Provenance') { $null = Get-PlatformBuildProvenance @verify }
        else {
            $remotePredicate = Get-PlatformPublicationAttestation @verify -PublisherAppId $PublisherAppId
            foreach ($key in $Predicate.get_Keys()) {
                if ($remotePredicate[$key] -cne $Predicate[$key]) {
                    throw "Retained publication predicate differs at '$key'; another operation cannot be adopted."
                }
            }
        }
        $digests[$name] = $candidates[0]['digest']
    }
    return $digests
}

# security-check: release-retained-input
function Test-RetainedReleaseInput {
    param([Collections.IDictionary] $Inputs, [string] $ApiUrl)
    $keys = @($Inputs.get_Keys())
    $retained = $keys -ccontains 'PublisherAppId' -or $keys -ccontains 'ProvenanceBundlePath' -or $keys -ccontains 'PublicationBundlePath'
    if ($retained -and ([long] $Inputs['PublisherAppId'] -le 0 -or
            [string]::IsNullOrWhiteSpace($Inputs['ProvenanceBundlePath']) -or
            [string]::IsNullOrWhiteSpace($Inputs['PublicationBundlePath']))) {
        throw 'Retained publication requires the publisher App and both attestation bundles.'
    }
    if ($retained -and $ApiUrl.TrimEnd('/') -cne 'https://api.github.com') {
        throw 'Retained platform publication requires the public github.com API.'
    }
    return $retained
}

if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$') {
    throw "Release tag '$Tag' must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N."
}
if (-not $ApiUrl -or ([uri] $ApiUrl).Scheme -cne 'https') { throw 'Publishing a release requires an HTTPS GitHub API URL.' }
if (-not $Token) { throw 'Publishing a release requires the workflow GITHUB_TOKEN.' }
if (-not (Test-Path -LiteralPath $AssetPath -PathType Leaf)) { throw "Release asset '$AssetPath' does not exist." }
$retained = Test-RetainedReleaseInput -Inputs $PSBoundParameters -ApiUrl $ApiUrl
$temporaryPath = $null
try {
$prerelease = $Tag.Contains('-rc.')
$assetName = "platform-$Tag.zip"
$assetBytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $AssetPath).Path)
$archiveSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($assetBytes)).ToLowerInvariant()
$digest = 'sha256:' + $archiveSha256
$requiredAssets = [ordered]@{ $assetName = @{ Digest = $digest; Bytes = $assetBytes; ContentType = 'application/zip' } }
$evidence = [ordered]@{}
$headers = @{
    Authorization = "Bearer $Token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2026-03-10'
}
$base = "$($ApiUrl.TrimEnd('/'))/repos/$Repository"
if ($retained) {
    Import-Module (Join-Path $PSScriptRoot 'PublicationAttestation.psm1')
    $temporaryPath = Join-Path ([IO.Path]::GetTempPath()) "platform-publication-$([guid]::NewGuid().ToString('N'))"
    $null = New-Item -ItemType Directory -Path $temporaryPath
    $AssetPath = Join-Path $temporaryPath $assetName
    [IO.File]::WriteAllBytes($AssetPath, $assetBytes)
    foreach ($kind in @('Provenance', 'Publication')) {
        $inputPath = if ($kind -ceq 'Provenance') { $ProvenanceBundlePath } else { $PublicationBundlePath }
        $bytes = [IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $inputPath).Path)
        $name = "platform-$Tag.$($kind.ToLowerInvariant()).sigstore.json"
        $path = Join-Path $temporaryPath $name
        [IO.File]::WriteAllBytes($path, $bytes)
        $verify = @{
            ArchivePath = $AssetPath; ArchiveSha256 = $archiveSha256; BundlePath = $path
            Repository = $Repository; Tag = $Tag; Commit = $Commit; SignerWorkflow = "$Repository/.github/workflows/release.yml"
        }
        if ($kind -ceq 'Provenance') { $null = Get-PlatformBuildProvenance @verify }
        else { $predicate = Get-PlatformPublicationAttestation @verify -PublisherAppId $PublisherAppId }
        $bundleDigest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
        $requiredAssets[$name] = @{ Digest = $bundleDigest; Bytes = $bytes; ContentType = 'application/json' }
        $evidence[$name] = $bundleDigest
    }
}

$reference = Invoke-ReleaseApi -Method GET -Uri "$base/git/ref/tags/$([uri]::EscapeDataString($Tag))"
$referenceObject = Get-ReleaseField $reference 'object'
if ((Get-ReleaseField $referenceObject 'type') -ceq 'tag' -and [string] (Get-ReleaseField $referenceObject 'sha') -cmatch '^[a-f0-9]{40}$') {
    # An annotated tag points to a tag object; its object must be the built commit.
    $reference = Invoke-ReleaseApi -Method GET -Uri "$base/git/tags/$(Get-ReleaseField $referenceObject 'sha')"
}
if (-not (Test-ReleaseTagCommit -Reference $reference -Expected $Commit)) {
    throw "Tag '$Tag' does not point to the built commit $Commit; it moved after the build. Release stopped."
}

# Listing includes drafts for a token with push access, so a rerun finds a draft whose creation response was lost.
$matching = [Collections.Generic.List[object]]::new()
for ($page = 1; ; $page++) {
    if ($page -gt 20) { throw 'Repository has more than 2000 releases; release lookup stopped.' }
    $releases = Invoke-ReleaseApi -Method GET -Uri "$base/releases?per_page=100&page=$page" -List
    foreach ($item in $releases) { if ((Get-ReleaseField $item 'tag_name') -ceq $Tag) { $matching.Add($item) } }
    if ($releases.Count -lt 100) { break }
}
if ($matching.Count -gt 1) { throw "Tag '$Tag' has $($matching.Count) releases; remove the extra drafts before publishing." }
$release = if ($matching.Count -eq 1) { $matching[0] } else { $null }

$existingDraft = if ($release) { Get-ReleaseField $release 'draft' } else { $true }
if ($existingDraft -isnot [bool]) { throw "Release '$Tag' has no boolean draft state; nothing is changed." }
if ($retained -and $release) {
    $existingEvidence = Assert-RetainedReleaseEvidence -Release $release -Predicate $predicate -Directory $temporaryPath -RequireComplete:(-not $existingDraft)
    foreach ($name in $existingEvidence.get_Keys()) {
        # A retry may produce new signature bytes; retain the independently verified original proof.
        $requiredAssets[$name].Digest = $existingEvidence[$name]
        $evidence[$name] = $existingEvidence[$name]
    }
}
if (-not $existingDraft) {
    if (-not (Test-PublishedRelease -Release $release -Tag $Tag -Prerelease $prerelease -Name $assetName -Digest $digest -Evidence $evidence)) {
        throw "Release '$Tag' is already published with different content; a published release is never changed. Publish a new tag."
    }
    Write-Information "Release '$Tag' is already published with asset $assetName ($digest)." -InformationAction Continue
    return [pscustomobject] @{ Tag = $Tag; Url = Get-ReleaseField $release 'html_url'; Asset = $assetName; Digest = $digest; Prerelease = $prerelease; Created = $false }
}

if (-not $release) {
    $release = Invoke-ReleaseApi -Method POST -Uri "$base/releases" -Accept @(201) -Body ([ordered] @{
        tag_name = $Tag
        target_commitish = $Commit
        name = $Tag
        body = "Platform release $Tag built from $Commit. Verify ${assetName}: gh attestation verify $assetName --repo $Repository --source-ref refs/tags/$Tag --signer-workflow $Repository/.github/workflows/release.yml"
        draft = $true
        prerelease = $prerelease
    })
}
$releaseId = Get-ReleaseField $release 'id'
if ("$releaseId" -cnotmatch '^[1-9][0-9]*$') { throw 'GitHub returned a release without a numeric id.' }

$uploaded = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($asset in @(Get-ReleaseField $release 'assets')) {
    $name = [string] (Get-ReleaseField $asset 'name')
    if ($requiredAssets.get_Keys() -ccontains $name -and -not $uploaded.Contains($name) -and
        (Test-ReleaseAsset -Asset $asset -Name $name -Digest $requiredAssets[$name].Digest)) {
        $null = $uploaded.Add($name)
        continue
    }
    # Partial uploads, stale builds and foreign files are removed so the release carries exactly the attested asset.
    $assetId = Get-ReleaseField $asset 'id'
    if ("$assetId" -cnotmatch '^[1-9][0-9]*$') { throw 'GitHub returned a release asset without a numeric id.' }
    $null = Invoke-ReleaseApi -Method DELETE -Uri "$base/releases/assets/$assetId" -Accept @(204, 404)
}
foreach ($name in $requiredAssets.get_Keys()) {
    if ($uploaded.Contains($name)) { continue }
    $uploadUrl = [string] (Get-ReleaseField $release 'upload_url')
    $uploadUrl = $uploadUrl -replace '\{\?[^}]*\}$', ''
    if (([uri] $uploadUrl).Scheme -cne 'https' -or -not $uploadUrl.EndsWith("/releases/$releaseId/assets")) {
        throw 'GitHub returned an unexpected release upload URL.'
    }
    $asset = Invoke-ReleaseApi -Method POST -Uri "${uploadUrl}?name=$([uri]::EscapeDataString($name))" -Accept @(201) `
        -ContentType $requiredAssets[$name].ContentType -Body $requiredAssets[$name].Bytes
    if (-not (Test-ReleaseAsset -Asset $asset -Name $name -Digest $requiredAssets[$name].Digest)) {
        throw "Uploaded asset $name does not report the digest $($requiredAssets[$name].Digest); release stays a draft."
    }
}

if ($retained) {
    $readback = Invoke-ReleaseApi -Method GET -Uri "$base/releases/$releaseId"
    $expected = [ordered]@{}
    foreach ($name in $requiredAssets.get_Keys()) { $expected[$name] = $requiredAssets[$name].Digest }
    if (-not (Test-ReleaseAssetInventory -Release $readback -Expected $expected)) {
        throw 'Release asset inventory changed before finalization; release stays a draft.'
    }
    $null = Assert-RetainedReleaseEvidence -Release $readback -Predicate $predicate -Directory $temporaryPath `
        -ExpectedReleaseId $releaseId -RequireComplete -RequireDraft
    $reference = Invoke-ReleaseApi -Method GET -Uri "$base/git/ref/tags/$([uri]::EscapeDataString($Tag))"
    $referenceObject = Get-ReleaseField $reference 'object'
    if ((Get-ReleaseField $referenceObject 'type') -ceq 'tag' -and [string] (Get-ReleaseField $referenceObject 'sha') -cmatch '^[a-f0-9]{40}$') {
        $reference = Invoke-ReleaseApi -Method GET -Uri "$base/git/tags/$(Get-ReleaseField $referenceObject 'sha')"
    }
    if (-not (Test-ReleaseTagCommit -Reference $reference -Expected $Commit)) { throw 'Release tag moved before finalization; release stays a draft.' }
}
$published = Invoke-ReleaseApi -Method PATCH -Uri "$base/releases/$releaseId" -Body ([ordered] @{
    draft = $false
    prerelease = $prerelease
    make_latest = if ($prerelease) { 'false' } else { 'legacy' }
})
if (-not (Test-PublishedRelease -Release $published -Tag $Tag -Prerelease $prerelease -Name $assetName -Digest $digest -Evidence $evidence)) {
    throw "Published release '$Tag' does not match the attested asset; inspect it before any import."
}
Write-Information "Published release '$Tag' with asset $assetName ($digest)." -InformationAction Continue
return [pscustomobject] @{ Tag = $Tag; Url = Get-ReleaseField $published 'html_url'; Asset = $assetName; Digest = $digest; Prerelease = $prerelease; Created = $true }
}
finally {
    if ($temporaryPath) {
        try { [IO.Directory]::Delete($temporaryPath, $true) }
        catch { throw [IO.IOException]::new("Could not remove temporary publication directory '$temporaryPath'.", $_.Exception) }
    }
}
