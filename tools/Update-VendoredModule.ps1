#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidatePattern('^\d+\.\d+\.\d+$')][string] $Version,
    [Parameter(Mandatory)][ValidatePattern('^[0-9a-fA-F]{64}$')][string] $Sha256,
    [string] $ToolsPath = $PSScriptRoot
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1') -Force
$requirementsPath = Join-Path $ToolsPath 'requirements.psd1'
$requirementsText = Get-Content -LiteralPath $requirementsPath -Raw
$requirements = Import-PowerShellDataFile $requirementsPath
$name = 'powershell-yaml'
$staging = Join-Path $ToolsPath ".dependencies/vendor-update-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $staging -Force
try {
    $package = Join-Path $staging "$name.$Version.nupkg"
    Invoke-WebRequest -Uri "https://www.powershellgallery.com/api/v2/package/$name/$Version" -OutFile $package -ErrorAction Stop
    Assert-ToolPackage -Path $package -Sha256 $Sha256 -Name $name
    $expanded = Join-Path $staging 'module'
    Expand-ToolPackage -PackagePath $package -DestinationPath $expanded
    Assert-ToolModulePayload -PackagePath $package -ModulePath $expanded
    $manifest = Import-PowerShellDataFile (Join-Path $expanded "$name.psd1")
    if ($manifest.ModuleVersion -cne $Version) { throw 'Package manifest version does not match the requested version.' }
    foreach ($license in @('LICENSE', 'lib/net47/LICENSE.txt', 'lib/netstandard2.1/LICENSE.txt')) {
        if (-not (Test-Path -LiteralPath (Join-Path $expanded $license) -PathType Leaf)) {
            throw "Package is missing required license '$license'."
        }
    }

    $vendor = Join-Path $ToolsPath 'vendor'
    $destination = Join-Path $vendor "$name/$Version"
    $storedPackage = Join-Path $vendor "packages/$name.$Version.nupkg"
    if (Test-Path -LiteralPath $destination) {
        Assert-ToolModulePayload -PackagePath $package -ModulePath $destination
    }
    else {
        $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
        Move-Item -LiteralPath $expanded -Destination $destination
    }
    $null = New-Item -ItemType Directory -Path (Split-Path $storedPackage -Parent) -Force
    if (Test-Path -LiteralPath $storedPackage) {
        Assert-ToolPackage -Path $storedPackage -Sha256 $Sha256 -Name $name
    }
    else {
        Move-Item -LiteralPath $package -Destination $storedPackage
    }
    $oldVersion = [regex]::Escape($requirements.Runtime[$name])
    $oldHash = [regex]::Escape($requirements.Sha256[$name])
    $newText = $requirementsText -creplace "('powershell-yaml'\s*=\s*)'$oldVersion'", "`${1}'$Version'"
    $newText = $newText -creplace "('powershell-yaml'\s*=\s*)'$oldHash'", "`${1}'$($Sha256.ToLowerInvariant())'"
    $temporaryRequirements = Join-Path $ToolsPath "requirements.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporaryRequirements, $newText)
        Move-Item -LiteralPath $temporaryRequirements -Destination $requirementsPath -Force
    }
    finally {
        if (Test-Path -LiteralPath $temporaryRequirements) { Remove-Item -LiteralPath $temporaryRequirements -Force }
    }
    Write-Information "Prepared $name $Version. Review the package, licenses and requirements changes before committing." -InformationAction Continue
}
finally {
    Remove-Item -LiteralPath $staging -Recurse -Force
}
