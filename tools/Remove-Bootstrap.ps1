#Requires -Version 7.4
<#
.SYNOPSIS
Removes the bootstrap resources of a platform instance after a successful teardown workflow run.

.DESCRIPTION
Deletes the instance repository, the platform organization, the Azure role assignments and Entra directory
roles of the module identities, the state lock and the bootstrap resource group. Every step is recorded in the
GitHub bootstrap inventory before its first remote change, so an interrupted run resumes with the same inventory.
GitHub Apps and their private keys are reported as manual steps.
#>
[CmdletBinding(SupportsShouldProcess, ConfirmImpact = 'High')]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [Parameter(Mandatory)][string] $InventoryPath,
    [Parameter(Mandatory)][string] $ConfirmInstanceName,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [scriptblock] $RequestPolicy,
    [ValidateRange(1, 1000)][int] $DeletionPollCount = 60
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')

$requestPolicyHook = $RequestPolicy
$deletionPolls = $DeletionPollCount
$stepOrder = @('repository', 'organization', 'identity-role-assignments', 'directory-roles', 'state-lock', 'resource-group')
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
$instanceName = $instance['instance']['name']
if ($ConfirmInstanceName -cne $instanceName) {
    throw "Bootstrap removal requires -ConfirmInstanceName '$instanceName'."
}
if (-not $instance.Contains('bootstrap')) { throw 'Bootstrap removal requires $.bootstrap connection identifiers.' }
$connection = $instance['bootstrap']
if ($connection['githubHost'] -cne "$($connection['enterprise']).ghe.com") {
    throw '$.bootstrap.githubHost must match $.bootstrap.enterprise on GHE.com.'
}
if ($connection['managementSubscriptionId'] -notin $connection['subscriptionIds']) {
    throw '$.bootstrap.subscriptionIds must include $.bootstrap.managementSubscriptionId.'
}

$inventoryFile = [IO.Path]::GetFullPath($InventoryPath)
$sourceRoot = (Split-Path $PSScriptRoot -Parent).TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
if ($inventoryFile.StartsWith($sourceRoot, [StringComparison]::OrdinalIgnoreCase)) {
    throw 'The bootstrap inventory must be outside the source checkout.'
}
if (-not (Test-Path -LiteralPath $inventoryFile -PathType Leaf)) {
    throw "Bootstrap inventory '$inventoryFile' does not exist. Use the inventory recorded by the GitHub bootstrap."
}
try {
    $inventory = Get-Content -LiteralPath $inventoryFile -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
}
catch { throw "Bootstrap inventory '$inventoryFile' is not valid JSON: $($_.Exception.Message)" }
if ($inventory -isnot [System.Collections.IDictionary]) { throw 'The bootstrap inventory is not a JSON object.' }
if ($inventory.Contains('deploymentIdentifier')) {
    try {
        $organization = Get-PlatformOrganizationName -InstanceName $instanceName `
            -DeploymentIdentifier ([string] $inventory['deploymentIdentifier']) -Kind platform
    }
    catch { throw "The bootstrap inventory has an invalid deployment identifier. $($_.Exception.Message)" }
}
else {
    # Inventories recorded before deployment identifiers keep their original organization name.
    $organization = "$instanceName-platform"
}
$repository = "$organization/instance"
if ($inventory['repository'] -cne $repository -or $inventory['enterprise'] -cne $connection['enterprise']) {
    throw 'The bootstrap inventory belongs to another instance.'
}
$resources = @(if ($inventory.Contains('resources')) { $inventory['resources'] })
if ($resources | Where-Object { $_ -isnot [string] }) { throw 'The bootstrap inventory has an invalid resources list.' }

if (-not $inventory.Contains('removal')) { $inventory['removal'] = @{ steps = @{}; completed = $false } }
$removal = $inventory['removal']
if ($removal -isnot [System.Collections.IDictionary] -or $removal['steps'] -isnot [System.Collections.IDictionary] -or
    $removal['completed'] -isnot [bool]) {
    throw 'The bootstrap inventory has an invalid removal record.'
}
foreach ($key in $removal['steps'].Keys) {
    if ($key -cnotin $stepOrder -or $removal['steps'][$key] -cnotin @('started', 'done')) {
        throw "The bootstrap inventory has an invalid removal step '$key'."
    }
}
if ($removal.Contains('githubUserId') -and (($removal['githubUserId'] -isnot [long] -and $removal['githubUserId'] -isnot [int]) -or
        $removal['githubUserId'] -le 0)) {
    throw 'The bootstrap inventory has an invalid removal record.'
}
if ($removal.Contains('azurePrincipals') -and ($removal['azurePrincipals'] -isnot [System.Collections.IList] -or
        @($removal['azurePrincipals'] | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[0-9a-f-]{36}$' }).Count -gt 0)) {
    throw 'The bootstrap inventory has an invalid removal record.'
}

function Save-RemovalInventory {
    [CmdletBinding()]
    param()

    $content = (ConvertTo-PlatformCanonicalJson $inventory) + "`n"
    $temporary = "$inventoryFile.tmp"
    [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $inventoryFile, $true)
}

function Get-RemovalStepState {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Step)

    if ($removal['steps'].Contains($Step)) { return $removal['steps'][$Step] }
    return 'pending'
}

