#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $ReportPath,
    [ValidateSet('Report', 'Clean', IgnoreCase = $false)][string] $Outcome = 'Report',
    [string] $TokensJson = $env:PLATFORM_GITHUB_TOKENS,
    [string] $AppSlug = $env:PLATFORM_APP_SLUG,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $ContentsToken = $env:DRIFT_CONTENTS_TOKEN,
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
        [System.Collections.IDictionary] $Body,
        [switch] $ReadRepository
    )

    if ($ReadRepository) { $token = $ContentsToken }
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

# security-check: drift-issue-state
function Assert-IssueState {
    [CmdletBinding()]
    param([AllowNull()][object] $Issue, [string] $Operation, [string] $ExpectedNumber,
        [ValidateSet('open', 'closed')][string] $ExpectedState = 'open')

    if ($Issue -isnot [System.Collections.IDictionary] -or $Issue.Contains('pull_request') -or
        ($Issue['number'] -isnot [int] -and $Issue['number'] -isnot [long]) -or
        [string] $Issue['number'] -cnotmatch '^[1-9][0-9]*$' -or
        $Issue['state'] -isnot [string] -or $Issue['state'] -cne $ExpectedState -or
        ($ExpectedNumber -and [string] $Issue['number'] -cne $ExpectedNumber)) {
        throw "GitHub issues API $Operation did not return an $ExpectedState issue."
    }
}

# security-check: drift-clean-comment
function Test-CleanComment {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Comment, [string] $CleanMarker)

    if ($Comment['body'] -isnot [string] -or
        -not $Comment['body'].StartsWith("$CleanMarker`n", [System.StringComparison]::Ordinal)) { return $false }
    if ($Comment['user'] -isnot [System.Collections.IDictionary] -or
        $Comment['user']['login'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Comment['user']['login']) -or
        $Comment['user']['type'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Comment['user']['type'])) {
        throw 'Cannot verify the author of an existing clean-result comment; leave the issue open and resolve the ambiguous recovery manually.'
    }
    return $Comment['user']['login'] -ceq $botLogin -and $Comment['user']['type'] -ceq 'Bot'
}

# security-check: drift-created-comment
function Assert-CreatedComment {
    [CmdletBinding()]
    param([AllowNull()][object] $Comment, [string] $ExpectedBody)

    if ($Comment -isnot [System.Collections.IDictionary] -or
        ($Comment['id'] -isnot [int] -and $Comment['id'] -isnot [long]) -or
        [string] $Comment['id'] -cnotmatch '^[1-9][0-9]*$' -or
        $Comment['body'] -isnot [string] -or $Comment['body'] -cne $ExpectedBody) {
        throw 'GitHub issues API POST did not return the clean-result comment.'
    }
}

# security-check: drift-run-evidence
function Get-DriftRunEvidence {
    param([string] $Body)

    $markers = [regex]::Matches($Body, '(?m)^<!-- platform-drift-run:')
    if ($markers.Count -eq 0) { return $null }
    $metadata = [regex]::Matches($Body, '(?m)^<!-- platform-drift-run:(?<workflow>[^|\r\n]+)\|(?<number>[1-9][0-9]*) -->$')
    $number = 0L
    if ($markers.Count -ne 1 -or $metadata.Count -ne 1 -or
        -not [long]::TryParse($metadata[0].Groups['number'].Value, [ref] $number)) {
        throw 'Unreadable clean-run evidence metadata.'
    }
    return @{ Workflow = $metadata[0].Groups['workflow'].Value; Number = $number }
}

# security-check: drift-clean-evidence
function Get-CleanDriftEvidence {
    param([string] $Report, [System.Collections.IDictionary] $Previous)

    $clean = Get-DriftRunEvidence -Body $Report
    $workflow = "$Repository/.github/workflows/drift.yml@refs/heads/main"
    $revisions = [regex]::Matches($Report, '(?m)^Revision: `(?<sha>[a-f0-9]{40})`$')
    if ($null -eq $clean -or $clean.Workflow -cne $workflow -or $Previous.Workflow -cne $workflow -or
        $revisions.Count -ne 1) {
        throw 'Unreadable or uncorrelated clean-run evidence.'
    }
    if ($clean.Number -le $Previous.Number) { throw 'Clean evidence must be newer than the last drift report.' }
    return @{ Number = $clean.Number; Revision = $revisions[0].Groups['sha'].Value }
}

