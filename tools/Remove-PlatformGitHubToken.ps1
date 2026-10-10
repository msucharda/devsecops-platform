#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([string] $ApiUrl = $env:GITHUB_API_URL)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:PLATFORM_GITHUB_TOKENS) { return }
$tokens = ConvertFrom-Json -InputObject $env:PLATFORM_GITHUB_TOKENS -AsHashtable
$failures = [Collections.Generic.List[string]]::new()
foreach ($organization in $tokens.PSBase.Keys) {
    if ($PSCmdlet.ShouldProcess($organization, 'Revoke the job installation token')) {
        try {
            $null = Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/installation/token" -Method DELETE -Headers @{
                Authorization = "Bearer $($tokens[$organization])"
                Accept = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2026-03-10'
            }
        }
        catch { $failures.Add("Token revocation failed for '$organization': $($_.Exception.Message)") }
    }
}
if ($failures.Count) { throw ($failures -join '; ') }
