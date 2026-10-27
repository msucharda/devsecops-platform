#Requires -Version 7.4
Set-StrictMode -Version Latest

<#
Merge gate for agent-driven pull request merges (issue #85).

Invoke-MergeGate evaluates one pull request with read-only GitHub API calls and returns the verdict
pass, pending, fail or already-merged. Invoke-GatedMerge evaluates the gate again, merges only on pass
with --squash --match-head-commit and verifies the merge afterwards. It never uses --admin or --auto.

API contract (X-GitHub-Api-Version 2026-03-10; GraphQL schema github/docs src/graphql/data/ghec/schema.docs.graphql):
- query repository.pullRequest: https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/objects#pullrequest
- query repository.pullRequest.userContentEdits: https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/objects#usercontentedit
- GET /repos/{owner}/{repo}/actions/runs: https://docs.github.com/en/enterprise-cloud@latest/rest/actions/workflow-runs#list-workflow-runs-for-a-repository
- GET /repos/{owner}/{repo}/commits/{ref}/check-runs: https://docs.github.com/en/enterprise-cloud@latest/rest/checks/runs#list-check-runs-for-a-git-reference
- GET /repos/{owner}/{repo}/commits/{ref}/status: https://docs.github.com/en/enterprise-cloud@latest/rest/commits/statuses#get-the-combined-status-for-a-specific-reference
- GET /repos/{owner}/{repo}/rules/branches/{branch}: https://docs.github.com/en/enterprise-cloud@latest/rest/repos/rules#get-rules-for-a-branch
- GET /repos/{owner}/{repo}/compare/{basehead}: https://docs.github.com/en/enterprise-cloud@latest/rest/commits/commits#compare-two-commits
- GET /repos/{owner}/{repo}/pulls/{pull_number}/files: https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#list-pull-requests-files
- GET /repos/{owner}/{repo}/rulesets/rule-suites: https://docs.github.com/en/enterprise-cloud@latest/rest/repos/rule-suites#list-repository-rule-suites
#>

$script:GateVersion = '1.0.0'
$script:ApiVersion = '2026-03-10'
$script:CopilotLogins = [string[]] @('copilot-pull-request-reviewer', 'copilot-pull-request-reviewer[bot]', 'Copilot')
$script:CopilotCheckName = 'copilot-pull-request-reviewer'
$script:CopilotWorkflowName = 'Running Copilot Code Review'
$script:PendingStatuses = [string[]] @('queued', 'in_progress', 'waiting', 'requested', 'pending')
$script:SuccessConclusions = [string[]] @('success', 'skipped', 'neutral')
# Changed lines that touch token permissions (any scope, also inside an unchanged permissions block), privileged triggers,
# secrets or self-hosted runners (issue #85, G10).
$script:SensitivePattern = 'permissions|\b(actions|attestations|checks|contents|deployments|discussions|id-token|issues|models|packages|pages|pull-requests|repository-projects|security-events|statuses)\b[''"]?\s*:\s*[''"]?(read|write|none)\b|:\s*[''"]?write\b|write-all|read-all|id-token|attestations|pull_request_target|workflow_run|secrets[''"]?\s*(\.|\[|:)|^[+-]\s*[''"]?(read|write|none|read-all|write-all)[''"]?\s*$|GITHUB_TOKEN|self-hosted'
$script:OpenQuestionsHeading = '(?im)^#{1,6}[ \t]*(Otev\u0159en\u00E9 ot\u00E1zky|Open questions)\b.*$'
$script:DecisionsHeading = '(?im)^#{1,6}[ \t]*(Rozhodnut\u00ED (pro )?u\u017Eivatele)\b.*$'
$script:DecisionsAcceptedMarker = '<!--\s*merge-gate:\s*decisions-accepted\s+(?<login>[A-Za-z0-9-]+(\[bot\])?)\s+(?<date>\d{4}-\d{2}-\d{2})\s*-->'
$script:OpenQuestionsMarker = '<!--\s*merge-gate:\s*open-questions=(?<count>\d+)\s*-->'
$script:MaxRestPages = 10
$script:MaxFilePages = 30
$script:MaxThreadPages = 10
$script:ExitCodes = @{ 'pass' = 0; 'fail' = 1; 'pending' = 2; 'already-merged' = 3 }
$script:CheckOrder = [string[]] @('pr-state', 'draft', 'head-pin', 'ci-checks', 'review-threads', 'copilot-review', 'mergeability', 'behind-base', 'open-questions', 'github-changes')

$script:PullRequestQuery = @'
query($owner: String!, $name: String!, $number: Int!, $threads: String) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      number state merged mergedAt mergedBy { login } mergeCommit { oid }
      headRefOid baseRefName baseRefOid isDraft mergeable mergeStateStatus body createdAt
      commits(last: 1) { nodes { commit { oid committedDate } } }
      reviewThreads(first: 100, after: $threads) {
        totalCount pageInfo { hasNextPage endCursor }
        nodes { isResolved isOutdated path comments(first: 1) { nodes { author { login } createdAt url } } }
      }
      reviews(last: 100) { totalCount nodes { author { login } state submittedAt commit { oid } body } }
      timelineItems(itemTypes: [REVIEW_REQUESTED_EVENT, HEAD_REF_FORCE_PUSHED_EVENT], last: 100) {
        pageInfo { hasPreviousPage }
        nodes {
          __typename
          ... on ReviewRequestedEvent { createdAt requestedReviewer { __typename ... on Bot { login } } }
          ... on HeadRefForcePushedEvent { createdAt }
        }
      }
    }
  }
}
'@

$script:MergeStateQuery = @'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) { state merged mergedAt mergedBy { login } mergeCommit { oid } headRefOid baseRefName }
  }
}
'@

$script:DecisionAuthorsQuery = @'
query($owner: String!, $name: String!, $number: Int!) {
  repository(owner: $owner, name: $name) {
    pullRequest(number: $number) {
      headRefOid body author { __typename login }
      userContentEdits(first: 100) {
        totalCount pageInfo { hasNextPage }
        nodes { deletedAt editor { __typename login } }
      }
    }
  }
}
'@

class MergeGateInputError : System.Exception {
    MergeGateInputError([string] $Message) : base($Message) {}
}

function ConvertTo-MergeGateTarget {
    <#
    .SYNOPSIS
    Parses 'owner/repo' or 'host/owner/repo' (GHE.com, for example 'example.ghe.com/example-platform/instance').
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Repository)

    $match = [regex]::Match($Repository, '^(?:(?<host>[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)/)?(?<owner>[A-Za-z0-9][A-Za-z0-9-]{0,38})/(?<name>[A-Za-z0-9._-]{1,100})$')
    if (-not $match.Success -or $match.Groups['name'].Value -in @('.', '..')) {
        throw [MergeGateInputError]::new("Repository '$Repository' must be 'owner/repo' or 'host/owner/repo'.")
    }
    $hostName = if ($match.Groups['host'].Success) { $match.Groups['host'].Value.ToLowerInvariant() } else { 'github.com' }
    $owner = $match.Groups['owner'].Value
    $name = $match.Groups['name'].Value
    return @{
        Host = $hostName
        Owner = $owner
        Name = $name
        Slug = "$owner/$name"
        Repository = "$hostName/$owner/$name"
    }
}

function ConvertTo-MergeGateSha {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Value, [Parameter(Mandatory)][string] $Parameter)

    if ([string]::IsNullOrEmpty($Value)) { return '' }
    if ($Value -notmatch '^[0-9a-fA-F]{40}$') { throw [MergeGateInputError]::new("$Parameter '$Value' must be a 40-character hexadecimal commit SHA.") }
    return $Value.ToLowerInvariant()
}

function ConvertTo-MergeGateTime {
    # ConvertFrom-Json turns ISO 8601 strings into DateTime values; both forms become a UTC DateTimeOffset.
    [CmdletBinding()]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    if ($Value -is [DateTimeOffset]) { return $Value.ToUniversalTime() }
    if ($Value -is [datetime]) {
        $kind = if ($Value.Kind -eq [DateTimeKind]::Unspecified) { [datetime]::SpecifyKind($Value, [DateTimeKind]::Utc) } else { $Value }
        return [DateTimeOffset]::new($kind.ToUniversalTime())
    }
    $parsed = [DateTimeOffset]::MinValue
    if ($Value -is [string] -and [DateTimeOffset]::TryParse($Value, [Globalization.CultureInfo]::InvariantCulture, [Globalization.DateTimeStyles]::AssumeUniversal, [ref] $parsed)) {
        return $parsed.ToUniversalTime()
    }
    throw "The API returned an unreadable timestamp '$Value'."
}

function Format-MergeGateTime {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $Value)

    if ($null -eq $Value) { return $null }
    return (ConvertTo-MergeGateTime -Value $Value).ToString('yyyy-MM-ddTHH:mm:ssZ', [Globalization.CultureInfo]::InvariantCulture)
}

function Get-MergeGateValue {
    # Reads a dotted path from parsed JSON; a missing key or a null parent returns $null. Lists are returned whole.
    [CmdletBinding()]
    param([AllowNull()] $Node, [Parameter(Mandatory)][string] $Path)

    foreach ($segment in $Path.Split('.')) {
        if ($Node -isnot [System.Collections.IDictionary] -or -not $Node.Contains($segment)) { return $null }
        $Node = $Node[$segment]
    }
    if ($Node -is [System.Collections.IList]) { return , $Node }
    return $Node
}

