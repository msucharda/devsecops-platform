Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
. (Join-Path $PSScriptRoot '../../shared/scripts/GitHubRetry.ps1')

# Endpoints, API version 2026-03-10:
# https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#get-github-actions-permissions-for-an-organization
# https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#set-github-actions-permissions-for-an-organization
# https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#get-default-workflow-permissions-for-an-organization
# https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#set-default-workflow-permissions-for-an-organization

$script:ApiVersion = '2026-03-10'
# Documented enums of the managed fields.
$script:EnabledRepositories = @('all', 'none', 'selected')
$script:AllowedActions = @('all', 'local_only', 'selected')
$script:WorkflowPermissions = @('read', 'write')

function Assert-ActionsPolicyApiUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl)

    $uri = $null
    if (-not [Uri]::TryCreate($ApiUrl, [UriKind]::Absolute, [ref] $uri) -or $uri.AbsolutePath -cne '/' -or $uri.Query -or
        $uri.UserInfo -or -not ($uri.Scheme -ceq 'https' -or ($uri.Scheme -ceq 'http' -and $uri.IsLoopback))) {
        throw "The GitHub API URL '$ApiUrl' must be an HTTPS origin; plain HTTP is only accepted for a loopback test stub."
    }
}

function Assert-ActionsPolicyOrganization {
    [CmdletBinding()]
    param([AllowNull()][object] $Organization)

    if ($Organization -isnot [string] -or $Organization -cnotmatch '^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$') {
        throw "'$Organization' is not a GitHub organization login."
    }
}

function Invoke-ActionsPolicyApi {
    <#
    .SYNOPSIS
    Sends one GitHub REST request with the job's installation token and returns the parsed JSON body.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][ValidateSet('GET', 'PUT')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][System.Collections.IDictionary] $Body
    )

    Assert-ActionsPolicyApiUrl -ApiUrl $ApiUrl
    if (-not $env:REST_API_BEARER) { throw 'REST_API_BEARER is not set; the runner must export the installation token.' }
    $request = @{
        Uri                = "$($ApiUrl.TrimEnd('/'))$Path"
        Method             = $Method
        Headers            = @{
            Authorization          = "Bearer $env:REST_API_BEARER"
            Accept                 = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = $script:ApiVersion
        }
        SkipHttpErrorCheck = $true
        MaximumRetryCount  = 0
        MaximumRedirection = 0
        TimeoutSec         = 60
    }
    if ($null -ne $Body) {
        $request.Body = ConvertTo-Json -InputObject $Body -Depth 5 -Compress
        $request.ContentType = 'application/json'
    }
    $reply = Invoke-GitHubRetryRequest -Request $request
    $status = [int] $reply.StatusCode
    if ($status -eq 409) {
        throw "GitHub returned HTTP 409 for $Method ${Path}: the enterprise policy prevents the organization setting. Align the enterprise GitHub Actions policy with the module or remove the enterprise restriction."
    }
    if ($status -lt 200 -or $status -gt 299) { throw "GitHub returned HTTP $status for $Method $Path." }
    if ($Method -ceq 'PUT') { return }
    $content = if ($reply.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($reply.Content) } else { [string] $reply.Content }
    if ([string]::IsNullOrWhiteSpace($content)) { throw "GitHub returned an empty successful GET response for $Path." }
    $parsed = ConvertFrom-Json -InputObject $content -AsHashtable -Depth 20 -NoEnumerate
    if ($parsed -isnot [System.Collections.IDictionary]) { throw "GitHub returned no JSON object for GET $Path." }
    return $parsed
}

function ConvertTo-ActionsPolicy {
    <#
    .SYNOPSIS
    Validates a managed policy from Terraform and returns it with a boolean can_approve_pull_request_reviews.
    .DESCRIPTION
    The external data source passes every query value as a string, so 'true' and 'false' are accepted besides booleans.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([AllowNull()][object] $Policy)

    if ($Policy -isnot [System.Collections.IDictionary]) { throw 'The managed actions policy is not an object.' }
    $approve = $Policy['can_approve_pull_request_reviews']
    if ($approve -is [string] -and $approve -cin @('true', 'false')) { $approve = $approve -ceq 'true' }
    if ($Policy['enabled_repositories'] -isnot [string] -or $Policy['enabled_repositories'] -cnotin $script:EnabledRepositories -or
        $Policy['allowed_actions'] -isnot [string] -or $Policy['allowed_actions'] -cnotin $script:AllowedActions -or
        $Policy['default_workflow_permissions'] -isnot [string] -or $Policy['default_workflow_permissions'] -cnotin $script:WorkflowPermissions -or
        $approve -isnot [bool]) {
        throw 'The managed actions policy has a missing or undocumented value.'
    }
    return [ordered]@{
        enabled_repositories             = $Policy['enabled_repositories']
        allowed_actions                  = $Policy['allowed_actions']
        default_workflow_permissions     = $Policy['default_workflow_permissions']
        can_approve_pull_request_reviews = $approve
    }
}

