#Requires -Version 7.4
[CmdletBinding()]
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'RunIdentifier',
    Justification = 'Retained for older instance workflows; import identity must not depend on a run.')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $PreparedPath,
    [Parameter(Mandatory)][string] $TargetPath,
    [Parameter(Mandatory)][string] $ReceiptPath,
    [string] $ModeManifestPath,
    [Parameter(Mandatory)][ValidateSet('action', 'release')][string] $Kind,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][string] $ApiUrl,
    [ValidatePattern('^[A-Za-z0-9-]+$')][string] $RunIdentifier,
    [string] $GitHubOutputPath,
    [string] $SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$Kind = $Kind.ToLowerInvariant()
$owner = $Repository.Split('/')[0]
if (([uri] $ApiUrl).Scheme -cne 'https' -or -not $env:PLATFORM_GITHUB_TOKENS -or $env:GH_TOKEN -cnotmatch '^ghs_') {
    throw 'Publishing requires an HTTPS API and a verified target installation token; GITHUB_TOKEN and PAT/OAuth are not supported.'
}
$tokens = $env:PLATFORM_GITHUB_TOKENS | ConvertFrom-Json -AsHashtable
if ($tokens[$owner] -cne $env:GH_TOKEN) { throw 'Publishing token differs from the verified target App token.' }
$headers = @{
    Authorization = "Bearer $($env:GH_TOKEN)"
    Accept = 'application/vnd.github+json'
    'X-GitHub-Api-Version' = '2026-03-10'
}
$scope = Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/installation/repositories?per_page=100" -Headers $headers
if ($scope.total_count -ne 1 -or @($scope.repositories).Count -ne 1 -or $scope.repositories[0].full_name -cne $Repository) {
    throw 'Publishing installation token must cover only the target repository.'
}
$target = (Resolve-Path -LiteralPath $TargetPath).Path
$prepared = (Resolve-Path -LiteralPath $PreparedPath).Path
$receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
if ($receipt['Commit'] -cnotmatch '^[a-f0-9]{40}$' -or $receipt['Sha256'] -cnotmatch '^[a-f0-9]{64}$' -or
    $receipt['Attestation'] -cnotin @('verified', 'not-present', 'manual-not-verified') -or
    $receipt['Repository'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$' -or
    $receipt['Tag'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
    throw 'Invalid source receipt.'
}
$receipt['Repository'] = $receipt['Repository'].ToLowerInvariant()
function Invoke-VendoringGit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Arguments)

    $result = & git -C $target -c core.hooksPath=/.vendoring-no-hooks -c core.quotepath=false @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git vendoring command '$($Arguments[0])' failed with exit code $LASTEXITCODE." }
    return $result
}

function Invoke-VendoringRemoteGit {
    param([Parameter(Mandatory)][string[]] $Arguments)
    $names = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = "http.$remote.extraheader"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$($env:GH_TOKEN)"))
        $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $encoded"
        Invoke-VendoringGit (@('-c', 'credential.helper=') + $Arguments)
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}

# security-check: vendoring-resume-pr
function Assert-VendoringPullRequest {
    param($PullRequest, [string] $Branch, [string] $HeadSha)
    if ($PullRequest -isnot [Collections.IDictionary]) { throw 'Invalid vendoring PR response.' }
    foreach ($side in @('head', 'base')) {
        $reference = $PullRequest[$side]
        if ($reference -isnot [Collections.IDictionary] -or $reference['repo'] -isnot [Collections.IDictionary] -or
            $reference['repo']['full_name'] -ine $Repository) { throw "Vendoring PR $side repository does not match the target." }
    }
    if ($PullRequest['head']['ref'] -cne $Branch) { throw 'Vendoring PR head does not match the import branch.' }
    if ($PullRequest['base']['ref'] -cne 'main') { throw 'Vendoring PR base is not main.' }
    if ($PullRequest['head']['sha'] -cne $HeadSha) { throw 'Vendoring PR head SHA changed; retry after inspection.' }
    if ($PullRequest['state'] -cnotin @('open', 'closed')) { throw 'Vendoring PR state is unknown.' }
    if ($PullRequest['number'] -notmatch '^[1-9][0-9]*$' -or
        $PullRequest['html_url'] -ine "https://$hostName/$Repository/pull/$($PullRequest['number'])") {
        throw 'Vendoring PR URL does not match the target.'
    }
    $mergedAt = [DateTimeOffset]::MinValue
    if ($PullRequest['state'] -eq 'closed' -and
        -not [DateTimeOffset]::TryParse($PullRequest['merged_at'], [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref] $mergedAt)) {
        throw 'Vendoring PR was closed without merging; restore it manually instead of creating a duplicate.'
    }
}

