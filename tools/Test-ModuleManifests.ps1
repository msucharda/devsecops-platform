#Requires -Version 7.4
[CmdletBinding()]
param([string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'))

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
Write-Verbose "Validated $($modules.PSBase.Count) module manifests and their prerequisites."
