#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [Parameter(Mandatory)][AllowEmptyString()][string] $ConfirmInstanceName
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')

$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
$teardown = $instance['teardown']
if ($teardown -isnot [System.Collections.IDictionary] -or -not $teardown.Contains('allowed') -or
    $teardown['allowed'] -isnot [bool] -or -not $teardown['allowed']) {
    throw 'Teardown is denied: $.teardown.allowed must be true in instance.yaml on main.'
}
$name = $instance['instance']['name']
if ($ConfirmInstanceName -cne $name) {
    throw "Teardown confirmation does not match: type the instance name '$name' exactly."
}
if ('emu-identity' -cnotin (Get-PlatformModuleSelection -Instance $instance -Modules $modules)) {
    throw 'Teardown requires the emu-identity module: its plan identity verifies the direct Enterprise Owner assignment before any destroy.'
}
Write-Information "Teardown of instance '$name' is enabled and confirmed." -InformationAction Continue