function Get-MergeGateList {
    # Returns a list value of parsed JSON as one object; anything else than a list is an unreadable response.
    # Callers enumerate it with (Get-MergeGateList ...) or assign it; @(Get-MergeGateList ...) would nest it.
    [CmdletBinding()]
    param([AllowNull()] $Node, [Parameter(Mandatory)][string] $Path)

    $value = Get-MergeGateValue -Node $Node -Path $Path
    if ($value -isnot [System.Collections.IList]) { throw "The API response has no list at '$Path'." }
    return , $value
}

function Invoke-MergeGateGh {
    <#
    .SYNOPSIS
    Runs gh and returns its standard output. A non-zero exit code throws.
    .NOTES
    For hosts other than github.com, GH_TOKEN is removed for the call so that gh uses the stored login of that host.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $savedToken = $env:GH_TOKEN
    try {
        if ($Target.Host -ne 'github.com') { Remove-Item Env:\GH_TOKEN -ErrorAction SilentlyContinue }
        $output = @(& gh @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        if ($null -ne $savedToken) { $env:GH_TOKEN = $savedToken }
    }
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '
    if ($exitCode -ne 0) { throw "gh $($Arguments[0]) $($Arguments[1]) failed with exit code ${exitCode}: $stderr" }
    return $stdout
}

# security-check: merge-gate-read-only
function Assert-MergeGateReadRequest {
    <#
    .SYNOPSIS
    Refuses every gh call of the gate that is not a REST GET or a GraphQL query.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string[]] $Arguments)

    if ($Arguments.Count -lt 4 -or $Arguments[0] -ne 'api') { throw "The merge gate refused a gh call that is not an API read: $($Arguments -join ' ')" }
    $bodyFlags = @($Arguments | Where-Object { $_ -in @('-X', '--method', '-f', '-F', '--field', '--raw-field', '--input') })
    if ($Arguments[1] -eq 'graphql') {
        if ($Arguments[2] -cne '-f' -or $Arguments[3] -notmatch '^query=\s*query\b' -or $Arguments[3] -match '\bmutation\b') {
            throw 'The merge gate refused a GraphQL request that is not a single query.'
        }
        return
    }
    if ($Arguments[1] -ne '--method' -or $Arguments[2] -ne 'GET' -or $bodyFlags.Count -ne 1) {
        throw "The merge gate refused a REST request that is not a plain GET: $($Arguments -join ' ')"
    }
}

function Invoke-MergeGateRest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][string] $Path
    )

    $arguments = [string[]] @('api', '--method', 'GET', '--hostname', $Target.Host,
        '-H', 'Accept: application/vnd.github+json', '-H', "X-GitHub-Api-Version: $script:ApiVersion", $Path)
    Assert-MergeGateReadRequest -Arguments $arguments
    $text = Invoke-MergeGateGh -Target $Target -Arguments $arguments
    try { $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100 -NoEnumerate }
    catch { throw "The response of GET $Path is not JSON: $($_.Exception.Message)" }
    if ($null -eq $value) { throw "The response of GET $Path is empty." }
    return , $value
}

function Invoke-MergeGateGraphQL {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][string] $Query,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Variables
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]] @('api', 'graphql', '-f', "query=$Query", '--hostname', $Target.Host))
    foreach ($key in $Variables.Keys) {
        $value = $Variables[$key]
        if ($null -eq $value) { continue }
        # -F sends integers as numbers; -f keeps strings such as cursors literal.
        if ($value -is [int]) { $arguments.AddRange([string[]] @('-F', "$key=$value")) }
        else { $arguments.AddRange([string[]] @('-f', "$key=$value")) }
    }
    Assert-MergeGateReadRequest -Arguments $arguments.ToArray()
    $text = Invoke-MergeGateGh -Target $Target -Arguments $arguments.ToArray()
    try { $value = ConvertFrom-Json -InputObject $text -AsHashtable -Depth 100 }
    catch { throw "The GraphQL response is not JSON: $($_.Exception.Message)" }
    if ($value -isnot [System.Collections.IDictionary]) { throw 'The GraphQL response is not an object.' }
    if ($value.Contains('errors') -and $null -ne $value['errors']) {
        $messages = @($value['errors'] | ForEach-Object { Get-MergeGateValue -Node $_ -Path 'message' }) -join '; '
        throw "The GraphQL query returned errors: $messages"
    }
    $data = Get-MergeGateValue -Node $value -Path 'data'
    if ($data -isnot [System.Collections.IDictionary]) { throw 'The GraphQL response has no data.' }
    return $data
}

function Get-MergeGateRestList {
    <#
    .SYNOPSIS
    Reads every page of a list endpoint and returns the items as one array object. A total that the pages do not
    reach, or more pages than allowed, fails: the gate never evaluates a partial list.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][string] $Path,
        # The list property of an object response with total_count; empty for an array response.
        [string] $Property,
        [int] $MaxPages = $script:MaxRestPages
    )

    $items = [System.Collections.Generic.List[object]]::new()
    $separator = if ($Path.Contains('?')) { '&' } else { '?' }
    for ($page = 1; $page -le $MaxPages; $page++) {
        $response = Invoke-MergeGateRest -Target $Target -Path "$Path${separator}per_page=100&page=$page"
        if ($Property) {
            $pageItems = Get-MergeGateList -Node $response -Path $Property
            $total = Get-MergeGateValue -Node $response -Path 'total_count'
            if ($total -isnot [int] -and $total -isnot [long]) { throw "GET $Path returned no total_count." }
            foreach ($item in $pageItems) { $items.Add($item) }
            if ($items.Count -ge $total -or $pageItems.Count -eq 0) {
                if ($items.Count -ne $total) { throw "GET $Path returned $($items.Count) items, but total_count is $total." }
                return , $items.ToArray()
            }
        }
        else {
            if ($response -isnot [System.Collections.IList]) { throw "GET $Path did not return a list." }
            foreach ($item in $response) { $items.Add($item) }
            if ($response.Count -lt 100) { return , $items.ToArray() }
        }
    }
    throw "GET $Path has more than $MaxPages pages of 100 items; the gate cannot evaluate a partial list."
}

function Get-MergeGatePullRequest {
    <#
    .SYNOPSIS
    Reads the pull request with all review threads. The head must not move between pages.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][int] $Number
    )

    $threads = [System.Collections.Generic.List[object]]::new()
    $cursor = $null
    $pullRequest = $null
    for ($page = 1; $page -le $script:MaxThreadPages; $page++) {
        $data = Invoke-MergeGateGraphQL -Target $Target -Query $script:PullRequestQuery -Variables ([ordered]@{
                owner = $Target.Owner; name = $Target.Name; number = $Number; threads = $cursor })
        $current = Get-MergeGateValue -Node $data -Path 'repository.pullRequest'
        if ($current -isnot [System.Collections.IDictionary]) { throw "Pull request $($Target.Slug)#$Number was not found." }
        if ($null -eq $pullRequest) {
            $pullRequest = $current
            # G1 returns immediately for a merged pull request; the other fields are not needed.
            if ($current['state'] -ceq 'MERGED' -and $current['merged'] -eq $true) { return $pullRequest }
        }
        elseif ($current['headRefOid'] -cne $pullRequest['headRefOid']) { throw 'The head of the pull request moved during the evaluation.' }
        $connection = Get-MergeGateValue -Node $current -Path 'reviewThreads'
        foreach ($node in (Get-MergeGateList -Node $connection -Path 'nodes')) { $threads.Add($node) }
        if ((Get-MergeGateValue -Node $connection -Path 'pageInfo.hasNextPage') -ne $true) {
            $total = Get-MergeGateValue -Node $connection -Path 'totalCount'
            if ($total -ne $threads.Count) { throw "The pull request reports $total review threads, but $($threads.Count) were read." }
            $pullRequest['reviewThreads'] = @{ totalCount = $total; nodes = $threads.ToArray() }
            return $pullRequest
        }
        $cursor = Get-MergeGateValue -Node $connection -Path 'pageInfo.endCursor'
        if ($cursor -isnot [string] -or $cursor -eq '') { throw 'The review thread page has no end cursor.' }
    }
    throw "The pull request has more than $($script:MaxThreadPages * 100) review threads; the gate cannot evaluate a partial list."
}

function Assert-MergeGatePullRequestShape {
    # Fails on a response that the documented schema does not allow, so that a partial read never passes.
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $PullRequest)

    foreach ($field in @('state', 'headRefOid', 'baseRefName', 'baseRefOid', 'mergeable', 'mergeStateStatus')) {
        if ($PullRequest[$field] -isnot [string] -or $PullRequest[$field] -eq '') { throw "The pull request has no $field." }
    }
    if ($PullRequest['headRefOid'] -cnotmatch '^[0-9a-f]{40}$' -or $PullRequest['baseRefOid'] -cnotmatch '^[0-9a-f]{40}$') {
        throw 'The pull request has no valid head or base SHA.'
    }
    if ($PullRequest['isDraft'] -isnot [bool]) { throw 'The pull request has no isDraft value.' }
    # PullRequest.body is String!; a missing body is an incomplete response, not a body without open questions.
    if ($PullRequest['body'] -isnot [string]) { throw 'The pull request has no body.' }
    $reviews = Get-MergeGateValue -Node $PullRequest -Path 'reviews'
    $reviewNodes = Get-MergeGateList -Node $reviews -Path 'nodes'
    if ((Get-MergeGateValue -Node $reviews -Path 'totalCount') -ne $reviewNodes.Count) {
        throw "The pull request has more than $($reviewNodes.Count) reviews; the gate cannot count Copilot rounds from a partial list."
    }
    $null = Get-MergeGateList -Node $PullRequest -Path 'timelineItems.nodes'
    if ((Get-MergeGateValue -Node $PullRequest -Path 'timelineItems.pageInfo.hasPreviousPage') -ne $false) {
        throw 'The pull request has more than 100 review request and force-push events; the gate cannot find the latest Copilot request in a partial list.'
    }
    $null = Get-MergeGateList -Node $PullRequest -Path 'commits.nodes'
}

