#Requires -Version 7.4
Set-StrictMode -Version Latest

<#
Offline stub of the gh calls of tools/agents/MergeGate.psm1. Responses come from the shared GitHub API fixtures of
real pull requests (tools/tests/fixtures/github-api/*/...merge-gate*). Tests mock Invoke-MergeGateGh with
Invoke-MergeGateStub, so every request goes through the same argument checks as a live run.
#>

Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')

$script:Scenarios = @{
    'pr-40' = @{ Number = 40; Behind = 0; Now = '2026-10-13T16:17:19Z'; Rest = 'pr-40'; Files = 'pr-40' }
    'pr-40-ready' = @{ Number = 40; Behind = 0; Now = '2026-10-13T16:17:30Z'; Rest = 'pr-40-ready'; Files = 'pr-40' }
    'pr-48' = @{ Number = 48; Behind = 2; Now = '2026-10-20T17:59:40Z'; Rest = 'pr-48'; Files = 'pr-48' }
    'pr-52' = @{ Number = 52; Behind = 4; Now = '2026-10-20T20:23:27Z'; Rest = 'pr-52'; Files = 'pr-52'; Rules = 'merge-gate-required-check' }
    'pr-60' = @{ Number = 60; Behind = 0; Now = '2026-10-21T15:12:36Z'; Rest = 'pr-60'; Files = 'pr-60' }
    'pr-70' = @{ Number = 70; Behind = 3; Now = '2026-10-21T21:14:19Z'; Rest = 'pr-70'; Files = 'pr-70' }
    'pr-71-open-questions' = @{ Number = 71; Behind = 0; Now = '2026-10-22T06:44:42Z'; Rest = 'pr-71'; Files = 'pr-71' }
    'pr-71' = @{ Number = 71; Behind = 0; Now = '2026-10-22T06:44:42Z'; Rest = 'pr-71'; Files = 'pr-71' }
    'pr-75' = @{ Number = 75; Behind = 1; Now = '2026-10-22T06:59:20Z'; Rest = 'pr-78'; Files = 'pr-78' }
    'pr-78' = @{ Number = 78; Behind = 1; Now = '2026-10-22T10:26:36Z'; Rest = 'pr-78'; Files = 'pr-78' }
}

function Get-MergeGateScenario {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string] $Name)

    if (-not $script:Scenarios.ContainsKey($Name)) { throw "Unknown merge gate scenario '$Name'." }
    return $script:Scenarios[$Name].Clone()
}

function Initialize-MergeGateStub {
    <#
    .SYNOPSIS
    Returns the mutable state of the stub for one real pull request scenario.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string] $Scenario)

    $definition = Get-MergeGateScenario -Name $Scenario
    $rules = if ($definition.ContainsKey('Rules')) { $definition.Rules } else { 'merge-gate' }
    $graphql = Get-GitHubApiFixture -Name "graphql/pull-request-merge-gate.$Scenario"
    $pullRequest = $graphql.data.repository.pullRequest
    # Behind is the behind_by of the real pull request at the moment, from the replay of issue #85.
    $compare = Get-GitHubApiFixture -Name 'repos/compare-commits.merge-gate' -Set @{
        behind_by = $definition.Behind
        'base_commit.sha' = $pullRequest.baseRefOid
        'merge_base_commit.sha' = $pullRequest.baseRefOid
    }
    return @{
        Scenario = $Scenario
        Number = $definition.Number
        Now = $definition.Now
        PullRequest = $pullRequest
        DecisionAuthors = Get-GitHubApiFixture -Name 'graphql/pull-request-decision-authors'
        WorkflowRuns = Get-GitHubApiFixture -Name "actions/list-workflow-runs-for-repo.merge-gate-$($definition.Rest)"
        CheckRuns = Get-GitHubApiFixture -Name "checks/list-for-ref.merge-gate-$($definition.Rest)"
        Status = Get-GitHubApiFixture -Name 'repos/get-combined-status-for-ref.merge-gate' -Set @{ sha = $pullRequest.headRefOid }
        Rules = Get-GitHubApiFixture -Name "repos/get-branch-rules.$rules"
        Compare = $compare
        Files = Get-GitHubApiFixture -Name "pulls/list-files.merge-gate-$($definition.Files)"
        RuleSuites = [System.Collections.Generic.List[object]]::new()
        SuiteResult = 'pass'
        MergeCommit = '1111111111111111111111111111111111111111'
        Calls = [System.Collections.Generic.List[string[]]]::new()
        Failures = @{}
        Responses = @{}
        Contents = @{}
        Trees = @{}
        TreeRefs = @{ $pullRequest.baseRefOid = 'd' * 40; $pullRequest.headRefOid = 'e' * 40 }
        Merges = 0
    }
}

function Add-MergeGateStubRuleSuite {
    # Adds a rule suite in the shape of the shared fixture (a real rule suite of main) for the given merge commit.
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Stub,
        [Parameter(Mandatory)][string] $AfterSha,
        [Parameter(Mandatory)][string] $Result
    )

    $suites = Get-GitHubApiFixture -Name 'repos/get-repo-rule-suites.merge-gate' -Set @{ '0.after_sha' = $AfterSha; '0.result' = $Result }
    $Stub.RuleSuites.Add($suites[0])
}

function Get-MergeGateStubPage {
    param([object[]] $Items, [int] $Page)

    $start = ($Page - 1) * 100
    if ($start -ge $Items.Count) { return , @() }
    return , @($Items[$start..([Math]::Min($Items.Count, $start + 100) - 1)])
}

function Invoke-MergeGateStub {
    <#
    .SYNOPSIS
    Answers one gh call like the API would and returns the standard output text. Failures maps a request pattern to an
    error message; Responses maps a request pattern to a raw response text.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][hashtable] $Stub,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $Stub.Calls.Add($Arguments)
    $request = if ($Arguments[0] -eq 'api' -and $Arguments[1] -eq 'graphql') {
        if ($Arguments[3] -match 'userContentEdits') { 'graphql decisionAuthors' }
        elseif ($Arguments[3] -match 'reviewThreads') { 'graphql pullRequest' }
        else { 'graphql mergeState' }
    }
    elseif ($Arguments[0] -eq 'api') { "GET $($Arguments[-1])" }
    else { $Arguments -join ' ' }
    foreach ($pattern in $Stub.Failures.Keys) {
        if ($request -match $pattern) { throw "gh $($Arguments[0]) $($Arguments[1]) failed with exit code 1: $($Stub.Failures[$pattern])" }
    }
    foreach ($pattern in $Stub.Responses.Keys) {
        if ($request -match $pattern) { return $Stub.Responses[$pattern] }
    }

    $pullRequest = $Stub.PullRequest
    if ($request -ceq 'graphql decisionAuthors') {
        return ConvertTo-Json -InputObject $Stub.DecisionAuthors -Depth 50
    }
    if ($request -ceq 'graphql pullRequest') {
        return ConvertTo-Json -InputObject @{ data = @{ repository = @{ pullRequest = $pullRequest } } } -Depth 50
    }
    if ($request -ceq 'graphql mergeState') {
        $state = [ordered]@{}
        foreach ($key in @('state', 'merged', 'mergedAt', 'mergedBy', 'mergeCommit', 'headRefOid', 'baseRefName')) { $state[$key] = $pullRequest[$key] }
        return ConvertTo-Json -InputObject @{ data = @{ repository = @{ pullRequest = $state } } } -Depth 50
    }
    if ($Arguments[0] -eq 'pr' -and $Arguments[1] -eq 'merge') {
        $headIndex = [array]::IndexOf($Arguments, '--match-head-commit')
        if ($headIndex -lt 0 -or $Arguments[$headIndex + 1] -cne $pullRequest.headRefOid) { throw 'gh pr merge failed with exit code 1: Head branch was modified.' }
        if ($pullRequest.state -ne 'OPEN') { throw 'gh pr merge failed with exit code 1: Pull request is already merged.' }
        $pullRequest.state = 'MERGED'
        $pullRequest.merged = $true
        $pullRequest.mergedAt = '2026-10-22T12:00:00Z'
        $pullRequest.mergedBy = @{ login = 'msucharda' }
        $pullRequest.mergeCommit = @{ oid = $Stub.MergeCommit }
        $Stub.Merges++
        Add-MergeGateStubRuleSuite -Stub $Stub -AfterSha $Stub.MergeCommit -Result $Stub.SuiteResult
        return ''
    }

    $path = $Arguments[-1]
    $page = if ($path -match '[?&]page=(\d+)') { [int] $Matches[1] } else { 1 }
    switch -Regex ($path) {
        '/git/commits/(?<ref>[0-9a-f]{40})$' {
            $ref = $Matches['ref']
            $response = Get-GitHubApiFixture -Name 'git/get-commit' -Set @{ sha = $ref; 'tree.sha' = $Stub.TreeRefs[$ref] }
            return ConvertTo-Json -InputObject $response -Depth 50
        }
        '/git/trees/(?<ref>[0-9a-f]{40})\?recursive=1$' {
            $treeRef = $Matches['ref']
            $ref = @($Stub.TreeRefs.Keys | Where-Object { $Stub.TreeRefs[$_] -ceq $treeRef })[0]
            if ($Stub.Trees.ContainsKey($ref)) {
                return ConvertTo-Json -InputObject $Stub.Trees[$ref] -Depth 50
            }
            $template = (Get-GitHubApiFixture -Name 'git/get-tree').tree[0]
            $entries = @(foreach ($file in $Stub.Files) {
                $isBase = $ref -ceq $pullRequest.baseRefOid
                if ($isBase -and $file.status -eq 'added') { continue }
                if (-not $isBase -and $file.status -eq 'removed') { continue }
                $name = if ($isBase -and $file.status -in @('renamed', 'copied') -and $file.previous_filename) { $file.previous_filename } else { $file.filename }
                $entry = $template.Clone()
                $entry.path = $name
                $entry.sha = if ($isBase) { 'b' * 40 } else { 'a' * 40 }
                $entry
            })
            $response = Get-GitHubApiFixture -Name 'git/get-tree' -Set @{ tree = $entries; sha = $treeRef }
            return ConvertTo-Json -InputObject $response -Depth 50
        }
        '/contents/(?<file>[^?]+)\?ref=(?<ref>[0-9a-f]{40})$' {
            $file = [uri]::UnescapeDataString($Matches['file'])
            $key = "$($Matches['ref'])/$file"
            # Synthetic YAML for unchanged settings; individual G10 cases supply their own base/head documents.
            $content = if ($Stub.Contents.ContainsKey($key)) { $Stub.Contents[$key] } else { "name: CI`non: push`njobs: {build: {runs-on: ubuntu-latest}}" }
            if ($Stub.Scenario -eq 'pr-70' -and $file -eq '.github/workflows/release.yml') {
                $content = (@($Stub.Files | Where-Object { $_.filename -eq $file })[0].patch -split "`n" |
                    Where-Object { $_.StartsWith('+') -and -not $_.StartsWith('+++') } |
                    ForEach-Object { $_.Substring(1) }) -join "`n"
            }
            $response = Get-GitHubApiFixture -Name 'repos/get-content.file' -Set @{
                path = $file; content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($content))
                size = [Text.Encoding]::UTF8.GetByteCount($content)
            }
            return ConvertTo-Json -InputObject $response -Depth 50
        }
        '/rules/branches/' { return ConvertTo-Json -InputObject (Get-MergeGateStubPage -Items $Stub.Rules -Page $page) -Depth 50 }
        '/actions/runs\?' {
            $runs = @($Stub.WorkflowRuns.workflow_runs)
            return ConvertTo-Json -InputObject @{ total_count = $Stub.WorkflowRuns.total_count; workflow_runs = (Get-MergeGateStubPage -Items $runs -Page $page) } -Depth 50
        }
        '/check-runs\?' {
            $runs = @($Stub.CheckRuns.check_runs)
            return ConvertTo-Json -InputObject @{ total_count = $Stub.CheckRuns.total_count; check_runs = (Get-MergeGateStubPage -Items $runs -Page $page) } -Depth 50
        }
        '/status\?' {
            $status = $Stub.Status.Clone()
            $status.statuses = Get-MergeGateStubPage -Items @($Stub.Status.statuses) -Page $page
            return ConvertTo-Json -InputObject $status -Depth 50
        }
        '/compare/' { return ConvertTo-Json -InputObject $Stub.Compare -Depth 50 }
        '/pulls/\d+/files\?' { return ConvertTo-Json -InputObject (Get-MergeGateStubPage -Items @($Stub.Files) -Page $page) -Depth 50 }
        '/rulesets/rule-suites\?' { return ConvertTo-Json -InputObject (Get-MergeGateStubPage -Items @($Stub.RuleSuites) -Page $page) -Depth 50 }
    }
    throw "The merge gate stub has no response for '$request'."
}

Export-ModuleMember -Function Get-MergeGateScenario, Initialize-MergeGateStub, Invoke-MergeGateStub, Add-MergeGateStubRuleSuite
