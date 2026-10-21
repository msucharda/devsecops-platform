#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $Sha = $env:GITHUB_SHA,
    [string] $ApiUrl = $env:GITHUB_API_URL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
# The teardown gate read instance.yaml at the dispatched commit; a merge during an approval wait must not reuse that decision.
if ($Sha -cnotmatch '^[a-f0-9]{40}$') { throw 'Teardown requires the dispatched main commit SHA.' }
if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Teardown requires the instance repository name.' }
if ([string]::IsNullOrWhiteSpace($ApiUrl)) { throw 'Teardown requires the GitHub API URL.' }
$token = $env:TEARDOWN_MAIN_TOKEN
if ([string]::IsNullOrWhiteSpace($token)) { throw 'Teardown requires TEARDOWN_MAIN_TOKEN to read main.' }

$uri = "$($ApiUrl.TrimEnd('/'))/repos/$Repository/git/ref/heads/main"
$headers = @{ Authorization = 'Bearer ' + $token; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
$response = Invoke-WebRequest -Uri $uri -Method GET -Headers $headers -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 60
if ($response.StatusCode -ne 200) {
    throw "Reading main of '$Repository' failed (HTTP $($response.StatusCode)); teardown stops before destroy."
}
$reference = $null
try { $reference = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop } catch { $reference = $null }
if ($reference -isnot [System.Collections.IDictionary] -or $reference['ref'] -cne 'refs/heads/main' -or
    $reference['object'] -isnot [System.Collections.IDictionary] -or $reference['object']['type'] -cne 'commit' -or
    $reference['object']['sha'] -isnot [string]) {
    throw "GitHub did not return a commit for main of '$Repository'; teardown stops before destroy."
}
if ($reference['object']['sha'] -cne $Sha) {
    throw "Main of '$Repository' no longer points to the dispatched commit $Sha. Dispatch the teardown again from the current main."
}
Write-Information "Main of '$Repository' still points to $Sha." -InformationAction Continue
