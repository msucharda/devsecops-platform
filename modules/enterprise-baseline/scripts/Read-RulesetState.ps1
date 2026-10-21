#Requires -Version 7.4
[CmdletBinding()]
param()

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Rulesets.psm1') -Force
    $query = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
    foreach ($key in @('api_url', 'organization', 'name')) {
        if ($query -isnot [Collections.IDictionary] -or -not $query[$key]) { throw "The ruleset query has no '$key'." }
    }
    $state = Get-OrganizationRulesetState -ApiUrl $query['api_url'] -Organization $query['organization'] -Name $query['name']
    [Console]::Out.Write((ConvertTo-Json -Compress -InputObject @{ state = (ConvertTo-Json -InputObject $state -Depth 50 -Compress) }))
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
