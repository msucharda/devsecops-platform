#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9._/-]*$')][string] $Tag,
    [Parameter(Mandatory)][string] $ApiUrl,
    [Parameter(Mandatory)][string] $WorkPath,
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._-]*\.zip$')][string] $AssetName,
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+/\.github/workflows/[A-Za-z0-9_.-]+\.ya?ml$')][string] $SignerWorkflow,
    [switch] $RequireAttestation,
    [ValidatePattern('^$|^[A-Za-z0-9][A-Za-z0-9._/-]*$')][string] $ProtectedBranch,
    [ValidateRange(0, 3600)][int] $MaxRateLimitWaitSeconds = 300,
    [string] $InstallationToken = $env:SOURCE_GITHUB_TOKEN
)

Set-StrictMode -Version Latest
$maxWait = $MaxRateLimitWaitSeconds
$ErrorActionPreference = 'Stop'

function Invoke-SourceRequest {
    # Unauthenticated api.github.com calls share the runner IP limit; follow the documented rate-limit backoff:
    # https://docs.github.com/en/enterprise-cloud@latest/rest/using-the-rest-api/rate-limits-for-the-rest-api#exceeding-the-rate-limit
    param([Parameter(Mandatory)][scriptblock] $Request)
    $secondaryWait = 60
    for ($attempt = 1; ; $attempt++) {
        try { return & $Request }
        catch {
            $response = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
            $status = if ($response) { [int] $response.StatusCode } else { 0 }
            if ($status -notin @(403, 429)) { throw }
            $header = {
                param($Name)
                $values = $null
                if ($response.Headers.TryGetValues($Name, [ref] $values)) { return @($values)[0] }
                return $null
            }
            $remaining = & $header 'x-ratelimit-remaining'
            $retryAfter = & $header 'retry-after'
            $message = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { '' }
            if ($remaining -eq '0') {
                $reset = & $header 'x-ratelimit-reset'
                $resetAt = if ($reset -match '^[0-9]+$') { [DateTimeOffset]::FromUnixTimeSeconds([long] $reset) } else { [DateTimeOffset]::UtcNow.AddHours(1) }
                $wait = [Math]::Max(1, [int] [Math]::Ceiling(($resetAt - [DateTimeOffset]::UtcNow).TotalSeconds))
            }
            elseif ($retryAfter -match '^[0-9]+$') { $wait = [Math]::Max(1, [int] $retryAfter) }
            elseif ($message -match 'secondary rate limit') { $wait = $secondaryWait; $secondaryWait *= 2 }
            else { throw }
            if ($attempt -gt 3 -or $wait -gt $maxWait) {
                throw "GitHub API rate limit for the source is exhausted (HTTP $status); retry after $wait s or import a private source with its installation token. $($_.Exception.Message)"
            }
            Write-Warning "GitHub API rate limit reached (HTTP $status); retrying in $wait s."
            Start-Sleep -Seconds $wait
        }
    }
}

# security-check: vendoring-required-attestation
function Test-AttestationRequirementMet {
    param([string] $Attestation, [bool] $Required, [string] $SignerWorkflow)
    if (-not $Required) { return $true }
    return $Attestation -eq 'verified' -and -not [string]::IsNullOrEmpty($SignerWorkflow)
}

# security-check: vendoring-commit-on-branch
function Test-CommitOnBranch {
    # The signer workflow runs from the tagged commit, so its own ancestry check cannot prove that the commit is on
    # the protected branch; the importer checks it independently. behind or identical means base contains head.
    param([AllowNull()] $Comparison, [Parameter(Mandatory)][string] $Commit)
    if ($Comparison.status -cnotin @('behind', 'identical')) { return $false }
    return $Comparison.merge_base_commit.sha -ceq $Commit
}