function Write-RemovalStepState {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Step,
        [Parameter(Mandatory)][ValidateSet('started', 'done')][string] $State
    )

    # The outer confirmation covers the whole removal; a separate prompt here could skip the recovery intent of a deletion.
    $removal['steps'][$Step] = $State
    Save-RemovalInventory
}

function Get-RemovalManualStep {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $appIds = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    if ($inventory['declaredApps'] -is [System.Collections.IDictionary]) {
        foreach ($app in $inventory['declaredApps'].Values) {
            foreach ($id in @($app['appId']) + @($app['previousAppIds'])) { if ($id) { $null = $appIds.Add([string] $id) } }
        }
    }
    if ($inventory['apps'] -is [System.Collections.IDictionary]) {
        foreach ($app in $inventory['apps'].Values) { if ($app['appId']) { $null = $appIds.Add([string] $app['appId']) } }
    }
    foreach ($id in $appIds) {
        "Delete GitHub App $id in its owner settings on https://$($connection['githubHost']); GitHub has no API that deletes an App."
    }
    'Delete the local private key files and key manifest of these GitHub Apps.'
    "Delete or archive the inventory '$inventoryFile'. A new deployment requires a new inventory; GHE.com keeps deleted organization names."
    'Keep the direct Enterprise Owner app role assignment; the next bootstrap requires it before the first emu-identity apply.'
}

if ($removal['completed']) {
    Write-Warning 'The bootstrap inventory records a completed removal; no request was sent.'
    return [pscustomobject]@{ Completed = $true; Steps = $removal['steps']; ManualSteps = @(Get-RemovalManualStep) }
}

$githubApi = "api.$($connection['githubHost'])"
$arm = 'https://management.azure.com'
$graph = 'https://graph.microsoft.com/v1.0'
$tokens = @{}
foreach ($variable in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
    if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($variable))) {
        throw "Bootstrap removal refuses $variable. Use the stored OAuth login from gh auth login."
    }
}
$githubToken = (& gh auth token --hostname $connection['githubHost'] 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $githubToken -cnotmatch '^gho_[A-Za-z0-9_]+$') {
    throw "Bootstrap removal requires an OAuth token from gh auth login --hostname $($connection['githubHost']); PATs are not supported."
}
$tokens[$githubApi] = $githubToken
foreach ($resource in @('https://management.azure.com/', 'https://graph.microsoft.com/')) {
    $text = & az account get-access-token --tenant $connection['tenantId'] --resource $resource --output json --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Azure authentication failed for '$resource'. Run az login --tenant $($connection['tenantId']) with a platform team user."
    }
    try { $token = ConvertFrom-Json -InputObject $text -AsHashtable -ErrorAction Stop }
    catch { throw "Azure CLI returned an unreadable token for '$resource'." }
    if ($token -isnot [System.Collections.IDictionary] -or $token['tenant'] -ne $connection['tenantId'] -or
        $token['accessToken'] -isnot [string] -or [string]::IsNullOrWhiteSpace($token['accessToken'])) {
        throw "Azure token does not belong to $.bootstrap.tenantId for '$resource'."
    }
    $tokens[([uri] $resource).Host] = $token['accessToken']
}

