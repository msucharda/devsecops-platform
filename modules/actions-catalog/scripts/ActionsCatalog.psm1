Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../shared/scripts/GitHubRetry.ps1')

# REST endpoints, API version 2026-03-10 (https://docs.github.com/en/enterprise-cloud@latest/rest):
# repos/repos#create-an-organization-repository, repos/repos#get-a-repository,
# actions/permissions#get-the-level-of-access-for-workflows-outside-of-the-repository and #set-...,
# teams/teams#get-a-team-by-name, teams/teams#check-team-permissions-for-a-repository,
# teams/teams#add-or-update-team-repository-permissions, repos/contents#get-repository-content,
# repos/contents#create-or-update-file-contents, git/refs#get-a-reference, git/refs#create-a-reference,
# commits/commits#compare-two-commits, repos/rules#get-rules-for-a-branch.

$script:ApiVersion = '2026-03-10'
$script:DefaultBranch = 'main'
$script:CodeOwnersPath = '.github/CODEOWNERS'
$script:ReceiptPath = '.vendoring.json'
$script:TeamRepositoryMediaType = 'application/vnd.github.v3.repository+json'

function Assert-CatalogApiUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl)

    $uri = $null
    if (-not [Uri]::TryCreate($ApiUrl, [UriKind]::Absolute, [ref] $uri) -or $uri.AbsolutePath -cne '/' -or $uri.Query -or
        $uri.UserInfo -or -not ($uri.Scheme -ceq 'https' -or ($uri.Scheme -ceq 'http' -and $uri.IsLoopback))) {
        throw "The GitHub API URL '$ApiUrl' must be an HTTPS origin; plain HTTP is only accepted for a loopback test stub."
    }
}

function Assert-CatalogInput {
    <#
    .SYNOPSIS
    Validates the names that the module puts into REST paths.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Upstream,
        [Parameter(Mandatory)][string] $SecurityTeam,
        [AllowNull()][AllowEmptyString()][string] $Tag,
        [AllowNull()][AllowEmptyString()][string] $Commit
    )

    if ($Organization -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z') { throw "Organization '$Organization' is not a GitHub login." }
    if ($Upstream -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,37}[a-z0-9])?/[a-z0-9_.-]{1,100}\z' -or $Upstream -cmatch '/\.\.?\z') {
        throw "Upstream '$Upstream' is not a lowercase owner/repository."
    }
    # The copy name {owner}-{repo} has the length of the upstream name; GitHub allows at most 100 characters.
    if ($Upstream.Length -gt 100) { throw "Upstream '$Upstream' gives a copy name longer than 100 characters." }
    if ($SecurityTeam -cnotmatch '^[a-z0-9](?:[a-z0-9-]{0,98}[a-z0-9])?\z') { throw "Security team '$SecurityTeam' is not a team slug." }
    if ([string]::IsNullOrEmpty($Tag) -ne [string]::IsNullOrEmpty($Commit)) { throw "Release of '$Upstream' needs both a tag and a commit." }
    if ($Tag -and ($Tag -cnotmatch '^[A-Za-z0-9][A-Za-z0-9._-]{0,99}\z' -or $Tag.Contains('..') -or $Tag.EndsWith('.lock') -or $Tag.EndsWith('.'))) {
        throw "Tag '$Tag' of '$Upstream' is not a supported tag name."
    }
    if ($Commit -and $Commit -cnotmatch '^[0-9a-f]{40}\z') { throw "Commit '$Commit' of '$Upstream' is not a full lowercase commit SHA." }
}

function Get-CatalogRepositoryName {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Upstream)

    return $Upstream.Replace('/', '-')
}

function Get-CatalogCodeOwners {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Organization, [Parameter(Mandatory)][string] $SecurityTeam)

    return "* @$Organization/$SecurityTeam`n"
}

