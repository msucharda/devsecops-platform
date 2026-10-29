#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1')

# security-check: deployment-release-tree
function Get-ReleaseFileHash {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [switch] $RawRelease)

    $root = Get-Item -LiteralPath $Path -Force -ErrorAction Stop
    if ($root.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Release tree contains symbolic link '$Path'." }
    $files = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    foreach ($item in Get-ChildItem -LiteralPath $Path -Recurse -Force -ErrorAction Stop) {
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw "Release tree contains symbolic link '$($item.FullName)'." }
        if ($item.PSIsContainer) { continue }
        $relative = [IO.Path]::GetRelativePath($root.FullName, $item.FullName).Replace('\', '/')
        if ($RawRelease -and -not (Test-PlatformReleaseFile -RelativePath $relative)) { continue }
        $files.Add($relative, (Get-FileHash -LiteralPath $item.FullName -Algorithm SHA256).Hash.ToLowerInvariant())
    }
    return ,$files
}

# security-check: deployment-release-files
function Assert-ReleaseFileHash {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][Collections.IDictionary] $Actual,
        [Parameter(Mandatory)][string] $Label
    )
    if ($Expected.get_Count() -eq 0) { throw "$Label has no release files." }
    if ($Actual.get_Count() -ne $Expected.get_Count()) { throw "$Label file set differs from the verified release." }
    $actualPaths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Actual.get_Keys()) { $null = $actualPaths.Add($path) }
    foreach ($path in $Expected.get_Keys()) {
        if (-not $actualPaths.Contains($path)) { throw "$Label is missing verified release file '$path'." }
        if ($Actual[$path] -isnot [string]) { throw "$Label hash for '$path' must be a string." }
        if ($Actual[$path] -cne $Expected[$path]) { throw "$Label hash differs for '$path'." }
    }
}

# security-check: deployment-release-raw
function Test-RawReleaseCandidate {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Collections.IDictionary] $Raw, [Collections.Generic.Dictionary[string,string]] $Candidate)
    if ($Candidate.get_Count() -ne $Raw.get_Count()) { return $false }
    foreach ($path in $Raw.get_Keys()) {
        if (-not [StringComparer]::Ordinal.Equals($Candidate[$path], $Raw[$path])) { return $false }
    }
    return $true
}

Export-ModuleMember -Function Get-ReleaseFileHash, Assert-ReleaseFileHash, Test-RawReleaseCandidate