# security-check: vendoring-attestation-pagination
function Get-SourceAttestationNextPage {
    param(
        [AllowNull()] $Headers,
        [Parameter(Mandatory)][string] $DigestUri,
        [Parameter(Mandatory)][Collections.Generic.HashSet[string]] $Visited
    )
    if ($null -eq $Headers) { return $null }
    $links = $Headers['Link']
    if ($null -eq $links) { return $null }
    [string[]] $values = @($links)
    if ($values.Count -eq 0) { throw 'Unreadable source attestation pagination Link header.' }
    $next = $null
    foreach ($value in $values) {
        $offset = 0
        foreach ($match in [regex]::Matches($value,
                '\G\s*<(?<url>[^<>]+)>\s*;\s*rel\s*=\s*(?:"(?<rel>[^"]+)"|(?<rel>[A-Za-z]+))\s*(?:,\s*(?=<)|(?=\z))')) {
            $offset += $match.Length
            if ($match.Groups['rel'].Value -ceq 'next') {
                if ($null -ne $next) { throw 'Multiple next-page links in source attestation pagination.' }
                $next = $match.Groups['url'].Value
            }
        }
        if ($offset -ne $value.Length -or $offset -eq 0) { throw 'Unreadable source attestation pagination Link header.' }
    }
    if ($null -eq $next) { return $null }
    $target = $null
    if (-not [uri]::TryCreate($next, [UriKind]::Absolute, [ref] $target) -or
        $target.Scheme -ne 'https' -or $target.UserInfo -or $target.Fragment -or
        -not [string]::Equals($target.GetLeftPart([UriPartial]::Authority),
            ([uri] $DigestUri).GetLeftPart([UriPartial]::Authority), [StringComparison]::Ordinal) -or
        -not [string]::Equals($target.AbsolutePath, ([uri] $DigestUri).AbsolutePath, [StringComparison]::Ordinal)) {
        throw 'Source attestation pagination link outside the digest endpoint.'
    }
    $query = $target.Query.TrimStart('?')
    if (-not $query) { throw 'Source attestation pagination link has no cursor.' }
    $parameters = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($part in $query.Split('&')) {
        if ($part -cnotmatch '^(after|before|per_page)=([^&=]+)$' -or -not $parameters.Add($Matches[1])) {
            throw 'Invalid source attestation pagination cursor.'
        }
    }
    if ((-not $parameters.Contains('after') -and -not $parameters.Contains('before')) -or
        ($parameters.Contains('after') -and $parameters.Contains('before'))) {
        throw 'Invalid source attestation pagination cursor.'
    }
    if ($Visited.Contains($target.AbsoluteUri)) {
        throw 'Cyclic source attestation pagination link.'
    }
    return $target.AbsoluteUri
}