function Invoke-CatalogApi {
    <#
    .SYNOPSIS
    Sends one GitHub request with the job's token and follows Link rel="next" on the same origin.
    .DESCRIPTION
    Returns @{ Status; Body }. Only the listed statuses are accepted; any other status throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][object] $Body,
        [int[]] $AcceptStatus = @(200),
        [string] $MediaType = 'application/vnd.github+json',
        [switch] $AllPages
    )

    Assert-CatalogApiUrl -ApiUrl $ApiUrl
    if (-not $env:REST_API_BEARER) { throw 'REST_API_BEARER is not set; the runner must export the GitHub token.' }
    $origin = $ApiUrl.TrimEnd('/')
    $headers = @{
        Authorization          = "Bearer $env:REST_API_BEARER"
        Accept                 = $MediaType
        'X-GitHub-Api-Version' = $script:ApiVersion
    }
    $operation = "$Method $($Path.Split('?')[0])"
    $uri = "$origin$Path"
    $items = [Collections.Generic.List[object]]::new()
    while ($uri) {
        $request = @{
            Uri = $uri; Method = $Method; Headers = $headers; SkipHttpErrorCheck = $true
            MaximumRetryCount = 0; MaximumRedirection = 0; TimeoutSec = 60
        }
        if ($null -ne $Body) {
            $request.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
            $request.ContentType = 'application/json'
        }
        $reply = Invoke-GitHubRetryRequest -Request $request
        $status = [int] $reply.StatusCode
        if ($status -notin $AcceptStatus) { throw "GitHub returned HTTP $status for $operation." }
        $content = if ($reply.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($reply.Content) } else { [string] $reply.Content }
        $parsed = if ([string]::IsNullOrWhiteSpace($content)) { $null } else { ConvertFrom-Json -InputObject $content -AsHashtable -Depth 100 -NoEnumerate }
        if (-not $AllPages) { return @{ Status = $status; Body = $parsed } }
        if ($parsed -isnot [array]) { throw "GitHub returned no JSON array for $operation." }
        foreach ($item in $parsed) { $items.Add($item) }
        $uri = $null
        foreach ($link in @($reply.Headers['Link'])) {
            foreach ($part in ([string] $link).Split(',')) {
                if ($part -match '^\s*<(?<url>[^>]+)>\s*;\s*rel="next"\s*$') {
                    $next = $Matches['url']
                    if (-not $next.StartsWith("$origin/", [StringComparison]::Ordinal)) {
                        throw "GitHub returned a pagination link outside '$origin'."
                    }
                    $uri = $next
                }
            }
        }
    }
    return @{ Status = 200; Body = $items.ToArray() }
}

function Get-CatalogRepository {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization, [Parameter(Mandatory)][string] $Repository)

    $reply = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/repos/$Organization/$Repository" -AcceptStatus @(200, 404)
    if ($reply.Status -eq 404) { return $null }
    if ($reply.Body -isnot [System.Collections.IDictionary]) { throw "GitHub returned no repository object for '$Organization/$Repository'." }
    return $reply.Body
}

# security-check: catalog-repository-adoptable
function Test-CatalogRepositoryAdoptable {
    <#
    .SYNOPSIS
    Returns the reasons why a repository is not an internal, active, non-fork repository of the organization on main.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Repository,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Name
    )

    $owner = $Repository['owner']
    # GitHub logins and repository names are case-insensitive.
    if ($owner -isnot [System.Collections.IDictionary] -or $owner['login'] -isnot [string] -or $owner['login'] -ne $Organization -or
        $Repository['name'] -isnot [string] -or $Repository['name'] -ne $Name) {
        "Repository '$Organization/$Name' is not owned by the actions organization under the catalog name."
    }
    if ($Repository['visibility'] -isnot [string] -or $Repository['visibility'] -cne 'internal') { "Repository '$Organization/$Name' is not internal." }
    if ($Repository['archived'] -isnot [bool] -or $Repository['archived']) { "Repository '$Organization/$Name' is archived." }
    if ($Repository['fork'] -isnot [bool] -or $Repository['fork']) { "Repository '$Organization/$Name' is a fork." }
    if ($Repository['default_branch'] -isnot [string] -or $Repository['default_branch'] -cne $script:DefaultBranch) { "Repository '$Organization/$Name' does not use the default branch main." }
}

function Get-CatalogAccessLevel {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization, [Parameter(Mandatory)][string] $Repository)

    $reply = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/repos/$Organization/$Repository/actions/permissions/access"
    if ($reply.Body -isnot [System.Collections.IDictionary] -or $reply.Body['access_level'] -isnot [string]) {
        throw "GitHub returned no actions access level for '$Organization/$Repository'."
    }
    return $reply.Body['access_level']
}