# security-check: vendoring-resume-tree
function Assert-VendoringResumeTree {
    param([string] $ExpectedTree, [string] $RemoteTree)
    if ($RemoteTree -cne $ExpectedTree) { throw 'Existing import branch has different content or provenance; it will not be overwritten.' }
}

# security-check: vendoring-resume-ref
function Get-VendoringResumeRef {
    $remoteRefs = @(Invoke-VendoringRemoteGit @('ls-remote', '--heads', $remote, "refs/heads/$branch"))
    if ($remoteRefs.Count -eq 0) { return $null }
    if ($remoteRefs.Count -ne 1 -or $remoteRefs[0] -cnotmatch "^([a-f0-9]{40})\s+refs/heads/$([regex]::Escape($branch))$") {
        throw 'Cannot resolve the existing import branch to one commit.'
    }
    $sha = $Matches[1]
    $null = Invoke-VendoringRemoteGit @('fetch', '--quiet', '--no-tags', $remote, $sha)
    $parents = (Invoke-VendoringGit @('rev-list', '--parents', '-n', '1', $sha)).Split(' ')
    if ($parents.Count -ne 2) { throw 'Existing import branch must contain a single-parent import commit.' }
    $parent = $parents[1]
    if ((Invoke-VendoringGit @('merge-base', $mainSha, $parent)) -cne $parent) {
        throw 'Existing import branch is not based on target main history.'
    }
    return @{ Sha = $sha; Parent = $parent }
}

# security-check: vendoring-pr-lookup
function Get-VendoringExistingPullRequest {
    $queryHead = [uri]::EscapeDataString("${owner}:$branch")
    $pullRequests = Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/repos/$Repository/pulls?state=all&head=$queryHead&base=main&per_page=100" -Headers $headers
    if ($pullRequests -isnot [Collections.IList] -or $pullRequests.Count -gt 1) {
        throw 'Vendoring PR lookup must return an array with at most one import PR.'
    }
    if ($pullRequests.Count -eq 1 -and -not $remoteSha) { throw 'Existing vendoring PR has no import branch; restore it manually.' }
    return ,$pullRequests
}

# security-check: vendoring-publish-head
function Assert-VendoringPublishHead {
    $refs = @(Invoke-VendoringRemoteGit @('ls-remote', '--heads', $remote, "refs/heads/$branch"))
    if ($refs.Count -ne 1 -or $refs[0] -cne "$remoteSha`trefs/heads/$branch") {
        throw 'Import branch changed before PR creation; retry after inspection.'
    }
}