function Invoke-RemovalRequest {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('GET', 'PUT', 'DELETE')][string] $Method = 'GET',
        [System.Collections.IDictionary] $Body,
        [switch] $AllowNotFound,
        [int[]] $ExpectedStatus = @(200),
        [System.Collections.IDictionary] $ResponseHeaders
    )

    $address = [uri] $Uri
    if ($address.Scheme -ne 'https' -or -not $tokens.ContainsKey($address.Host) -or -not $address.IsDefaultPort -or
        $address.UserInfo -or $address.Fragment) {
        throw "Untrusted bootstrap removal API address '$Uri'."
    }
    $headers = @{ Authorization = 'Bearer ' + $tokens[$address.Host]; Accept = 'application/json' }
    if ($address.Host -ceq $githubApi) {
        $headers.Accept = 'application/vnd.github+json'
        $headers['X-GitHub-Api-Version'] = '2026-03-10'
    }
    $arguments = @{
        Uri = $Uri; Method = $Method; Headers = $headers; SkipHttpErrorCheck = $true
        MaximumRedirection = 0; TimeoutSec = 60; MaximumRetryCount = 0
    }
    if ($Body) {
        $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 10 -Compress
        $arguments.ContentType = 'application/json'
    }
    $kind = if ($Method -ceq 'GET') { 'Read' } else { 'Reconcile' }
    for ($attempt = 1; ; $attempt++) {
        Assert-PlatformBootstrapRequest -Uri $Uri -Method $Method -Body $Body -Kind $kind -RequestPolicy $requestPolicyHook
        $response = Invoke-WebRequest @arguments
        if ($response.StatusCode -in @(429, 503) -and $attempt -lt 6) {
            Write-Verbose "Retrying $Method '$Uri' after HTTP $($response.StatusCode)."
            Start-Sleep -Seconds 5
            continue
        }
        break
    }
    if ($null -ne $ResponseHeaders -and $null -ne $response.Headers) {
        foreach ($name in $response.Headers.Keys) { $ResponseHeaders[$name] = @($response.Headers[$name]) -join ',' }
    }
    if ($response.StatusCode -eq 404 -and $AllowNotFound) { return $null }
    if ($response.StatusCode -notin $ExpectedStatus) {
        throw "Bootstrap removal $Method '$Uri' failed (HTTP $($response.StatusCode)): $($response.Content). Correct the cause and rerun with the same inventory."
    }
    if ($Method -cne 'GET' -or [string]::IsNullOrWhiteSpace($response.Content)) {
        if ($Method -ceq 'GET') { throw "Bootstrap removal GET '$Uri' returned an empty body." }
        return @{}
    }
    try { $data = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop }
    catch { throw "Bootstrap removal GET '$Uri' returned invalid JSON: $($_.Exception.Message)" }
    if ($data -isnot [System.Collections.IDictionary]) { throw "Bootstrap removal GET '$Uri' did not return a JSON object." }
    return $data
}

function Get-RemovalCollection {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Uri)

    $visited = [System.Collections.Generic.HashSet[string]]::new()
    while ($Uri) {
        if (-not $visited.Add($Uri)) { throw "API pagination cycle at '$Uri'." }
        $page = Invoke-RemovalRequest -Uri $Uri
        if ($page['value'] -isnot [System.Collections.IList]) { throw "API '$Uri' did not return a collection." }
        foreach ($item in $page['value']) {
            if ($item -isnot [System.Collections.IDictionary]) { throw "API '$Uri' returned an invalid collection item." }
            $item
        }
        $Uri = if ($page.Contains('@odata.nextLink')) { $page['@odata.nextLink'] } elseif ($page.Contains('nextLink')) { $page['nextLink'] } else { $null }
    }
}

function Get-RemovalWorkflowRun {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Workflow)

    $runs = Invoke-RemovalRequest -Uri "https://$githubApi/repos/$repository/actions/workflows/$Workflow/runs?branch=main&per_page=1"
    if ($runs['total_count'] -isnot [long] -and $runs['total_count'] -isnot [int]) { throw "GitHub did not return a run count for $Workflow." }
    if ($runs['workflow_runs'] -isnot [System.Collections.IList]) { throw "GitHub did not return runs of $Workflow." }
    if ($runs['total_count'] -eq 0) { return $null }
    if ($runs['workflow_runs'].Count -ne 1) { throw "GitHub returned an inconsistent run list for $Workflow." }
    $run = $runs['workflow_runs'][0]
    if ($run -isnot [System.Collections.IDictionary] -or $run['created_at'] -isnot [datetime] -or
        $run['path'] -isnot [string] -or -not $run['path'].StartsWith(".github/workflows/$Workflow", [StringComparison]::Ordinal)) {
        throw "GitHub returned an invalid run of $Workflow."
    }
    return $run
}

