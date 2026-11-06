#Requires -Version 7.4
<#
.SYNOPSIS
Inspects, checkpoints or publishes one retrospective distillation batch.
.DESCRIPTION
Reads Git from pinned commits and persists the PR body in the commit before pushing.
GitHub REST uses API version 2026-03-10:
https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#list-pull-requests
https://docs.github.com/en/enterprise-cloud@latest/rest/pulls/pulls#create-a-pull-request
The paginated list accepts nullable user/body fields. Repository identities are
nonnullable in the pinned schema. No author-type policy is imposed.
#>
[CmdletBinding()]
param(
    [ValidateSet('Inspect', 'Commit', 'Publish')][string] $Mode = 'Inspect',
    [string] $RepositoryPath = '.',
    [string] $SourceSha,
    [string] $BodyPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryPath = (Resolve-Path -LiteralPath $RepositoryPath).Path

function Invoke-RetroGit {
    param([string[]] $Arguments)
    $output = @(& git -C $RepositoryPath @Arguments)
    if ($LASTEXITCODE -ne 0) { throw "git $($Arguments -join ' ') failed ($LASTEXITCODE)." }
    return $output
}

# security-check: retro-distillation-origin
function Assert-RetroOrigin {
    foreach ($side in @('fetch', 'push')) {
        $arguments = @('remote', 'get-url', '--all')
        if ($side -eq 'push') { $arguments += '--push' }
        $arguments += 'origin'
        $urls = @(Invoke-RetroGit -Arguments $arguments)
        if ($urls.Count -ne 1) { throw 'Remote origin must target exactly one msucharda/devsecops-platform repository.' }
        if ($urls[0] -inotmatch '\A(?:https://github\.com/|git@github\.com:|ssh://git@github\.com/)msucharda/devsecops-platform(?:\.git)?\z') {
            throw 'Remote origin must target msucharda/devsecops-platform on github.com for fetch and push.'
        }
    }
}

# security-check: retro-distillation-inventory
function Assert-RetroInventory {
    param([object] $Pages)
    if ($Pages -isnot [array] -or $Pages.Count -eq 0) { throw 'Pull request inventory requires at least one page.' }
    foreach ($page in $Pages) {
        if ($page -isnot [array]) { throw 'Each pull request page must be an array.' }
        foreach ($pull in $page) {
            if ($pull -isnot [Collections.IDictionary]) { throw 'Pull request must be an object.' }
            foreach ($side in @('head', 'base')) {
                if ($pull[$side] -isnot [Collections.IDictionary]) { throw "Unreadable pull request identity: $side" }
                if ($pull[$side].ref -isnot [string] -or [string]::IsNullOrEmpty($pull[$side].ref)) {
                    throw "Unreadable pull request identity: $side.ref"
                }
                if ($pull[$side].repo -isnot [Collections.IDictionary]) { throw "Unreadable pull request identity: $side.repo" }
                if ($pull[$side].repo.full_name -isnot [string] -or [string]::IsNullOrEmpty($pull[$side].repo.full_name)) {
                    throw "Unreadable pull request identity: $side.repo.full_name"
                }
            }
            if ($pull.state -isnot [string] -or $pull.state -cnotin @('open', 'closed')) {
                throw 'An unknown distillation PR state requires human review.'
            }
            if ($null -ne $pull.body -and $pull.body -isnot [string]) { throw 'Unreadable pull request body.' }
        }
    }
}

# security-check: retro-distillation-source-pr
function Get-RetroPull {
    $output = @(& gh api --paginate --slurp --method GET -H 'X-GitHub-Api-Version: 2026-03-10' `
            '/repos/msucharda/devsecops-platform/pulls?state=all&per_page=100')
    if ($LASTEXITCODE -ne 0) { throw "Pull request listing failed ($LASTEXITCODE)." }
    $pages = ($output -join "`n") | ConvertFrom-Json -AsHashtable -NoEnumerate -Depth 100
    Assert-RetroInventory -Pages $pages
    foreach ($page in $pages) {
        foreach ($pull in $page) {
            if ($pull.head.repo.full_name -ine 'msucharda/devsecops-platform') { continue }
            if ($pull.base.repo.full_name -ine 'msucharda/devsecops-platform' -or $pull.base.ref -cne 'main') { continue }
            if ($pull.head.ref -clike 'retro-distillation/*') {
                $pull
            }
        }
    }
}

function Get-RetroBatchId {
    param([AllowEmptyCollection()][string[]] $Paths)
    $sorted = [string[]] @($Paths)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes(($sorted -join "`n")))).ToLowerInvariant()
}

function Get-RetroInput {
    param([string] $Source)
    Invoke-RetroGit -Arguments @('ls-tree', '-r', '--name-only', $Source, '--', 'docs/agents/retros') |
        Where-Object { $_ -cmatch '^docs/agents/retros/\d{4}-\d{2}-\d{2}-[^/]+\.md$' }
}

