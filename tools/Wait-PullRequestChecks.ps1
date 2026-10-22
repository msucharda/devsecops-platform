#Requires -Version 7.4
<#
.SYNOPSIS
Waits at most -MaxSeconds for the checks of a pull request head commit and reports one status line.

.DESCRIPTION
The script reads the pull request head SHA, the workflow runs and check runs for that SHA, and the Copilot review state.
It polls until the checks pass or fail, or until -MaxSeconds elapse. Sleeps end before the deadline, and every request uses the
remaining time as its connection timeout and read-stall timeout. Repository and token come from local sources without a network call.

Output: one line, for example 'pending 3/7; copilot: requested', 'failed: Platform tools; copilot: reviewed (rounds 1)'
or 'passed; copilot: none'.
Exit codes: 0 passed, 1 failed, 2 pending (deadline reached), 3 error (for example HTTP error or unexpected response).

API (X-GitHub-Api-Version 2026-03-10):
- GET /repos/{owner}/{repo}/pulls/{pull_number}            https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#get-a-pull-request
- GET /repos/{owner}/{repo}/actions/runs?head_sha={sha}    https://docs.github.com/en/enterprise-cloud@latest/rest/actions/workflow-runs#list-workflow-runs-for-a-repository
- GET /repos/{owner}/{repo}/commits/{ref}/check-runs       https://docs.github.com/en/enterprise-cloud@latest/rest/checks/runs#list-check-runs-for-a-git-reference
- GET /repos/{owner}/{repo}/pulls/{pull_number}/reviews    https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/reviews#list-reviews-for-a-pull-request
- GET /repos/{owner}/{repo}/pulls/{pull_number}/requested_reviewers
  https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/review-requests#get-all-requested-reviewers-for-a-pull-request
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateRange(1, [int]::MaxValue)][int] $Pr,
    [ValidateRange(1, 3600)][int] $MaxSeconds = 230,
    [ValidateRange(1, 600)][int] $IntervalSeconds = 20,
    [string] $Repository,
    [string] $ApiUrl = $(if ($env:GITHUB_API_URL) { $env:GITHUB_API_URL } else { 'https://api.github.com' })
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$deadline = (Get-Date).ToUniversalTime().AddSeconds($MaxSeconds)
trap {
    Write-Output "error: $($_.Exception.Message)"
    exit 3
}