# security-check: merge-gate-pr-state
function Get-MergeGateStateFinding {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $PullRequest,
        [switch] $ExpectMerged
    )

    if ($PullRequest['state'] -ceq 'MERGED' -and $PullRequest['merged'] -eq $true) { return 'already-merged' }
    if ($ExpectMerged) { return 'fail:not-merged' }
    if ($PullRequest['state'] -ceq 'CLOSED') { return 'fail:pr-closed' }
    if ($PullRequest['state'] -cne 'OPEN') { return 'fail:pr-state-unknown' }
}

# security-check: merge-gate-draft
function Get-MergeGateDraftFinding {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $PullRequest)

    if ($PullRequest['isDraft'] -ne $false) { 'fail:draft' }
}

# security-check: merge-gate-head-pin
function Get-MergeGateHeadFinding {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $HeadSha,
        [AllowEmptyString()][string] $ExpectedHeadSha
    )

    if ($ExpectedHeadSha -and $HeadSha -ne $ExpectedHeadSha) { 'fail:head-moved' }
}

# security-check: merge-gate-run-state
function Get-MergeGateRunState {
    <#
    .SYNOPSIS
    Classifies a workflow run, check run or commit status as success, pending or failure. Unknown values are failures.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowNull()] $Status,
        [AllowNull()] $Conclusion
    )

    if ($Status -cin $script:PendingStatuses) { return 'pending' }
    if ($Status -ceq 'completed' -and $Conclusion -cin $script:SuccessConclusions) { return 'success' }
    return 'failure'
}

function Get-MergeGateStatusState {
    # Commit statuses use state success, pending, failure or error.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowNull()] $State)

    switch -CaseSensitive ($State) {
        'success' { return Get-MergeGateRunState -Status 'completed' -Conclusion 'success' }
        'pending' { return Get-MergeGateRunState -Status 'pending' -Conclusion $null }
    }
    return Get-MergeGateRunState -Status 'completed' -Conclusion 'failure'
}

# security-check: merge-gate-copilot-run
function Test-MergeGateCopilotRun {
    # The Copilot review runs as a dynamic workflow and as the check run copilot-pull-request-reviewer; G6 evaluates both.
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Run, [ValidateSet('WorkflowRun', 'CheckRun')][string] $Kind)

    if ($Kind -eq 'CheckRun') { return $Run['name'] -ceq $script:CopilotCheckName }
    return $Run['event'] -ceq 'dynamic' -and $Run['name'] -ceq $script:CopilotWorkflowName
}

# security-check: merge-gate-ci-checks
function Get-MergeGateCheckFinding {
    <#
    .SYNOPSIS
    G4: every workflow run, check run and commit status of the head must succeed, and every expected workflow and
    required context must exist. A missing one is pending during the grace period after the head push, then a failure.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][object[]] $WorkflowRuns = @(),
        [AllowEmptyCollection()][object[]] $CheckRuns = @(),
        [AllowEmptyCollection()][object[]] $Statuses = @(),
        [AllowEmptyCollection()][object[]] $RequiredChecks = @(),
        [AllowEmptyCollection()][string[]] $ExpectedWorkflows = @(),
        [AllowNull()] $PushedAt,
        [Parameter(Mandatory)][DateTimeOffset] $Now,
        [int] $GraceMinutes = 15
    )

    foreach ($run in $WorkflowRuns) {
        if (Test-MergeGateCopilotRun -Run $run -Kind WorkflowRun) { continue }
        $state = Get-MergeGateRunState -Status $run['status'] -Conclusion $run['conclusion']
        if ($state -ceq 'failure') { "fail:check-failed:$($run['name'])" }
        elseif ($state -ceq 'pending') { "pending:checks-pending:$($run['name'])" }
    }
    foreach ($run in $CheckRuns) {
        if (Test-MergeGateCopilotRun -Run $run -Kind CheckRun) { continue }
        $state = Get-MergeGateRunState -Status $run['status'] -Conclusion $run['conclusion']
        if ($state -ceq 'failure') { "fail:check-failed:$($run['name'])" }
        elseif ($state -ceq 'pending') { "pending:checks-pending:$($run['name'])" }
    }
    foreach ($status in $Statuses) {
        $state = Get-MergeGateStatusState -State $status['state']
        if ($state -ceq 'failure') { "fail:check-failed:$($status['context'])" }
        elseif ($state -ceq 'pending') { "pending:checks-pending:$($status['context'])" }
    }

    $pushed = ConvertTo-MergeGateTime -Value $PushedAt
    $withinGrace = $null -ne $pushed -and ($Now - $pushed).TotalMinutes -lt $GraceMinutes
    $missing = [System.Collections.Generic.List[string]]::new()
    foreach ($workflow in $ExpectedWorkflows) {
        $present = @($WorkflowRuns | Where-Object { $_['name'] -ceq $workflow -and $_['event'] -ceq 'pull_request' })
        if ($present.Count -eq 0) { $missing.Add($workflow) }
    }
    foreach ($check in $RequiredChecks) {
        if (-not (Test-MergeGateRequiredCheck -Check $check -CheckRuns $CheckRuns -Statuses $Statuses)) { $missing.Add($check['context']) }
    }
    foreach ($name in $missing) {
        if ($withinGrace) { "pending:required-check-missing:$name" }
        else { "fail:required-check-missing:$name" }
    }
}

# security-check: merge-gate-required-integration
function Test-MergeGateRequiredCheck {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Check,
        [AllowEmptyCollection()][object[]] $CheckRuns = @(),
        [AllowEmptyCollection()][object[]] $Statuses = @()
    )

    $integration = $Check['integration_id']
    if ($Check.Contains('integration_id') -and $integration -isnot [int] -and $integration -isnot [long]) {
        throw 'A required status check has an invalid integration_id; expected an integer or an absent field.'
    }
    foreach ($run in $CheckRuns) {
        if ($run['name'] -cne $Check['context']) { continue }
        if ($null -eq $integration) { return $true }
        $appId = Get-MergeGateValue -Node $run -Path 'app.id'
        if (($appId -is [int] -or $appId -is [long]) -and $appId -eq $integration) { return $true }
    }
    if ($null -eq $integration) {
        foreach ($status in $Statuses) {
            if ($status['context'] -ceq $Check['context']) { return $true }
        }
    }
    return $false
}

# security-check: merge-gate-review-threads
function Get-MergeGateThreadFinding {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]] $Threads = @())

    foreach ($thread in $Threads) {
        # Outdated threads still count: GitHub requires them resolved too.
        if ($thread['isResolved'] -ne $true) { 'fail:unresolved-threads' }
    }
}

# security-check: merge-gate-copilot-author
function Test-MergeGateCopilotReview {
    <#
    .SYNOPSIS
    True for a submitted review by the Copilot reviewer, except the notice that the review job was not started.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Review)

    if ((Get-MergeGateValue -Node $Review -Path 'author.login') -cnotin $script:CopilotLogins) { return $false }
    if ($null -eq $Review['submittedAt']) { return $false }
    if ([string] $Review['body'] -match '^\s*The job was not started') { return $false }
    return $true
}

function Test-MergeGateCopilotRequest {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $TimelineItem)

    $reviewer = Get-MergeGateValue -Node $TimelineItem -Path 'requestedReviewer'
    return $TimelineItem['__typename'] -ceq 'ReviewRequestedEvent' -and (Get-MergeGateValue -Node $reviewer -Path '__typename') -ceq 'Bot' -and
        (Get-MergeGateValue -Node $reviewer -Path 'login') -cin $script:CopilotLogins
}

function Get-MergeGateCopilotState {
    <#
    .SYNOPSIS
    Summarizes the Copilot reviews, review requests and Copilot check runs of the head.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $PullRequest,
        [AllowEmptyCollection()][object[]] $CheckRuns = @(),
        [AllowEmptyCollection()][object[]] $WorkflowRuns = @(),
        [Parameter(Mandatory)][string] $HeadSha
    )

    # A Copilot workflow run counts like its check run; a completed run has no completed_at, so updated_at stands in.
    $copilotRuns = @(@($CheckRuns | Where-Object { Test-MergeGateCopilotRun -Run $_ -Kind CheckRun }) +
        @($WorkflowRuns | Where-Object { Test-MergeGateCopilotRun -Run $_ -Kind WorkflowRun } | ForEach-Object {
                @{ name = $_['name']; status = $_['status']; completed_at = if ($_['status'] -ceq 'completed') { $_['updated_at'] } else { $null } } }))
    $reviews = @((Get-MergeGateList -Node $PullRequest -Path 'reviews.nodes') | Where-Object { Test-MergeGateCopilotReview -Review $_ } |
        Sort-Object { ConvertTo-MergeGateTime -Value $_['submittedAt'] })
    $requests = @((Get-MergeGateList -Node $PullRequest -Path 'timelineItems.nodes') | Where-Object { Test-MergeGateCopilotRequest -TimelineItem $_ } |
        ForEach-Object { ConvertTo-MergeGateTime -Value $_['createdAt'] } | Sort-Object)
    $last = if ($reviews.Count -gt 0) { $reviews[-1] } else { $null }
    $headReviews = @($reviews | Where-Object { (Get-MergeGateValue -Node $_ -Path 'commit.oid') -ceq $HeadSha })
    $overview = $null
    if ($headReviews.Count -gt 0) {
        $line = [regex]::Match([string] $headReviews[-1]['body'], '(?m)^###[^\r\n]*(Approval recommended|Needs a closer look|Changes recommended)[^\r\n]*')
        if ($line.Success) { $overview = $line.Value.Trim() }
    }
    return @{
        Rounds = $reviews.Count
        LastReviewAt = if ($last) { ConvertTo-MergeGateTime -Value $last['submittedAt'] } else { $null }
        LastReviewSha = if ($last) { Get-MergeGateValue -Node $last -Path 'commit.oid' } else { $null }
        LastRequestAt = if ($requests.Count -gt 0) { $requests[-1] } else { $null }
        ReviewedHead = $headReviews.Count -gt 0
        CheckRuns = $copilotRuns
        HeadOverview = $overview
    }
}