# security-check: catalog-team-push
function Get-CatalogTeamPush {
    <#
    .SYNOPSIS
    Returns whether the security team can push to the repository; a missing or secret team throws.
    .DESCRIPTION
    The repository media type is required: with the default media type GitHub answers 204 for any team permission,
    including read.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $SecurityTeam
    )

    $team = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/orgs/$Organization/teams/$SecurityTeam" -AcceptStatus @(200, 404)
    if ($team.Status -eq 404) { throw "Security team '$Organization/$SecurityTeam' does not exist; create it before the catalog." }
    # CODEOWNERS ignores a secret team, so its review would not be required.
    if ($team.Body -isnot [System.Collections.IDictionary] -or $team.Body['privacy'] -isnot [string] -or $team.Body['privacy'] -cne 'closed') {
        throw "Security team '$Organization/$SecurityTeam' is not visible; CODEOWNERS requires a team with privacy 'closed'."
    }
    $reply = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/orgs/$Organization/teams/$SecurityTeam/repos/$Organization/$Repository" `
        -AcceptStatus @(200, 404) -MediaType $script:TeamRepositoryMediaType
    if ($reply.Status -eq 404) { return $false }
    $permissions = if ($reply.Body -is [System.Collections.IDictionary]) { $reply.Body['permissions'] } else { $null }
    if ($permissions -isnot [System.Collections.IDictionary] -or $permissions['push'] -isnot [bool]) {
        throw "GitHub returned no team permissions for '$Organization/$SecurityTeam' on '$Repository'."
    }
    return $permissions['push']
}

function Get-CatalogBranchSha {
    <#
    .SYNOPSIS
    Returns the commit SHA of main, or $null when main or every commit of the repository is missing.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization, [Parameter(Mandatory)][string] $Repository)

    # GitHub answers 409 for a repository without commits.
    $reply = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/repos/$Organization/$Repository/git/ref/heads/$($script:DefaultBranch)" `
        -AcceptStatus @(200, 404, 409)
    if ($reply.Status -ne 200) { return $null }
    $reference = $reply.Body
    $object = if ($reference -is [System.Collections.IDictionary]) { $reference['object'] } else { $null }
    if ($object -isnot [System.Collections.IDictionary] -or $reference['ref'] -isnot [string] -or $reference['ref'] -cne "refs/heads/$($script:DefaultBranch)" -or
        $object['type'] -isnot [string] -or $object['type'] -cne 'commit' -or $object['sha'] -isnot [string] -or $object['sha'] -cnotmatch '^[0-9a-f]{40}\z') {
        throw "GitHub returned no commit for the main branch of '$Organization/$Repository'."
    }
    return $object['sha']
}

function Get-CatalogFile {
    <#
    .SYNOPSIS
    Returns the text of a file at a fixed commit, or $null when it does not exist.
    .DESCRIPTION
    The contents API returns one of a directory, file, symlink or submodule; anything but a base64 file is refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $Commit
    )

    $reply = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/repos/$Organization/$Repository/contents/$($Path)?ref=$Commit" -AcceptStatus @(200, 404)
    if ($reply.Status -eq 404) { return $null }
    $file = $reply.Body
    if ($file -isnot [System.Collections.IDictionary] -or $file['type'] -isnot [string] -or $file['type'] -cne 'file' -or
        $file['path'] -isnot [string] -or $file['path'] -cne $Path -or $file['encoding'] -isnot [string] -or $file['encoding'] -cne 'base64' -or
        $file['content'] -isnot [string]) {
        throw "'$Path' in '$Organization/$Repository' at $Commit is not a regular file."
    }
    try {
        return [Text.UTF8Encoding]::new($false, $true).GetString([Convert]::FromBase64String(($file['content'] -replace '\s', '')))
    }
    catch { throw "'$Path' in '$Organization/$Repository' at $Commit is not base64 UTF-8 text." }
}

