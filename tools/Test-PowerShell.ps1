#Requires -Version 7.4
[CmdletBinding()]
param(
    [string[]] $Path,
    # Opt-in only: authoritative CI and -Full always analyze every selected file.
    [string] $CacheDirectory
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PowerShellAnalysisCache.psm1')
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
$files = if ($Path) {
    foreach ($item in $Path) {
        Get-Item -LiteralPath $item -ErrorAction Stop
    }
}
else {
    Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File
}
$files = $files |
    Where-Object {
        -not $_.PSIsContainer -and $_.Extension -in @('.ps1', '.psm1', '.psd1') -and
        $_.FullName -notlike "$(Join-Path $PSScriptRoot 'vendor')$([IO.Path]::DirectorySeparatorChar)*" -and
        $_.FullName -notlike "$(Join-Path $PSScriptRoot '.dependencies')$([IO.Path]::DirectorySeparatorChar)*"
    }
foreach ($file in $files) {
    $rules = @{ IncludeDefaultRules = $true }
    if ($file.Name -like '*.Tests.ps1') {
        # Pester shares BeforeAll variables with tests in separate script blocks.
        $rules.ExcludeRules = @('PSUseDeclaredVarsMoreThanAssignments')
    }
    Invoke-CachedPowerShellAnalysis -Path $file.FullName -Settings $rules -CacheDirectory $CacheDirectory `
        -AnalyzerVersion $requirements.Development.PSScriptAnalyzer -PowerShellVersion $PSVersionTable.PSVersion.ToString()
}
