#Requires -Version 7.4
[CmdletBinding()]
param([Parameter(Mandatory)][ValidateSet('Set', 'Remove')][string] $Action)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
try {
    Import-Module (Join-Path $PSScriptRoot 'Rulesets.psm1') -Force
    if (-not $env:RULESET_INPUT) { throw 'RULESET_INPUT is not set.' }
    $resourceInput = $env:RULESET_INPUT | ConvertFrom-Json -AsHashtable
    foreach ($key in @('api_url', 'organization')) {
        if ($resourceInput -isnot [Collections.IDictionary] -or -not $resourceInput[$key]) { throw "RULESET_INPUT has no '$key'." }
    }
    $target = @{ ApiUrl = $resourceInput['api_url']; Organization = $resourceInput['organization'] }
    if ($Action -ceq 'Set') { Set-OrganizationRuleset @target -Ruleset $resourceInput['ruleset'] }
    else { Remove-OrganizationRuleset @target -Name $resourceInput['name'] }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