# security-check: retro-distillation-batch-identity
function Get-RetroBatchIdentity {
    param([AllowNull()][AllowEmptyString()][string] $Body)
    if ([regex]::Matches($Body, '(?i)<!--\s*distillation-batch\b').Count -ne 1) {
        throw 'Distillation PR requires exactly one readable batch identity.'
    }
    $marker = [regex]::Match($Body, '<!-- distillation-batch: sha256:(?<id>[a-f0-9]{64}) -->')
    if (-not $marker.Success) { throw 'Distillation PR requires a canonical batch identity.' }
    return $marker.Groups['id'].Value
}

# security-check: retro-distillation-checkpoint
function Get-RetroCheckpoint {
    param([string] $Branch, [string] $HeadSha)
    $source = $Branch.Substring('retro-distillation/'.Length)
    $parents = ((Invoke-RetroGit -Arguments @('rev-list', '--parents', '-n', '1', $HeadSha)) -join '').Split(' ')
    if ($parents.Count -ne 2 -or $parents[1] -ne $source) { throw 'Checkpoint must be one commit on its source SHA.' }
    $message = (Invoke-RetroGit -Arguments @('show', '-s', '--format=%B', $HeadSha)) -join "`n"
    $bodyMatches = [regex]::Matches($message, '(?m)^Retro-Body: ([A-Za-z0-9+/=]+)$')
    if ($bodyMatches.Count -ne 1) { throw 'Checkpoint requires one persisted PR body.' }
    $body = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($bodyMatches[0].Groups[1].Value))
    Assert-RetroOutput -Source $source -Tree $HeadSha -Body $body
    return [pscustomobject] @{ Action = 'Resume'; SourceSha = $source; HeadSha = $HeadSha; Branch = $Branch; Body = $body }
}

# security-check: retro-distillation-pr-response
function Assert-RetroCreation {
    param([object] $Pull, [object] $Checkpoint)
    $expected = @{
        state                 = 'open'
        'head.ref'            = $Checkpoint.Branch
        'head.sha'            = $Checkpoint.HeadSha
        'head.repo.full_name' = 'msucharda/devsecops-platform'
        'base.ref'            = 'main'
        'base.repo.full_name' = 'msucharda/devsecops-platform'
        body                  = $Checkpoint.Body
    }
    foreach ($path in $expected.Keys) {
        $actual = $Pull
        foreach ($part in $path.Split('.')) {
            if ($actual -isnot [Collections.IDictionary]) { throw "Unreadable PR creation response: $path" }
            $actual = $actual[$part]
        }
        if ($actual -isnot [string] -or $actual -cne $expected[$path]) { throw "Mismatched PR creation response: $path" }
    }
    if ($Pull.number -isnot [long] -and $Pull.number -isnot [int]) { throw 'Invalid PR creation response: number type' }
    if ($Pull.number -lt 1) { throw 'Invalid PR creation response: number' }
    if ($Pull.html_url -isnot [string] -or $Pull.html_url -cne "https://github.com/msucharda/devsecops-platform/pull/$($Pull.number)") {
        throw 'Invalid PR creation response: html_url'
    }
}

# security-check: retro-distillation-output
function Assert-RetroOutput {
    param([string] $Source, [string] $Tree, [string] $Body)
    if ([regex]::Matches($Body, '<!--\s*retro:').Count -ne 1 -or
        -not $Body.Contains('<!-- retro: none distillation -->', [StringComparison]::Ordinal)) {
        throw 'PR body requires exactly one distillation marker.'
    }
    if (-not $Body.Contains($Source, [StringComparison]::Ordinal)) { throw 'PR body must identify the source SHA.' }
    if ($Body -cnotmatch '(?m)^## Otevřené otázky\r?$') { throw 'PR body requires the open-questions section.' }
    $deleted = @()
    foreach ($line in @(Invoke-RetroGit -Arguments @('diff', '--name-status', '--no-renames', $Source, $Tree))) {
        $parts = $line.Split("`t")
        $status = $parts[0]
        $path = $parts[1]
        if ($status -eq 'D' -and $path -cmatch '^docs/agents/retros/\d{4}-\d{2}-\d{2}-[^/]+\.md$') {
            $deleted += $path
            continue
        }
        if ($line -cnotmatch '^[AM]\t(AGENTS\.md|docs/agents/retros/candidates\.md|docs/agents/guide/[a-z0-9-]+\.md)$') {
            throw "Change outside the distillation output: $line"
        }
        $entry = (Invoke-RetroGit -Arguments @('ls-tree', $Tree, '--', $path)) -join ''
        if ($entry -notmatch '^100644 blob ') { throw "Distillation output must be a regular file: $path" }
        if ($path -eq 'AGENTS.md') {
            $before = (Invoke-RetroGit -Arguments @('show', "${Source}:AGENTS.md")) -join "`n"
            $after = (Invoke-RetroGit -Arguments @('show', "${Tree}:AGENTS.md")) -join "`n"
            $index = '(?ms)^### Průvodce agentů\n.*?(?=^### |^## |\z)'
            if ([regex]::Replace($before, $index, '').TrimEnd() -cne [regex]::Replace($after, $index, '').TrimEnd()) {
                throw 'AGENTS.md changed outside its guide index.'
            }
        }
    }
    if ($deleted.Count -lt 3) { throw 'A distillation checkpoint must delete at least three retrospective inputs.' }
    $batchId = Get-RetroBatchIdentity -Body $Body
    if ($batchId -ne (Get-RetroBatchId -Paths $deleted)) {
        throw 'Checkpoint deletions must match the persisted batch identity.'
    }
    if ($batchId -ne (Get-RetroBatchId -Paths @(Get-RetroInput -Source $Source))) {
        throw 'Checkpoint batch identity must match the complete source inventory.'
    }
}

