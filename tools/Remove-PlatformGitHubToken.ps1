#Requires -Version 7.4
[CmdletBinding(SupportsShouldProcess)]
param([string] $ApiUrl = $env:GITHUB_API_URL)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if (-not $env:PLATFORM_GITHUB_TOKENS) { return }
. (Join-Path $PSScriptRoot '../modules/shared/scripts/GitHubRetry.ps1')

# security-check: github-token-revocation-status
function Test-PlatformTokenRevocationStatus {
    param([int] $StatusCode)
    return ($StatusCode -eq 204)
}

$tokens = ConvertFrom-Json -InputObject $env:PLATFORM_GITHUB_TOKENS -AsHashtable
$failures = [Collections.Generic.List[string]]::new()
foreach ($organization in $tokens.PSBase.Keys) {
    if ($PSCmdlet.ShouldProcess($organization, 'Revoke the job installation token')) {
        try {
            $request = @{
                Uri     = "$($ApiUrl.TrimEnd('/'))/installation/token"
                Method  = 'DELETE'
                TimeoutSec = 60
                MaximumRedirection = 0
                Headers = @{
                    Authorization          = "Bearer $($tokens[$organization])"
                    Accept                 = 'application/vnd.github+json'
                    'X-GitHub-Api-Version' = '2026-03-10'
                }
            }
            $reply = Invoke-GitHubRetryRequest -Request $request -TokenRevocation
            if (-not (Test-PlatformTokenRevocationStatus -StatusCode $reply.StatusCode)) {
                throw "DELETE $(([uri] $request.Uri).AbsolutePath) status=$([int] $reply.StatusCode)"
            }
        }
        catch { $failures.Add("Token revocation failed for '$organization': $($_.Exception.Message)") }
    }
}
if ($failures.Count) { throw ($failures -join '; ') }