# security-check: catalog-approval-rule
function Test-CatalogApprovalRule {
    <#
    .SYNOPSIS
    Returns whether the rules active on main require an approving code owner review before merge.
    .DESCRIPTION
    Only a rule of an organization ruleset of the given organization counts. The apply credential holds repository
    administration and could change a repository ruleset itself.
    #>
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][AllowEmptyCollection()][object[]] $Rule,
        [Parameter(Mandatory)][string] $Organization
    )

    foreach ($item in @($Rule)) {
        if ($item -isnot [System.Collections.IDictionary] -or $item['type'] -isnot [string] -or $item['type'] -cne 'pull_request') { continue }
        # Organization logins are case-insensitive.
        if ($item['ruleset_source_type'] -isnot [string] -or $item['ruleset_source_type'] -cne 'Organization' -or
            $item['ruleset_source'] -isnot [string] -or $item['ruleset_source'] -ne $Organization) { continue }
        $parameters = $item['parameters']
        if ($parameters -isnot [System.Collections.IDictionary]) { continue }
        $count = $parameters['required_approving_review_count']
        # Without stale review dismissal, a later push keeps the approval of the reviewed import.
        if ($parameters['require_code_owner_review'] -is [bool] -and $parameters['require_code_owner_review'] -and
            $parameters['dismiss_stale_reviews_on_push'] -is [bool] -and $parameters['dismiss_stale_reviews_on_push'] -and
            ($count -is [int] -or $count -is [long]) -and $count -ge 1) {
            return $true
        }
    }
    return $false
}

function Get-CatalogTag {
    <#
    .SYNOPSIS
    Returns @{ Type; Sha } of a tag reference, or $null when the tag does not exist.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Tag
    )

    $reply = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/repos/$Organization/$Repository/git/ref/tags/$Tag" -AcceptStatus @(200, 404)
    if ($reply.Status -eq 404) { return $null }
    $reference = $reply.Body
    $object = if ($reference -is [System.Collections.IDictionary]) { $reference['object'] } else { $null }
    if ($object -isnot [System.Collections.IDictionary] -or $reference['ref'] -isnot [string] -or $reference['ref'] -cne "refs/tags/$Tag" -or
        $object['type'] -isnot [string] -or $object['sha'] -isnot [string]) {
        throw "GitHub returned no object for tag '$Tag' of '$Organization/$Repository'."
    }
    return @{ Type = $object['type']; Sha = $object['sha'] }
}

# security-check: catalog-release-commit
function Test-CatalogReleaseCommit {
    <#
    .SYNOPSIS
    Returns the reasons why a commit of the vendored copy is not an approved import of the upstream tag.
    .DESCRIPTION
    The commit must be reachable from the given commit of the protected main branch, so it passed the reviewed PR, and its
    .vendoring.json receipt must record the upstream repository and tag. The caller reads main once and passes its SHA, so a
    moving branch cannot change the answer between the checks.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $Upstream,
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $Commit,
        [Parameter(Mandatory)][ValidatePattern('^[0-9a-f]{40}$')][string] $Main
    )

    $compare = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/repos/$Organization/$Repository/compare/$Commit...$($Main)?per_page=1" `
        -AcceptStatus @(200, 404)
    if ($compare.Status -eq 404) { return "Commit $Commit is not in '$Organization/$Repository'." }
    $comparison = $compare.Body
    if ($comparison -isnot [System.Collections.IDictionary] -or $comparison['status'] -cnotin @('identical', 'ahead')) {
        return "Commit $Commit of '$Organization/$Repository' is not on the protected main branch."
    }
    $text = Get-CatalogFile -ApiUrl $ApiUrl -Organization $Organization -Repository $Repository -Path $script:ReceiptPath -Commit $Commit
    if ($null -eq $text) { return "Commit $Commit of '$Organization/$Repository' has no $($script:ReceiptPath) receipt." }
    $receipt = try { ConvertFrom-Json -InputObject $text -AsHashtable -Depth 20 -NoEnumerate } catch { $null }
    if ($receipt -isnot [System.Collections.IDictionary] -or $receipt['version'] -isnot [long] -or $receipt['version'] -ne 1 -or
        $receipt['kind'] -isnot [string] -or $receipt['kind'] -cne 'action') {
        return "The receipt at $Commit of '$Organization/$Repository' is not a version 1 action receipt."
    }
    if ($receipt['source'] -isnot [string] -or $receipt['source'] -cne $Upstream) { "The receipt at $Commit of '$Organization/$Repository' records source '$($receipt['source'])', not '$Upstream'." }
    if ($receipt['tag'] -isnot [string] -or $receipt['tag'] -cne $Tag) { "The receipt at $Commit of '$Organization/$Repository' records tag '$($receipt['tag'])', not '$Tag'." }
}

