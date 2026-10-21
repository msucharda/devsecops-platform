#Requires -Version 7.4
<#
.SYNOPSIS
Program of the Terraform external data source: reads the state of one instance organization.
.DESCRIPTION
Reads the query {api_url, enterprise, organization} from standard input and writes {"state": "<JSON>"}.
Any read error exits non-zero, so the plan fails instead of treating an unknown state as compliant.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Organizations.psm1') -Force
    $query = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    foreach ($key in @('api_url', 'enterprise', 'organization')) {
        if ($query -isnot [System.Collections.IDictionary] -or -not $query[$key]) { throw "The query has no '$key'." }
    }
    $state = Get-InstanceOrganizationState -ApiUrl $query['api_url'] -Enterprise $query['enterprise'] -Organization $query['organization']
    [Console]::Out.Write((ConvertTo-Json -Compress -InputObject @{ state = (ConvertTo-Json -InputObject $state -Depth 10 -Compress) }))
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
