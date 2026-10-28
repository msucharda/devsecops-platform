#Requires -Version 7.4
[CmdletBinding()]
param(
    [ValidateSet('TFLint', 'Actionlint', 'Terraform')][string] $Name = 'TFLint',
    [switch] $Local
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1')
$package = Get-ToolBinaryPackage -Name $Name
$parent = if ($Local) { Split-Path $package.CachePath -Parent } else { $env:RUNNER_TEMP }
$null = New-Item -ItemType Directory -Path $parent -Force
$directory = Join-Path $parent "platform-$($Name.ToLowerInvariant())-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$published = $false
try {
    if ($Local -and (Test-Path -LiteralPath $package.CachePath -PathType Leaf)) {
        Assert-ToolPackage -Path $package.CachePath -Sha256 $package.Sha256 -Name $Name
        return
    }
    $archive = Join-Path $directory $package.Archive
    Invoke-WebRequest -Uri $package.Uri -OutFile $archive -ErrorAction Stop
    Assert-ToolPackage -Path $archive -Sha256 $package.Sha256 -Name $Name
    if ($Local) {
        [IO.File]::Move($archive, $package.CachePath, $true)
        return
    }
    $null = Expand-ToolBinary -Package $package -ArchivePath $archive -DestinationPath $directory
    Add-Content -LiteralPath $env:GITHUB_PATH -Value $directory
    $published = $true
}
finally {
    if (-not $published) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
