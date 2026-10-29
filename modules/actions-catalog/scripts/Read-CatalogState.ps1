#Requires -Version 7.4
<#
.SYNOPSIS
Program of the Terraform external data source: reads the state of one catalog repository.
.DESCRIPTION
Reads the query {api_url, organization, upstream, security_team, tag, commit, upstream_commit} from standard input; release fields are
empty strings for an action without a release. Writes {"state": "<JSON>", "violations": "<JSON array>"}. Any read
error exits non-zero, so the plan fails instead of treating an unknown state as compliant.
#>
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'ActionsCatalog.psm1') -Force
    $query = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    if ($query -isnot [System.Collections.IDictionary]) { throw 'The query is not a JSON object.' }
    foreach ($key in @('api_url', 'organization', 'upstream', 'security_team')) {
        if ($query[$key] -isnot [string] -or -not $query[$key]) { throw "The query has no '$key'." }
    }
    foreach ($key in @('tag', 'commit', 'upstream_commit')) {
        if ($query[$key] -isnot [string]) { throw "The query has no string '$key'." }
    }
    $target = @{ Organization = $query['organization']; SecurityTeam = $query['security_team']; Tag = $query['tag']; Commit = $query['commit'] }
    $state = Get-CatalogRepositoryState @target -ApiUrl $query['api_url'] -Upstream $query['upstream'] -UpstreamCommit $query['upstream_commit']
    $violations = @(Get-CatalogStateViolation @target -State $state)
    [Console]::Out.Write((ConvertTo-CatalogStateResult -State $state -Violation $violations))
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
