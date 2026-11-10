#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourcePath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][string] $Commit,
    [string] $PublicationPredicatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# security-check: platform-publication-predicate-output
function Clear-PlatformPublicationPredicateOutput {
    param([string] $Path)
    if ($Path) {
        try { $item = Get-Item -LiteralPath $Path -Force -ErrorAction Stop }
        catch [Management.Automation.ItemNotFoundException] { return }
        if ($item.PSIsContainer -or ($item.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Publication signing requires a regular predicate output file, not a directory or link.'
        }
        Remove-Item -LiteralPath $Path -Force -ErrorAction Stop
    }
}
if ($PublicationPredicatePath) {
    $PublicationPredicatePath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($PublicationPredicatePath)
}
Clear-PlatformPublicationPredicateOutput -Path $PublicationPredicatePath
Import-Module (Join-Path $PSScriptRoot 'PublicationSource.psm1')
. (Join-Path $PSScriptRoot 'SourceRequest.ps1')

# security-check: platform-release-build-boundary
function Assert-PlatformReleaseBuildSource {
    param([string] $SourcePath, [string] $Repository, [string] $Commit, [string] $PublicationPredicatePath)

    if ($Commit -cnotmatch '\A[0-9a-f]{40}\z') { throw 'Invalid release build commit.' }
    $head = & git -C $SourcePath rev-parse --verify 'HEAD^{commit}'
    if ($LASTEXITCODE -ne 0 -or $head -isnot [string] -or $head -cne $Commit) {
        throw 'Release source checkout must match the exact build commit.'
    }
    $dirty = @(& git -C $SourcePath status --porcelain --untracked-files=all --ignored -- release-source-policy.json)
    if ($LASTEXITCODE -ne 0 -or $dirty.Count -ne 0) {
        throw 'Release source declaration must match the committed checkout, including absence.'
    }
    $policy = Get-PlatformReleaseSourcePolicy -SourcePath $SourcePath
    if ($policy.Line -eq 'main') {
        & git -C $SourcePath merge-base --is-ancestor $Commit refs/remotes/origin/main
        if ($LASTEXITCODE -ne 0) { throw 'Release commit must be on the original main authority.' }
        return
    }
    $base = "https://api.github.com/repos/$Repository"
    $headers = @{ Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
    $read = {
        param($Route)
        $requestUri = "$base/$Route"
        $response = Invoke-SourceRequest {
            Invoke-WebRequest -Uri $requestUri -Headers $headers -MaximumRedirection 0
        }
        return ,($response.Content | ConvertFrom-Json -AsHashtable -NoEnumerate)
    }
    if ($PublicationPredicatePath) {
        $predicate = New-PlatformPublicationPredicate -Repository $Repository -Commit $Commit -PublisherAppId $policy.PublisherAppId -Read $read
        $stagingPath = "$PublicationPredicatePath.$([guid]::NewGuid().ToString('N')).new"
        try {
            $predicate | ConvertTo-Json -Compress | Set-Content -LiteralPath $stagingPath -Encoding utf8NoBOM
            [IO.File]::Move($stagingPath, $PublicationPredicatePath)
        }
        finally {
            if (Test-Path -LiteralPath $stagingPath) { Remove-Item -LiteralPath $stagingPath -Force -ErrorAction Stop }
        }
        return
    }
    Assert-PlatformPublishedSource -Repository $Repository -Commit $Commit -PublisherAppId $policy.PublisherAppId -Read $read
}

Assert-PlatformReleaseBuildSource -SourcePath $SourcePath -Repository $Repository -Commit $Commit -PublicationPredicatePath $PublicationPredicatePath
