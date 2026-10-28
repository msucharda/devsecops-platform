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

function Get-ToolBinaryPackage {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Actionlint', 'TFLint', 'Terraform')][string] $Name,
        [string] $ToolsPath = $PSScriptRoot
    )

    if ((-not $IsWindows -and -not $IsLinux) -or
        [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64 -or
        ($Name -eq 'TFLint' -and -not $IsLinux)) {
        throw "$Name binary installation supports $(if ($Name -eq 'TFLint') { 'Linux' } else { 'Windows and Linux' }) amd64 only."
    }
    $requirements = Import-PowerShellDataFile (Join-Path $ToolsPath 'requirements.psd1')
    $pin = $requirements.Binaries[$Name]
    $platform = if ($IsWindows) { 'windows_amd64' } else { 'linux_amd64' }
    $key = if ($IsWindows) { 'WindowsAmd64ArchiveSha256' } else { 'LinuxAmd64ArchiveSha256' }
    $archive = switch ($Name) {
        'Actionlint' { "actionlint_$($pin.Version)_$platform.$(if ($IsWindows) { 'zip' } else { 'tar.gz' })" }
        'TFLint' { 'tflint_linux_amd64.zip' }
        'Terraform' { "terraform_$($pin.Version)_$platform.zip" }
    }
    $uri = switch ($Name) {
        'Actionlint' { "https://github.com/rhysd/actionlint/releases/download/v$($pin.Version)/$archive" }
        'TFLint' { "https://github.com/terraform-linters/tflint/releases/download/v$($pin.Version)/$archive" }
        'Terraform' { "https://releases.hashicorp.com/terraform/$($pin.Version)/$archive" }
    }
    [pscustomobject]@{
        Name = $Name; Version = $pin.Version; Archive = $archive; Uri = $uri; Sha256 = $pin[$key]
        Executable = $Name.ToLowerInvariant() + $(if ($IsWindows) { '.exe' } else { '' })
        CachePath = Join-Path $ToolsPath ".dependencies/binaries/$Name/$($pin.Version)/$archive"
    }
}

function Expand-ToolBinary {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object] $Package,
        [Parameter(Mandatory)][string] $ArchivePath,
        [Parameter(Mandatory)][string] $DestinationPath
    )

    Assert-ToolPackage -Path $ArchivePath -Sha256 $Package.Sha256 -Name $Package.Name
    $null = New-Item -ItemType Directory -Path $DestinationPath -Force
    $executable = Join-Path $DestinationPath $Package.Executable
    $archive = $null
    $file = $null
    $gzip = $null
    $output = $null
    try {
        if ($Package.Archive.EndsWith('.zip', [StringComparison]::Ordinal)) {
            $archive = [IO.Compression.ZipFile]::OpenRead($ArchivePath)
            $entries = @($archive.Entries | Where-Object FullName -CEQ $Package.Executable)
            if ($entries.Count -ne 1) { throw "$($Package.Name) archive must contain exactly one $($Package.Executable)." }
            $inputStream = $entries[0].Open()
            try {
                $output = [IO.File]::Open($executable, [IO.FileMode]::CreateNew)
                $inputStream.CopyTo($output)
            }
            finally { $inputStream.Dispose() }
        }
        else {
            $file = [IO.File]::OpenRead($ArchivePath)
            $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Decompress)
            $archive = [System.Formats.Tar.TarReader]::new($gzip)
            $found = $false
            while ($null -ne ($entry = $archive.GetNextEntry())) {
                if ($entry.Name -cne $Package.Executable) { continue }
                if ($found -or $entry.EntryType -notin @([System.Formats.Tar.TarEntryType]::RegularFile, [System.Formats.Tar.TarEntryType]::V7RegularFile)) {
                    throw "$($Package.Name) archive must contain exactly one regular $($Package.Executable)."
                }
                $found = $true
                $output = [IO.File]::Open($executable, [IO.FileMode]::CreateNew)
                $entry.DataStream.CopyTo($output)
                $output.Dispose()
                $output = $null
            }
            if (-not $found) { throw "$($Package.Name) archive does not contain $($Package.Executable)." }
        }
    }
    finally {
        if ($null -ne $output) { $output.Dispose() }
        if ($null -ne $archive) { $archive.Dispose() }
        if ($null -ne $gzip) { $gzip.Dispose() }
        if ($null -ne $file) { $file.Dispose() }
    }
    if (-not $IsWindows) {
        & chmod '+x' $executable
        if ($LASTEXITCODE -ne 0) { throw "Cannot mark $($Package.Name) executable." }
    }
    return $executable
}

function Get-ToolBinaryPath {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('Actionlint', 'TFLint', 'Terraform')][string] $Name,
        [Parameter(Mandatory)][string] $DestinationPath,
        [string] $ToolsPath = $PSScriptRoot
    )

    $package = Get-ToolBinaryPackage -Name $Name -ToolsPath $ToolsPath
    if (-not (Test-Path -LiteralPath $package.CachePath -PathType Leaf)) {
        throw "$Name $($package.Version) archive is missing. Run ./tools/Install-ToolDependencies.ps1 -Binary $Name."
    }
    return Expand-ToolBinary -Package $package -ArchivePath $package.CachePath -DestinationPath $DestinationPath
}

# security-check: platform-release-cache
function Test-PlatformReleaseFile {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowNull()][AllowEmptyString()][string] $RelativePath)

    if ([string]::IsNullOrWhiteSpace($RelativePath)) { return $false }
    return $RelativePath -notmatch '(^|[\\/])\.dependencies([\\/]|$)'
}

Export-ModuleMember -Function Assert-ToolPackage, Assert-ToolModulePayload, Expand-ToolPackage, Get-ToolDependencyPath, Test-PlatformReleaseFile,
    Get-ToolBinaryPackage, Expand-ToolBinary, Get-ToolBinaryPath
