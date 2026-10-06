#Requires -Version 7.4
[CmdletBinding()]
param([switch] $CI)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
Import-Module Pester -RequiredVersion $requirements.Development.Pester
$configuration = New-PesterConfiguration
$configuration.Run.Path = Join-Path $PSScriptRoot 'tests'
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
if ($CI) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = Join-Path $PSScriptRoot '../artifacts/pester.xml'
}
$result = Invoke-Pester -Configuration $configuration
if ($result.TotalCount -eq 0 -or $result.FailedCount -gt 0 -or $result.NotRunCount -gt 0) {
    throw "Pester failed: $($result.FailedCount) failed, $($result.NotRunCount) not run, $($result.TotalCount) total tests."
}
