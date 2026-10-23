#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $SourceRepository,
    [Parameter(Mandatory)][ValidatePattern('^[^\s]+$')][string] $Tag,
    [Parameter(Mandatory)][string] $InstancePath,
    [Parameter(Mandatory)][string] $PlatformOrganization,
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1') -Force
$instance = Get-PlatformYaml -Path $InstancePath
$organizations = Get-PlatformInstanceOrganization -InstanceName $instance['instance']['name'] -PlatformOrganization $PlatformOrganization
$source = $SourceRepository.ToLowerInvariant()
$result = [pscustomobject] @{
    SourceRepository = $source
    Tag = $Tag
    ActionsOrganization = $organizations['actions']
    TargetRepository = "$($organizations['actions'])/$($source.Replace('/', '-'))"
}
if ($GitHubOutputPath) {
    Add-Content -LiteralPath $GitHubOutputPath -Value @(
        "source-repository=$($result.SourceRepository)"
        "target-repository=$($result.TargetRepository)"
        "actions-organization=$($result.ActionsOrganization)"
    )
}
return $result
