#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $ReportPath,
    [string] $TokensJson = $env:PLATFORM_GITHUB_TOKENS,
    [string] $AppSlug = $env:PLATFORM_APP_SLUG,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $ApiUrl = $env:GITHUB_API_URL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$marker = '<!-- platform-drift-report -->'
$title = 'Infrastructure drift detected'
$maximumBodyLength = 65536

$tokens = $null
if ($TokensJson) {
    try { $tokens = ConvertFrom-Json -InputObject $TokensJson -AsHashtable -ErrorAction Stop } catch { $tokens = $null }
}
$owner, $name = if ($Repository -cmatch '^([A-Za-z0-9-]+)/([A-Za-z0-9._-]+)$') { $Matches[1], $Matches[2] } else { $null, $null }
if (-not $owner -or $tokens -isnot [System.Collections.IDictionary] -or -not $tokens.Contains($owner) -or
    [string]::IsNullOrEmpty([string] $tokens[$owner]) -or $AppSlug -cnotmatch '^[a-z0-9][a-z0-9-]*$' -or
    -not $ApiUrl -or ([uri] $ApiUrl).Scheme -cne 'https') {
    throw 'Drift issue publication requires the issue-writer token for the instance owner, the App slug, the instance repository owner/name and an HTTPS API URL.'
}
$report = [System.IO.File]::ReadAllText([System.IO.Path]::GetFullPath($ReportPath))
if (-not $report.StartsWith("$marker`n", [System.StringComparison]::Ordinal)) {
    throw 'The report does not start with the drift report marker.'
}
if ($report.Length -gt $maximumBodyLength) {
    $notice = "`n`n_Report truncated; see the job summary of the run for the complete report._`n"
    $report = $report.Substring(0, $maximumBodyLength - $notice.Length) + $notice
}
$token = [string] $tokens[$owner]
$issuesPath = "/repos/$owner/$name/issues"
$botLogin = "$AppSlug[bot]"

function Invoke-IssueRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PATCH')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [System.Collections.IDictionary] $Body
    )

    $arguments = @{
        Method = $Method
        Uri = "$($ApiUrl.TrimEnd('/'))$Path"
        Headers = @{
            Authorization = "Bearer $token"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2026-03-10'
        }
        MaximumRedirection = 0
        MaximumRetryCount = 0
        TimeoutSec = 60
    }
    if ($Body) {
        $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 5 -Compress
        $arguments.ContentType = 'application/json'
    }
    try {
        $response = Invoke-RestMethod @arguments
        ConvertTo-Json -InputObject $response -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -NoEnumerate
    }
    catch {
        throw "GitHub issues API $Method $($Path.Split('?')[0]) failed; the drift issue may be missing or stale. $($_.Exception.Message)"
    }
}

function Assert-OpenIssue {
    [CmdletBinding()]
    param([AllowNull()][object] $Issue, [string] $Operation, [string] $ExpectedNumber)

    if ($Issue -isnot [System.Collections.IDictionary] -or $Issue.Contains('pull_request') -or
        [string] $Issue['number'] -cnotmatch '^[1-9][0-9]*$' -or $Issue['state'] -cne 'open' -or
        ($ExpectedNumber -and [string] $Issue['number'] -cne $ExpectedNumber)) {
        throw "GitHub issues API $Operation did not return an open issue."
    }
}

$matching = [System.Collections.Generic.List[object]]::new()
$page = 1
# A short page does not prove the end of the list; only an empty page does.
do {
    if ($page -gt 1000) { throw 'GitHub issues API did not end the open issue list within 1000 pages.' }
    $items = @(Invoke-IssueRequest -Method GET -Path "$issuesPath`?state=open&per_page=100&page=$page")
    if ($items.Count -eq 1 -and $items[0] -is [System.Collections.IList]) { $items = @($items[0]) }
    foreach ($item in $items) {
        if ($item -isnot [System.Collections.IDictionary] -or -not $item.Contains('user')) {
            throw 'GitHub issues API returned an unknown issue list item.'
        }
        if ($item.Contains('pull_request') -or $null -eq $item['user']) { continue }
        if ($item['user'] -isnot [System.Collections.IDictionary] -or
            -not ($item['user']['login'] -is [string] -and $item['user']['login']) -or
            -not ($item['user']['type'] -is [string] -and $item['user']['type'])) {
            throw 'GitHub issues API returned an issue author without a readable login and type.'
        }
        if ($item['user']['login'] -ceq $botLogin -and $item['user']['type'] -ceq 'Bot' -and
            $item['body'] -is [string] -and $item['body'].StartsWith("$marker`n", [System.StringComparison]::Ordinal)) {
            $matching.Add($item)
        }
    }
    $page++
} while ($items.Count -gt 0)

if ($matching.Count -gt 1) {
    throw "Found more than one open drift issue of this App: $(($matching | ForEach-Object { "#$($_['number'])" }) -join ', '). Close the duplicates manually."
}
if ($matching.Count -eq 1) {
    $number = [string] $matching[0]['number']
    $issue = Invoke-IssueRequest -Method PATCH -Path "$issuesPath/$number" -Body @{ body = $report }
    Assert-OpenIssue -Issue $issue -Operation 'PATCH' -ExpectedNumber $number
    $action = 'updated'
}
else {
    $issue = Invoke-IssueRequest -Method POST -Path $issuesPath -Body ([ordered]@{ title = $title; body = $report })
    Assert-OpenIssue -Issue $issue -Operation 'POST'
    $action = 'created'
}
Write-Information "Drift issue #$($issue['number']) $action." -InformationAction Continue
[pscustomobject]@{ Action = $action; Number = [int] $issue['number'] }