# security-check: drift-current-main
function Assert-CurrentDriftMain {
    param([string] $Revision)

    if ([string]::IsNullOrWhiteSpace($ContentsToken)) {
        throw 'Clean drift closure requires the existing contents:read token.'
    }
    $reference = Invoke-IssueRequest -Method GET -Path "/repos/$owner/$name/git/ref/heads/main" -ReadRepository
    if ($reference -isnot [Collections.IDictionary] -or $reference['ref'] -isnot [string] -or
        $reference['ref'] -cne 'refs/heads/main' -or $reference['object'] -isnot [Collections.IDictionary] -or
        $reference['object']['type'] -isnot [string] -or $reference['object']['type'] -cne 'commit' -or
        $reference['object']['sha'] -isnot [string] -or $reference['object']['sha'] -cne $Revision) {
        throw 'Current main is unreadable or no longer matches the clean plan revision.'
    }
}

# security-check: drift-report-order
function Assert-DriftReportOrder {
    param([AllowNull()][object] $Previous, [AllowNull()][object] $Incoming)

    if ($null -ne $Previous -and ($null -eq $Incoming -or $Incoming.Workflow -cne $Previous.Workflow -or
            $Incoming.Number -lt $Previous.Number)) {
        throw 'Refusing an older or uncorrelated drift report over the last recorded run.'
    }
}

# security-check: drift-collection
function Get-DriftCollection {
    param([string] $Path, [ValidateSet('issue', 'comment')][string] $Name)

    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    # A short page does not prove the end of the list; only an empty page does.
    for ($page = 1; $page -le 1000; $page++) {
        $items = Invoke-IssueRequest -Method GET -Path "${Path}${separator}per_page=100&page=$page"
        if ($items -isnot [Collections.IList]) { throw "GitHub issues API returned an unknown $Name list." }
        foreach ($item in $items) {
            if ($item -isnot [Collections.IDictionary]) { throw "GitHub issues API returned an unknown $Name list item." }
            $item
        }
        if ($items.Count -eq 0) { return }
    }
    throw "GitHub issues API did not end the $Name list within 1000 pages."
}

function Get-MatchingDriftIssues {
    param([ValidateSet('open', 'closed')][string] $State)

    foreach ($item in (Get-DriftCollection -Path "$issuesPath`?state=$State" -Name issue)) {
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
            Assert-IssueState -Issue $item -Operation GET -ExpectedState $State
            $item
        }
    }
}

# security-check: drift-resolved-report
function Assert-DriftReportNotResolved {
    param([string] $Report)

    $incoming = Get-DriftRunEvidence -Body $Report
    foreach ($resolved in (Get-MatchingDriftIssues -State closed)) {
        $previous = Get-DriftRunEvidence -Body $resolved['body']
        if ($null -eq $previous) { continue }
        if ($null -eq $incoming -or $incoming.Workflow -cne $previous.Workflow) {
            throw 'Cannot compare uncorrelated resolved-run evidence; start a new drift run.'
        }
        $latest = $previous.Number
        $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($resolved['body']))).ToLowerInvariant()
        $prefix = "<!-- platform-drift-clean:${digest}:"
        foreach ($comment in (Get-DriftCollection -Path "$issuesPath/$($resolved['number'])/comments" -Name comment)) {
            if ($comment['body'] -isnot [string]) { throw 'Unreadable resolved-run evidence in a comment body.' }
            if (-not $comment['body'].StartsWith($prefix, [StringComparison]::Ordinal)) { continue }
            $metadata = [regex]::Match($comment['body'], "^$([regex]::Escape($prefix))(?<number>[1-9][0-9]*):[a-f0-9]{40} -->`n")
            $number = 0L
            if (-not [long]::TryParse($metadata.Groups['number'].Value, [ref] $number)) {
                throw 'Unreadable resolved-run evidence in a clean-result marker.'
            }
            if (Test-CleanComment -Comment $comment -CleanMarker $metadata.Value.TrimEnd("`n")) {
                $latest = [Math]::Max($latest, $number)
            }
        }
        if ($incoming.Number -le $latest) {
            throw 'The report was already resolved by this workflow; start a new drift run.'
        }
    }
}