function Assert-RemovalPreflight {
    [CmdletBinding()]
    param()

    foreach ($status in @('in_progress', 'queued', 'requested', 'waiting', 'pending')) {
        $active = Invoke-RemovalRequest -Uri "https://$githubApi/repos/$repository/actions/runs?status=$status&per_page=1"
        if (($active['total_count'] -isnot [long] -and $active['total_count'] -isnot [int]) -or $active['total_count'] -ne 0) {
            throw "Workflow runs with status '$status' are not finished in '$repository'. Wait until all runs finish, then rerun."
        }
    }
    $teardown = Get-RemovalWorkflowRun -Workflow 'teardown.yml'
    if (-not $teardown -or $teardown['head_branch'] -cne 'main' -or $teardown['status'] -cne 'completed' -or
        $teardown['conclusion'] -cne 'success') {
        throw "The latest teardown workflow run on main in '$repository' did not succeed. Run the teardown workflow before removing bootstrap."
    }
    if ($teardown['run_started_at'] -isnot [datetime]) {
        throw "GitHub did not return the start time of the latest teardown attempt in '$repository'."
    }
    # A rerun keeps created_at of the original run, so every deploy run on any branch is compared by updated_at.
    $listedDeployRuns = 0
    for ($page = 1; ; $page++) {
        if ($page -gt 10) { throw "The deploy workflow in '$repository' has more than 1000 runs; verify the teardown evidence manually." }
        $runs = Invoke-RemovalRequest -Uri "https://$githubApi/repos/$repository/actions/workflows/deploy.yml/runs?per_page=100&page=$page"
        if (($runs['total_count'] -isnot [long] -and $runs['total_count'] -isnot [int]) -or $runs['workflow_runs'] -isnot [System.Collections.IList]) {
            throw "GitHub returned an invalid run list for deploy.yml."
        }
        foreach ($deploy in $runs['workflow_runs']) {
            if ($deploy -isnot [System.Collections.IDictionary] -or $deploy['updated_at'] -isnot [datetime]) {
                throw "GitHub returned an invalid run of deploy.yml."
            }
            if ($deploy['updated_at'] -ge $teardown['run_started_at']) {
                throw "A deploy workflow run changed after the latest successful teardown started in '$repository'. Run the teardown workflow again."
            }
        }
        $listedDeployRuns += $runs['workflow_runs'].Count
        if ($listedDeployRuns -ge $runs['total_count'] -or $runs['workflow_runs'].Count -eq 0) {
            if ($listedDeployRuns -lt $runs['total_count']) { throw "GitHub returned an incomplete run list for deploy.yml." }
            break
        }
    }
}

function Disable-RemovalActionExecution {
    [CmdletBinding()]
    param()

    # Disabled Actions survive an interrupted run, so no workflow can start between the final checks and the deletion.
    $uri = "https://$githubApi/repos/$repository/actions/permissions"
    $permissions = Invoke-RemovalRequest -Uri $uri
    if ($permissions['enabled'] -isnot [bool]) { throw "GitHub did not return the Actions permissions of '$repository'." }
    if ($permissions['enabled']) {
        $null = Invoke-RemovalRequest -Uri $uri -Method PUT -Body @{ enabled = $false } -ExpectedStatus 204
        $permissions = Invoke-RemovalRequest -Uri $uri
        if ($permissions['enabled'] -isnot [bool] -or $permissions['enabled']) {
            throw "GitHub did not confirm that Actions are disabled in '$repository'."
        }
    }
}

function Assert-RemovalUnrecordedResource {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Name
    )

    # The GitHub bootstrap creates a resource before it records it; an interruption between them leaves it unrecorded.
    if (Invoke-RemovalRequest -Uri $Uri -AllowNotFound) {
        throw "$Name exists although the bootstrap inventory does not record it. Rerun the GitHub bootstrap with the same inventory to record it, or verify its ownership and delete it manually."
    }
}