# security-check: retro-distillation-mode
function Test-RetroPublicationMode {
    param([string] $Mode)
    return $Mode -ieq 'Publish'
}

Assert-RetroOrigin
if ($Mode -ieq 'Commit') {
    if ($SourceSha -cnotmatch '^[a-f0-9]{40}$') { throw 'Commit requires a full source SHA.' }
    $head = (Invoke-RetroGit -Arguments @('rev-parse', 'HEAD')) -join ''
    $body = Get-Content -LiteralPath $BodyPath -Raw
    if (-not [regex]::IsMatch($body, '(?i)<!--\s*distillation-batch\b')) {
        $batchId = Get-RetroBatchId -Paths @(Get-RetroInput -Source $SourceSha)
        $body += "`n<!-- distillation-batch: sha256:$batchId -->"
    }
    if ($head -cne $SourceSha) {
        $saved = Get-RetroCheckpoint -Branch "retro-distillation/$SourceSha" -HeadSha $head
        if ($saved.Body -cne $body) { throw 'A local checkpoint already exists with another PR body.' }
        return $saved
    }
    $encoded = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
    $null = Invoke-RetroGit -Arguments @('add', '--all')
    $tree = (Invoke-RetroGit -Arguments @('write-tree')) -join ''
    Assert-RetroOutput -Source $SourceSha -Tree $tree -Body $body
    $null = Invoke-RetroGit -Arguments @('commit', '--quiet', '-m', "Distill session retrospectives`n`nRetro-Body: $encoded`n`nCo-authored-by: Copilot App <223556219+Copilot@users.noreply.github.com>")
    $commit = (Invoke-RetroGit -Arguments @('rev-parse', 'HEAD')) -join ''
    return Get-RetroCheckpoint -Branch "retro-distillation/$SourceSha" -HeadSha $commit
}

function Get-RetroPlan {
    $pulls = @(Get-RetroPull)
    $open = @($pulls | Where-Object { $_.state -ceq 'open' })
    if ($open.Count -gt 0) {
        return [pscustomobject] @{ Action = 'NoOp'; Reason = 'open-pr'; PullRequests = @($open.number) }
    }
    $null = Invoke-RetroGit -Arguments @('fetch', '--quiet', 'origin', 'main')
    $source = (Invoke-RetroGit -Arguments @('rev-parse', 'refs/remotes/origin/main')) -join ''
    $retros = @(Get-RetroInput -Source $source)
    $batchId = Get-RetroBatchId -Paths $retros
    Assert-RetroHistory -ClosedPull @($pulls | Where-Object { $_.state -ceq 'closed' }) -BatchId $batchId
    $orphans = @()
    foreach ($line in @(Invoke-RetroGit -Arguments @('ls-remote', '--heads', 'origin', 'refs/heads/retro-distillation/*'))) {
        if ($line -cnotmatch '^([a-f0-9]{40})\s+refs/heads/(retro-distillation/[a-f0-9]{40})$') { throw 'Invalid distillation remote ref.' }
        $head = $Matches[1]
        $branch = $Matches[2]
        $history = @($pulls | Where-Object { $_.head.ref -ceq $branch })
        if ($history.Count -gt 0) { continue }
        $null = Invoke-RetroGit -Arguments @('fetch', '--quiet', 'origin', $head)
        $orphans += Get-RetroCheckpoint -Branch $branch -HeadSha $head
    }
    if ($orphans.Count -gt 1) { throw 'Multiple orphan distillation branches require human review.' }
    if ($orphans.Count -eq 1) {
        $pending = $orphans[0]
        $null = Invoke-RetroGit -Arguments @('merge-base', '--is-ancestor', $pending.SourceSha, $source)
        $drift = @(Invoke-RetroGit -Arguments @('diff', '--name-only', $pending.SourceSha, $source, '--', 'AGENTS.md', 'docs/agents', 'docs/adr'))
        if ($drift.Count) { throw 'Distillation inputs changed on main; preserve the checkpoint for human review.' }
        return $pending
    }
    if ($retros.Count -lt 3) {
        return [pscustomobject] @{ Action = 'NoOp'; Reason = 'threshold'; SourceSha = $source; Retrospectives = $retros }
    }
    return [pscustomobject] @{ Action = 'Prepare'; Reason = 'ready'; SourceSha = $source; Branch = "retro-distillation/$source"; Retrospectives = $retros; BatchId = $batchId }
}

