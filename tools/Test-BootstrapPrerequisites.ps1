#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [switch] $AllowUnboundApps
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# Runs the bootstrap checks without changes and reports every result instead of stopping at the first failure.
& (Join-Path $PSScriptRoot 'Invoke-Bootstrap.ps1') -InstancePath $InstancePath -ModulesPath $ModulesPath -AllowUnboundApps:$AllowUnboundApps -Preflight
