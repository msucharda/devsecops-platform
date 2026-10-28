#Requires -Version 7.4
[CmdletBinding()]
param(
    [switch] $CI,
    # Runs only tests with these tags. Without it, the interruption harness is excluded because its own CI job runs it in shards.
    [string[]] $Tag,
    # Runs only these test files or directories instead of tools/tests. The tag logic stays the same.
    [string[]] $Path,
    # Zero-based index/count. File estimates balance the shards; unknown files are included automatically.
    [ValidatePattern('^(0|[1-9][0-9]*)/([1-9][0-9]*)$')]
    [string] $Shard
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
if ($Shard) {
    $parts = $Shard.Split('/')
    $index = [int]::Parse($parts[0], [Globalization.CultureInfo]::InvariantCulture)
    $count = [int]::Parse($parts[1], [Globalization.CultureInfo]::InvariantCulture)
    if ($index -ge $count) { throw "Shard index must be smaller than count: '$Shard'." }

    $files = [Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($item in $configuration.Run.Path.Value) {
        if (Test-Path -LiteralPath $item -PathType Container) {
            foreach ($file in Get-ChildItem -LiteralPath $item -Recurse -File -Filter '*.Tests.ps1') {
                $null = $files.Add($file.FullName)
            }
        }
        else { $null = $files.Add($item) }
    }
    if ($files.Count -lt $count) { throw "Cannot split $($files.Count) test files into $count nonempty shards." }
    $durations = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'pester-durations.psd1')
    $weighted = @($files | ForEach-Object {
        $name = [IO.Path]::GetFileName($_)
        [pscustomobject]@{ Path = $_; Seconds = if ($durations.ContainsKey($name)) { $durations[$name] } else { 1 } }
    } | Sort-Object -Property Seconds -Descending -Stable)
    $loads = [int[]]::new($count)
    $selected = [Collections.Generic.List[string]]::new()
    foreach ($file in $weighted) {
        $target = 0
        for ($candidate = 1; $candidate -lt $count; $candidate++) {
            if ($loads[$candidate] -lt $loads[$target]) { $target = $candidate }
        }
        $loads[$target] += $file.Seconds
        if ($target -eq $index) { $selected.Add($file.Path) }
    }
    $configuration.Run.Path = $selected.ToArray()
    Write-Information "Pester shard ${Shard}: $($selected.Count)/$($files.Count) files; estimated $($loads[$index])s." -InformationAction Continue
}
$configuration.Run.PassThru = $true
$configuration.Output.Verbosity = 'Detailed'
if ($Tag) { $configuration.Filter.Tag = $Tag }
else { $configuration.Filter.ExcludeTag = 'Interruption' }
if ($CI) {
    $configuration.TestResult.Enabled = $true
    $resultName = if ($Shard) { "pester-$($parts[0])-of-$($parts[1]).xml" } else { 'pester.xml' }
    $configuration.TestResult.OutputPath = Join-Path $PSScriptRoot "../artifacts/$resultName"
}
$result = Invoke-Pester -Configuration $configuration
# Pester counts tests excluded by the tag filter as not run; only selected tests must run.
$notRun = @($result.Tests | Where-Object { $_.ShouldRun -and $_.Result -eq 'NotRun' }).Count
if ($result.Result -cne 'Passed' -or $result.PassedCount -eq 0 -or $result.FailedCount -gt 0 -or $notRun -gt 0) {
    throw "Pester failed: $($result.FailedCount) failed, $notRun not run, $($result.PassedCount) passed of $($result.TotalCount) total tests; result=$($result.Result), $($result.FailedContainersCount) failed containers, $($result.FailedBlocksCount) failed blocks."
}
