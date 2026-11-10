#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourcePath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $Repository,
    [Parameter(Mandatory)][string] $Commit
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PublicationSource.psm1')

# security-check: platform-release-build-boundary
function Assert-PlatformReleaseBuildSource {
    param([string] $SourcePath, [string] $Repository, [string] $Commit)

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
        $response = Invoke-WebRequest -Uri "$base/$Route" -Headers $headers -MaximumRedirection 0
        return ,($response.Content | ConvertFrom-Json -AsHashtable -NoEnumerate)
    }
    Assert-PlatformPublishedSource -Repository $Repository -Commit $Commit -PublisherAppId $policy.PublisherAppId -Read $read
}

Assert-PlatformReleaseBuildSource -SourcePath $SourcePath -Repository $Repository -Commit $Commit
