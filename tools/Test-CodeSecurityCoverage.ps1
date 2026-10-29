#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $TokensJson = $env:PLATFORM_GITHUB_TOKENS,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [Parameter(Mandatory)][string] $ReportPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$reportFile = [IO.Path]::GetFullPath($ReportPath)
[IO.File]::Delete($reportFile)
Import-Module (Join-Path $PSScriptRoot '../modules/enterprise-baseline/scripts/CodeSecurity.psm1')
$tokens = ConvertFrom-Json -InputObject $TokensJson -AsHashtable -ErrorAction Stop
if ($tokens -isnot [Collections.IDictionary] -or $tokens.Count -eq 0) {
    throw 'Code Security coverage requires the enterprise-baseline plan installation token map.'
}
$organizations = [ordered]@{}
$previousBearer = $env:REST_API_BEARER
try {
    foreach ($organization in @($tokens.Keys | Sort-Object -CaseSensitive)) {
        if ($organization -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*$' -or
            $tokens[$organization] -isnot [string] -or [string]::IsNullOrWhiteSpace($tokens[$organization])) {
            throw 'Code Security coverage has an invalid organization or installation token.'
        }
        $env:REST_API_BEARER = $tokens[$organization]
        $organizations[$organization] = Get-CodeSecurityCoverage -ApiUrl $ApiUrl -Organization $organization
    }
}
finally { $env:REST_API_BEARER = $previousBearer }
$result = [ordered]@{ organizations = $organizations }
$json = ConvertTo-Json -InputObject $result -Depth 20 -Compress
[IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($reportFile)) | Out-Null
[IO.File]::WriteAllText($reportFile, $json, [Text.UTF8Encoding]::new($false))
$result