# security-check: vendoring-merged-main
function Assert-VendoringMergedImport {
    $paths = if ($Kind -eq 'release') { @('platform') } else { @('.', ':(top,exclude).github') }
    $differences = @(Invoke-VendoringGit (@('diff', '--name-only', '--no-renames', $mainSha, $remoteSha, '--') + $paths))
    if ($differences.Count -gt 0) {
        throw 'Import identity was merged but target main no longer contains it; manual intervention is required.'
    }
}
if (@(Invoke-VendoringGit @('status', '--porcelain')).Count -gt 0) { throw 'Target checkout must be clean before vendoring.' }
if ((Invoke-VendoringGit @('branch', '--show-current')) -cne 'main') { throw 'Target checkout must start on protected main.' }
$mainSha = Invoke-VendoringGit @('rev-parse', 'HEAD')
$items = @(Get-ChildItem -LiteralPath $prepared -Recurse -Force)
if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'Prepared source must not contain symbolic links.'
}
$newFiles = [Collections.Generic.List[string]]::new()
foreach ($file in @($items | Where-Object { -not $_.PSIsContainer })) {
    $relative = [IO.Path]::GetRelativePath($prepared, $file.FullName).Replace('\', '/')
    if ($relative -match '(^|/)\.git(/|$)' -or $relative -eq '.vendoring.json' -or
        ($Kind -eq 'action' -and $relative.StartsWith('.github/')) -or
        ($Kind -eq 'release' -and -not $relative.StartsWith('platform/'))) {
        throw "Prepared file '$relative' is outside the $Kind vendoring boundary."
    }
    $newFiles.Add($relative)
}
if (-not $newFiles.Count) { throw 'Prepared source is empty.' }
$modes = $null
if ($ModeManifestPath) {
    $manifest = Get-Content -LiteralPath $ModeManifestPath -Raw | ConvertFrom-Json -AsHashtable
    if ($manifest['version'] -ne 1 -or $manifest['files'] -isnot [Collections.IDictionary] -or
        $manifest['files'].Count -ne $newFiles.Count) {
        throw 'Mode manifest must describe every prepared file exactly once.'
    }
    $modes = $manifest['files']
    foreach ($relative in $newFiles) {
        if (-not $modes.Contains($relative) -or $modes[$relative] -isnot [bool]) {
            throw "Mode manifest has no boolean executable flag for '$relative'."
        }
    }
}
$identity = ConvertTo-Json -InputObject @($Kind, $receipt['Repository'].ToLowerInvariant(), $receipt['Tag']) -Compress
$identityHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
$branch = "vendor/$Kind/$identityHash"
$hostName = ([uri] $ApiUrl).Host -replace '^api\.', ''
$remote = "https://$hostName/$Repository.git"
$remoteSha = $null
$start = $mainSha
if ($resumeRef = Get-VendoringResumeRef) {
    $remoteSha = $resumeRef.Sha
    $start = $resumeRef.Parent
}
$null = Invoke-VendoringGit @('switch', '--quiet', '--detach', $start)
foreach ($item in @(Get-ChildItem -LiteralPath $target -Recurse -Force |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
    $relative = [IO.Path]::GetRelativePath($target, $item.FullName).Replace('\', '/')
    if (($Kind -eq 'release' -and $relative.StartsWith('platform/')) -or
        ($Kind -eq 'release' -and $relative -ceq 'platform') -or
        ($Kind -eq 'action' -and -not $relative.StartsWith('.github/'))) {
        throw "Target vendoring boundary contains symbolic link '$relative'."
    }
}
$oldFiles = @(Invoke-VendoringGit @('ls-files')) | Where-Object {
    if ($Kind -eq 'release') { $_.StartsWith('platform/') } else { -not $_.StartsWith('.github/') -and $_ -cne '.vendoring.json' }
}
foreach ($relative in $oldFiles) {
    if (-not $newFiles.Contains($relative)) {
        $null = Invoke-VendoringGit @('rm', '--quiet', '--', $relative)
    }
}
foreach ($relative in $newFiles) {
    $destination = Join-Path $target $relative
    $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $prepared $relative) -Destination $destination -Force
    if (-not $IsWindows) {
        $mode = if ($null -ne $modes) { if ($modes[$relative]) { 493 } else { 420 } } else { [IO.File]::GetUnixFileMode((Join-Path $prepared $relative)) }
        [IO.File]::SetUnixFileMode($destination, [IO.UnixFileMode] $mode)
    }
}
$metadataPath = if ($Kind -eq 'release') { 'platform/.vendoring.json' } else { '.vendoring.json' }
$metadata = [ordered]@{
    version = 1; kind = $Kind
    source = $receipt['Repository']; tag = $receipt['Tag']; commit = $receipt['Commit']
    sha256 = $receipt['Sha256']; asset = $receipt['Asset']; attestation = $receipt['Attestation']
    files = @($newFiles | Sort-Object -CaseSensitive)
}
$metadata | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath (Join-Path $target $metadataPath) -Encoding utf8NoBOM
foreach ($relative in @($newFiles) + @($metadataPath)) {
    $null = Invoke-VendoringGit @('add', '--force', '--', $relative)
    if ($null -ne $modes -and $relative -cne $metadataPath) {
        $flag = if ($modes[$relative]) { '--chmod=+x' } else { '--chmod=-x' }
        $null = Invoke-VendoringGit @('update-index', $flag, '--', $relative)
    }
}
if ($remoteSha) {
    Assert-VendoringResumeTree -ExpectedTree (Invoke-VendoringGit @('write-tree')) `
        -RemoteTree (Invoke-VendoringGit @('rev-parse', "${remoteSha}^{tree}"))
    $null = Invoke-VendoringGit @('reset', '--quiet', $remoteSha)
}
$diff = if ($remoteSha) { 'Existing import branch' } else { Invoke-VendoringGit @('diff', '--cached', '--stat') }
if (-not $diff) {
    $result = [pscustomobject]@{ HasChanges = $false; Branch = $branch; PullRequest = $null }
}
else {
    $pullRequests = Get-VendoringExistingPullRequest
    if ($pullRequests.Count -eq 1) {
        $pullRequest = $pullRequests[0] | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        Assert-VendoringPullRequest -PullRequest $pullRequest -Branch $branch -HeadSha $remoteSha
        if ($pullRequest['state'] -ceq 'closed') { Assert-VendoringMergedImport }
        $url = if ($pullRequest['state'] -ceq 'open') { $pullRequest['html_url'] } else { $null }
        $result = [pscustomobject]@{ HasChanges = $pullRequest['state'] -ceq 'open'; Branch = $branch; PullRequest = $url }
    }
    else {
        if (-not $remoteSha) {
            $null = Invoke-VendoringGit @('-c', 'user.name=Platform vendoring', '-c', 'user.email=platform-vendoring@users.noreply.github.com',
                'commit', '--quiet', '-m', "Vendor $($receipt['Repository']) at $($receipt['Tag'])")
            # An empty lease is create-only: a concurrent publisher must never be overwritten.
            $null = Invoke-VendoringRemoteGit @('push', '--quiet', "--force-with-lease=refs/heads/${branch}:", $remote, "HEAD:refs/heads/$branch")
            $remoteSha = Invoke-VendoringGit @('rev-parse', 'HEAD')
        }
        Assert-VendoringPublishHead
        $body = @"
Vendoring $($receipt['Repository']) at tag $($receipt['Tag']), commit $($receipt['Commit']).

Source SHA256: $($receipt['Sha256'])
Attestation: $($receipt['Attestation']). Absence is not verification.

Cloud PR plan: **NOT PERFORMED**. This App-created PR receives no cloud credentials.
Review and merge into protected main must precede the main plan and approved apply (ADR 0016).
Release workflow templates stay under platform/; promotion of live workflows is a separate reviewed manual step.
"@
        $pullRequest = Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/repos/$Repository/pulls" -Method POST -Headers $headers `
            -ContentType application/json -Body (ConvertTo-Json -InputObject @{
                title = "Vendor $($receipt['Repository']) $($receipt['Tag'])"
                head = $branch; base = 'main'; body = $body
            } -Compress)
        $pullRequest = $pullRequest | ConvertTo-Json -Depth 100 | ConvertFrom-Json -AsHashtable
        Assert-VendoringPullRequest -PullRequest $pullRequest -Branch $branch -HeadSha $remoteSha
        $result = [pscustomobject]@{ HasChanges = $true; Branch = $branch; PullRequest = $pullRequest['html_url'] }
    }
}
if ($GitHubOutputPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath),
        "has-changes=$($result.HasChanges.ToString().ToLowerInvariant())`npull-request=$($result.PullRequest)`n", [Text.UTF8Encoding]::new($false))
}
if ($SummaryPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($SummaryPath),
        "Vendoring PR: $($result.PullRequest). Changes: $($result.HasChanges). Attestation: $($receipt['Attestation']).`nCloud PR plan: **NOT PERFORMED**; plan runs after review and merge into protected main, before approved apply.`n",
        [Text.UTF8Encoding]::new($false))
}
$result