# security-check: merge-gate-copilot-review
function Get-MergeGateCopilotFinding {
    <#
    .SYNOPSIS
    G6: pending while a Copilot review is requested, running or recently finished without a review of the head;
    a failure when no Copilot review exists at all or, with RequireOnHead, when the head has no Copilot review.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable] $Copilot,
        [Parameter(Mandatory)][DateTimeOffset] $Now,
        [int] $PostGraceMinutes = 45,
        [bool] $RequireReview = $true,
        [switch] $RequireOnHead
    )

    if ($null -ne $Copilot.LastRequestAt -and -not ($Copilot.LastReviewAt -ge $Copilot.LastRequestAt)) { 'pending:copilot-review-in-progress' }
    foreach ($run in $Copilot.CheckRuns) {
        $completedAt = ConvertTo-MergeGateTime -Value $run['completed_at']
        if ($run['status'] -cne 'completed') { 'pending:copilot-review-in-progress' }
        elseif (-not $Copilot.ReviewedHead -and ($null -eq $completedAt -or ($Now - $completedAt).TotalMinutes -lt $PostGraceMinutes)) { 'pending:copilot-review-in-progress' }
    }
    if ($RequireReview -and $Copilot.Rounds -lt 1 -and $null -eq $Copilot.LastRequestAt) { 'fail:copilot-review-missing' }
    if ($RequireOnHead -and -not $Copilot.ReviewedHead) { 'fail:copilot-review-stale' }
}

# security-check: merge-gate-mergeability
function Get-MergeGateMergeFinding {
    <#
    .SYNOPSIS
    G7: a conflict fails, an unknown mergeability is pending and BLOCKED fails when no other check explains it.
    A merge queue fails: gh pr merge would only queue the pull request, and the queue would merge it later without the gate.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $PullRequest,
        [bool] $OtherFindings,
        [bool] $MergeQueue
    )

    if ($MergeQueue) { 'fail:merge-queue-unsupported' }
    $mergeable = $PullRequest['mergeable']
    $status = $PullRequest['mergeStateStatus']
    if ($mergeable -ceq 'CONFLICTING' -or $status -ceq 'DIRTY') { 'fail:conflict' }
    elseif ($mergeable -ceq 'UNKNOWN' -or $status -ceq 'UNKNOWN') { 'pending:mergeability-unknown' }
    elseif ($mergeable -cne 'MERGEABLE') { 'fail:mergeability-unrecognized' }
    elseif ($status -ceq 'BLOCKED') {
        if (-not $OtherFindings) { 'fail:blocked-by-rules' }
    }
    # DRAFT is deprecated; for a draft, G2 already fails.
    elseif ($status -cnotin @('CLEAN', 'HAS_HOOKS', 'BEHIND', 'UNSTABLE') -and -not ($status -ceq 'DRAFT' -and $PullRequest['isDraft'] -eq $true)) { 'fail:mergeability-unrecognized' }
}

# security-check: merge-gate-behind-base
function Get-MergeGateBaseFinding {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][long] $BehindBy,
        [switch] $RequireUpToDate,
        [bool] $StrictPolicy
    )

    if ($BehindBy -gt 0 -and ($RequireUpToDate -or $StrictPolicy)) { 'fail:behind-base' }
}

# security-check: merge-gate-empty-section
function Test-MergeGateEmptySection {
    <#
    .SYNOPSIS
    True when a section says that it has nothing: empty, the Czech word for none, "None" or "-" (comments, list marker and final period ignored).
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string] $Content)

    $text = ($Content -replace '(?s)<!--.*?-->', '').Trim()
    $text = ($text -replace '^[-*+]\s+', '' -replace '\.$', '').Trim()
    return $text -match '^(\u017D\u00E1dn\u00E9|None|-)?$'
}

function Get-MergeGateSection {
    # Returns the content of every heading that matches the pattern, up to the next heading of the same or a higher level.
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Body, [Parameter(Mandatory)][string] $Pattern)

    foreach ($heading in [regex]::Matches($Body, $Pattern)) {
        $start = $heading.Index + $heading.Length
        $level = $heading.Value.Length - $heading.Value.TrimStart('#').Length
        $next = [regex]::Match($Body.Substring($start), "(?m)^#{1,$level}[ \t]")
        if ($next.Success) { $Body.Substring($start, $next.Index) } else { $Body.Substring($start) }
    }
}

# security-check: merge-gate-open-questions
function Get-MergeGateBodyFinding {
    <#
    .SYNOPSIS
    G9: open questions for the user stop the merge.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyString()][string] $Body)

    foreach ($content in @(Get-MergeGateSection -Body $Body -Pattern $script:OpenQuestionsHeading)) {
        if (-not (Test-MergeGateEmptySection -Content $content)) { 'fail:open-questions' }
    }
    foreach ($marker in [regex]::Matches($Body, $script:OpenQuestionsMarker)) {
        if ([long] $marker.Groups['count'].Value -gt 0) { 'fail:open-questions' }
    }
}

function Test-MergeGateDecisionsUnconfirmed {
    # Unverified acceptance remains a warning, not a blocking finding.
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string] $Body, [bool] $Verified = $false)

    return $Body -match $script:DecisionsHeading -and -not $Verified
}

# security-check: merge-gate-decision-authors
function Assert-MergeGateDecisionAuthor {
    <#
    .SYNOPSIS
    Proves marker provenance only when the PR author and every editor have the marker login.
    UserContentEdit.diff has no documented representation, so it is not used as a body snapshot or patch.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()] $PullRequest,
        [Parameter(Mandatory)][string] $HeadSha,
        [AllowEmptyString()][string] $Body
    )

    $markers = [regex]::Matches($Body, $script:DecisionsAcceptedMarker)
    if ($markers.Count -ne 1) { throw 'Decision acceptance requires exactly one decisions-accepted marker.' }
    $snapshotHead = Get-MergeGateValue -Node $PullRequest -Path 'headRefOid'
    if ($snapshotHead -isnot [string] -or $snapshotHead -cne $HeadSha) { throw 'The decision history does not belong to the evaluated head.' }
    $snapshotBody = Get-MergeGateValue -Node $PullRequest -Path 'body'
    if ($snapshotBody -isnot [string] -or $snapshotBody -cne $Body) { throw 'The pull request body changed while reading decision history.' }
    $login = $markers[0].Groups['login'].Value
    $author = Get-MergeGateValue -Node $PullRequest -Path 'author.login'
    if ($author -isnot [string] -or $author -ine $login) { throw 'The pull request author does not match the decision marker login.' }
    $history = Get-MergeGateValue -Node $PullRequest -Path 'userContentEdits'
    $nodes = Get-MergeGateList -Node $history -Path 'nodes'
    $hasNext = Get-MergeGateValue -Node $history -Path 'pageInfo.hasNextPage'
    if ($hasNext -isnot [bool] -or $hasNext) { throw 'The decision edit history is incomplete or unreadable.' }
    $total = Get-MergeGateValue -Node $history -Path 'totalCount'
    if (($total -isnot [int] -and $total -isnot [long]) -or $total -ne $nodes.Count) { throw 'The decision edit history count does not match the returned edits.' }
    foreach ($edit in $nodes) {
        if ($edit -isnot [System.Collections.IDictionary] -or -not $edit.Contains('deletedAt') -or $null -ne $edit['deletedAt']) {
            throw 'The decision edit history contains a redacted or unreadable edit.'
        }
        $editor = Get-MergeGateValue -Node $edit -Path 'editor.login'
        if ($editor -isnot [string] -or $editor -ine $login) { throw 'A decision edit author does not match the decision marker login.' }
    }
    return [ordered]@{ login = $login; date = $markers[0].Groups['date'].Value }
}

# security-check: merge-gate-workflow-path
function Test-MergeGateWorkflowPath {
    [CmdletBinding()]
    [OutputType([bool])]
    param([AllowEmptyString()][string] $Path)

    return $Path -match '^\.github/(workflows|actions)/'
}