function Get-CatalogRepositoryState {
    <#
    .SYNOPSIS
    Reads the live state of one catalog repository. Any read error throws.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Upstream,
        [Parameter(Mandatory)][string] $SecurityTeam,
        [AllowNull()][AllowEmptyString()][string] $Tag,
        [AllowNull()][AllowEmptyString()][string] $Commit
    )

    Assert-CatalogInput -Organization $Organization -Upstream $Upstream -SecurityTeam $SecurityTeam -Tag $Tag -Commit $Commit
    $name = Get-CatalogRepositoryName -Upstream $Upstream
    $state = [ordered]@{ repository = $name; exists = $false }
    $repository = Get-CatalogRepository -ApiUrl $ApiUrl -Organization $Organization -Repository $name
    if ($null -eq $repository) { return $state }
    $state.exists = $true
    $state.adoption = @(Test-CatalogRepositoryAdoptable -Repository $repository -Organization $Organization -Name $name)
    $state.accessLevel = Get-CatalogAccessLevel -ApiUrl $ApiUrl -Organization $Organization -Repository $name
    $state.teamPush = Get-CatalogTeamPush -ApiUrl $ApiUrl -Organization $Organization -Repository $name -SecurityTeam $SecurityTeam
    $state.mainSha = Get-CatalogBranchSha -ApiUrl $ApiUrl -Organization $Organization -Repository $name
    $state.codeOwners = if ($state.mainSha) {
        Get-CatalogFile -ApiUrl $ApiUrl -Organization $Organization -Repository $name -Path $script:CodeOwnersPath -Commit $state.mainSha
    }
    $rules = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/repos/$Organization/$name/rules/branches/$($script:DefaultBranch)?per_page=100" -AllPages
    $state.approvalRule = Test-CatalogApprovalRule -Rule $rules.Body -Organization $Organization
    if ($Tag) {
        $state.tag = Get-CatalogTag -ApiUrl $ApiUrl -Organization $Organization -Repository $name -Tag $Tag
        # Without main, the violations already report the missing branch.
        $state.release = if ($state.mainSha) {
            @(Test-CatalogReleaseCommit -ApiUrl $ApiUrl -Organization $Organization -Repository $name -Upstream $Upstream -Tag $Tag -Commit $Commit -Main $state.mainSha)
        }
    }
    return $state
}

# security-check: catalog-state-violation
function Get-CatalogStateViolation {
    <#
    .SYNOPSIS
    Lists every difference between the live state of a catalog repository and the module configuration.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $State,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $SecurityTeam,
        [AllowNull()][AllowEmptyString()][string] $Tag,
        [AllowNull()][AllowEmptyString()][string] $Commit
    )

    $name = "$Organization/$($State['repository'])"
    if ($State['exists'] -isnot [bool] -or -not $State['exists']) { return "Repository '$name' does not exist." }
    foreach ($reason in @($State['adoption'])) { if ($reason) { $reason } }
    if ($State['accessLevel'] -cne 'enterprise') { "Actions in '$name' are not accessible to the enterprise (access level '$($State['accessLevel'])')." }
    if ($State['teamPush'] -isnot [bool] -or -not $State['teamPush']) { "Security team '$SecurityTeam' cannot push to '$name'." }
    if (-not $State['mainSha']) { "Repository '$name' has no main branch." }
    elseif ($State['codeOwners'] -cne (Get-CatalogCodeOwners -Organization $Organization -SecurityTeam $SecurityTeam)) {
        "$($script:CodeOwnersPath) on main of '$name' does not name only the security team; change it through a reviewed PR."
    }
    if ($State['approvalRule'] -isnot [bool] -or -not $State['approvalRule']) {
        "Main of '$name' has no active rule that requires an approving code owner review."
    }
    if ($Tag) {
        $tagState = $State['tag']
        if ($tagState -isnot [System.Collections.IDictionary]) { "Tag '$Tag' does not exist in '$name'." }
        elseif ($tagState['Type'] -cne 'commit' -or $tagState['Sha'] -cne $Commit) { "Tag '$Tag' in '$name' does not point to commit $Commit." }
        foreach ($reason in @($State['release'])) { if ($reason) { $reason } }
    }
}

