#Requires -Version 7.4
[CmdletBinding()]
param([ValidateSet('Terraform')][string] $Name = 'Terraform')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1')
if (-not $IsLinux -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'CI binary pins support Linux amd64 only.'
}
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
$command = Get-Command $Name.ToLowerInvariant() -CommandType Application -ErrorAction Stop | Select-Object -First 1
Assert-ToolPackage -Path $command.Source -Sha256 $requirements.Binaries[$Name].LinuxAmd64Sha256 -Name $Name
