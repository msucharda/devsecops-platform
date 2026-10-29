#Requires -Version 7.4
<#
.SYNOPSIS
Provisioner program of the actions-catalog module: creates or adopts a catalog repository, or tags an approved import.
.DESCRIPTION
Reads the resource input as JSON from CATALOG_INPUT. Every action is idempotent, so Terraform can repeat it after an
interrupted run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('InitializeRepository', 'CreateReleaseTag')]
    [string] $Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'ActionsCatalog.psm1') -Force
    if (-not $env:CATALOG_INPUT) { throw 'CATALOG_INPUT is not set.' }
    $resourceInput = $env:CATALOG_INPUT | ConvertFrom-Json -AsHashtable
    $required = @('api_url', 'organization', 'upstream', 'security_team')
    if ($Action -eq 'CreateReleaseTag') { $required += @('tag', 'commit', 'upstream_commit') }
    foreach ($key in $required) {
        if ($resourceInput -isnot [System.Collections.IDictionary] -or $resourceInput[$key] -isnot [string] -or -not $resourceInput[$key]) {
            throw "CATALOG_INPUT has no '$key'."
        }
    }
    $target = @{
        ApiUrl = $resourceInput['api_url']; Organization = $resourceInput['organization']
        Upstream = $resourceInput['upstream']; SecurityTeam = $resourceInput['security_team']
    }
    switch ($Action) {
        'InitializeRepository' { Initialize-CatalogRepository @target }
        'CreateReleaseTag' { New-CatalogReleaseTag @target -Tag $resourceInput['tag'] -Commit $resourceInput['commit'] -UpstreamCommit $resourceInput['upstream_commit'] }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
