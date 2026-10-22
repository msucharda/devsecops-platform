#Requires -Version 7.4
[CmdletBinding()]
param(
    [switch] $CI,
    # Runs only tests with these tags. Without it, the interruption harness is excluded because its own CI job runs it in shards.
    [string[]] $Tag,
    # Runs only these test files or directories instead of tools/tests. The tag logic stays the same.
    [string[]] $Path
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
Import-Module Pester -RequiredVersion $requirements.Development.Pester
$configuration = New-PesterConfiguration
$configuration.Run.Path = if ($Path) {
    @(foreach ($item in $Path) { (Resolve-Path -LiteralPath $item -ErrorAction Stop).ProviderPath })
}
else { Join-Path $PSScriptRoot 'tests' }
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
if ($Tag) { $configuration.Filter.Tag = $Tag }
else { $configuration.Filter.ExcludeTag = 'Interruption' }
if ($CI) {
    $configuration.TestResult.Enabled = $true
    $configuration.TestResult.OutputPath = Join-Path $PSScriptRoot '../artifacts/pester.xml'
}
$result = Invoke-Pester -Configuration $configuration
# Pester counts tests excluded by the tag filter as not run; only selected tests must run.
$notRun = @($result.Tests | Where-Object { $_.ShouldRun -and $_.Result -eq 'NotRun' }).Count
if ($result.PassedCount -eq 0 -or $result.FailedCount -gt 0 -or $notRun -gt 0) {
    throw "Pester failed: $($result.FailedCount) failed, $notRun not run, $($result.PassedCount) passed of $($result.TotalCount) total tests."
}
