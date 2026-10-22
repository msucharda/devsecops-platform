#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $PreparedPath,
    [Parameter(Mandatory)][string] $TargetPath,
    [Parameter(Mandatory)][string] $ReceiptPath,
    [string] $ModeManifestPath,
    [Parameter(Mandatory)][ValidateSet('action', 'release')][string] $Kind,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][string] $ApiUrl,
    [string] $GitHubOutputPath,
    [string] $SummaryPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
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
foreach ($item in @(Get-ChildItem -LiteralPath $target -Recurse -Force |
    Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint })) {
    $relative = [IO.Path]::GetRelativePath($target, $item.FullName).Replace('\', '/')
    if (($Kind -eq 'release' -and $relative.StartsWith('platform/')) -or
        ($Kind -eq 'release' -and $relative -ceq 'platform') -or
        ($Kind -eq 'action' -and -not $relative.StartsWith('.github/'))) {
        throw "Target vendoring boundary contains symbolic link '$relative'."
    }
}
$receipt = Get-Content -LiteralPath $ReceiptPath -Raw | ConvertFrom-Json -AsHashtable
if ($receipt['Commit'] -cnotmatch '^[a-f0-9]{40}$' -or $receipt['Sha256'] -cnotmatch '^[a-f0-9]{64}$' -or
    $receipt['Attestation'] -cnotin @('verified', 'not-present', 'manual-not-verified') -or
    $receipt['Repository'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$' -or
    $receipt['Tag'] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._/-]*$') {
    throw 'Invalid source receipt.'
}
function Invoke-VendoringGit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Arguments)

    $result = & git -C $target -c core.hooksPath=/.vendoring-no-hooks -c core.quotepath=false @Arguments
    if ($LASTEXITCODE -ne 0) { throw "Git vendoring command '$($Arguments[0])' failed with exit code $LASTEXITCODE." }
    return $result
}
$hostName = ([uri] $ApiUrl).Host -replace '^api\.', ''
$remote = "https://$hostName/$Repository.git"
$vendoringEmail = 'platform-vendoring@users.noreply.github.com'
function Invoke-VendoringRemoteGit {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Arguments)

    $names = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = "http.$remote.extraheader"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$($env:GH_TOKEN)"))
        $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $encoded"
        return Invoke-VendoringGit (@('-c', 'credential.helper=') + $Arguments)
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
}

# security-check: vendoring-branch-replaceable
function Test-VendoringBranchReplaceable {
    # An existing import branch may be replaced only when it holds a single vendoring commit on top of main history;
    # anything else (a reviewer's commit, a merge, unrelated history) needs human inspection instead of a force push.
    param([AllowNull()][string] $Committer, [AllowNull()][string[]] $Parents, [bool] $ParentOnMain)
    if ($Committer -cne $vendoringEmail) { return $false }
    if (@($Parents).Count -ne 1) { return $false }
    return $ParentOnMain
}

# security-check: vendoring-pull-request-reuse
function Select-VendoringPullRequest {
    # Returns the open App PR of the import branch or $null. A PR of the branch that the App did not open stops the
    # import before the branch changes: a push would synchronize it, and a human author can release cloud credentials.
    param([AllowNull()][object[]] $PullRequests, [Parameter(Mandatory)][string] $Branch, [Parameter(Mandatory)][string] $Repository)
    $own = @(foreach ($pullRequest in @($PullRequests)) {
            if ($null -eq $pullRequest -or $null -eq $pullRequest.head -or $null -eq $pullRequest.head.repo) { continue }
            if ($pullRequest.head.ref -cne $Branch -or $pullRequest.head.repo.full_name -ne $Repository) { continue }
            $pullRequest
        })
    foreach ($pullRequest in $own) {
        if ($null -eq $pullRequest.user -or $pullRequest.user.type -cne 'Bot' -or [string] $pullRequest.user.login -notlike '*[[]bot]') {
            throw "Import branch '$Branch' has a pull request that the vendoring App did not open; inspect it before importing again."
        }
    }
    $open = @($own | Where-Object { $_.state -ceq 'open' })
    if ($open.Count -gt 1) { throw "Import branch '$Branch' has $($open.Count) open pull requests; inspect them before importing again." }
    if ($open.Count -eq 0) { return $null }
    $pullRequest = $open[0]
    if ($null -eq $pullRequest.base -or $pullRequest.base.ref -cne 'main' -or
        $pullRequest.number -isnot [ValueType] -or [long] $pullRequest.number -lt 1 -or [string] $pullRequest.html_url -cnotmatch '^https://') {
        throw "Pull request of import branch '$Branch' is not an open PR into main; inspect it before importing again."
    }
    return $pullRequest
}