function ConvertFrom-SnappyBlock {
    # Decodes the raw snappy block format (https://github.com/google/snappy/blob/main/format_description.txt).
    # The result is untrusted; gh attestation verify validates it cryptographically.
    param([Parameter(Mandatory)][byte[]] $Data)
    $index = 0
    [long] $length = 0
    $shift = 0
    do {
        if ($index -ge $Data.Length -or $shift -gt 28) { throw 'Invalid snappy attestation bundle length.' }
        [int] $byte = $Data[$index++]
        $length = $length -bor ([long] ($byte -band 0x7F) -shl $shift)
        $shift += 7
    } while ($byte -band 0x80)
    if ($length -gt 16MB) { throw 'Attestation bundle exceeds 16 MiB.' }
    $output = [byte[]]::new($length)
    $written = 0
    while ($index -lt $Data.Length) {
        [int] $tag = $Data[$index++]
        $type = $tag -band 3
        if ($type -eq 0) {
            [long] $count = $tag -shr 2
            if ($count -ge 60) {
                $width = $count - 59
                if ($index + $width -gt $Data.Length) { throw 'Truncated snappy literal.' }
                $count = 0
                for ($k = 0; $k -lt $width; $k++) { $count = $count -bor ([long] $Data[$index++] -shl (8 * $k)) }
            }
            $count++
            if ($index + $count -gt $Data.Length -or $written + $count -gt $length) { throw 'Invalid snappy literal.' }
            [Array]::Copy($Data, $index, $output, $written, $count)
            $index += $count
            $written += $count
            continue
        }
        if ($type -eq 1) {
            if ($index + 1 -gt $Data.Length) { throw 'Truncated snappy copy.' }
            $count = (($tag -shr 2) -band 7) + 4
            $offset = (($tag -shr 5) -shl 8) -bor [int] $Data[$index++]
        }
        elseif ($type -eq 2) {
            if ($index + 2 -gt $Data.Length) { throw 'Truncated snappy copy.' }
            $count = ($tag -shr 2) + 1
            $offset = [int] $Data[$index] -bor ([int] $Data[$index + 1] -shl 8)
            $index += 2
        }
        else {
            if ($index + 4 -gt $Data.Length) { throw 'Truncated snappy copy.' }
            $count = ($tag -shr 2) + 1
            $offset = [BitConverter]::ToUInt32($Data, $index)
            $index += 4
        }
        if ($offset -le 0 -or $offset -gt $written -or $written + $count -gt $length) { throw 'Invalid snappy copy.' }
        for ($k = 0; $k -lt $count; $k++) { $output[$written] = $output[$written - $offset]; $written++ }
    }
    if ($written -ne $length) { throw 'Snappy attestation bundle length does not match its content.' }
    return , $output
}
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
    $reference = Invoke-SourceRequest { Invoke-RestMethod -Uri "$base/git/ref/tags/$([uri]::EscapeDataString($Tag))" -Headers $headers }
}
catch {
    throw "Cannot read source tag '$Repository@$Tag'. If a private source is unavailable to the enterprise App, use the declared manual import; no PAT/OAuth fallback. $($_.Exception.Message)"
}
$object = $reference.object
$depth = 0
while ($object.type -ceq 'tag') {
    if (++$depth -gt 10 -or $object.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Invalid annotated tag chain.' }
    $annotation = Invoke-SourceRequest { Invoke-RestMethod -Uri "$base/git/tags/$($object.sha)" -Headers $headers }
    $object = $annotation.object
}
if ($object.type -cne 'commit' -or $object.sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Source tag must resolve to a commit SHA.' }
$commit = $object.sha
if ($RequireAttestation -and -not $ProtectedBranch) { throw 'A required attestation needs the protected source branch the release commit must be on.' }
if ($ProtectedBranch) {
    # per_page=1 keeps the response small; status and merge_base_commit cover the whole comparison.
    $basehead = "$([uri]::EscapeDataString($ProtectedBranch))...$commit"
    $comparison = Invoke-SourceRequest { Invoke-RestMethod -Uri "$base/compare/${basehead}?per_page=1" -Headers $headers }
    if (-not (Test-CommitOnBranch -Comparison $comparison -Commit $commit)) {
        throw "Source tag '$Tag' points to commit $commit, which is not on the protected branch '$ProtectedBranch'; import stopped."
    }
}
$downloadUrl = "$base/zipball/$commit"
if ($AssetName) {
    $release = Invoke-SourceRequest { Invoke-RestMethod -Uri "$base/releases/tags/$([uri]::EscapeDataString($Tag))" -Headers $headers }
    $assets = @($release.assets | Where-Object { $_.name -ceq $AssetName })
    if ($assets.Count -ne 1 -or $assets[0].id -notmatch '^[1-9][0-9]*$') { throw "Release '$Tag' must contain exactly one asset '$AssetName'." }
    $downloadUrl = "$base/releases/assets/$($assets[0].id)"
}
$null = New-Item -ItemType Directory -Path $WorkPath
$archivePath = Join-Path $WorkPath 'source.zip'
$downloadHeaders = @{} + $headers
if ($AssetName) { $downloadHeaders.Accept = 'application/octet-stream' }
$null = Invoke-SourceRequest { Invoke-WebRequest -Uri $downloadUrl -Headers $downloadHeaders -OutFile $archivePath }
$digest = (Get-FileHash -LiteralPath $archivePath -Algorithm SHA256).Hash.ToLowerInvariant()
# GitHub.com returns 404 for an unrecorded digest, but private access failures can look identical.
$digestUri = "$base/attestations/sha256:$digest"
$pageHeaders = $null
try {
    $firstPage = Invoke-SourceRequest {
        $responseHeaders = $null
        $body = Invoke-RestMethod -Uri $digestUri -Headers $headers -ResponseHeadersVariable responseHeaders -MaximumRedirection 0
        [pscustomobject]@{ Body = $body; Headers = $responseHeaders }
    }
    $response = $firstPage.Body
    $pageHeaders = $firstPage.Headers
}
catch {
    $status = if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response) { [int] $_.Exception.Response.StatusCode } else { 0 }
    if ($status -ne 404 -or ([uri] $ApiUrl).Host -cne 'api.github.com') { throw }
    $repositoryInfo = Invoke-SourceRequest { Invoke-RestMethod -Uri $base -Headers $headers }
    if ($repositoryInfo.full_name -ine $Repository -or $repositoryInfo.private -ne $false) {
        throw 'Cannot prove attestation absence for a private source; use the declared manual import rather than bypassing verification.'
    }
    Write-Warning 'Public GitHub.com source has no attestation for the downloaded digest (404). Provenance is NOT VERIFIED.'
    $response = @{ attestations = @() }
}
$attestation = 'not-present'
$pageUri = $digestUri
$visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$null = $visited.Add(([uri] $digestUri).AbsoluteUri)
$bundleDirectory = Join-Path $WorkPath 'bundles'
$bundleCount = 0
while ($true) {
    if (-not $response.PSObject.Properties['attestations'] -and
        -not ($response -is [Collections.IDictionary] -and $response.Contains('attestations'))) {
        throw 'Source attestation API returned no attestations collection.'
    }
    if ($response.attestations -isnot [Collections.IList]) { throw 'Source attestation API returned an invalid attestations collection.' }
    foreach ($item in @($response.attestations)) {
        $bundleUrl = if ($item -is [Collections.IDictionary]) { $item['bundle_url'] } elseif ($item.PSObject.Properties['bundle_url']) { $item.bundle_url } else { $null }
        if ($bundleUrl -isnot [string] -or -not [uri]::IsWellFormedUriString($bundleUrl, [UriKind]::Absolute) -or
            ([uri] $bundleUrl).Scheme -cne 'https' -or ([uri] $bundleUrl).UserInfo) {
            throw 'Source attestation has no HTTPS bundle_url; import stopped.'
        }
        if (-not (Test-Path -LiteralPath $bundleDirectory)) { $null = New-Item -ItemType Directory -Path $bundleDirectory }
        $compressedPath = Join-Path $bundleDirectory "$bundleCount.json.sn"
        # The pre-signed storage URL must not receive the GitHub credential.
        $null = Invoke-WebRequest -Uri $bundleUrl -OutFile $compressedPath
        if ((Get-Item -LiteralPath $compressedPath).Length -gt 16MB) { throw 'Attestation bundle download exceeds 16 MiB.' }
        $bundlePath = Join-Path $bundleDirectory "$bundleCount.json"
        [IO.File]::WriteAllBytes($bundlePath, (ConvertFrom-SnappyBlock -Data ([IO.File]::ReadAllBytes($compressedPath))))
        $bundleCount++
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
            $policy = @('--repo', $Repository, '--hostname', $hostName, '--source-ref', "refs/tags/$Tag",
                '--source-digest', $commit, '--deny-self-hosted-runners')
            if ($SignerWorkflow) { $policy += @('--signer-workflow', $SignerWorkflow) }
            & gh attestation verify $archivePath --bundle $bundlePath @policy | Out-Host
            if ($LASTEXITCODE -eq 0) { $attestation = 'verified'; break }
        }
        finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
    if ($attestation -ceq 'verified') { break }
    $nextPage = Get-SourceAttestationNextPage -Headers $pageHeaders -DigestUri $digestUri -Visited $visited
    if ($null -eq $nextPage) { break }
    $null = $visited.Add($nextPage)
    $pageUri = $nextPage
    $page = Invoke-SourceRequest {
        $responseHeaders = $null
        $body = Invoke-RestMethod -Uri $pageUri -Headers $headers -ResponseHeadersVariable responseHeaders -MaximumRedirection 0
        [pscustomobject]@{ Body = $body; Headers = $responseHeaders }
    }
    $response = $page.Body
    $pageHeaders = $page.Headers
}
if ($attestation -cne 'verified' -and $bundleCount -gt 0) {
    throw "Invalid or unverifiable source attestation for '$Repository@$Tag'; import stopped."
}
if (-not (Test-AttestationRequirementMet -Attestation $attestation -Required $RequireAttestation.IsPresent -SignerWorkflow $SignerWorkflow)) {
    throw "Source '$Repository@$Tag' requires a verified attestation from a pinned signer workflow; import stopped."
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
