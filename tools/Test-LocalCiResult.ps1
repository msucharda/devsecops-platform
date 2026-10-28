#Requires -Version 7.4
[CmdletBinding()]
param([string] $Base, [string] $ExpectedHead)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalCiGate.psm1') -Force
try {
    $null = Test-LocalCiGateResult -RepositoryRoot (Split-Path $PSScriptRoot -Parent) -Base $Base -ExpectedHead $ExpectedHead
    Write-Information 'Selected local gate result matches HEAD, base and working-tree content.' -InformationAction Continue
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