# security-check: retro-distillation-closed-history
function Assert-RetroHistory {
    param([object[]] $ClosedPull, [string] $BatchId)
    foreach ($pull in $ClosedPull) {
        # ConvertFrom-Json in the supported PowerShell runtime deserializes RFC 3339 timestamps as DateTime.
        if ($pull.merged_at -is [datetime]) { continue }
        if ($null -ne $pull.merged_at) { throw 'An unknown distillation merge state requires human review.' }
        if ((Get-RetroBatchIdentity -Body $pull.body) -eq $BatchId) {
            throw 'An unmerged distillation PR for the same batch requires human review.'
        }
    }
}

$distillationPlan = Get-RetroPlan
if (-not (Test-RetroPublicationMode -Mode $Mode) -or $distillationPlan.Action -ceq 'NoOp') { return $distillationPlan }
if (@(Invoke-RetroGit -Arguments @('status', '--porcelain', '--untracked-files=all')).Count) {
    throw 'Publication requires a clean checkout.'
}
$head = (Invoke-RetroGit -Arguments @('rev-parse', 'HEAD')) -join ''
if ($distillationPlan.Action -ceq 'Resume') {
    $checkpoint = $distillationPlan
    $null = Invoke-RetroGit -Arguments @('switch', '--quiet', '--detach', $checkpoint.HeadSha)
}
else {
    $checkpoint = Get-RetroCheckpoint -Branch $distillationPlan.Branch -HeadSha $head
}
$null = @(& pwsh -NoProfile -File (Join-Path (Join-Path $RepositoryPath 'tools') 'Test-LocalCiResult.ps1') -Base $checkpoint.SourceSha -ExpectedHead $checkpoint.HeadSha)
if ($LASTEXITCODE -ne 0) { throw 'A matching successful local gate is required before publication.' }

$latest = Get-RetroPlan
if ($latest.Action -ceq 'NoOp') { return $latest }
if ($latest.Branch -cne $checkpoint.Branch) { throw 'Distillation source changed before publication.' }
if ($latest.Action -ceq 'Resume' -and $latest.HeadSha -cne $checkpoint.HeadSha) { throw 'Concurrent distillation checkpoint requires human review.' }
if ($latest.Action -ceq 'Prepare') {
    $null = Invoke-RetroGit -Arguments @('-c', 'core.hooksPath=.githooks', 'push', '--quiet',
        "--force-with-lease=refs/heads/$($checkpoint.Branch):", 'origin', "HEAD:refs/heads/$($checkpoint.Branch)")
}
$remoteLines = @(Invoke-RetroGit -Arguments @('ls-remote', '--heads', 'origin', "refs/heads/$($checkpoint.Branch)"))
if ($remoteLines.Count -ne 1 -or $remoteLines[0] -cne "$($checkpoint.HeadSha)`trefs/heads/$($checkpoint.Branch)") {
    throw 'Distillation branch changed before PR creation.'
}
$beforeCreate = Get-RetroPlan
if ($beforeCreate.Action -ceq 'NoOp') { return $beforeCreate }
if ($beforeCreate.HeadSha -cne $checkpoint.HeadSha) { throw 'Distillation checkpoint changed before PR creation.' }
$output = @(& gh api --method POST -H 'X-GitHub-Api-Version: 2026-03-10' `
        '/repos/msucharda/devsecops-platform/pulls' --raw-field "head=$($checkpoint.Branch)" `
        --raw-field 'base=main' --raw-field 'title=Destilace retrospektiv session' --raw-field "body=$($checkpoint.Body)")
if ($LASTEXITCODE -ne 0) { throw 'PR creation failed; the next run must inspect the existing checkpoint.' }
$pull = ($output -join "`n") | ConvertFrom-Json -AsHashtable -Depth 100
Assert-RetroCreation -Pull $pull -Checkpoint $checkpoint
return [pscustomobject] @{ Action = 'Published'; SourceSha = $checkpoint.SourceSha; HeadSha = $checkpoint.HeadSha; Branch = $checkpoint.Branch; PullRequest = $pull.html_url }
