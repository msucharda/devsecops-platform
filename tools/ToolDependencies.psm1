#Requires -Version 7.4
Set-StrictMode -Version Latest

# security-check: tool-package-sha256
function Assert-ToolPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][AllowEmptyString()][string] $Sha256,
        [Parameter(Mandatory)][string] $Name
    )

    if ($Sha256 -notmatch '^[0-9a-fA-F]{64}$') {
        throw "Invalid SHA256 pin for $Name."
    }
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256 -ErrorAction Stop).Hash -ine $Sha256) {
        throw "SHA256 mismatch for $Name."
    }
}

function Get-ToolPackagePayload {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $archive = [IO.Compression.ZipFile]::OpenRead($Path)
    try {
        foreach ($entry in $archive.Entries) {
            $name = $entry.FullName
            if ($name.EndsWith('/') -or $name -like '_rels/*' -or $name -like 'package/*' -or
                $name -like '*.nuspec' -or $name -ceq '[Content_Types].xml') { continue }
            $stream = $entry.Open()
            try {
                [pscustomobject]@{ Name = $name; Sha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) }
            }
            finally { $stream.Dispose() }
        }
    }
    finally { $archive.Dispose() }
}

# security-check: tool-module-payload
function Assert-ToolModulePayload {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PackagePath,
        [Parameter(Mandatory)][string] $ModulePath
    )

    $payload = @(Get-ToolPackagePayload -Path $PackagePath)
    foreach ($entry in $payload) {
        $file = Join-Path $ModulePath $entry.Name
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Module payload is missing '$($entry.Name)'."
        }
        Assert-ToolPackage -Path $file -Sha256 $entry.Sha256 -Name $entry.Name
    }
    $files = @(Get-ChildItem -LiteralPath $ModulePath -File -Recurse -Force | Where-Object {
        $_.Name -ne 'PSGetModuleInfo.xml'
    })
    if ($files.Count -ne $payload.Count) {
        throw "Module payload contains unexpected files in '$ModulePath'."
    }
}

function Expand-ToolPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $PackagePath,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    [IO.Compression.ZipFile]::ExtractToDirectory($PackagePath, $DestinationPath)
    Remove-Item -LiteralPath (Join-Path $DestinationPath '_rels'), (Join-Path $DestinationPath 'package') -Recurse -Force
    Remove-Item -LiteralPath (Join-Path $DestinationPath '[Content_Types].xml') -Force
    Get-ChildItem -LiteralPath $DestinationPath -Filter '*.nuspec' -File | Remove-Item -Force
}

function Get-ToolDependencyPath {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [string] $ToolsPath = $PSScriptRoot,
        [switch] $ReuseLoaded
    )

    $requirements = Import-PowerShellDataFile (Join-Path $ToolsPath 'requirements.psd1')
    $group = if ($requirements.Runtime.ContainsKey($Name)) { 'Runtime' } else { 'Development' }
    $version = $requirements[$group][$Name]
    $root = if ($group -eq 'Runtime') { 'vendor' } else { '.dependencies' }
    $directory = Join-Path $ToolsPath "$root/$Name/$version"
    $package = Join-Path $ToolsPath "$root/packages/$Name.$version.nupkg"
    Assert-ToolPackage -Path $package -Sha256 $requirements.Sha256[$Name] -Name $Name
    Assert-ToolModulePayload -PackagePath $package -ModulePath $directory
    if ($ReuseLoaded -and $group -eq 'Runtime') {
        # LoadFile keeps DLLs locked on Windows even after Remove-Module. Reuse only byte-identical bundled content.
        $pattern = "^(?<directory>.+[\\/]vendor[\\/]$([regex]::Escape($Name))[\\/]$([regex]::Escape($version)))[\\/]"
        foreach ($assembly in [AppDomain]::CurrentDomain.GetAssemblies()) {
            if ($assembly.IsDynamic) { continue }
            if ($assembly.Location -match $pattern) {
                $loadedDirectory = $Matches.directory
                Assert-ToolModulePayload -PackagePath $package -ModulePath $loadedDirectory
                return Join-Path $loadedDirectory "$Name.psd1"
            }
        }
    }
    return Join-Path $directory "$Name.psd1"
}

# security-check: platform-release-cache
function Test-PlatformReleaseFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string] $RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    return $RelativePath -notmatch '(^|[\\/])\.dependencies([\\/]|$)'
}

Export-ModuleMember -Function Assert-ToolPackage, Assert-ToolModulePayload, Expand-ToolPackage, Get-ToolDependencyPath, Test-PlatformReleaseFile
