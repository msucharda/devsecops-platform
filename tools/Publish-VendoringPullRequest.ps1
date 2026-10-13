#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $PreparedPath,
    [Parameter(Mandatory)][string] $TargetPath,
    [Parameter(Mandatory)][string] $ReceiptPath,
    [Parameter(Mandatory)][ValidateSet('action', 'release')][string] $Kind,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][string] $ApiUrl,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9-]+$')][string] $RunIdentifier,
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
$oldFiles = @(Invoke-VendoringGit @('ls-files')) | Where-Object {
    if ($Kind -eq 'release') { $_.StartsWith('platform/') } else { -not $_.StartsWith('.github/') -and $_ -cne '.vendoring.json' }
}
$branch = "vendor/$Kind/$($receipt['Sha256'].Substring(0, 12))-$RunIdentifier"
$null = Invoke-VendoringGit @('switch', '--quiet', '-c', $branch)
foreach ($relative in $oldFiles) {
    if (-not $newFiles.Contains($relative)) {
        $null = Invoke-VendoringGit @('rm', '--quiet', '--', $relative)
    }
}
foreach ($relative in $newFiles) {
    $destination = Join-Path $target $relative
    $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
    Copy-Item -LiteralPath (Join-Path $prepared $relative) -Destination $destination -Force
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($destination, [IO.File]::GetUnixFileMode((Join-Path $prepared $relative))) }
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
}
$diff = Invoke-VendoringGit @('diff', '--cached', '--stat')
if (-not $diff) {
    $result = [pscustomobject]@{ HasChanges = $false; Branch = $branch; PullRequest = $null }
}
else {
    $null = Invoke-VendoringGit @('-c', 'user.name=Platform vendoring', '-c', 'user.email=platform-vendoring@users.noreply.github.com',
        'commit', '--quiet', '-m', "Vendor $($receipt['Repository']) at $($receipt['Tag'])")
    $hostName = ([uri] $ApiUrl).Host -replace '^api\.', ''
    $remote = "https://$hostName/$Repository.git"
    $names = @('GIT_CONFIG_COUNT', 'GIT_CONFIG_KEY_0', 'GIT_CONFIG_VALUE_0')
    $saved = @{}
    foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        $env:GIT_CONFIG_COUNT = '1'
        $env:GIT_CONFIG_KEY_0 = "http.$remote.extraheader"
        $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("x-access-token:$($env:GH_TOKEN)"))
        $env:GIT_CONFIG_VALUE_0 = "AUTHORIZATION: basic $encoded"
        $null = Invoke-VendoringGit @('-c', 'credential.helper=', 'push', '--quiet', $remote, "HEAD:refs/heads/$branch")
    }
    finally {
        foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
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
    if (-not $pullRequest.html_url) { throw "GitHub did not return a PR URL; branch '$branch' was pushed and requires inspection." }
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
