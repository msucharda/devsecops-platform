#Requires -Version 7.4
[CmdletBinding()]
param([string[]] $Path)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
Import-Module PSScriptAnalyzer -RequiredVersion $requirements.Development.PSScriptAnalyzer
$files = if ($Path) {
    foreach ($item in $Path) {
        Get-Item -LiteralPath $item -ErrorAction Stop |
            Where-Object { -not $_.PSIsContainer -and $_.Extension -in @('.ps1', '.psm1', '.psd1') }
    }
}
else {
    Get-ChildItem -LiteralPath $PSScriptRoot -Recurse -File |
        Where-Object { $_.Extension -in @('.ps1', '.psm1', '.psd1') }
}
foreach ($file in $files) {
    $parseErrors = $null
    $null = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) {
        throw "PowerShell syntax errors in '$($file.FullName)': $($parseErrors.Message -join '; ')"
    }
    $rules = @{ IncludeDefaultRules = $true }
    if ($file.Name -like '*.Tests.ps1') {
        # Pester shares BeforeAll variables with tests in separate script blocks.
        $rules.ExcludeRules = @('PSUseDeclaredVarsMoreThanAssignments')
    }
    $diagnostics = @(Invoke-ScriptAnalyzer -Path $file.FullName -Settings $rules -Severity Error, Warning)
    if ($diagnostics.Count -gt 0) {
        $diagnostics | Format-Table RuleName, ScriptName, Line, Message -Wrap | Out-Host
        throw "PowerShell static analysis failed in '$($file.FullName)'."
    }
}