function Get-ActionsPolicyState {
    <#
    .SYNOPSIS
    Reads the GitHub Actions permissions and the default workflow permissions of one organization.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization)

    Assert-ActionsPolicyOrganization -Organization $Organization
    return [ordered]@{
        actions_permissions  = Invoke-ActionsPolicyApi -ApiUrl $ApiUrl -Method GET -Path "/orgs/$Organization/actions/permissions"
        workflow_permissions = Invoke-ActionsPolicyApi -ApiUrl $ApiUrl -Method GET -Path "/orgs/$Organization/actions/permissions/workflow"
    }
}

# security-check: actions-policy-state
function Get-ActionsPolicyStateViolation {
    <#
    .SYNOPSIS
    Returns the reasons why the read state of an organization differs from the managed policy.
    .DESCRIPTION
    A missing, mistyped or undocumented field is a violation, so an unreadable state never passes as compliant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $State,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Policy,
        [Parameter(Mandatory)][string] $Organization
    )

    $actions = $State['actions_permissions']
    $workflow = $State['workflow_permissions']
    if ($actions -isnot [System.Collections.IDictionary] -or $actions['enabled_repositories'] -isnot [string] -or
        $actions['enabled_repositories'] -cne $Policy['enabled_repositories']) {
        "GitHub Actions of $Organization are not enabled for $($Policy['enabled_repositories']) repositories."
    }
    if ($actions -isnot [System.Collections.IDictionary] -or $actions['allowed_actions'] -isnot [string] -or
        $actions['allowed_actions'] -cne $Policy['allowed_actions']) {
        "The allowed actions policy of $Organization is not $($Policy['allowed_actions'])."
    }
    if ($workflow -isnot [System.Collections.IDictionary] -or $workflow['default_workflow_permissions'] -isnot [string] -or
        $workflow['default_workflow_permissions'] -cne $Policy['default_workflow_permissions']) {
        "The default GITHUB_TOKEN permissions of $Organization are not $($Policy['default_workflow_permissions'])."
    }
    if ($workflow -isnot [System.Collections.IDictionary] -or $workflow['can_approve_pull_request_reviews'] -isnot [bool] -or
        $workflow['can_approve_pull_request_reviews'] -ne $Policy['can_approve_pull_request_reviews']) {
        "Whether GitHub Actions of $Organization can create and approve pull requests is not $($Policy['can_approve_pull_request_reviews'].ToString().ToLowerInvariant())."
    }
}

function Set-ActionsPolicy {
    <#
    .SYNOPSIS
    Writes the GitHub Actions permissions and the default workflow permissions of one organization.
    .DESCRIPTION
    Both writes are idempotent PUT requests of the complete managed fields, so a repeated run after an interruption
    converges. A write is skipped when the read value already matches; an enterprise policy that enforces the same value
    then cannot fail the run.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][AllowNull()][object] $Policy
    )

    $managed = ConvertTo-ActionsPolicy -Policy $Policy
    $state = Get-ActionsPolicyState -ApiUrl $ApiUrl -Organization $Organization
    $actions = $state['actions_permissions']
    if ($actions['enabled_repositories'] -cne $managed['enabled_repositories'] -or $actions['allowed_actions'] -cne $managed['allowed_actions']) {
        Invoke-ActionsPolicyApi -ApiUrl $ApiUrl -Method PUT -Path "/orgs/$Organization/actions/permissions" -Body ([ordered]@{
                enabled_repositories = $managed['enabled_repositories']
                allowed_actions      = $managed['allowed_actions']
            })
    }
    $workflow = $state['workflow_permissions']
    if ($workflow['default_workflow_permissions'] -cne $managed['default_workflow_permissions'] -or
        $workflow['can_approve_pull_request_reviews'] -isnot [bool] -or
        $workflow['can_approve_pull_request_reviews'] -ne $managed['can_approve_pull_request_reviews']) {
        Invoke-ActionsPolicyApi -ApiUrl $ApiUrl -Method PUT -Path "/orgs/$Organization/actions/permissions/workflow" -Body ([ordered]@{
                default_workflow_permissions     = $managed['default_workflow_permissions']
                can_approve_pull_request_reviews = $managed['can_approve_pull_request_reviews']
            })
    }
    $violations = @(Get-ActionsPolicyStateViolation -State (Get-ActionsPolicyState -ApiUrl $ApiUrl -Organization $Organization) -Policy $managed -Organization $Organization)
    if ($violations.Count -gt 0) { throw ($violations -join ' ') }
}

function Get-ActionsPolicyStateResult {
    <#
    .SYNOPSIS
    Returns the program output of the external data source: the read state and its violations as JSON strings.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization, [Parameter(Mandatory)][AllowNull()][object] $Policy)

    $managed = ConvertTo-ActionsPolicy -Policy $Policy
    $state = Get-ActionsPolicyState -ApiUrl $ApiUrl -Organization $Organization
    $violations = @(Get-ActionsPolicyStateViolation -State $state -Policy $managed -Organization $Organization)
    return ConvertTo-Json -Compress -InputObject ([ordered]@{
            state      = ConvertTo-Json -InputObject $state -Depth 10 -Compress
            violations = ConvertTo-Json -InputObject $violations -Compress
        })
}

Export-ModuleMember -Function Invoke-ActionsPolicyApi, ConvertTo-ActionsPolicy, Get-ActionsPolicyState, Get-ActionsPolicyStateViolation, Set-ActionsPolicy, Get-ActionsPolicyStateResult
