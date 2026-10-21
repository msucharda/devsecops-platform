#Requires -Version 7.4
<#
.SYNOPSIS
Program of the Terraform external data source: reads the code security state of one organization.
.DESCRIPTION
Reads the query {api_url, organization, configuration_name} from standard input and writes {"state": "<JSON>"}.
Any read error exits non-zero, so the plan fails instead of treating an unknown state as compliant.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'CodeSecurity.psm1') -Force
    $query = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    foreach ($key in @('api_url', 'organization', 'configuration_name')) {
        if ($query -isnot [System.Collections.IDictionary] -or -not $query[$key]) { throw "The query has no '$key'." }
    }
    $state = Get-CodeSecurityState -ApiUrl $query['api_url'] -Organization $query['organization'] -ConfigurationName $query['configuration_name']
    [Console]::Out.Write((ConvertTo-Json -Compress -InputObject @{ state = (ConvertTo-Json -InputObject $state -Depth 50 -Compress) }))
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
