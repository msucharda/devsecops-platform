#Requires -Version 7.4
<#
.SYNOPSIS
Provisioner program of the actions policy resources: writes the managed or the GitHub default policy of one organization.
.DESCRIPTION
Reads the resource input {api_url, organization, policy} as JSON from ACTIONS_POLICY_INPUT. Both actions write the
policy of the input with idempotent PUT requests, so Terraform can repeat them after an interrupted run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('SetPolicy', 'ResetPolicy')]
    [string] $Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'ActionsPolicy.psm1') -Force
    if (-not $env:ACTIONS_POLICY_INPUT) { throw 'ACTIONS_POLICY_INPUT is not set.' }
    $resourceInput = $env:ACTIONS_POLICY_INPUT | ConvertFrom-Json -AsHashtable
    foreach ($key in @('api_url', 'organization', 'policy')) {
        if ($resourceInput -isnot [System.Collections.IDictionary] -or -not $resourceInput[$key]) { throw "ACTIONS_POLICY_INPUT has no '$key'." }
    }
    Write-Verbose "$Action for $($resourceInput['organization'])."
    Set-ActionsPolicy -ApiUrl $resourceInput['api_url'] -Organization $resourceInput['organization'] -Policy $resourceInput['policy'] -Reset:($Action -ceq 'ResetPolicy')
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