function Invoke-RepositoryRemoval {
    [CmdletBinding()]
    param()

    $state = Get-RemovalStepState -Step 'repository'
    if ($state -ceq 'done') { return }
    if ("/repos/$repository" -cnotin $resources) {
        Assert-RemovalUnrecordedResource -Uri "https://$githubApi/repos/$repository" -Name "Repository '$repository'"
        Write-RemovalStepState -Step 'repository' -State 'done'
        return
    }
    $repo = Invoke-RemovalRequest -Uri "https://$githubApi/repos/$repository" -AllowNotFound
    if (-not $repo) {
        if ($state -cne 'started') {
            throw "Repository '$repository' is missing although this inventory never started its removal. Verify the inventory and the teardown evidence manually."
        }
        Write-RemovalStepState -Step 'repository' -State 'done'
        return
    }
    $ownership = "Platform instance $instanceName; bootstrap-owned."
    if ($repo['full_name'] -cne $repository -or $repo['owner'] -isnot [System.Collections.IDictionary] -or
        $repo['owner']['login'] -cne $organization -or $repo['private'] -isnot [bool] -or -not $repo['private'] -or
        $repo['description'] -cne $ownership) {
        throw "Repository '$repository' is not the private bootstrap-owned instance repository; refusing to delete it."
    }
    # A failed check before the first change leaves Actions enabled, so the teardown workflow can run again.
    if ($state -cne 'started') { Assert-RemovalPreflight }
    Write-RemovalStepState -Step 'repository' -State 'started'
    Disable-RemovalActionExecution
    try { Assert-RemovalPreflight }
    catch {
        throw "$($_.Exception.Message) Actions in '$repository' stay disabled; enable them before you run the teardown workflow again."
    }
    $null = Invoke-RemovalRequest -Uri "https://$githubApi/repos/$repository" -Method DELETE -AllowNotFound -ExpectedStatus 204
    Write-RemovalStepState -Step 'repository' -State 'done'
}

function Invoke-OrganizationRemoval {
    [CmdletBinding()]
    param()

    $state = Get-RemovalStepState -Step 'organization'
    if ($state -ceq 'done') { return }
    if ("/orgs/$organization" -cnotin $resources) {
        Assert-RemovalUnrecordedResource -Uri "https://$githubApi/orgs/$organization" -Name "Organization '$organization'"
        Write-RemovalStepState -Step 'organization' -State 'done'
        return
    }
    $org = Invoke-RemovalRequest -Uri "https://$githubApi/orgs/$organization" -AllowNotFound
    if (-not $org) {
        if ($state -cne 'started') {
            throw "Organization '$organization' is missing although this inventory never started its removal. Verify the inventory manually."
        }
        Write-RemovalStepState -Step 'organization' -State 'done'
        return
    }
    if ($org['login'] -cne $organization) {
        throw "GitHub returned organization '$($org['login'])' for '$organization'; refusing to delete it."
    }
    Write-RemovalStepState -Step 'organization' -State 'started'
    $null = Invoke-RemovalRequest -Uri "https://$githubApi/orgs/$organization" -Method DELETE -AllowNotFound -ExpectedStatus 202
    # GitHub deletes the organization asynchronously; the step stays started until it disappears.
    $deleted = $false
    for ($poll = 0; $poll -lt $deletionPolls; $poll++) {
        $org = Invoke-RemovalRequest -Uri "https://$githubApi/orgs/$organization" -AllowNotFound
        if (-not $org) { $deleted = $true; break }
        if ($org['login'] -cne $organization) {
            throw "GitHub returned organization '$($org['login'])' for '$organization' during its deletion."
        }
        Start-Sleep -Seconds 10
    }
    if (-not $deleted) {
        throw "Organization '$organization' is still being deleted. Rerun with the same inventory to continue."
    }
    Write-RemovalStepState -Step 'organization' -State 'done'
}

$resourceGroupName = "rg-$instanceName-bootstrap"
$resourceGroupId = "/subscriptions/$($connection['managementSubscriptionId'])/resourceGroups/$resourceGroupName"
$storageAccountId = "$resourceGroupId/providers/Microsoft.Storage/storageAccounts/st$($instanceName)tfstate"
$tags = [ordered]@{ platformInstance = $instanceName; platformComponent = 'bootstrap' }

