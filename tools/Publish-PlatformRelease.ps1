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
        $request.Body = if ($Body -is [byte[]]) { $Body } else { $Body | ConvertTo-Json -Depth 10 -Compress }
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

# security-check: release-published-state
function Test-PublishedRelease {
    # A published release is accepted on rerun only when it already is exactly the release this run would publish.
    param([AllowNull()] $Release, [Parameter(Mandatory)][string] $Tag, [Parameter(Mandatory)][bool] $Prerelease,
        [Parameter(Mandatory)][string] $Name, [Parameter(Mandatory)][string] $Digest)
    if ((Get-ReleaseField $Release 'tag_name') -cne $Tag) { return $false }
    # Only real JSON booleans count; PowerShell would coerce strings and numbers such as 'FALSE' or 0.
    $draft = Get-ReleaseField $Release 'draft'
    if ($draft -isnot [bool] -or $draft) { return $false }
    $isPrerelease = Get-ReleaseField $Release 'prerelease'
    if ($isPrerelease -isnot [bool] -or $isPrerelease -ne $Prerelease) { return $false }
    $assets = @(Get-ReleaseField $Release 'assets')
    if ($assets.Count -ne 1) { return $false }
    return Test-ReleaseAsset -Asset $assets[0] -Name $Name -Digest $Digest
}

if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$') {
    throw "Release tag '$Tag' must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N."
}
if (-not $ApiUrl -or ([uri] $ApiUrl).Scheme -cne 'https') { throw 'Publishing a release requires an HTTPS GitHub API URL.' }
if (-not $Token) { throw 'Publishing a release requires the workflow GITHUB_TOKEN.' }
if (-not (Test-Path -LiteralPath $AssetPath -PathType Leaf)) { throw "Release asset '$AssetPath' does not exist." }
$prerelease = $Tag.Contains('-rc.')
$assetName = "platform-$Tag.zip"
$digest = 'sha256:' + (Get-FileHash -LiteralPath $AssetPath -Algorithm SHA256).Hash.ToLowerInvariant()
$headers = @{
    Authorization = "Bearer $Token"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2026-03-10'
}
$base = "$($ApiUrl.TrimEnd('/'))/repos/$Repository"

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
if (-not $existingDraft) {
    if (-not (Test-PublishedRelease -Release $release -Tag $Tag -Prerelease $prerelease -Name $assetName -Digest $digest)) {
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

$uploaded = $false
foreach ($asset in @(Get-ReleaseField $release 'assets')) {
    if (-not $uploaded -and (Test-ReleaseAsset -Asset $asset -Name $assetName -Digest $digest)) { $uploaded = $true; continue }
    # Partial uploads, stale builds and foreign files are removed so the release carries exactly the attested asset.
    $assetId = Get-ReleaseField $asset 'id'
    if ("$assetId" -cnotmatch '^[1-9][0-9]*$') { throw 'GitHub returned a release asset without a numeric id.' }
    $null = Invoke-ReleaseApi -Method DELETE -Uri "$base/releases/assets/$assetId" -Accept @(204, 404)
}
if (-not $uploaded) {
    $uploadUrl = [string] (Get-ReleaseField $release 'upload_url')
    $uploadUrl = $uploadUrl -replace '\{\?[^}]*\}$', ''
    if (([uri] $uploadUrl).Scheme -cne 'https' -or -not $uploadUrl.EndsWith("/releases/$releaseId/assets")) {
        throw 'GitHub returned an unexpected release upload URL.'
    }
    $asset = Invoke-ReleaseApi -Method POST -Uri "${uploadUrl}?name=$([uri]::EscapeDataString($assetName))" -Accept @(201) `
        -ContentType 'application/zip' -Body ([IO.File]::ReadAllBytes((Resolve-Path -LiteralPath $AssetPath).Path))
    if (-not (Test-ReleaseAsset -Asset $asset -Name $assetName -Digest $digest)) {
        throw "Uploaded asset $assetName does not report the digest $digest; release stays a draft."
    }
}

$published = Invoke-ReleaseApi -Method PATCH -Uri "$base/releases/$releaseId" -Body ([ordered] @{
    draft = $false
    prerelease = $prerelease
    make_latest = if ($prerelease) { 'false' } else { 'legacy' }
})
if (-not (Test-PublishedRelease -Release $published -Tag $Tag -Prerelease $prerelease -Name $assetName -Digest $digest)) {
    throw "Published release '$Tag' does not match the attested asset; inspect it before any import."
}
Write-Information "Published release '$Tag' with asset $assetName ($digest)." -InformationAction Continue
return [pscustomobject] @{ Tag = $Tag; Url = Get-ReleaseField $published 'html_url'; Asset = $assetName; Digest = $digest; Prerelease = $prerelease; Created = $true }
