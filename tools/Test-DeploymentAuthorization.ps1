#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string] $EventPath = $env:GITHUB_EVENT_PATH,
    [string] $EventName = $env:GITHUB_EVENT_NAME,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $Ref = $env:GITHUB_REF,
    [string] $Sha = $env:GITHUB_SHA,
    [string] $Team = $env:PLATFORM_TEAM_SLUG,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [string] $GitHubOutputPath,
    [switch] $Preflight
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$payload = Get-Content -LiteralPath $EventPath -Raw | ConvertFrom-Json -AsHashtable
$allowed = $false
$eligible = $false
$revision = $Sha
$reason = 'Only protected main or an authorized platform-team pull request can receive credentials.'
if ($EventName -in @('push', 'workflow_dispatch', 'schedule')) {
    if ($Ref -cne 'refs/heads/main' -or $Sha -cnotmatch '^[a-f0-9]{40}$') {
        throw 'Deployment must run from the protected main branch at an immutable commit.'
    }
    $allowed = $true
    $reason = 'Protected main deployment.'
}
elseif ($EventName -eq 'pull_request_target') {
    $pr = $payload['pull_request']
    $revision = $pr['head']['sha']
    if ($revision -cnotmatch '^[a-f0-9]{40}$') {
        throw 'Pull request head must be an immutable commit.'
    }
    if ($pr['base']['ref'] -cne 'main' -or $pr['base']['repo']['full_name'] -cne $Repository) {
        $reason = 'Pull request does not target protected main in the instance repository.'
    }
    elseif (-not $pr['head']['repo'] -or
        $pr['head']['repo']['id'] -ne $pr['base']['repo']['id'] -or
        $pr['head']['repo']['full_name'] -cne $Repository) {
        $reason = 'Pull request is from a fork; cloud plan NOT PERFORMED.'
    }
    elseif ($pr['user']['type'] -cne 'User' -or $pr['user']['login'] -like '*[[]bot]' -or $pr['performed_via_github_app']) {
        $reason = 'Pull request was created by an App; cloud plan NOT PERFORMED. Plan runs after review and merge.'
    }
    elseif ($pr['draft']) {
        $reason = 'Draft pull request; cloud plan NOT PERFORMED.'
    }
    else {
        $eligible = $true
        $reason = 'Platform-team membership has not been verified; cloud plan NOT PERFORMED.'
        if (-not $Preflight) {
            if (-not $Team -or -not $ApiUrl -or -not $env:PLATFORM_GITHUB_TOKENS) {
                throw 'PR authorization requires the protected platform-team slug and a members: read installation token.'
            }
            $owner = $Repository.Split('/')[0]
            $tokens = ConvertFrom-Json -InputObject $env:PLATFORM_GITHUB_TOKENS -AsHashtable
            if (-not $tokens.Contains($owner)) {
                throw "PR authorization token does not cover organization '$owner'."
            }
            $headers = @{
                Authorization = "Bearer $($tokens[$owner])"
                Accept = 'application/vnd.github+json'
                'X-GitHub-Api-Version' = '2026-03-10'
            }
            $teamUrl = "$($ApiUrl.TrimEnd('/'))/orgs/$([uri]::EscapeDataString($owner))/teams/$([uri]::EscapeDataString($Team))"
            try {
                $verifiedTeam = Invoke-RestMethod -Uri $teamUrl -Headers $headers
                if ($verifiedTeam.slug -cne $Team) { throw 'Team API response does not identify the protected platform team.' }
            }
            catch {
                throw "Platform-team authorization API failed; no credentials will be released: $($_.Exception.Message)"
            }
            $url = "$teamUrl/memberships/$([uri]::EscapeDataString($pr['user']['login']))"
            try {
                $membership = Invoke-RestMethod -Uri $url -Headers $headers
                $allowed = $membership.state -ceq 'active'
                $reason = if ($allowed) { 'Active platform-team author in the instance repository.' } else { 'Author is not an active platform-team member; cloud plan NOT PERFORMED.' }
            }
            catch {
                if ($_.Exception.PSObject.Properties['Response'] -and $_.Exception.Response -and [int] $_.Exception.Response.StatusCode -eq 404) {
                    $reason = 'Author is not a platform-team member (membership API returned 404); cloud plan NOT PERFORMED.'
                }
                else {
                    throw "Platform-team authorization API failed; no credentials will be released: $($_.Exception.Message)"
                }
            }
        }
    }
}
else {
    throw "Unsupported deployment event '$EventName'."
}
if ($GitHubOutputPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath),
        "allowed=$($allowed.ToString().ToLowerInvariant())`neligible=$($eligible.ToString().ToLowerInvariant())`nrevision=$revision`n",
        [Text.UTF8Encoding]::new($false))
}
[pscustomobject]@{ Allowed = $allowed; Eligible = $eligible; Revision = $revision; Reason = $reason }
