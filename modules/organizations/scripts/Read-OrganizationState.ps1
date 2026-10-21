#Requires -Version 7.4
<#
.SYNOPSIS
Program of the Terraform external data source: reads the state of one instance organization.
.DESCRIPTION
Reads the query {api_url, enterprise, organization, client_ids} from standard input; client_ids is a JSON array in a string
because the external data source passes only strings. Writes {"state": "<JSON>", "violations": "<JSON array>"}.
Any read error exits non-zero, so the plan fails instead of treating an unknown state as compliant.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Organizations.psm1') -Force
    $query = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    foreach ($key in @('api_url', 'enterprise', 'organization', 'client_ids')) {
        if ($query -isnot [System.Collections.IDictionary] -or -not $query[$key]) { throw "The query has no '$key'." }
    }
    $clientIds = ConvertFrom-Json -InputObject $query['client_ids'] -NoEnumerate
    if ($clientIds -isnot [array] -or @($clientIds | Where-Object { $_ -isnot [string] -or -not $_ }).Count) {
        throw "The query client_ids is not a JSON array of client IDs."
    }
    $state = Get-InstanceOrganizationState -ApiUrl $query['api_url'] -Enterprise $query['enterprise'] -Organization $query['organization'] `
        -ClientId ([string[]] $clientIds)
    $violations = Get-OrganizationStateViolation -State $state -Organization $query['organization'] -ClientId ([string[]] $clientIds)
    [Console]::Out.Write((ConvertTo-OrganizationStateResult -State $state -Violation $violations))
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
