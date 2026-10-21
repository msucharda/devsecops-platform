#Requires -Version 7.4
<#
.SYNOPSIS
Provisioner program of the organizations module: creates an organization, verifies its removal, or installs and removes an App.
.DESCRIPTION
Reads the resource input as JSON from ORGANIZATIONS_INPUT. Every action is idempotent, so Terraform can repeat it
after an interrupted run.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)]
    [ValidateSet('CreateOrganization', 'AssertOrganizationRemoved', 'InstallApp', 'UninstallApp')]
    [string] $Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

try {
    Import-Module (Join-Path $PSScriptRoot 'Organizations.psm1') -Force
    if (-not $env:ORGANIZATIONS_INPUT) { throw 'ORGANIZATIONS_INPUT is not set.' }
    $resourceInput = $env:ORGANIZATIONS_INPUT | ConvertFrom-Json -AsHashtable
    $required = switch ($Action) {
        'CreateOrganization' { @('api_url', 'enterprise', 'organization', 'admin_logins', 'billing_email') }
        { $_ -in @('InstallApp', 'UninstallApp') } { @('api_url', 'enterprise', 'organization', 'client_id') }
        default { @('api_url', 'enterprise', 'organization') }
    }
    foreach ($key in $required) {
        if ($resourceInput -isnot [System.Collections.IDictionary] -or -not $resourceInput[$key]) { throw "ORGANIZATIONS_INPUT has no '$key'." }
    }
    $target = @{ ApiUrl = $resourceInput['api_url']; Enterprise = $resourceInput['enterprise']; Organization = $resourceInput['organization'] }
    switch ($Action) {
        'CreateOrganization' {
            if ($resourceInput['allow_existing'] -isnot [bool]) { throw "ORGANIZATIONS_INPUT has no boolean 'allow_existing'." }
            $null = New-EnterpriseOrganization @target -AdminLogins @($resourceInput['admin_logins']) -BillingEmail $resourceInput['billing_email'] `
                -AllowExisting:$resourceInput['allow_existing'] -InformationAction Continue
        }
        'AssertOrganizationRemoved' { Assert-EnterpriseOrganizationRemoved @target }
        'InstallApp' { $null = Install-OrganizationApp @target -ClientId $resourceInput['client_id'] }
        'UninstallApp' { Uninstall-OrganizationApp @target -ClientId $resourceInput['client_id'] }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
