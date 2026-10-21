#Requires -Version 7.4
<#
.SYNOPSIS
Derives the vendoring inputs for importing one attested platform release into the instance repository.
.DESCRIPTION
The tag must be a stable SemVer release (vMAJOR.MINOR.PATCH) or a release candidate (vMAJOR.MINOR.PATCH-rc.N).
The actions organization comes from the platform organization and instance.name, the same derivation the
organizations module uses. The asset name is the one the source release workflow publishes and attests.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][AllowEmptyString()][string] $Tag,
    [Parameter(Mandatory)][string] $InstancePath,
    [Parameter(Mandatory)][AllowEmptyString()][string] $PlatformOrganization,
    [AllowEmptyString()][string] $SourceRepository,
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1') -Force

if ($Tag -cnotmatch '^v(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$') {
    throw "Release tag '$Tag' must be vMAJOR.MINOR.PATCH or vMAJOR.MINOR.PATCH-rc.N."
}
if (-not $SourceRepository) { $SourceRepository = 'msucharda/devsecops-platform' }
if ($SourceRepository -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$') {
    throw "Platform source repository '$SourceRepository' must be owner/repo."
}
$instance = Get-PlatformYaml -Path $InstancePath
if ($instance -isnot [Collections.IDictionary] -or $instance['instance'] -isnot [Collections.IDictionary] -or
    $instance['instance']['name'] -isnot [string]) {
    throw "Instance configuration '$InstancePath' must declare instance.name."
}
$organizations = Get-PlatformInstanceOrganization -InstanceName $instance['instance']['name'] -PlatformOrganization $PlatformOrganization
$result = [pscustomobject] @{
    SourceRepository = $SourceRepository
    Tag = $Tag
    Asset = "platform-$Tag.zip"
    Prerelease = $Tag.Contains('-rc.')
    ActionsOrganization = $organizations['actions']
}
if ($GitHubOutputPath) {
    Add-Content -LiteralPath $GitHubOutputPath -Value @(
        "source-repository=$($result.SourceRepository)"
        "source-asset=$($result.Asset)"
        "actions-organization=$($result.ActionsOrganization)"
    )
}
return $result
