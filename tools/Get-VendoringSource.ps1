#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')][string] $Tag,
    [Parameter(Mandatory)][string] $ApiUrl,
    [Parameter(Mandatory)][string] $WorkPath,
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$')][string] $AssetName,
    [string] $InstallationToken = $env:SOURCE_GITHUB_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (([uri] $ApiUrl).Scheme -cne 'https' -or
    ([uri] $ApiUrl).Host -cnotmatch '^api\.(github\.com|[a-z0-9-]+\.ghe\.com)$' -or
    ([uri] $ApiUrl).UserInfo -or ([uri] $ApiUrl).AbsolutePath -cne '/' -or
    -not ([uri] $ApiUrl).IsDefaultPort -or ([uri] $ApiUrl).Query -or ([uri] $ApiUrl).Fragment) {
    throw 'Source API must be an HTTPS GitHub.com or GHE.com API origin.'
}
if ($InstallationToken -and $InstallationToken -cnotmatch '^ghs_') {
    throw 'Source credentials must be an installation token, not a personal PAT or OAuth token.'
}
if (Test-Path -LiteralPath $WorkPath) { throw "Work path '$WorkPath' already exists." }
$headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
if ($InstallationToken) { $headers.Authorization = "Bearer $InstallationToken" }
$base = "$($ApiUrl.TrimEnd('/'))/repos/$Repository"
try {
    $reference = Invoke-RestMethod -Uri "$base/git/ref/tags/$([uri]::EscapeDataString($Tag))" -Headers $headers
}
catch {
    throw "Cannot read source tag '$Repository@$Tag'. If a private source is unavailable to the enterprise App, use the declared manual import; no PAT/OAuth fallback. $($_.Exception.Message)"
}
$object = $reference.object
$depth = 0
while ($object.type -ceq 'tag') {
    if (++$depth -gt 10 -or $object.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid annotated tag chain.' }
    $annotation = Invoke-RestMethod -Uri "$base/git/tags/$($object.sha)" -Headers $headers
    $object = $annotation.object
}
if ($object.type -cne 'commit' -or $object.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Source tag must resolve to a commit SHA.' }
$commit = $object.sha
$downloadUrl = "$base/zipball/$commit"
if ($AssetName) {
    $release = Invoke-RestMethod -Uri "$base/releases/tags/$([uri]::EscapeDataString($Tag))" -Headers $headers
    $assets = @($release.assets | Where-Object { $_.name -ceq $AssetName })
    if ($assets.Count -ne 1 -or $assets[0].id -notmatch '^[1-9][0-9]*$') { throw "Release '$Tag' must contain exactly one asset '$AssetName'." }
    $downloadUrl = "$base/releases/assets/$($assets[0].id)"
}
$null = New-Item -ItemType Directory -Path $WorkPath
$archivePath = Join-Path $WorkPath 'source.zip'
$downloadHeaders = @{} + $headers
if ($AssetName) { $downloadHeaders.Accept = 'application/octet-stream' }
$null = Invoke-WebRequest -Uri $downloadUrl -Headers $downloadHeaders -OutFile $archivePath
$digest = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
# GitHub.com returns 404 for an unrecorded digest, but private access failures can look identical.
try {
    $response = Invoke-RestMethod -Uri "$base/attestations/sha256:$digest" -Headers $headers
}
catch {
    $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int] $_.Exception.Response.StatusCode } else { 0 }
    if ($status -ne 404 -or ([uri] $ApiUrl).Host -cne 'api.github.com') { throw }
    $repositoryInfo = Invoke-RestMethod -Uri $base -Headers $headers
    if ($repositoryInfo.full_name -ine $Repository -or $repositoryInfo.private -ne $false) {
        throw 'Cannot prove attestation absence for a private source; use the declared manual import rather than bypassing verification.'
    }
    Write-Warning 'Public GitHub.com source has no attestation for the downloaded digest (404). Provenance is NOT VERIFIED.'
    $response = @{ attestations = @() }
}
if (-not $response.PSObject.Properties['attestations'] -and
    -not ($response -is [Collections.IDictionary] -and $response.Contains('attestations'))) {
    throw 'Source attestation API returned no attestations collection.'
}
if ($response.attestations -isnot [Collections.IList]) { throw 'Source attestation API returned an invalid attestations collection.' }
$attestation = 'not-present'
if (@($response.attestations).Count -gt 0) {
    $saved = @{}
    foreach ($name in @('GH_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_HOST', 'GH_CONFIG_DIR')) {
        $saved[$name] = [Environment]::GetEnvironmentVariable($name)
    }
    try {
        $hostName = ([uri] $ApiUrl).Host -replace '^api\.', ''
        $env:GH_TOKEN = $InstallationToken
        $env:GH_ENTERPRISE_TOKEN = $InstallationToken
        $env:GITHUB_TOKEN = $null
        $env:GITHUB_ENTERPRISE_TOKEN = $null
        $env:GH_HOST = $hostName
        $env:GH_CONFIG_DIR = Join-Path $WorkPath 'gh-config'
        & gh attestation verify $archivePath --repo $Repository --hostname $hostName `
            --source-ref "refs/tags/$Tag" --source-digest $commit | Out-Host
        if ($LASTEXITCODE -ne 0) { throw "Invalid or unverifiable source attestation for '$Repository@$Tag'; import stopped." }
        $attestation = 'verified'
    }
    finally {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}
$archive = [IO.Compression.ZipFile]::OpenRead($archivePath)
$extracted = Join-Path $WorkPath 'extracted'
try {
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $rootNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    [long] $total = 0
    foreach ($entry in $archive.Entries) {
        $path = $entry.FullName
        $parts = $path.TrimEnd('/').Split('/')
        $unixType = ($entry.ExternalAttributes -shr 16) -band 0xF000
        if ($parts.Count -lt 2 -and -not $path.EndsWith('/')) { throw 'Source ZIP must contain a single root directory.' }
        if ($path.Contains('\') -or $path.StartsWith('/') -or $path.Contains(':') -or
            @($parts | Where-Object { $_ -in @('', '.', '..', '.git') }).Count -gt 0 -or
            $unixType -notin @(0, 0x8000, 0x4000) -or -not $paths.Add($path.TrimEnd('/'))) {
            throw "Unsafe or duplicate archive entry '$path'."
        }
        $null = $rootNames.Add($parts[0])
        $total += $entry.Length
        if ($total -gt 512MB) { throw 'Source ZIP exceeds the 512 MiB extraction limit.' }
    }
    if ($rootNames.Count -ne 1) { throw 'Source ZIP must contain exactly one root directory.' }
    foreach ($entry in $archive.Entries) {
        $destination = Join-Path $extracted $entry.FullName
        if ($entry.FullName.EndsWith('/')) { $null = New-Item -ItemType Directory -Path $destination -Force; continue }
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        [IO.Compression.ZipFileExtensions]::ExtractToFile($entry, $destination)
        if (-not $IsWindows) {
            $mode = ($entry.ExternalAttributes -shr 16) -band 0x1FF
            if ($mode) { [IO.File]::SetUnixFileMode($destination, [IO.UnixFileMode] $mode) }
        }
    }
}
finally { $archive.Dispose() }
$result = [pscustomobject]@{
    Repository = $Repository; Tag = $Tag; Commit = $commit; Sha256 = $digest
    Asset = $AssetName; Attestation = $attestation
    SourcePath = Join-Path $extracted @($rootNames)[0]
}
$result | ConvertTo-Json | Set-Content -LiteralPath (Join-Path $WorkPath 'receipt.json') -Encoding utf8NoBOM
$result