$matching = @(Get-MatchingDriftIssues -State open)
if ($matching.Count -gt 1) {
    throw "Found more than one open drift issue of this App: $(($matching | ForEach-Object { "#$($_['number'])" }) -join ', '). Close the duplicates manually."
}
if ($Outcome -ceq 'Clean') {
    if ($matching.Count -eq 0) {
        Write-Information 'No open drift issue of this App to close.' -InformationAction Continue
        return [pscustomobject]@{ Action = 'unchanged'; Number = $null }
    }
    $current = $matching[0]
    Assert-IssueState -Issue $current -Operation 'GET'
    $number = [string] $current['number']
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($current['body']))).ToLowerInvariant()
    $previous = Get-DriftRunEvidence -Body $current['body']
    $manual = $null -eq $previous
    $evidence = $null
    if ($manual) {
        $cleanMarker = "<!-- platform-drift-manual:$digest -->"
        $commentReport = 'The last drift report has no run_number; verify the latest clean run and ' +
            '[close this issue manually](https://docs.github.com/en/issues/tracking-your-work-with-issues/administering-issues/closing-an-issue).' +
            "`n`n$report"
    }
    else {
        $evidence = Get-CleanDriftEvidence -Report $report -Previous $previous
        Assert-CurrentDriftMain -Revision $evidence.Revision
        # A rerun keeps its counter and revision; another clean plan must not reuse stale evidence.
        $cleanMarker = "<!-- platform-drift-clean:${digest}:$($evidence.Number):$($evidence.Revision) -->"
        $commentReport = $report
    }
    $commentFound = $false
    foreach ($comment in (Get-DriftCollection -Path "$issuesPath/$number/comments" -Name comment)) {
        if (Test-CleanComment -Comment $comment -CleanMarker $cleanMarker) { $commentFound = $true }
    }
    if (-not $commentFound) {
        $commentBody = "$cleanMarker`n$commentReport"
        if ($commentBody.Length -gt $maximumBodyLength) {
            $notice = "`n`n_Report truncated; see the job summary of the run for the complete report._`n"
            $commentBody = $commentBody.Substring(0, $maximumBodyLength - $notice.Length) + $notice
        }
        $comment = Invoke-IssueRequest -Method POST -Path "$issuesPath/$number/comments" -Body @{ body = $commentBody }
        Assert-CreatedComment -Comment $comment -ExpectedBody $commentBody
    }
    if ($manual) {
        Write-Information "Drift issue #$number remains open; its legacy report requires manual closure." -InformationAction Continue
        return [pscustomobject]@{ Action = 'manual'; Number = [int] $number }
    }
    Assert-CurrentDriftMain -Revision $evidence.Revision
    $issue = Invoke-IssueRequest -Method PATCH -Path "$issuesPath/$number" -Body @{ state = 'closed'; state_reason = 'completed' }
    Assert-IssueState -Issue $issue -Operation 'PATCH' -ExpectedNumber $number -ExpectedState closed
    Write-Information "Drift issue #$number closed after a clean result." -InformationAction Continue
    return [pscustomobject]@{ Action = 'closed'; Number = [int] $number }
}
if ($matching.Count -eq 1) {
    Assert-DriftReportOrder -Previous (Get-DriftRunEvidence -Body $matching[0]['body']) -Incoming (Get-DriftRunEvidence -Body $report)
    $number = [string] $matching[0]['number']
    $issue = Invoke-IssueRequest -Method PATCH -Path "$issuesPath/$number" -Body @{ body = $report }
    Assert-IssueState -Issue $issue -Operation 'PATCH' -ExpectedNumber $number
    $action = 'updated'
}
else {
    Assert-DriftReportNotResolved -Report $report
    $issue = Invoke-IssueRequest -Method POST -Path $issuesPath -Body ([ordered]@{ title = $title; body = $report })
    Assert-IssueState -Issue $issue -Operation 'POST'
    $action = 'created'
}
Write-Information "Drift issue #$($issue['number']) $action." -InformationAction Continue
[pscustomobject]@{ Action = $action; Number = [int] $issue['number'] }
