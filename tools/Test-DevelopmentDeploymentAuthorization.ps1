#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $PullRequest,
    [Parameter(Mandatory)][string] $Revision,
    [Parameter(Mandatory)][string] $WorkPath,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $Ref = $env:GITHUB_REF,
    [string] $Sha = $env:GITHUB_SHA,
    [string] $EventName = $env:GITHUB_EVENT_NAME,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [string] $ServerUrl = $env:GITHUB_SERVER_URL,
    [string] $ReadToken = $env:DEVELOPMENT_READ_TOKEN,
    [string] $GitHubOutputPath,
    [switch] $Preflight
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# security-check: development-dispatch-request
function Assert-DevelopmentDispatchRequest {
    param([string] $DispatchEvent, [string] $Server)
    if ($DispatchEvent -cne 'workflow_dispatch' -or $Ref -cne 'refs/heads/main' -or $Sha -cnotmatch '^[a-f0-9]{40}\z') {
        throw 'Development deployment requires manual dispatch of immutable protected main.'
    }
    if ($PullRequest -cnotmatch '^[1-9][0-9]*\z' -or $Revision -cnotmatch '^[a-f0-9]{40}\z' -or
        $Repository -cnotmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+\z') {
        throw 'Development deployment requires an exact PR number and head SHA.'
    }
    if ([string]::IsNullOrWhiteSpace($ReadToken)) { throw 'Development PR inspection requires the read-only workflow token.' }
    $address = [uri] $Server
    if ($address.Scheme -cne 'https' -or -not $address.IsDefaultPort -or
        $address.UserInfo -or $address.Query -or $address.Fragment -or $address.AbsolutePath -cne '/' -or
        $ApiUrl.TrimEnd('/') -cne "https://api.$($address.DnsSafeHost)") {
        throw 'Development PR inspection requires the API of the current HTTPS GitHub Cloud server.'
    }
}

# security-check: development-dispatch-context
function Assert-DevelopmentDispatchContext {
    param([AllowNull()][object] $Pull)
    if ($Pull -isnot [Collections.IDictionary] -or $Pull['state'] -cne 'open' -or
        $Pull['merged'] -isnot [bool] -or $Pull['merged'] -or
        $Pull['draft'] -isnot [bool] -or $Pull['draft'] -or
        [string] $Pull['number'] -cne $PullRequest) {
        throw 'Development deployment requires the specified open, unmerged, ready PR.'
    }
    if ($Pull['head']['sha'] -cne $Revision -or $Pull['base']['sha'] -cne $Sha) {
        throw 'Development PR head or trusted base changed; obtain a new exact-content approval.'
    }
}

Assert-DevelopmentDispatchRequest -DispatchEvent $EventName -Server $ServerUrl
$pull = Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))/repos/$Repository/pulls/$PullRequest" -Headers @{
    Authorization = "Bearer $ReadToken"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10'
} -MaximumRedirection 0 -TimeoutSec 60
$pull = ConvertTo-Json -InputObject $pull -Depth 100 | ConvertFrom-Json -AsHashtable -NoEnumerate
Assert-DevelopmentDispatchContext -Pull $pull
$null = New-Item -ItemType Directory -Path $WorkPath -Force
$eventPath = Join-Path $WorkPath 'development-event.json'
@{ pull_request = $pull } | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $eventPath -Encoding utf8NoBOM
$result = & (Join-Path $PSScriptRoot 'Test-DeploymentAuthorization.ps1') -EventPath $eventPath `
    -EventName pull_request_target -Repository $Repository -Ref $Ref -Sha $Sha -ApiUrl $ApiUrl -Preflight:$Preflight
if (-not $result.Eligible -or (-not $Preflight -and -not $result.Allowed)) {
    throw "Development author is not authorized: $($result.Reason)"
}
if ($GitHubOutputPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath),
        "allowed=$($result.Allowed.ToString().ToLowerInvariant())`neligible=true`nrevision=$Revision`n",
        [Text.UTF8Encoding]::new($false))
}
$result