function ConvertTo-CatalogStateResult {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $State, [AllowEmptyCollection()][string[]] $Violation = @())

    return ConvertTo-Json -Compress -InputObject ([ordered]@{
            state      = ConvertTo-Json -InputObject $State -Depth 10 -Compress
            violations = ConvertTo-Json -InputObject @($Violation) -Compress
        })
}

function Initialize-CatalogRepository {
    <#
    .SYNOPSIS
    Creates or adopts the internal repository of one catalog action and grants the enterprise and the security team access.
    .DESCRIPTION
    Every step reads first, so a repeated run after an interruption converges without a second creation. CODEOWNERS is
    written only into an empty repository; later changes go through a reviewed PR.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Upstream,
        [Parameter(Mandatory)][string] $SecurityTeam
    )

    Assert-CatalogInput -Organization $Organization -Upstream $Upstream -SecurityTeam $SecurityTeam
    $name = Get-CatalogRepositoryName -Upstream $Upstream
    $repository = Get-CatalogRepository -ApiUrl $ApiUrl -Organization $Organization -Repository $name
    if ($null -eq $repository) {
        $created = Invoke-CatalogApi -ApiUrl $ApiUrl -Method POST -Path "/orgs/$Organization/repos" -AcceptStatus @(201, 422) -Body @{
            name = $name; description = "Vendored copy of $Upstream."; visibility = 'internal'; auto_init = $false
            has_issues = $false; has_projects = $false; has_wiki = $false
        }
        # 422 follows a creation whose response was lost; the adoption check below decides about the existing repository.
        $repository = if ($created.Status -eq 201) { $created.Body } else { Get-CatalogRepository -ApiUrl $ApiUrl -Organization $Organization -Repository $name }
        if ($repository -isnot [System.Collections.IDictionary]) { throw "GitHub did not create repository '$Organization/$name'." }
    }
    $reasons = @(Test-CatalogRepositoryAdoptable -Repository $repository -Organization $Organization -Name $name)
    if ($reasons.Count) { throw ($reasons -join ' ') }
    if (-not (Get-CatalogTeamPush -ApiUrl $ApiUrl -Organization $Organization -Repository $name -SecurityTeam $SecurityTeam)) {
        $null = Invoke-CatalogApi -ApiUrl $ApiUrl -Method PUT -Path "/orgs/$Organization/teams/$SecurityTeam/repos/$Organization/$name" `
            -Body @{ permission = 'push' } -AcceptStatus @(204)
    }
    $codeOwners = Get-CatalogCodeOwners -Organization $Organization -SecurityTeam $SecurityTeam
    $main = Get-CatalogBranchSha -ApiUrl $ApiUrl -Organization $Organization -Repository $name
    if (-not $main) {
        $null = Invoke-CatalogApi -ApiUrl $ApiUrl -Method PUT -Path "/repos/$Organization/$name/contents/$($script:CodeOwnersPath)" -AcceptStatus @(201) -Body @{
            message = 'Require security team review'
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($codeOwners))
        }
        $main = Get-CatalogBranchSha -ApiUrl $ApiUrl -Organization $Organization -Repository $name
        if (-not $main) { throw "Repository '$Organization/$name' has no main branch after the CODEOWNERS commit." }
    }
    $current = Get-CatalogFile -ApiUrl $ApiUrl -Organization $Organization -Repository $name -Path $script:CodeOwnersPath -Commit $main
    if ($current -cne $codeOwners) {
        throw "$($script:CodeOwnersPath) on main of '$Organization/$name' does not name only the security team; change it through a reviewed PR."
    }
    $rules = Invoke-CatalogApi -ApiUrl $ApiUrl -Method GET -Path "/repos/$Organization/$name/rules/branches/$($script:DefaultBranch)?per_page=100" -AllPages
    if (-not (Test-CatalogApprovalRule -Rule $rules.Body -Organization $Organization)) {
        throw "Main of '$Organization/$name' has no active organization rule that requires an approving code owner review; its actions stay closed to the enterprise."
    }
    # Sharing comes last, so a repository that fails adoption or lacks the approval rule is never opened to the enterprise.
    if ((Get-CatalogAccessLevel -ApiUrl $ApiUrl -Organization $Organization -Repository $name) -cne 'enterprise') {
        $null = Invoke-CatalogApi -ApiUrl $ApiUrl -Method PUT -Path "/repos/$Organization/$name/actions/permissions/access" `
            -Body @{ access_level = 'enterprise' } -AcceptStatus @(204)
    }
}

