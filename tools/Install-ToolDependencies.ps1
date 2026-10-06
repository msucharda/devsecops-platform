#Requires -Version 7.4
[CmdletBinding()]
param([switch] $Development)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
$dependencies = @{} + $requirements.Runtime
if ($Development) {
    $dependencies += $requirements.Development
}
foreach ($name in ($dependencies.Keys | Sort-Object)) {
    $version = $dependencies[$name]
    $installed = Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq [version] $version }
    if (-not $installed) {
        Install-Module -Name $name -RequiredVersion $version -Repository PSGallery -Scope CurrentUser -Force -AllowClobber
    }
}