function Get-RemovalResourceGroup {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param()

    $group = Invoke-RemovalRequest -Uri "$arm$resourceGroupId`?api-version=2021-04-01" -AllowNotFound
    if (-not $group) { return $null }
    if ($group['id'] -ne $resourceGroupId -or $group['tags'] -isnot [System.Collections.IDictionary]) {
        throw "Resource group '$resourceGroupName' does not carry the bootstrap ownership tags; refusing to delete it."
    }
    foreach ($key in $tags.Keys) {
        if (-not $group['tags'].Contains($key) -or $group['tags'][$key] -cne $tags[$key]) {
            throw "Resource group '$resourceGroupName' does not carry the bootstrap ownership tags; refusing to delete it."
        }
    }
    return $group
}

function Get-RemovalIdentityPrincipal {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $identities = @(Get-RemovalCollection -Uri "$arm$resourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities?api-version=2023-01-31")
    foreach ($identity in $identities) {
        $identityTags = $identity['tags']
        $properties = $identity['properties']
        if ($identityTags -isnot [System.Collections.IDictionary] -or $identityTags['platformInstance'] -cne $instanceName -or
            $identityTags['platformComponent'] -cne 'bootstrap' -or $identityTags['platformModule'] -isnot [string] -or
            $identityTags['platformPhase'] -cnotin @('plan', 'apply') -or
            $identity['name'] -cne "id-$instanceName-$($identityTags['platformModule'])-$($identityTags['platformPhase'])") {
            throw "Managed identity '$($identity['id'])' does not carry the bootstrap ownership tags; refusing to remove its access."
        }
        if ($properties -isnot [System.Collections.IDictionary] -or $properties['tenantId'] -ne $connection['tenantId'] -or
            $properties['principalId'] -isnot [string] -or $properties['principalId'] -notmatch '^[0-9a-fA-F-]{36}$') {
            throw "Managed identity '$($identity['id'])' has no usable principal in $.bootstrap.tenantId."
        }
        $properties['principalId'].ToLowerInvariant()
    }
}

function Assert-RemovalAzureGeneration {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [switch] $Record,
        [switch] $AllowPartial
    )

    # Managed identities get a new principal ID when a deployment recreates them, so their set binds Azure resources to this inventory.
    $principals = @(Get-RemovalIdentityPrincipal | Sort-Object -Unique)
    if (-not $removal.Contains('azurePrincipals')) {
        if (-not $Record) {
            throw "The inventory does not record the managed identities of resource group '$resourceGroupName'; refusing to delete resources it cannot bind to this deployment."
        }
        $removal['azurePrincipals'] = $principals
        Save-RemovalInventory
        return $principals
    }
    $recorded = @($removal['azurePrincipals'])
    $foreign = @($principals | Where-Object { $_ -cnotin $recorded })
    if ($foreign.Count -gt 0 -or (-not $AllowPartial -and $principals.Count -ne $recorded.Count)) {
        throw "The managed identities in resource group '$resourceGroupName' differ from those this inventory recorded; another deployment may have replaced it. Verify the resources manually."
    }
    return $principals
}

function Invoke-IdentityRoleAssignmentRemoval {
    [CmdletBinding()]
    param()

    $state = Get-RemovalStepState -Step 'identity-role-assignments'
    if ($state -ceq 'done') { return }
    if (-not (Get-RemovalResourceGroup)) {
        if ((Get-RemovalStepState -Step 'resource-group') -cne 'pending') {
            Write-RemovalStepState -Step 'identity-role-assignments' -State 'done'
            return
        }
        throw "Resource group '$resourceGroupName' is missing before the role assignments of module identities were removed. Remove orphaned role assignments manually."
    }
    $principals = Assert-RemovalAzureGeneration
    $scopes = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($subscriptionId in $connection['subscriptionIds']) { $null = $scopes.Add("/subscriptions/$subscriptionId") }
    foreach ($module in $modules.Values) {
        foreach ($grant in @($module['permissions']['azure'])) {
            if ($grant -is [System.Collections.IDictionary] -and $grant['scope'] -like '/providers/Microsoft.Management/managementGroups/*') {
                $null = $scopes.Add($grant['scope'].TrimEnd('/'))
            }
        }
    }
    if (@($principals).Count -gt 0) { Write-RemovalStepState -Step 'identity-role-assignments' -State 'started' }
    $removed = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($principalId in $principals) {
        $filter = [uri]::EscapeDataString("principalId eq '$principalId'")
        foreach ($scope in $scopes) {
            foreach ($assignment in @(Get-RemovalCollection -Uri "$arm$scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=$filter")) {
                if ($assignment['id'] -isnot [string] -or $assignment['properties'] -isnot [System.Collections.IDictionary] -or
                    $assignment['properties']['principalId'] -ne $principalId -or $assignment['properties']['scope'] -isnot [string] -or
                    $assignment['id'] -notmatch '/providers/Microsoft\.Authorization/roleAssignments/[^/]+$') {
                    throw "Azure returned role assignment '$($assignment['id'])' that does not belong to principal '$principalId'."
                }
                $assignmentScope = $assignment['properties']['scope']
                if ($assignmentScope -eq $resourceGroupId -or $assignmentScope.StartsWith("$resourceGroupId/", [StringComparison]::OrdinalIgnoreCase)) {
                    continue
                }
                if ($removed.Add($assignment['id'])) {
                    $null = Invoke-RemovalRequest -Uri "$arm$($assignment['id'])?api-version=2022-04-01" -Method DELETE -AllowNotFound -ExpectedStatus 200, 204
                }
            }
        }
    }
    Write-RemovalStepState -Step 'identity-role-assignments' -State 'done'
}

