#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalCiGate.psm1')
$script:loadedAnalyzerVersion = $null
$script:implementationHash = (Get-FileHash -LiteralPath $PSCommandPath -Algorithm SHA256).Hash

# security-check: powershell-analysis-cache-entry
function Assert-PowerShellAnalysisCacheEntry {
    [CmdletBinding()]
    param([IO.FileSystemInfo] $File, [string] $Key)
    if ($File.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Cache entry is a reparse point.' }
    if ($File.Length -gt 4096) { throw 'Cache entry is too large.' }
    $entry = [IO.File]::ReadAllText($File.FullName) | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($entry['Schema'] -isnot [long] -or $entry['Schema'] -ne 1) { throw 'Invalid cache schema.' }
    # Culture-aware string equality ignores some Unicode characters; these ASCII tokens must match exactly.
    if ($entry['Key'] -isnot [string] -or $entry['Key'] -cnotmatch "\A$Key\z") { throw 'Cache key differs.' }
    if ($entry['Status'] -isnot [string] -or $entry['Status'] -cnotmatch '\APassed\z') { throw 'Cache result did not pass.' }
    if ($entry['CompletedAtUtcTicks'] -isnot [long]) { throw 'Invalid cache completion time.' }
    $now = [datetime]::UtcNow.Ticks
    if ($entry['CompletedAtUtcTicks'] -gt $now) { throw 'Cache completion time is in the future.' }
    if ($now - $entry['CompletedAtUtcTicks'] -gt [timespan]::FromDays(7).Ticks) { throw 'Cache entry expired.' }
}

# security-check: powershell-analysis-source-binding
function Assert-PowerShellAnalysisSource {
    param([string] $Path, [string] $ExpectedHash)
    if ((Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash -ne $ExpectedHash) {
        throw "PowerShell source '$Path' changed during analysis."
    }
}

# security-check: powershell-analysis-success
function Assert-PowerShellAnalysisSuccess {
    param([string] $Path, [AllowEmptyCollection()][object[]] $Diagnostic)
    if ($Diagnostic.Count -gt 0) {
        $Diagnostic | Format-Table RuleName, ScriptName, Line, Message -Wrap | Out-Host
        throw "PowerShell static analysis failed in '$Path'."
    }
}

function Invoke-PowerShellAnalysisCachePruning {
    param([string] $Directory)
    Get-ChildItem -LiteralPath $Directory -File -Force |
        Sort-Object -Property LastWriteTimeUtc, Name -Descending |
        Select-Object -Skip 256 |
        Remove-Item -Force
}

function Invoke-CachedPowerShellAnalysis {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][hashtable] $Settings,
        [Parameter(Mandatory)][string] $AnalyzerVersion,
        [Parameter(Mandatory)][string] $PowerShellVersion,
        [string] $CacheDirectory
    )
    $contentHash = (Get-FileHash -LiteralPath $Path -Algorithm SHA256).Hash
    $orderedSettings = [ordered]@{}
    foreach ($name in @($Settings.Keys | Sort-Object -CaseSensitive)) { $orderedSettings[$name] = $Settings[$name] }
    $settingsJson = $orderedSettings | ConvertTo-Json -Depth 20 -Compress
    $settingsHash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($settingsJson)))
    $keyJson = @($contentHash, $settingsHash, $AnalyzerVersion, $PowerShellVersion,
        [IO.Path]::GetFullPath($Path), $script:implementationHash) |
        ConvertTo-Json -Compress
    $key = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($keyJson)))
    if ($CacheDirectory) {
        try {
            Initialize-LocalCiPrivateTempDirectory -Path $CacheDirectory
            Invoke-PowerShellAnalysisCachePruning -Directory $CacheDirectory
        }
        catch {
            Write-Verbose "PowerShell cache unavailable: $($_.Exception.Message)"
            $CacheDirectory = $null
        }
    }
    if ($CacheDirectory) {
        $entryPath = Join-Path $CacheDirectory "$key.json"
        try {
            $entryFile = Get-Item -LiteralPath $entryPath -Force
            Assert-PowerShellAnalysisCacheEntry -File $entryFile -Key $key
            return
        }
        catch { Write-Verbose "PowerShell cache miss: $($_.Exception.Message)" }
    }

    $parseErrors = $null
    $null = [Management.Automation.Language.Parser]::ParseFile($Path, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "PowerShell syntax errors in '$Path': $($parseErrors.Message -join '; ')" }
    if ($script:loadedAnalyzerVersion -ne $AnalyzerVersion) {
        Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1')
        Import-Module (Get-ToolDependencyPath -Name PSScriptAnalyzer)
        $script:loadedAnalyzerVersion = $AnalyzerVersion
    }
    $diagnostics = @(Invoke-ScriptAnalyzer -Path $Path -Settings $Settings -Severity Error, Warning)
    Assert-PowerShellAnalysisSuccess -Path $Path -Diagnostic $diagnostics
    Assert-PowerShellAnalysisSource -Path $Path -ExpectedHash $contentHash
    if ($CacheDirectory) {
        $receipt = @{ Schema = 1; Key = $key; Status = 'Passed'; CompletedAtUtcTicks = [datetime]::UtcNow.Ticks }
        $pending = Join-Path $CacheDirectory "$key.$([guid]::NewGuid().ToString('N')).pending"
        try {
            [IO.File]::WriteAllText($pending, ($receipt | ConvertTo-Json -Compress))
            [IO.File]::Move($pending, $entryPath, $true)
            Invoke-PowerShellAnalysisCachePruning -Directory $CacheDirectory
        }
        catch { Write-Verbose "PowerShell cache write skipped: $($_.Exception.Message)" }
        finally {
            if (Test-Path -LiteralPath $pending) { Remove-Item -LiteralPath $pending -Force -ErrorAction SilentlyContinue }
        }
    }
}

Export-ModuleMember -Function Invoke-CachedPowerShellAnalysis