# security-check: merge-gate-workflow-lines
function Get-MergeGateSensitiveLine {
    <#
    .SYNOPSIS
    Returns the added or removed lines of a workflow or action change that touch permissions, triggers, secrets or runners.
    A file without a patch (too large, binary or renamed without changes) cannot be checked and is reported.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $File)

    # A copy, or a rename other than between two workflow files, can activate content that the patch does not show.
    $direct = '^\.github/workflows/[^/]+\.ya?ml$'
    if ($File['status'] -ceq 'copied' -or
        ($File['status'] -ceq 'renamed' -and -not ([string] $File['previous_filename'] -match $direct -and [string] $File['filename'] -match $direct))) {
        "$($File['filename']): $($File['status']) from $($File['previous_filename'])"
    }
    $patch = $File['patch']
    if ($patch -isnot [string] -or $patch -eq '') {
        "$($File['filename']): patch unavailable"
        return
    }
    foreach ($line in ($patch -split '\r?\n')) {
        if ($line -match '^[+-]' -and $line -match $script:SensitivePattern) { "$($File['filename']): $line" }
    }
}

# security-check: merge-gate-workflow-changes
function Get-MergeGateWorkflowFinding {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [AllowEmptyCollection()][string[]] $SensitiveLines = @(),
        [Parameter(Mandatory)][string] $HeadSha,
        [AllowEmptyString()][string] $AcknowledgedSha
    )

    if ($SensitiveLines.Count -gt 0 -and $AcknowledgedSha -ne $HeadSha) { 'fail:workflow-permissions-changed' }
}

function Get-MergeGateGitHubChange {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][object[]] $Files = @())

    $workflowFiles = [System.Collections.Generic.List[string]]::new()
    $otherFiles = [System.Collections.Generic.List[string]]::new()
    $templateFiles = [System.Collections.Generic.List[string]]::new()
    $sensitive = [System.Collections.Generic.List[string]]::new()
    foreach ($file in $Files) {
        if ($file -isnot [System.Collections.IDictionary] -or $file['filename'] -isnot [string] -or $file['filename'] -eq '') { throw 'A changed file has no filename.' }
        $name = [string] $file['filename']
        $paths = @(@($name, $file['previous_filename']) | Where-Object { $_ -is [string] -and $_ -ne '' })
        if (@($paths | Where-Object { Test-MergeGateWorkflowPath -Path $_ }).Count -gt 0) {
            $workflowFiles.Add($name)
            foreach ($line in @(Get-MergeGateSensitiveLine -File $file)) { $sensitive.Add($line) }
        }
        elseif (@($paths | Where-Object { $_ -match '^\.github/' }).Count -gt 0) { $otherFiles.Add($name) }
        if (@($paths | Where-Object { $_ -match '^templates/(.+/)?\.github/workflows/' }).Count -gt 0) { $templateFiles.Add($name) }
    }
    return @{
        WorkflowFiles = $workflowFiles.ToArray()
        OtherGitHubFiles = $otherFiles.ToArray()
        TemplateWorkflowFiles = $templateFiles.ToArray()
        SensitiveLines = $sensitive.ToArray()
    }
}

function Get-MergeGateRuleSummary {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([AllowEmptyCollection()][object[]] $Rules = @())

    $contexts = [System.Collections.Generic.List[string]]::new()
    $checks = [System.Collections.Generic.List[object]]::new()
    $strict = $false
    $reviewOnPush = $null
    $threadResolution = $null
    $mergeQueue = $false
    foreach ($rule in $Rules) {
        if ($rule -isnot [System.Collections.IDictionary] -or $rule['type'] -isnot [string]) { throw 'A branch rule has no type.' }
        switch -CaseSensitive ($rule['type']) {
            'required_status_checks' {
                foreach ($check in (Get-MergeGateList -Node $rule -Path 'parameters.required_status_checks')) {
                    $context = Get-MergeGateValue -Node $check -Path 'context'
                    if ($context -isnot [string] -or $context -eq '') { throw 'A required status check has no context.' }
                    if (-not $contexts.Contains($context)) { $contexts.Add($context) }
                    $checks.Add($check)
                }
                $policy = Get-MergeGateValue -Node $rule -Path 'parameters.strict_required_status_checks_policy'
                if ($policy -isnot [bool]) { throw 'A required status checks rule has no strict_required_status_checks_policy.' }
                if ($policy) { $strict = $true }
            }
            'copilot_code_review' { $reviewOnPush = (Get-MergeGateValue -Node $rule -Path 'parameters.review_on_push') -eq $true }
            'pull_request' { $threadResolution = (Get-MergeGateValue -Node $rule -Path 'parameters.required_review_thread_resolution') -eq $true }
            'merge_queue' { $mergeQueue = $true }
        }
    }
    return @{ RequiredContexts = $contexts.ToArray(); RequiredChecks = $checks.ToArray(); Strict = $strict; CopilotReviewOnPush = $reviewOnPush; ThreadResolutionRequired = $threadResolution; MergeQueue = $mergeQueue }
}

# security-check: merge-gate-verdict
function Get-MergeGateVerdict {
    [CmdletBinding()]
    [OutputType([string])]
    param([AllowEmptyCollection()][object[]] $Reasons = @())

    if (@($Reasons | Where-Object { $_.status -cne 'pending' }).Count -gt 0) { return 'fail' }
    if (@($Reasons | Where-Object { $_.status -ceq 'pending' }).Count -gt 0) { return 'pending' }
    return 'pass'
}

function Get-MergeGateMessage {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Code, [AllowEmptyCollection()][string[]] $Subjects = @())

    $list = if ($Subjects.Count -gt 0) { ": $($Subjects -join ', ')" } else { '' }
    switch -CaseSensitive ($Code) {
        'pr-closed' { return 'The pull request is closed without merge.' }
        'not-merged' { return 'The pull request was reported as merged, but it is not merged.' }
        'pr-state-unknown' { return 'The pull request state is not OPEN, CLOSED or MERGED.' }
        'draft' { return 'The pull request is a draft. Mark it ready in a separate step and wait for the Copilot review it triggers.' }
        'head-moved' { return 'The head of the pull request differs from the expected head SHA.' }
        'check-failed' { return "Checks failed on the head$list." }
        'checks-pending' { return "Checks are still running on the head$list." }
        'required-check-missing' { return "Expected workflows or required checks have not reported on the head$list." }
        'unresolved-threads' { return 'Review threads are unresolved.' }
        'copilot-review-in-progress' { return 'A Copilot review is requested or running for the head.' }
        'copilot-review-missing' { return 'The pull request has no Copilot review and none is requested.' }
        'copilot-review-stale' { return 'The latest Copilot review is not on the head.' }
        'conflict' { return 'The pull request has merge conflicts.' }
        'merge-queue-unsupported' { return 'The base branch requires a merge queue; the gate supports only a direct squash merge pinned to the evaluated head.' }
        'mergeability-unknown' { return 'GitHub has not computed the mergeability yet.' }
        'mergeability-unrecognized' { return 'GitHub reports an unrecognized mergeability state.' }
        'blocked-by-rules' { return 'Branch rules block the merge although all gate checks pass. Fix the rules; never use --admin.' }
        'behind-base' { return 'The head is behind the base branch.' }
        'open-questions' { return 'The pull request body has open questions for the user.' }
        'workflow-permissions-changed' { return 'Workflow or action changes touch permissions, triggers, secrets or runners and need a human acknowledgement for the head SHA.' }
    }
    return $Code
}

function ConvertTo-MergeGateReason {
    <#
    .SYNOPSIS
    Groups findings 'status:code[:subject]' of one check into reasons with a message and evidence.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $Check,
        [AllowEmptyCollection()][string[]] $Finding = @(),
        [System.Collections.IDictionary] $Evidence = @{}
    )

    $groups = [ordered]@{}
    foreach ($item in $Finding) {
        $parts = $item.Split(':', 3)
        if ($parts.Count -lt 2 -or $parts[0] -notin @('fail', 'pending')) { throw "Unexpected finding '$item'." }
        $key = "$($parts[0]):$($parts[1])"
        if (-not $groups.Contains($key)) { $groups[$key] = [System.Collections.Generic.List[string]]::new() }
        if ($parts.Count -eq 3 -and -not $groups[$key].Contains($parts[2])) { $groups[$key].Add($parts[2]) }
    }
    foreach ($key in $groups.Keys) {
        $status, $code = $key.Split(':', 2)
        $reason = [ordered]@{
            check = $Check
            status = $status
            code = $code
            message = Get-MergeGateMessage -Code $code -Subjects $groups[$key].ToArray()
        }
        $details = [ordered]@{}
        if ($groups[$key].Count -gt 0) { $details['subjects'] = $groups[$key].ToArray() }
        if ($Evidence.Contains($code)) { foreach ($name in $Evidence[$code].Keys) { $details[$name] = $Evidence[$code][$name] } }
        if ($details.Count -gt 0) { $reason['evidence'] = $details }
        [pscustomobject] $reason
    }
}

function Get-MergeGateEmptyResult {
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [AllowNull()][hashtable] $Target,
        [int] $Number,
        [Parameter(Mandatory)][DateTimeOffset] $Now,
        [AllowEmptyString()][string] $ExpectedHeadSha
    )

    return [ordered]@{
        schemaVersion = 1
        gateVersion = $script:GateVersion
        repository = if ($Target) { $Target.Slug } else { $null }
        host = if ($Target) { $Target.Host } else { $null }
        pr = $Number
        evaluatedAt = Format-MergeGateTime -Value $Now
        verdict = 'fail'
        headSha = $null
        expectedHeadSha = if ($ExpectedHeadSha) { $ExpectedHeadSha } else { $null }
        reasons = @()
        warnings = @()
        details = [ordered]@{}
        exitCode = 1
    }
}