if (@(Invoke-VendoringGit @('status', '--porcelain')).Count -gt 0) { throw 'Target checkout must be clean before vendoring.' }
if ((Invoke-VendoringGit @('branch', '--show-current')) -cne 'main') { throw 'Target checkout must start on protected main.' }
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
$oldFiles = @(Invoke-VendoringGit @('ls-files')) | Where-Object {
    if ($Kind -eq 'release') { $_.StartsWith('platform/') } else { -not $_.StartsWith('.github/') -and $_ -cne '.vendoring.json' }
}
$identity = "$Kind`n$($receipt['Repository'].ToLowerInvariant())`n$($receipt['Tag'])"
$identityHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant().Substring(0, 16)
$slug = ("$($receipt['Repository'])-$($receipt['Tag'])".ToLowerInvariant() -creplace '[^a-z0-9.]+', '-' -creplace '\.{2,}', '.' -creplace '-?\.-?', '.').Trim('.', '-')
if ($slug.Length -gt 60) { $slug = $slug.Substring(0, 60).TrimEnd('.', '-') }
# The branch is derived only from the import kind, source and tag, so a rerun of any attempt finds the same branch and PR.
$branch = "vendor/$Kind/$slug-$identityHash"
$null = Invoke-VendoringGit @('check-ref-format', '--branch', $branch)
$null = Invoke-VendoringGit @('switch', '--quiet', '-C', $branch)
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
    # Copied files keep the source timestamp, so an equal size and timestamp second would let Git keep the old blob.
    $null = Invoke-VendoringGit @('rm', '--cached', '--quiet', '--ignore-unmatch', '--', $relative)
    $null = Invoke-VendoringGit @('add', '--force', '--', $relative)
    if ($null -ne $modes -and $relative -cne $metadataPath) {
        $flag = if ($modes[$relative]) { '--chmod=+x' } else { '--chmod=-x' }
        $null = Invoke-VendoringGit @('update-index', $flag, '--', $relative)
    }
}
$diff = Invoke-VendoringGit @('diff', '--cached', '--stat')
if (-not $diff) {
    $result = [pscustomobject]@{ HasChanges = $false; Branch = $branch; PullRequest = $null }
}
else {
    $null = Invoke-VendoringGit @('-c', 'user.name=Platform vendoring', '-c', "user.email=$vendoringEmail",
        'commit', '--quiet', '-m', "Vendor $($receipt['Repository']) at $($receipt['Tag'])")
    $body = @"
Vendoring $($receipt['Repository']) at tag $($receipt['Tag']), commit $($receipt['Commit']).

Source SHA256: $($receipt['Sha256'])
Attestation: $($receipt['Attestation']). Absence is not verification.

Cloud PR plan: **NOT PERFORMED**. This App-created PR receives no cloud credentials.
Review and merge into protected main must precede the main plan and approved apply (ADR 0016).
Release workflow templates stay under platform/; promotion of live workflows is a separate reviewed manual step.
"@
    $title = "Vendor $($receipt['Repository']) $($receipt['Tag'])"
    $apiBase = "$($ApiUrl.TrimEnd('/'))/repos/$Repository/pulls"
    $headFilter = [uri]::EscapeDataString("$($owner):$branch")
    $listed = Invoke-RestMethod -Uri "$($apiBase)?state=all&head=$headFilter&per_page=100" -Headers $headers
    if (@($listed).Count -ge 100) { throw "Import branch '$branch' has too many pull requests to inspect." }
    # Inspect the PRs before the push, which would synchronize any PR of the branch.
    $pullRequest = Select-VendoringPullRequest -PullRequests @($listed) -Branch $branch -Repository $Repository
    $localTree = Invoke-VendoringGit @('rev-parse', 'HEAD^{tree}')
    $localParent = Invoke-VendoringGit @('rev-parse', 'HEAD~1')
    $branchPattern = "^(?<sha>[0-9a-f]{40})\trefs/heads/$([regex]::Escape($branch))$"
    $remoteHeads = @(@(Invoke-VendoringRemoteGit @('ls-remote', '--heads', $remote, "refs/heads/$branch")) | Where-Object { $_ -cmatch $branchPattern })
    $expected = ''
    $push = $true
    if ($remoteHeads.Count -gt 1) { throw "Remote lists import branch '$branch' more than once." }
    if ($remoteHeads.Count -eq 1) {
        # A previous attempt pushed the branch: reuse an identical commit, replace a stale vendoring commit, stop otherwise.
        $expected = ($remoteHeads[0] -csplit "`t")[0]
        $null = Invoke-VendoringRemoteGit @('fetch', '--quiet', '--no-tags', $remote, "+refs/heads/${branch}:refs/vendoring/remote")
        if ((Invoke-VendoringGit @('rev-parse', 'refs/vendoring/remote')) -cne $expected) {
            throw "Import branch '$branch' changed during the import; inspect it before importing again."
        }
        $remoteCommit = @(Invoke-VendoringGit @('log', '-1', '--format=%ce%n%P', $expected))
        $remoteParents = @(([string] $remoteCommit[1]).Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
        $parentOnMain = $false
        if ($remoteParents.Count -eq 1) {
            & git -C $target merge-base --is-ancestor $remoteParents[0] $localParent 2>$null
            $parentOnMain = $LASTEXITCODE -eq 0
            if ($LASTEXITCODE -notin @(0, 1)) { throw "Git vendoring command 'merge-base' failed with exit code $LASTEXITCODE." }
        }
        if (-not (Test-VendoringBranchReplaceable -Committer $remoteCommit[0] -Parents $remoteParents -ParentOnMain $parentOnMain)) {
            throw "Import branch '$branch' contains commits that the vendoring App did not create on top of main; inspect it before importing again."
        }
        $push = (Invoke-VendoringGit @('rev-parse', "$expected^{tree}")) -cne $localTree -or $remoteParents[0] -cne $localParent
    }
    if ($push) {
        $null = Invoke-VendoringRemoteGit @('push', '--quiet', "--force-with-lease=refs/heads/${branch}:$expected", $remote, "HEAD:refs/heads/$branch")
    }
    if ($null -eq $pullRequest) {
        $pullRequest = Invoke-RestMethod -Uri $apiBase -Method POST -Headers $headers -ContentType application/json -Body (ConvertTo-Json -InputObject @{
                title = $title; head = $branch; base = 'main'; body = $body
            } -Compress)
        if (-not $pullRequest.html_url) { throw "GitHub did not return a PR URL; branch '$branch' was pushed and requires inspection." }
    }
    elseif ($pullRequest.title -cne $title -or ([string] $pullRequest.body -creplace "`r`n", "`n") -cne ($body -creplace "`r`n", "`n")) {
        # A re-tagged source or a reworded description updates the existing PR instead of opening another one.
        $pullRequest = Invoke-RestMethod -Uri "$apiBase/$($pullRequest.number)" -Method PATCH -Headers $headers -ContentType application/json -Body (ConvertTo-Json -InputObject @{
                title = $title; body = $body
            } -Compress)
        if (-not $pullRequest.html_url) { throw "GitHub did not return the updated PR URL for branch '$branch'." }
    }
    $result = [pscustomobject]@{ HasChanges = $true; Branch = $branch; PullRequest = $pullRequest.html_url }
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