if (-not $Repository) {
    # Read from the local remote; a network call here would not be bounded by the deadline.
    $remote = (& git -C $PSScriptRoot remote get-url origin 2>$null | Out-String).Trim()
    if ($remote -match '[:/](?<name>[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+?)(\.git)?$') { $Repository = $Matches['name'] }
}
if ($Repository -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$') { throw 'Pass -Repository <owner>/<repo>; it could not be read from the origin remote.' }
$token = if ($env:GH_TOKEN) { $env:GH_TOKEN } elseif ($env:GITHUB_TOKEN) { $env:GITHUB_TOKEN } else { (& gh auth token 2>$null | Out-String).Trim() }
if ([string]::IsNullOrWhiteSpace($token)) { throw 'No GitHub token: set GH_TOKEN or sign in with gh auth login.' }
$headers = @{ Authorization = 'Bearer ' + $token; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
$apiBase = "$($ApiUrl.TrimEnd('/'))/repos/$Repository"
# The Copilot code review bot submits reviews as this user; requests list it as Copilot.
$copilotLogins = @('copilot-pull-request-reviewer[bot]', 'Copilot')

function Get-RemainingSecond {
    return ($deadline - (Get-Date).ToUniversalTime()).TotalSeconds
}

function Invoke-GitHubGet {
    <#
    .SYNOPSIS
    Sends one GET request that ends before the deadline. Returns $null when no time is left.
    #>
    param([Parameter(Mandatory)][string] $Path)
    $remaining = [Math]::Floor((Get-RemainingSecond))
    if ($remaining -lt 1) { return $null }
    try {
        $response = Invoke-WebRequest -Uri "$apiBase/$Path" -Method GET -Headers $headers -SkipHttpErrorCheck -MaximumRedirection 0 -ConnectionTimeoutSeconds ([int] $remaining) -OperationTimeoutSeconds ([int] $remaining)
    }
    catch {
        # A request cut off by the deadline leaves the state pending; any other transport error is an error.
        if ((Get-RemainingSecond) -lt 1) { return $null }
        throw
    }
    if ($response.StatusCode -ne 200) { throw "GET $Path failed with HTTP $($response.StatusCode)." }
    try { return , (ConvertFrom-Json -InputObject $response.Content -AsHashtable -NoEnumerate -Depth 100 -ErrorAction Stop) }
    catch { throw "GET $Path returned a body that is not JSON." }
}

function Get-PagedItem {
    <#
    .SYNOPSIS
    Reads every page of a list response. Returns $null when the deadline interrupts paging.
    #>
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Property)
    $items = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; ; $page++) {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $body = Invoke-GitHubGet -Path "$Path$($separator)per_page=100&page=$page"
        if ($null -eq $body) { return $null }
        if ($body -isnot [System.Collections.IDictionary] -or $body[$Property] -isnot [System.Collections.IList] -or $body['total_count'] -isnot [long] -and $body['total_count'] -isnot [int]) {
            throw "GET $Path returned an unexpected shape without '$Property' and 'total_count'."
        }
        foreach ($item in $body[$Property]) { $items.Add($item) }
        if ($body[$Property].Count -eq 0 -or $items.Count -ge $body['total_count']) { return , $items.ToArray() }
    }
}

function Get-ReviewList {
    param([Parameter(Mandatory)][string] $Path)
    $items = [System.Collections.Generic.List[object]]::new()
    for ($page = 1; ; $page++) {
        $body = Invoke-GitHubGet -Path "$Path`?per_page=100&page=$page"
        if ($null -eq $body) { return $null }
        if ($body -isnot [System.Collections.IList]) { throw "GET $Path returned an unexpected shape; a list was expected." }
        foreach ($item in $body) { $items.Add($item) }
        if ($body.Count -lt 100) { return , $items.ToArray() }
    }
}

function Get-ChecksState {
    <#
    .SYNOPSIS
    Combines workflow runs and check runs for the head SHA. Unknown or missing state never counts as passed.
    #>
    param([object[]] $WorkflowRun, [object[]] $CheckRun)
    $passing = @('success', 'neutral', 'skipped')
    # A new run of the same workflow and event (for example after reopening) replaces the older one; the check
    # runs of a replaced run's check suite no longer count. A rerun keeps its run ID and replaces its check runs.
    $latestRun = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($run in $WorkflowRun) {
        $key = "$($run['workflow_id'])/$($run['event'])"
        if (-not $latestRun.ContainsKey($key) -or [long] $run['id'] -gt [long] $latestRun[$key]['id']) { $latestRun[$key] = $run }
    }
    $replacedSuites = @($WorkflowRun | Where-Object { $_ -notin $latestRun.Values } | ForEach-Object { [string] $_['check_suite_id'] })
    $WorkflowRun = @($latestRun.Values)
    $CheckRun = @($CheckRun | Where-Object {
        -not ($_['check_suite'] -is [System.Collections.IDictionary] -and [string] $_['check_suite']['id'] -cin $replacedSuites)
    })
    # A rerun creates a new check run with the same app and name; checks of different apps or names stay separate.
    $latest = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($run in $CheckRun) {
        $app = if ($run['app'] -is [System.Collections.IDictionary]) { [string] $run['app']['id'] } else { '' }
        $key = "$app/$($run['name'])"
        if (-not $latest.ContainsKey($key) -or [long] $run['id'] -gt [long] $latest[$key]['id']) { $latest[$key] = $run }
    }
    $checks = @($latest.Values)
    $failedNames = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    foreach ($check in $checks) {
        if ($check['status'] -ceq 'completed' -and $check['conclusion'] -cnotin $passing) { $null = $failedNames.Add([string] $check['name']) }
    }
    foreach ($run in $WorkflowRun) {
        if ($run['status'] -ceq 'completed' -and $run['conclusion'] -cnotin $passing -and
            @($checks | Where-Object { $_['status'] -ceq 'completed' -and $_['conclusion'] -cnotin $passing }).Count -eq 0) {
            $null = $failedNames.Add("workflow $($run['name'])")
        }
    }
    if ($failedNames.Count -gt 0) { return [pscustomobject]@{ State = 'failed'; Line = "failed: $($failedNames -join ', ')" } }
    $done = @($checks | Where-Object { $_['status'] -ceq 'completed' }).Count
    $runsDone = @($WorkflowRun | Where-Object { $_['status'] -ceq 'completed' }).Count -eq @($WorkflowRun).Count
    if (@($WorkflowRun).Count -gt 0 -and $runsDone -and $checks.Count -gt 0 -and $done -eq $checks.Count) {
        return [pscustomobject]@{ State = 'passed'; Line = 'passed' }
    }
    return [pscustomobject]@{ State = 'pending'; Line = "pending $done/$($checks.Count)" }
}