function Invoke-MergeGate {
    <#
    .SYNOPSIS
    Evaluates the merge gate G1-G11 for one pull request with read-only API calls.
    .OUTPUTS
    An ordered dictionary in the JSON schema of the gate; exitCode holds the process exit code (0-5) and is not
    part of the JSON output.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Repository,
        [Parameter(Mandatory)][int] $Pr,
        [AllowEmptyString()][string] $ExpectedHeadSha,
        [AllowEmptyString()][string] $AcknowledgeWorkflowChanges,
        [switch] $ExpectMerged,
        [int] $CopilotRoundCap = 2,
        [bool] $RequireCopilotReview = $true,
        [switch] $RequireCopilotOnHead,
        [switch] $RequireUpToDate,
        [AllowEmptyCollection()][string[]] $ExpectedWorkflows = @('Source CI'),
        [int] $MissingCheckGraceMinutes = 15,
        [int] $CopilotPostGraceMinutes = 45,
        [AllowNull()] $Now
    )

    $clock = if ($null -ne $Now) { ConvertTo-MergeGateTime -Value $Now } else { [DateTimeOffset]::UtcNow }
    $target = $null
    try {
        $target = ConvertTo-MergeGateTarget -Repository $Repository
        if ($Pr -lt 1) { throw [MergeGateInputError]::new("Pr $Pr must be a positive pull request number.") }
        $expected = ConvertTo-MergeGateSha -Value $ExpectedHeadSha -Parameter 'ExpectedHeadSha'
        $acknowledged = ConvertTo-MergeGateSha -Value $AcknowledgeWorkflowChanges -Parameter 'AcknowledgeWorkflowChanges'
    }
    catch [MergeGateInputError] {
        $result = Get-MergeGateEmptyResult -Target $target -Number $Pr -Now $clock -ExpectedHeadSha ''
        $result.reasons = @([pscustomobject][ordered]@{ check = 'input'; status = 'fail'; code = 'invalid-input'; message = $_.Exception.Message })
        $result.exitCode = 4
        return $result
    }

    $result = Get-MergeGateEmptyResult -Target $target -Number $Pr -Now $clock -ExpectedHeadSha $expected
    try {
        $evaluation = @{
            Result = $result; Target = $target; Number = $Pr; ExpectedHeadSha = $expected; AcknowledgedSha = $acknowledged
            ExpectMerged = $ExpectMerged; CopilotRoundCap = $CopilotRoundCap; RequireCopilotReview = $RequireCopilotReview
            RequireCopilotOnHead = $RequireCopilotOnHead; RequireUpToDate = $RequireUpToDate; ExpectedWorkflows = $ExpectedWorkflows
            MissingCheckGraceMinutes = $MissingCheckGraceMinutes; CopilotPostGraceMinutes = $CopilotPostGraceMinutes; Now = $clock
        }
        Complete-MergeGateEvaluation @evaluation
    }
    catch {
        # Fail closed: an API, authentication, pagination or parse error never yields pass.
        $result.verdict = 'fail'
        $result.reasons = @([pscustomobject][ordered]@{ check = 'evaluation'; status = 'fail'; code = 'evaluation-error'; message = $_.Exception.Message })
        $result.exitCode = 5
    }
    return $result
}

