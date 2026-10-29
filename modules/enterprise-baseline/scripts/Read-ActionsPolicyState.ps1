#Requires -Version 7.4
<#
.SYNOPSIS
Program of the Terraform external data source: reads the actions policy of one organization and lists its violations.
.DESCRIPTION
Reads the query {api_url, organization, enabled_repositories, allowed_actions, sha_pinning_required, default_workflow_permissions,
can_approve_pull_request_reviews} from standard input and writes {"state": "<JSON>", "violations": "<JSON array>"}.
Any read error exits non-zero, so the plan fails instead of treating an unknown state as compliant.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'ActionsPolicy.psm1') -Force
    $query = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    foreach ($key in @('api_url', 'organization')) {
        if ($query -isnot [System.Collections.IDictionary] -or -not $query[$key]) { throw "The query has no '$key'." }
    }
    [Console]::Out.Write((Get-ActionsPolicyStateResult -ApiUrl $query['api_url'] -Organization $query['organization'] -Policy $query))
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