function New-CatalogReleaseTag {
    <#
    .SYNOPSIS
    Tags an approved import commit of the vendored copy with the upstream tag. An existing tag is never moved.
    .DESCRIPTION
    The repository must be governed before a new tag is published: the approval rule, CODEOWNERS and the security team
    make main the reviewed branch that the release check relies on. Main is read once and read again before the tag, so a
    push between the check and the tag fails the run instead of tagging a commit that main no longer contains.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Upstream,
        [Parameter(Mandatory)][string] $SecurityTeam,
        [Parameter(Mandatory)][string] $Tag,
        [Parameter(Mandatory)][string] $Commit
    )

    Assert-CatalogInput -Organization $Organization -Upstream $Upstream -SecurityTeam $SecurityTeam -Tag $Tag -Commit $Commit
    $name = Get-CatalogRepositoryName -Upstream $Upstream
    $existing = Get-CatalogTag -ApiUrl $ApiUrl -Organization $Organization -Repository $name -Tag $Tag
    if ($null -eq $existing) {
        $governance = Get-CatalogRepositoryState -ApiUrl $ApiUrl -Organization $Organization -Upstream $Upstream -SecurityTeam $SecurityTeam
        $reasons = @(Get-CatalogStateViolation -State $governance -Organization $Organization -SecurityTeam $SecurityTeam)
        if ($reasons.Count) { throw ((@('Repository is not governed;') + $reasons) -join ' ') }
        $main = $governance['mainSha']
        $reasons = @(Test-CatalogReleaseCommit -ApiUrl $ApiUrl -Organization $Organization -Repository $name -Upstream $Upstream -Tag $Tag -Commit $Commit -Main $main)
        if ($reasons.Count) { throw ($reasons -join ' ') }
        if ((Get-CatalogBranchSha -ApiUrl $ApiUrl -Organization $Organization -Repository $name) -cne $main) {
            throw "Main of '$Organization/$name' changed during the release check; run the release again."
        }
        $reply = Invoke-CatalogApi -ApiUrl $ApiUrl -Method POST -Path "/repos/$Organization/$name/git/refs" -AcceptStatus @(201, 422) `
            -Body @{ ref = "refs/tags/$Tag"; sha = $Commit }
        if ($reply.Status -eq 201) { return }
        # 422 follows a tag created by a run whose response was lost; the check below refuses any other tag.
        $existing = Get-CatalogTag -ApiUrl $ApiUrl -Organization $Organization -Repository $name -Tag $Tag
        if ($null -eq $existing) { throw "GitHub refused tag '$Tag' in '$Organization/$name'." }
    }
    if ($existing['Type'] -cne 'commit' -or $existing['Sha'] -cne $Commit) {
        throw "Tag '$Tag' in '$Organization/$name' already points to another object; the module never moves a tag."
    }
}

Export-ModuleMember -Function Assert-CatalogInput, Get-CatalogRepositoryName, Get-CatalogCodeOwners, Invoke-CatalogApi, Get-CatalogFile, Test-CatalogRepositoryAdoptable,
Test-CatalogApprovalRule, Test-CatalogReleaseCommit, Get-CatalogRepositoryState, Get-CatalogStateViolation, ConvertTo-CatalogStateResult,
Initialize-CatalogRepository, New-CatalogReleaseTag