function Complete-MergeGateEvaluation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary] $Result,
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][int] $Number,
        [AllowEmptyString()][string] $ExpectedHeadSha,
        [AllowEmptyString()][string] $AcknowledgedSha,
        [switch] $ExpectMerged,
        [int] $CopilotRoundCap,
        [bool] $RequireCopilotReview,
        [switch] $RequireCopilotOnHead,
        [switch] $RequireUpToDate,
        [AllowEmptyCollection()][string[]] $ExpectedWorkflows = @(),
        [int] $MissingCheckGraceMinutes,
        [int] $CopilotPostGraceMinutes,
        [Parameter(Mandatory)][DateTimeOffset] $Now
    )

    $warnings = [System.Collections.Generic.List[object]]::new()
    $reasons = [System.Collections.Generic.List[object]]::new()
    $pullRequest = Get-MergeGatePullRequest -Target $Target -Number $Number
    if ($pullRequest['headRefOid'] -isnot [string] -or $pullRequest['headRefOid'] -cnotmatch '^[0-9a-f]{40}$') { throw 'The pull request has no valid head SHA.' }
    $head = [string] $pullRequest['headRefOid']
    $Result.headSha = $head
    $Result.details['state'] = [ordered]@{
        state = $pullRequest['state']
        isDraft = $pullRequest['isDraft']
        mergedAt = Format-MergeGateTime -Value $pullRequest['mergedAt']
        mergeCommit = Get-MergeGateValue -Node $pullRequest -Path 'mergeCommit.oid'
        mergedBy = Get-MergeGateValue -Node $pullRequest -Path 'mergedBy.login'
    }

    # G1: a merged pull request ends the evaluation.
    $stateFinding = @(Get-MergeGateStateFinding -PullRequest $pullRequest -ExpectMerged:$ExpectMerged)
    if ($stateFinding -ccontains 'already-merged') {
        if ($ExpectedHeadSha -and $head -ne $ExpectedHeadSha) {
            $warnings.Add([pscustomobject][ordered]@{ check = 'pr-state'; code = 'merged-head-differs'; message = "The merged head $head differs from the expected head $ExpectedHeadSha." })
        }
        $Result.verdict = 'already-merged'
        $Result.warnings = $warnings.ToArray()
        $Result.exitCode = 3
        return
    }
    Assert-MergeGatePullRequestShape -PullRequest $pullRequest
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'pr-state' -Finding $stateFinding)) { $reasons.Add($reason) }

    # G2, G3
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'draft' -Finding @(Get-MergeGateDraftFinding -PullRequest $pullRequest))) { $reasons.Add($reason) }
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'head-pin' -Finding @(Get-MergeGateHeadFinding -HeadSha $head -ExpectedHeadSha $ExpectedHeadSha))) { $reasons.Add($reason) }

    # G4 and G11 sources.
    $slug = $Target.Slug
    $baseRef = [string] $pullRequest['baseRefName']
    $rules = Get-MergeGateRestList -Target $Target -Path "repos/$slug/rules/branches/$([uri]::EscapeDataString($baseRef))"
    $ruleSummary = Get-MergeGateRuleSummary -Rules $rules
    $workflowRuns = Get-MergeGateRestList -Target $Target -Path "repos/$slug/actions/runs?head_sha=$head" -Property 'workflow_runs'
    $checkRuns = Get-MergeGateRestList -Target $Target -Path "repos/$slug/commits/$head/check-runs?filter=latest" -Property 'check_runs'
    $statuses = Get-MergeGateRestList -Target $Target -Path "repos/$slug/commits/$head/status" -Property 'statuses'
    foreach ($item in @($workflowRuns) + @($checkRuns)) {
        if ($item -isnot [System.Collections.IDictionary] -or $item['head_sha'] -cne $head) { throw 'A workflow run or check run does not belong to the evaluated head.' }
    }
    $pushedTimes = @(@((Get-MergeGateList -Node $pullRequest -Path 'commits.nodes') | ForEach-Object { Get-MergeGateValue -Node $_ -Path 'commit.committedDate' }) +
        @((Get-MergeGateList -Node $pullRequest -Path 'timelineItems.nodes') | Where-Object { $_['__typename'] -ceq 'HeadRefForcePushedEvent' } | ForEach-Object { $_['createdAt'] }) |
        Where-Object { $null -ne $_ } | ForEach-Object { ConvertTo-MergeGateTime -Value $_ } | Sort-Object)
    $pushedAt = if ($pushedTimes.Count -gt 0) { $pushedTimes[-1] } else { $null }
    $checkFinding = @(Get-MergeGateCheckFinding -WorkflowRuns $workflowRuns -CheckRuns $checkRuns -Statuses $statuses `
            -RequiredChecks $ruleSummary.RequiredChecks -ExpectedWorkflows $ExpectedWorkflows -PushedAt $pushedAt -Now $Now -GraceMinutes $MissingCheckGraceMinutes)
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'ci-checks' -Finding $checkFinding)) { $reasons.Add($reason) }
    $missing = @($checkFinding | Where-Object { $_ -match '^(fail|pending):required-check-missing:' } | ForEach-Object { $_.Split(':', 3)[2] })
    $Result.details['checks'] = [ordered]@{
        workflowRuns = @($workflowRuns | ForEach-Object { [ordered]@{ name = $_['name']; event = $_['event']; status = $_['status']; conclusion = $_['conclusion'] } })
        checkRuns = @($checkRuns | ForEach-Object { [ordered]@{ name = $_['name']; status = $_['status']; conclusion = $_['conclusion']; completedAt = Format-MergeGateTime -Value $_['completed_at'] } })
        statuses = @($statuses | ForEach-Object { [ordered]@{ context = $_['context']; state = $_['state'] } })
        required = $ruleSummary.RequiredContexts
        expectedWorkflows = $ExpectedWorkflows
        missing = $missing
        headPushedAt = Format-MergeGateTime -Value $pushedAt
    }

    # G5
    $threads = Get-MergeGateList -Node $pullRequest -Path 'reviewThreads.nodes'
    $unresolved = @($threads | Where-Object { $_['isResolved'] -ne $true } | ForEach-Object {
            $comment = (Get-MergeGateList -Node $_ -Path 'comments.nodes') | Select-Object -First 1
            [ordered]@{ path = $_['path']; outdated = $_['isOutdated']; author = Get-MergeGateValue -Node $comment -Path 'author.login'; url = Get-MergeGateValue -Node $comment -Path 'url' }
        })
    $threadEvidence = @{ 'unresolved-threads' = @{ threads = $unresolved } }
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'review-threads' -Finding @(Get-MergeGateThreadFinding -Threads $threads) -Evidence $threadEvidence)) { $reasons.Add($reason) }
    $Result.details['threads'] = [ordered]@{ total = @($threads).Count; unresolved = $unresolved.Count; items = $unresolved }

    # G6
    $copilot = Get-MergeGateCopilotState -PullRequest $pullRequest -CheckRuns $checkRuns -WorkflowRuns $workflowRuns -HeadSha $head
    $copilotEvidence = @{
        'copilot-review-in-progress' = [ordered]@{ lastRequestAt = Format-MergeGateTime $copilot.LastRequestAt; lastReviewAt = Format-MergeGateTime $copilot.LastReviewAt; lastReviewSha = $copilot.LastReviewSha }
        'copilot-review-stale' = [ordered]@{ lastReviewSha = $copilot.LastReviewSha }
    }
    $copilotFinding = @(Get-MergeGateCopilotFinding -Copilot $copilot -Now $Now -PostGraceMinutes $CopilotPostGraceMinutes `
            -RequireReview $RequireCopilotReview -RequireOnHead:$RequireCopilotOnHead)
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'copilot-review' -Finding $copilotFinding -Evidence $copilotEvidence)) { $reasons.Add($reason) }
    if (-not $copilot.ReviewedHead -and $copilot.Rounds -gt 0 -and -not $RequireCopilotOnHead) {
        $warnings.Add([pscustomobject][ordered]@{ check = 'copilot-review'; code = 'copilot-review-stale'; message = "The latest Copilot review is on $($copilot.LastReviewSha), not on the head." })
    }
    if ($copilot.Rounds -gt $CopilotRoundCap) {
        $warnings.Add([pscustomobject][ordered]@{ check = 'copilot-review'; code = 'copilot-rounds-over-cap'; message = "$($copilot.Rounds) rounds > cap $CopilotRoundCap" })
    }
    $Result.details['copilot'] = [ordered]@{
        rounds = $copilot.Rounds; cap = $CopilotRoundCap; reviewedHead = $copilot.ReviewedHead
        inProgress = @($copilotFinding | Where-Object { $_ -ceq 'pending:copilot-review-in-progress' }).Count -gt 0
        lastReviewSha = $copilot.LastReviewSha; lastReviewAt = Format-MergeGateTime $copilot.LastReviewAt
        lastRequestAt = Format-MergeGateTime $copilot.LastRequestAt; headOverview = $copilot.HeadOverview
    }

    # G7 depends on G2-G6: BLOCKED fails on its own only when nothing else explains it.
    $other = @($reasons | Where-Object { $_.check -in @('draft', 'head-pin', 'ci-checks', 'review-threads', 'copilot-review') }).Count -gt 0
    $mergeEvidence = @{ 'blocked-by-rules' = [ordered]@{ requiredContexts = $ruleSummary.RequiredContexts; strict = $ruleSummary.Strict; threadResolutionRequired = $ruleSummary.ThreadResolutionRequired } }
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'mergeability' -Finding @(Get-MergeGateMergeFinding -PullRequest $pullRequest -OtherFindings $other -MergeQueue $ruleSummary.MergeQueue) -Evidence $mergeEvidence)) { $reasons.Add($reason) }
    $Result.details['merge'] = [ordered]@{ mergeable = $pullRequest['mergeable']; mergeStateStatus = $pullRequest['mergeStateStatus'] }

    # G8
    $baseSha = [string] $pullRequest['baseRefOid']
    $comparison = Invoke-MergeGateRest -Target $Target -Path "repos/$slug/compare/$baseSha...${head}?per_page=1"
    $behind = Get-MergeGateValue -Node $comparison -Path 'behind_by'
    $ahead = Get-MergeGateValue -Node $comparison -Path 'ahead_by'
    if (($behind -isnot [int] -and $behind -isnot [long]) -or $behind -lt 0) { throw 'The comparison with the base has no behind_by.' }
    $baseFinding = @(Get-MergeGateBaseFinding -BehindBy $behind -RequireUpToDate:$RequireUpToDate -StrictPolicy $ruleSummary.Strict)
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'behind-base' -Finding $baseFinding -Evidence @{ 'behind-base' = @{ behindBy = $behind } })) { $reasons.Add($reason) }
    if ($behind -gt 0 -and $baseFinding.Count -eq 0) {
        $warnings.Add([pscustomobject][ordered]@{ check = 'behind-base'; code = 'behind-base'; message = "The head is $behind commits behind $baseRef." })
    }
    $Result.details['base'] = [ordered]@{ baseRef = $baseRef; baseSha = $baseSha; behindBy = $behind; aheadBy = $ahead }

    # G9
    $body = [string] $pullRequest['body']
    $bodyFinding = @(Get-MergeGateBodyFinding -Body $body)
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'open-questions' -Finding $bodyFinding)) { $reasons.Add($reason) }
    $accepted = $null
    $acceptanceError = $null
    if ($body -match $script:DecisionsHeading -and $body -cmatch $script:DecisionsAcceptedMarker) {
        try {
            $decisionData = Invoke-MergeGateGraphQL -Target $Target -Query $script:DecisionAuthorsQuery -Variables ([ordered]@{
                    owner = $Target.Owner; name = $Target.Name; number = $Number })
            $accepted = Assert-MergeGateDecisionAuthor -PullRequest (Get-MergeGateValue -Node $decisionData -Path 'repository.pullRequest') -HeadSha $head -Body $body
        }
        catch {
            # G9 deliberately warns on unreadable provenance, including API errors; it must never confirm the marker.
            $acceptanceError = $_.Exception.Message
        }
    }
    if (Test-MergeGateDecisionsUnconfirmed -Body $body -Verified ($null -ne $accepted)) {
        $warnings.Add([pscustomobject][ordered]@{
                check = 'open-questions'; code = 'decisions-unconfirmed'
                message = 'The pull request body has decisions for the user without a verified decisions-accepted marker.'
                evidence = [ordered]@{ error = $acceptanceError }
            })
    }
    $decisions = [regex]::Match($body, $script:DecisionsHeading)
    $Result.details['body'] = [ordered]@{
        openQuestions = @($bodyFinding | Where-Object { $_ -ceq 'fail:open-questions' }).Count -gt 0
        decisionsSection = if ($decisions.Success) { $decisions.Groups[1].Value } else { $null }
        decisionsAccepted = $accepted
    }

    # G10
    $files = Get-MergeGateRestList -Target $Target -Path "repos/$slug/pulls/$Number/files" -MaxPages $script:MaxFilePages
    $change = Get-MergeGateGitHubChange -Files $files
    $workflowEvidence = @{ 'workflow-permissions-changed' = [ordered]@{ sensitiveLines = $change.SensitiveLines; acknowledgedFor = if ($AcknowledgedSha) { $AcknowledgedSha } else { $null } } }
    $workflowFinding = @(Get-MergeGateWorkflowFinding -SensitiveLines $change.SensitiveLines -HeadSha $head -AcknowledgedSha $AcknowledgedSha)
    foreach ($reason in @(ConvertTo-MergeGateReason -Check 'github-changes' -Finding $workflowFinding -Evidence $workflowEvidence)) { $reasons.Add($reason) }
    if ($change.OtherGitHubFiles.Count -gt 0) {
        $warnings.Add([pscustomobject][ordered]@{ check = 'github-changes'; code = 'github-dir-changed'; message = "Other .github files changed: $($change.OtherGitHubFiles -join ', ')" })
    }
    $Result.details['github'] = [ordered]@{
        workflowFiles = $change.WorkflowFiles; sensitiveLines = $change.SensitiveLines
        acknowledgedFor = if ($AcknowledgedSha) { $AcknowledgedSha } else { $null }
        otherGithubFiles = $change.OtherGitHubFiles; templateWorkflowFiles = $change.TemplateWorkflowFiles
    }

    # G11 (information only)
    $Result.details['rules'] = [ordered]@{
        copilotReviewOnPush = $ruleSummary.CopilotReviewOnPush
        threadResolutionRequired = $ruleSummary.ThreadResolutionRequired
        strictRequiredStatusChecks = $ruleSummary.Strict
        mergeQueue = $ruleSummary.MergeQueue
        requiredContexts = $ruleSummary.RequiredContexts
    }

    $ordered = @(foreach ($check in $script:CheckOrder) { $reasons | Where-Object { $_.check -ceq $check } })
    $Result.reasons = $ordered
    $Result.warnings = $warnings.ToArray()
    $Result.verdict = Get-MergeGateVerdict -Reasons $ordered
    $Result.exitCode = $script:ExitCodes[$Result.verdict]
}

function ConvertTo-MergeGateOutput {
    # Removes the process exit code, which the scripts return instead of printing.
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Result)

    $copy = [ordered]@{}
    foreach ($key in $Result.Keys) { if ($key -ne 'exitCode') { $copy[$key] = $Result[$key] } }
    return $copy
}

function ConvertTo-MergeGateJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Result)

    return ConvertTo-Json -InputObject (ConvertTo-MergeGateOutput -Result $Result) -Depth 20
}

function Wait-MergeGateInterval {
    [CmdletBinding()]
    param([Parameter(Mandatory)][int] $Seconds)

    Start-Sleep -Seconds $Seconds
}