function Get-CopilotState {
    param([object[]] $Review, [System.Collections.IDictionary] $Requested, [string] $HeadSha)
    $copilotReviews = @($Review | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['user'] -is [System.Collections.IDictionary] -and $_['user']['login'] -cin $copilotLogins })
    $rounds = $copilotReviews.Count
    if (@($copilotReviews | Where-Object { $_['commit_id'] -ceq $HeadSha }).Count -gt 0) { return "copilot: reviewed (rounds $rounds)" }
    if (@($Requested['users'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['login'] -cin $copilotLogins }).Count -gt 0) {
        return "copilot: requested (rounds $rounds)"
    }
    return "copilot: none for head (rounds $rounds)"
}

$line = 'pending 0/0; copilot: unknown'
while ($true) {
    $pull = Invoke-GitHubGet -Path "pulls/$Pr"
    if ($null -eq $pull) { break }
    if ($pull -isnot [System.Collections.IDictionary] -or $pull['head'] -isnot [System.Collections.IDictionary] -or
        $pull['head']['sha'] -cnotmatch '^[0-9a-f]{40}$') {
        throw "GET pulls/$Pr returned no head SHA."
    }
    $sha = $pull['head']['sha']
    $runs = Get-PagedItem -Path "actions/runs?head_sha=$sha" -Property workflow_runs
    if ($null -eq $runs) { break }
    $checkRuns = Get-PagedItem -Path "commits/$sha/check-runs" -Property check_runs
    if ($null -eq $checkRuns) { break }
    $reviews = Get-ReviewList -Path "pulls/$Pr/reviews"
    if ($null -eq $reviews) { break }
    $requested = Invoke-GitHubGet -Path "pulls/$Pr/requested_reviewers"
    if ($null -eq $requested) { break }
    if ($requested -isnot [System.Collections.IDictionary] -or $requested['users'] -isnot [System.Collections.IList]) {
        throw "GET pulls/$Pr/requested_reviewers returned an unexpected shape."
    }

    $checks = Get-ChecksState -WorkflowRun @($runs) -CheckRun @($checkRuns)
    $line = "$($checks.Line); $(Get-CopilotState -Review @($reviews) -Requested $requested -HeadSha $sha)"
    if ($checks.State -ne 'pending') {
        Write-Output $line
        exit $(if ($checks.State -eq 'passed') { 0 } else { 1 })
    }
    $sleep = [Math]::Min($IntervalSeconds, [Math]::Floor((Get-RemainingSecond)) - 1)
    if ($sleep -lt 1) { break }
    Start-Sleep -Seconds $sleep
}
Write-Output $line
exit 2