function Invoke-DirectoryRoleRemoval {
    [CmdletBinding()]
    param()

    if ((Get-RemovalStepState -Step 'directory-roles') -ceq 'done') { return }
    if (Get-RemovalResourceGroup) { $null = Assert-RemovalAzureGeneration }
    $definitions = foreach ($name in @($modules.Keys | Sort-Object)) {
        foreach ($phase in @('plan', 'apply')) {
            $displayName = "platform-$instanceName-$name-$phase"
            $filter = [uri]::EscapeDataString("displayName eq '$displayName'")
            $found = @(Get-RemovalCollection -Uri "$graph/roleManagement/directory/roleDefinitions?`$filter=$filter")
            if ($found.Count -gt 1) { throw "Entra directory role '$displayName' is ambiguous; refusing to delete it." }
            if ($found.Count -eq 1) {
                $definition = $found[0]
                $description = "Platform module $name ($phase) on the EMU enterprise application. Managed by bootstrap."
                if ($definition['displayName'] -cne $displayName -or $definition['isBuiltIn'] -isnot [bool] -or $definition['isBuiltIn'] -or
                    $definition['description'] -cne $description -or $definition['id'] -isnot [string] -or
                    $definition['id'] -notmatch '^[0-9a-fA-F-]{36}$') {
                    throw "Entra directory role '$displayName' is not a bootstrap-owned custom role; refusing to delete it."
                }
                $definition
            }
        }
    }
    if (@($definitions).Count -gt 0) { Write-RemovalStepState -Step 'directory-roles' -State 'started' }
    foreach ($definition in $definitions) {
        $filter = [uri]::EscapeDataString("roleDefinitionId eq '$($definition['id'])'")
        foreach ($assignment in @(Get-RemovalCollection -Uri "$graph/roleManagement/directory/roleAssignments?`$filter=$filter")) {
            if ($assignment['roleDefinitionId'] -ne $definition['id'] -or $assignment['id'] -isnot [string] -or
                [string]::IsNullOrWhiteSpace($assignment['id']) -or $assignment['id'] -match '[/?#]') {
                throw "Microsoft Graph returned a role assignment that does not belong to Entra directory role '$($definition['displayName'])'."
            }
            $null = Invoke-RemovalRequest -Uri "$graph/roleManagement/directory/roleAssignments/$($assignment['id'])" -Method DELETE -AllowNotFound -ExpectedStatus 204
        }
        $null = Invoke-RemovalRequest -Uri "$graph/roleManagement/directory/roleDefinitions/$($definition['id'])" -Method DELETE -AllowNotFound -ExpectedStatus 204
    }
    Write-RemovalStepState -Step 'directory-roles' -State 'done'
}

