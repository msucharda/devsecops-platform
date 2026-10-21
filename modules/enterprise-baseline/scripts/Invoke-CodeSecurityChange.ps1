#Requires -Version 7.4
<#
.SYNOPSIS
Provisioner program of the code security resources: writes or deletes one configuration or custom pattern.
.DESCRIPTION
Reads the resource input as JSON from CODE_SECURITY_INPUT. Every action is idempotent by name, so Terraform can
repeat it after an interrupted run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('SetConfiguration', 'RemoveConfiguration', 'SetCustomPattern', 'RemoveCustomPattern')]
    [string] $Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'CodeSecurity.psm1') -Force
    if (-not $env:CODE_SECURITY_INPUT) { throw 'CODE_SECURITY_INPUT is not set.' }
    $resourceInput = $env:CODE_SECURITY_INPUT | ConvertFrom-Json -AsHashtable
    foreach ($key in @('api_url', 'organization')) {
        if ($resourceInput -isnot [System.Collections.IDictionary] -or -not $resourceInput[$key]) { throw "CODE_SECURITY_INPUT has no '$key'." }
    }
    $target = @{ ApiUrl = $resourceInput['api_url']; Organization = $resourceInput['organization'] }
    switch ($Action) {
        'SetConfiguration' {
            $timeout = if ($env:CODE_SECURITY_ATTACHMENT_TIMEOUT) { [int] $env:CODE_SECURITY_ATTACHMENT_TIMEOUT } else { 600 }
            Set-CodeSecurityConfiguration @target -Configuration $resourceInput['configuration'] -AttachmentTimeoutSeconds $timeout
        }
        'RemoveConfiguration' { Remove-CodeSecurityConfiguration @target -Name $resourceInput['name'] }
        'SetCustomPattern' { Set-CustomPattern @target -Pattern $resourceInput['pattern'] }
        'RemoveCustomPattern' { Remove-CustomPattern @target -Name $resourceInput['name'] }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