function Get-MergeGateClock {
    [CmdletBinding()]
    [OutputType([DateTimeOffset])]
    param()

    return [DateTimeOffset]::UtcNow
}

# security-check: merge-gate-merge-allowed
function Test-MergeGateMergeAllowed {
    <#
    .SYNOPSIS
    True only for a fresh pass verdict on the expected head.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Gate,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedHeadSha
    )

    return $Gate['verdict'] -ceq 'pass' -and $Gate['exitCode'] -eq 0 -and $Gate['headSha'] -ceq $ExpectedHeadSha
}

# security-check: merge-gate-post-merge
function Test-MergeGatePostMerge {
    <#
    .SYNOPSIS
    True when the pull request is merged and the rule suite of the merge commit passed without bypass.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][System.Collections.IDictionary] $State,
        [AllowNull()][System.Collections.IDictionary] $Suite,
        # The base branch the gate evaluated; a pull request retargeted before the merge fails the verification.
        [AllowEmptyString()][string] $BaseRef
    )

    if ($null -eq $State -or $null -eq $Suite) { return $false }
    if ($BaseRef -and $State['baseRefName'] -cne $BaseRef) { return $false }
    return $State['state'] -ceq 'MERGED' -and $State['merged'] -eq $true -and $Suite['result'] -ceq 'pass' -and
        $Suite['after_sha'] -ceq (Get-MergeGateValue -Node $State -Path 'mergeCommit.oid')
}

function Get-MergeGatePostMerge {
    <#
    .SYNOPSIS
    Reads the merge state and the rule suite of the merge commit. Rule suites appear with a delay, so it retries.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][int] $Number,
        [ValidateSet('hour', 'day', 'week', 'month')][string] $TimePeriod = 'hour',
        [AllowEmptyString()][string] $BaseRef,
        [int] $Attempts = 4,
        [int] $DelaySeconds = 15
    )

    $state = $null
    $suite = $null
    $errorMessage = $null
    try {
        $data = Invoke-MergeGateGraphQL -Target $Target -Query $script:MergeStateQuery -Variables ([ordered]@{ owner = $Target.Owner; name = $Target.Name; number = $Number })
        $state = Get-MergeGateValue -Node $data -Path 'repository.pullRequest'
        $mergeCommit = Get-MergeGateValue -Node $state -Path 'mergeCommit.oid'
        if ($state -is [System.Collections.IDictionary] -and $mergeCommit -is [string] -and $mergeCommit -ne '') {
            $ref = [uri]::EscapeDataString("refs/heads/$($state['baseRefName'])")
            for ($attempt = 1; $attempt -le $Attempts -and $null -eq $suite; $attempt++) {
                if ($attempt -gt 1) { Wait-MergeGateInterval -Seconds $DelaySeconds }
                $suites = Get-MergeGateRestList -Target $Target -Path "repos/$($Target.Slug)/rulesets/rule-suites?ref=$ref&time_period=$TimePeriod"
                $suite = $suites | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['after_sha'] -ceq $mergeCommit } | Select-Object -First 1
            }
        }
    }
    catch { $errorMessage = $_.Exception.Message }
    $verified = $null -eq $errorMessage -and (Test-MergeGatePostMerge -State $state -Suite $suite -BaseRef $BaseRef)
    return [ordered]@{
        verified = $verified
        state = Get-MergeGateValue -Node $state -Path 'state'
        mergeCommit = Get-MergeGateValue -Node $state -Path 'mergeCommit.oid'
        mergedBy = Get-MergeGateValue -Node $state -Path 'mergedBy.login'
        ruleSuiteResult = if ($suite) { $suite['result'] } else { 'not-found' }
        error = $errorMessage
    }
}

function Invoke-MergeGatePullRequestMerge {
    <#
    .SYNOPSIS
    The only write of the merge gate: a squash merge pinned to the evaluated head. Never --admin, --auto, --merge or --rebase.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][int] $Number,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $HeadSha
    )

    $arguments = [System.Collections.Generic.List[string]]::new()
    $arguments.AddRange([string[]] @('pr', 'merge', [string] $Number, '--repo', $Target.Repository, '--squash', '--match-head-commit', $HeadSha))
    if ($PSCmdlet.ShouldProcess("$($Target.Repository)#$Number", "squash merge at $HeadSha")) {
        $null = Invoke-MergeGateGh -Target $Target -Arguments $arguments.ToArray()
    }
}

function Complete-MergeGateAlreadyMerged {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.Specialized.OrderedDictionary] $Output,
        [Parameter(Mandatory)][hashtable] $Target,
        [Parameter(Mandatory)][int] $Number,
        # The base branch evaluated before a merge attempt; empty when the pull request was already merged before.
        [AllowEmptyString()][string] $BaseRef
    )

    $Output['reason'] = 'already-merged'
    $Output['postVerify'] = Get-MergeGatePostMerge -Target $Target -Number $Number -TimePeriod 'day' -BaseRef $BaseRef
    $Output['mergeCommit'] = $Output['postVerify']['mergeCommit']
    $Output['mergedBy'] = $Output['postVerify']['mergedBy']
    # A merge that bypassed the rules, or whose rule suite cannot be found, is not a verified outcome.
    $Output['exitCode'] = if ($Output['postVerify']['verified']) { 3 } else { 5 }
    return $Output
}

function Invoke-GatedMerge {
    <#
    .SYNOPSIS
    Evaluates the merge gate again and squash-merges the pull request only on pass, pinned to the evaluated head.
    .OUTPUTS
    An ordered dictionary with action (merged or none), the gate result, the post-merge verification and exitCode.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Repository,
        [Parameter(Mandatory)][int] $Pr,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ExpectedHeadSha,
        # The user consent or mandate behind the merge; it goes only into the output.
        [Parameter(Mandatory)][AllowEmptyString()][string] $Reason,
        [AllowEmptyString()][string] $AcknowledgeWorkflowChanges,
        [ValidateRange(0, 240)][int] $WaitPendingMinutes = 0,
        [AllowNull()] $Now
    )

    $output = [ordered]@{ action = 'none'; reason = $null; consent = $Reason; gate = $null; postVerify = $null; exitCode = 1 }
    if ([string]::IsNullOrWhiteSpace($Reason) -or [string]::IsNullOrWhiteSpace($ExpectedHeadSha)) {
        $output['reason'] = 'invalid-input'
        $output['gate'] = [ordered]@{ verdict = 'fail'; reasons = @([ordered]@{ check = 'input'; status = 'fail'; code = 'invalid-input'; message = 'ExpectedHeadSha and Reason are required.' }) }
        $output['exitCode'] = 4
        return $output
    }
    $gateParameters = @{ Repository = $Repository; Pr = $Pr; ExpectedHeadSha = $ExpectedHeadSha; AcknowledgeWorkflowChanges = $AcknowledgeWorkflowChanges; Now = $Now }

    # Always a fresh evaluation: an earlier result is never reused.
    $gate = Invoke-MergeGate @gateParameters
    $deadline = (Get-MergeGateClock).AddMinutes($WaitPendingMinutes)
    while ($gate['verdict'] -ceq 'pending' -and (Get-MergeGateClock) -lt $deadline) {
        Wait-MergeGateInterval -Seconds 60
        $gate = Invoke-MergeGate @gateParameters
    }
    $output['gate'] = ConvertTo-MergeGateOutput -Result $gate
    if ($gate['exitCode'] -eq 4) {
        $output['reason'] = 'invalid-input'
        $output['exitCode'] = 4
        return $output
    }
    $target = ConvertTo-MergeGateTarget -Repository $Repository

    if ($gate['verdict'] -ceq 'already-merged') { return Complete-MergeGateAlreadyMerged -Output $output -Target $target -Number $Pr }
    if (-not (Test-MergeGateMergeAllowed -Gate $gate -ExpectedHeadSha ([string] $gate['expectedHeadSha']))) {
        $output['reason'] = "gate-$($gate['verdict'])"
        $output['exitCode'] = $gate['exitCode']
        return $output
    }

    # The base the gate evaluated; recovery after a lost merge response verifies against it too.
    $evaluatedBase = [string] $gate['details']['base']['baseRef']
    try {
        Invoke-MergeGatePullRequestMerge -Target $target -Number $Pr -HeadSha $gate['headSha']
    }
    catch {
        # No retry with other flags: evaluate once more and report that verdict.
        $mergeError = $_.Exception.Message
        $gate = Invoke-MergeGate @gateParameters
        $output['gate'] = ConvertTo-MergeGateOutput -Result $gate
        if ($gate['verdict'] -ceq 'already-merged') { return Complete-MergeGateAlreadyMerged -Output $output -Target $target -Number $Pr -BaseRef $evaluatedBase }
        $output['reason'] = "merge-refused: $mergeError"
        $output['exitCode'] = if ($gate['exitCode'] -eq 0) { 1 } else { $gate['exitCode'] }
        return $output
    }

    $output['action'] = 'merged'
    $output['postVerify'] = Get-MergeGatePostMerge -Target $target -Number $Pr -BaseRef $evaluatedBase
    $output['mergeCommit'] = $output['postVerify']['mergeCommit']
    $output['exitCode'] = if ($output['postVerify']['verified']) { 0 } else { 5 }
    return $output
}

Export-ModuleMember -Function Invoke-MergeGate, Invoke-GatedMerge, ConvertTo-MergeGateJson, ConvertTo-MergeGateOutput