function Invoke-StateLockRemoval {
    [CmdletBinding()]
    param()

    if ((Get-RemovalStepState -Step 'state-lock') -ceq 'done') { return }
    if (Get-RemovalResourceGroup) {
        $null = Assert-RemovalAzureGeneration
        Write-RemovalStepState -Step 'state-lock' -State 'started'
        $null = Invoke-RemovalRequest -Uri "$arm$storageAccountId/providers/Microsoft.Authorization/locks/lock-state?api-version=2016-09-01" `
            -Method DELETE -AllowNotFound -ExpectedStatus 200, 204
    }
    elseif ((Get-RemovalStepState -Step 'resource-group') -ceq 'pending') {
        throw "Resource group '$resourceGroupName' is missing although this inventory never started its removal. Verify the state backend manually."
    }
    Write-RemovalStepState -Step 'state-lock' -State 'done'
}

function Invoke-ResourceGroupRemoval {
    [CmdletBinding()]
    param()

    if ((Get-RemovalStepState -Step 'resource-group') -ceq 'done') { return }
    if (Get-RemovalResourceGroup) {
        $null = Assert-RemovalAzureGeneration -AllowPartial:((Get-RemovalStepState -Step 'resource-group') -ceq 'started')
        Write-RemovalStepState -Step 'resource-group' -State 'started'
        $null = Invoke-RemovalRequest -Uri "$arm$resourceGroupId`?api-version=2021-04-01" -Method DELETE -AllowNotFound -ExpectedStatus 200, 202
        $deleted = $false
        for ($poll = 0; $poll -lt $deletionPolls; $poll++) {
            if (-not (Get-RemovalResourceGroup)) { $deleted = $true; break }
            Start-Sleep -Seconds 10
        }
        if (-not $deleted) {
            throw "Resource group '$resourceGroupName' is still being deleted. Rerun with the same inventory to continue."
        }
    }
    elseif ((Get-RemovalStepState -Step 'resource-group') -ceq 'pending') {
        throw "Resource group '$resourceGroupName' is missing although this inventory never started its removal. Verify the state backend manually."
    }
    Write-RemovalStepState -Step 'resource-group' -State 'done'
}

if (-not $PSCmdlet.ShouldProcess("platform instance '$instanceName' ($repository, $resourceGroupId)", 'Remove bootstrap resources')) {
    return
}
# GitHub hides resources from users without access, so a 404 counts as deletion evidence only for the user that started the removal.
$githubUserHeaders = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
$githubUser = Invoke-RemovalRequest -Uri "https://$githubApi/user" -ResponseHeaders $githubUserHeaders
if (($githubUser['id'] -isnot [long] -and $githubUser['id'] -isnot [int]) -or $githubUser['id'] -le 0 -or
    $githubUser['login'] -isnot [string] -or [string]::IsNullOrWhiteSpace($githubUser['login'])) {
    throw 'GitHub did not return the authenticated user.'
}
# Repository deletion needs delete_repo; check it before Actions are disabled so a missing scope cannot strand the instance.
$githubScopes = if ($githubUserHeaders.ContainsKey('X-OAuth-Scopes')) { @($githubUserHeaders['X-OAuth-Scopes'] -split ',' | ForEach-Object { $_.Trim() }) } else { @() }
if ($githubScopes -cnotcontains 'delete_repo') {
    throw "The GitHub OAuth token lacks the delete_repo scope required to delete the instance repository. Run gh auth refresh --hostname $($connection['githubHost']) --scopes delete_repo and rerun."
}
if ($removal['steps'].Count -gt 0) {
    if (-not $removal.Contains('githubUserId')) {
        throw 'The bootstrap inventory does not record the GitHub user that started the removal; verify the remaining resources manually.'
    }
    if ($removal['githubUserId'] -ne $githubUser['id']) {
        throw "Bootstrap removal started with GitHub user ID $($removal['githubUserId']), not with '$($githubUser['login'])'. Sign in with gh auth login as that user and rerun."
    }
}
else {
    # Bind the user and the Azure resources before the first deletion; a later first binding could adopt a replacement deployment.
    $removal['githubUserId'] = [long] $githubUser['id']
    Save-RemovalInventory
    if (Get-RemovalResourceGroup) { $null = Assert-RemovalAzureGeneration -Record }
}
Invoke-RepositoryRemoval
Invoke-OrganizationRemoval
Invoke-IdentityRoleAssignmentRemoval
Invoke-DirectoryRoleRemoval
Invoke-StateLockRemoval
Invoke-ResourceGroupRemoval
$removal['completed'] = $true
Save-RemovalInventory

[pscustomobject]@{ Completed = $true; Steps = $removal['steps']; ManualSteps = @(Get-RemovalManualStep) }
