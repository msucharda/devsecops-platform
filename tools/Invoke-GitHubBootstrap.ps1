#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [Parameter(Mandatory)][object] $AzureBootstrap,
    [string] $ReleasePath = (Split-Path $PSScriptRoot -Parent),
    [Parameter(Mandatory)][ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$')][string] $ReleaseVersion,
    [Parameter(Mandatory)][string] $InventoryPath,
    [string] $AuthorizationApp,
    [string] $AppKeysPath,
    [switch] $AcceptanceOnly,
    [switch] $ResourcesOnly,
    [switch] $NoChanges,
    [scriptblock] $RequestPolicy,
    [scriptblock] $TokenLifecycle,
    [switch] $VerifyTokenRevocation
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
if ($AzureBootstrap -is [pscustomobject]) {
    $AzureBootstrap = ConvertTo-Json -InputObject $AzureBootstrap -Depth 100 | ConvertFrom-Json -AsHashtable
}
if ($AzureBootstrap -isnot [Collections.IDictionary]) { throw '-AzureBootstrap requires the Azure bootstrap result object.' }
$ReleasePath = (Resolve-Path -LiteralPath $ReleasePath).Path
$acceptanceMarker = Join-Path $ReleasePath 'bootstrap-acceptance.json'
if ((Test-Path -LiteralPath $acceptanceMarker) -ne [bool] $AcceptanceOnly) {
    throw 'Acceptance candidates require -AcceptanceOnly; production releases must not use it.'
}
if ($AcceptanceOnly -and (Get-Content $acceptanceMarker -Raw | ConvertFrom-Json -AsHashtable)['kind'] -cne 'github-bootstrap-acceptance') {
    throw 'The acceptance candidate marker is invalid.'
}
$modules = Get-PlatformModuleGraph -ModulesPath (Join-Path $ReleasePath 'modules')
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules -AllowUnboundApps:$ResourcesOnly
Assert-PlatformManualPrerequisite -Instance $instance
$releaseScript = Join-Path $ReleasePath 'tools/Invoke-GitHubBootstrap.ps1'
if (-not (Test-Path -LiteralPath $releaseScript) -or
    (Get-FileHash -LiteralPath $releaseScript).Hash -cne (Get-FileHash -LiteralPath $PSCommandPath).Hash) {
    throw 'Run the bootstrap from the same approved release that will be vendored.'
}
if (Test-Path -LiteralPath (Join-Path $ReleasePath '.git')) {
    $dirty = & git -C $ReleasePath status --porcelain --untracked-files=all
    if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'Vendoring requires a clean release checkout without untracked files.' }
    $tagCommit = & git -C $ReleasePath rev-parse "refs/tags/v$ReleaseVersion^{commit}" 2>&1
    if ($LASTEXITCODE -ne 0) { throw "Release tag v$ReleaseVersion is missing." }
    $headCommit = & git -C $ReleasePath rev-parse HEAD
    if ($LASTEXITCODE -ne 0 -or $headCommit -cne $tagCommit) { throw 'The checkout does not match the requested release tag.' }
}
& (Join-Path $ReleasePath 'tools/Generate-DeploymentWorkflow.ps1') -ModulesPath (Join-Path $ReleasePath 'modules') `
    -OutputPath (Join-Path $ReleasePath 'templates/instance/.github/workflows/deploy.yml') -Check
if (-not $instance.Contains('bootstrap')) { throw 'GitHub bootstrap requires $.bootstrap.' }
$connection = $instance['bootstrap']
if (-not $ResourcesOnly -and (-not $AppKeysPath -or -not $AuthorizationApp)) {
    throw 'Credential setup requires -AuthorizationApp and -AppKeysPath. Use -ResourcesOnly to prepare App registration.'
}
if ($connection['githubHost'] -cne "$($connection['enterprise']).ghe.com") {
    throw '$.bootstrap.githubHost must match $.bootstrap.enterprise on GHE.com.'
}
function Assert-GitHubBootstrapExternalPath {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    foreach ($root in @($ReleasePath, (Split-Path $PSScriptRoot -Parent))) {
        $prefix = $root.TrimEnd([IO.Path]::DirectorySeparatorChar) + [IO.Path]::DirectorySeparatorChar
        if ($fullPath.StartsWith($prefix, [StringComparison]::OrdinalIgnoreCase)) {
            throw 'Bootstrap inventory, key manifests and private keys must be outside the source checkout and release.'
        }
    }
    return $fullPath
}
$inventoryFile = Assert-GitHubBootstrapExternalPath -Path $InventoryPath
foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
    if ([Environment]::GetEnvironmentVariable($name)) { throw "Bootstrap refuses $name. Use gh auth login." }
}
$oauth = (& gh auth token --hostname $connection['githubHost'] 2>&1 | Out-String).Trim()
if ($LASTEXITCODE -ne 0 -or $oauth -cnotmatch '^gho_[A-Za-z0-9_]+$') {
    throw 'GitHub bootstrap requires the stored gh OAuth login. PAT fallback is not supported.'
}
$api = "https://api.$($connection['githubHost'])"
$changed = [Collections.Generic.List[string]]::new()
$organization = "$($instance['instance']['name'])-platform"
$repository = "$organization/instance"
$ownership = "Platform instance $($instance['instance']['name']); bootstrap-owned."
$inventory = @{
    version = 1; repository = $repository; enterprise = $connection['enterprise']
    releaseVersion = $ReleaseVersion; apps = @{}; resources = @()
}
if (Test-Path -LiteralPath $inventoryFile) {
    $inventory = Get-Content -LiteralPath $inventoryFile -Raw | ConvertFrom-Json -AsHashtable
    if ($inventory['repository'] -cne $repository -or $inventory['enterprise'] -cne $connection['enterprise']) {
        throw 'The bootstrap inventory belongs to another instance.'
    }
    if ($inventory['releaseVersion'] -cne $ReleaseVersion -and -not $NoChanges) {
        throw 'The bootstrap inventory belongs to another release. Resume with the recorded approved release.'
    }
    if ($NoChanges -and ($inventory['initializationPending'] -isnot [bool] -or $inventory['initializationPending'])) {
        throw 'NoChanges requires an initialized inventory with initializationPending=false.'
    }
}
elseif ($NoChanges) { throw 'NoChanges requires an existing initialized bootstrap inventory.' }
if (-not $inventory.Contains('declaredApps')) { $inventory['declaredApps'] = @{} }
foreach ($alias in $instance['githubApps'].PSBase.Keys) {
    $appId = $instance['githubApps'][$alias]['appId']
    $previous = $inventory['declaredApps'][$alias]
    $previousIds = @()
    if ($previous) {
        if ($previous.Contains('previousAppIds')) { $previousIds = @($previous['previousAppIds']) }
        if ($previous['appId'] -cne $appId) { $previousIds += $previous['appId'] }
    }
    $inventory['declaredApps'][$alias] = @{
        appId = $appId; removalRequired = $true; previousAppIds = @($previousIds | Sort-Object -Unique)
    }
}

function Save-GitHubBootstrapInventory {
    [CmdletBinding()]
    param()

    if ($NoChanges) { return }
    $content = (ConvertTo-PlatformCanonicalJson $inventory) + "`n"
    if (-not (Test-Path -LiteralPath $inventoryFile) -or [IO.File]::ReadAllText($inventoryFile) -cne $content) {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($inventoryFile))
        $temporary = "$inventoryFile.tmp"
        [IO.File]::WriteAllText($temporary, $content, [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $inventoryFile, $true)
    }
}

Save-GitHubBootstrapInventory

function Register-GitHubBootstrapResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if ($Path -cnotin $inventory['resources']) {
        $inventory['resources'] += $Path
        Save-GitHubBootstrapInventory
    }
}

function Invoke-GitHubBootstrapApi {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH')][string] $Method = 'GET',
        [System.Collections.IDictionary] $Body,
        [switch] $AllowNotFound
    )

    $arguments = @{
        Uri = "$api$Path"; Method = $Method
        Headers = @{ Authorization = "Bearer $oauth"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
        ContentType = 'application/json'; SkipHttpErrorCheck = $true; MaximumRedirection = 0; TimeoutSec = 60
    }
    $isTeamRepositoryPermissionRead = $Method -eq 'GET' -and $Path -match '^/orgs/[^/]+/teams/[^/]+/repos/[^/]+/[^/]+$'
    if ($isTeamRepositoryPermissionRead) { $arguments.Headers.Accept = 'application/vnd.github.v3.repository+json' }
    if ($Body) { $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 100 -Compress }
    $arguments.MaximumRetryCount = 0
    $readOnlyPost = $Path -ceq '/graphql' -and $Method -ceq 'POST' -and $Body -and $Body['query'] -ceq $enterpriseQuery
    $kind = if ($Method -ceq 'GET' -or $readOnlyPost) { 'Read' } else { 'Reconcile' }
    Assert-PlatformBootstrapRequest -Uri $arguments.Uri -Method $Method -Body $Body -NoChanges:$NoChanges `
        -ReadOnlyPost:$readOnlyPost -Kind $kind -RequestPolicy $RequestPolicy
    $response = Invoke-WebRequest @arguments
    if ($AllowNotFound -and $Method -eq 'GET' -and $response.StatusCode -eq 404) { return $null }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "GitHub bootstrap $Method $Path failed (HTTP $($response.StatusCode)). Verify GHE.com API availability, OAuth scopes and SSO, then rerun. $($response.Content)"
    }
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
        $data = ConvertFrom-Json -InputObject $response.Content -AsHashtable -NoEnumerate
        if ($data -is [System.Collections.IDictionary] -and $data.Contains('errors')) {
            throw "GitHub GraphQL failed: $(ConvertTo-Json -InputObject $data['errors'] -Compress)"
        }
    }
    if ($isTeamRepositoryPermissionRead -and ($response.StatusCode -ne 200 -or
        $data -isnot [System.Collections.IDictionary] -or $data['permissions'] -isnot [System.Collections.IDictionary] -or
        $data['permissions']['push'] -isnot [bool])) {
        throw "GitHub bootstrap GET $Path did not prove team repository permissions: expected HTTP 200 with a boolean permissions.push."
    }
    if ($Method -ne 'GET' -and ($Path -ne '/graphql' -or $Body['query'] -like 'mutation*')) {
        $changed.Add($Path)
        Save-GitHubBootstrapInventory
    }
    return ,$data
}

function Get-GitHubBootstrapCollection {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [string] $Property)

    $page = 1
    $pageSize = if ($Property -ceq 'variables') { 30 } else { 100 }
    do {
        $separator = if ($Path.Contains('?')) { '&' } else { '?' }
        $data = Invoke-GitHubBootstrapApi -Path "$Path${separator}per_page=$pageSize&page=$page"
        $items = $data
        if ($Property) { $items = $data[$Property] }
        if ($items -isnot [Collections.IList]) { throw "GitHub API $Path did not return a collection." }
        foreach ($item in $items) { $item }
        $page++
    } while ($items.Count -eq $pageSize)
}

function Disable-GitHubBootstrapActionExecution {
    [CmdletBinding()]
    param()

    $path = "/repos/$repository/actions/permissions"
    $permissions = Invoke-GitHubBootstrapApi -Path $path
    if ($permissions['enabled'] -ne $false) {
        $null = Invoke-GitHubBootstrapApi -Path $path -Method PUT -Body @{ enabled = $false }
        $permissions = Invoke-GitHubBootstrapApi -Path $path
        if ($permissions['enabled'] -ne $false) { throw 'GitHub did not confirm repository Actions isolation.' }
    }
}

function Test-GitHubBootstrapValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Actual, $Desired)

    if ($Desired -is [Collections.IDictionary]) {
        if ($Actual -isnot [Collections.IDictionary]) { return $false }
        foreach ($key in $Desired.Keys) {
            if (-not (Test-GitHubBootstrapValue -Actual $Actual[$key] -Desired $Desired[$key])) { return $false }
        }
        return $true
    }
    if ($Desired -is [Collections.IList]) {
        if ($Actual -isnot [Collections.IList] -or $Actual.Count -ne $Desired.Count) { return $false }
        for ($index = 0; $index -lt $Desired.Count; $index++) {
            if (-not (Test-GitHubBootstrapValue -Actual $Actual[$index] -Desired $Desired[$index])) { return $false }
        }
        return $true
    }
    return (ConvertTo-PlatformCanonicalJson $Actual) -ceq (ConvertTo-PlatformCanonicalJson $Desired)
}

function Initialize-GitHubBootstrapVariable {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Environment,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Variables
    )

    $path = "/repos/$repository/environments/$Environment/variables"
    $current = @{}
    foreach ($variable in @(Get-GitHubBootstrapCollection -Path $path -Property 'variables')) {
        $current[$variable['name']] = $variable['value']
    }
    foreach ($name in $Variables.Keys) {
        if (-not $current.ContainsKey($name)) {
            $null = Invoke-GitHubBootstrapApi -Path $path -Method POST -Body @{ name = $name; value = [string] $Variables[$name] }
        }
        elseif ($current[$name] -cne [string] $Variables[$name]) {
            $null = Invoke-GitHubBootstrapApi -Path "$path/$name" -Method PATCH -Body @{ name = $name; value = [string] $Variables[$name] }
        }
    }
}

function Get-GitHubBootstrapReviewer {
    [CmdletBinding()]
    param([System.Collections.IDictionary] $Environment)

    if ($Environment) {
        $Environment['protection_rules'] | Where-Object { $_['type'] -ceq 'required_reviewers' } |
            ForEach-Object { $_['reviewers'] } | ForEach-Object { @{ type = $_['type']; id = $_['reviewer']['id'] } }
    }
}

function Initialize-GitHubBootstrapEnvironment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [int] $ReviewerId = 0,
        [switch] $CredentialFree
    )

    $path = "/repos/$repository/environments/$Name"
    $current = Invoke-GitHubBootstrapApi -Path $path -AllowNotFound
    $reviewers = @()
    if ($ReviewerId) { $reviewers = @(@{ type = 'Team'; id = $ReviewerId }) }
    $body = @{
        wait_timer = 0; prevent_self_review = $false; reviewers = $reviewers
        can_admins_bypass = $false
        deployment_branch_policy = @{ protected_branches = $false; custom_branch_policies = $true }
    }
    $actualReviewers = @(Get-GitHubBootstrapReviewer -Environment $current)
    if (-not $current -or $current['can_admins_bypass'] -ne $false -or
        -not (Test-GitHubBootstrapValue -Actual $current['deployment_branch_policy'] -Desired $body['deployment_branch_policy']) -or
        -not (Test-GitHubBootstrapValue -Actual $actualReviewers -Desired $reviewers) -or
        @($current['protection_rules'] | Where-Object { $_['type'] -cnotin @('required_reviewers', 'branch_policy') }).Count -gt 0) {
        $current = Invoke-GitHubBootstrapApi -Path $path -Method PUT -Body $body
        $confirmed = @(Get-GitHubBootstrapReviewer -Environment $current)
        if (-not (Test-GitHubBootstrapValue -Actual $confirmed -Desired $reviewers) -or
            $current['can_admins_bypass'] -ne $false -or
            -not (Test-GitHubBootstrapValue -Actual $current['deployment_branch_policy'] -Desired $body['deployment_branch_policy'])) {
            throw "GHE.com did not enforce environment '$Name' protection. Do not deploy modules."
        }
    }
    Register-GitHubBootstrapResource -Path $path
    $branches = @(Get-GitHubBootstrapCollection -Path "$path/deployment-branch-policies" -Property 'branch_policies')
    if ($branches.Count -gt 0 -and ($branches.Count -ne 1 -or $branches[0]['name'] -cne 'main' -or $branches[0]['type'] -cne 'branch')) {
        throw "Environment '$Name' permits refs other than main. Remove them through an approved access change."
    }
    if (-not $branches.Count) {
        $null = Invoke-GitHubBootstrapApi -Path "$path/deployment-branch-policies" -Method POST -Body @{ name = 'main'; type = 'branch' }
    }
    $secrets = @(Get-GitHubBootstrapCollection -Path "$path/secrets" -Property 'secrets')
    if ($CredentialFree) {
        $variables = @(Get-GitHubBootstrapCollection -Path "$path/variables" -Property 'variables')
        if ($secrets.Count -or $variables.Count) { throw "Gate environment '$Name' must not have secrets or variables." }
    }
    elseif (@($secrets | Where-Object { $_['name'] -cne 'PLATFORM_APP_PRIVATE_KEY' }).Count) {
        throw "Environment '$Name' has undeclared secrets. Remove them through an approved access change."
    }
}

function Invoke-GitHubBootstrapAzure {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [ValidateSet('GET', 'PUT')][string] $Method = 'GET',
        [System.Collections.IDictionary] $Body
    )

    $arguments = @{
        Uri = "https://management.azure.com$Path"; Method = $Method
        Headers = @{ Authorization = "Bearer $azureToken" }; ContentType = 'application/json'
        SkipHttpErrorCheck = $true; MaximumRedirection = 0; TimeoutSec = 60
    }
    if ($Body) { $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 100 -Compress }
    $arguments.MaximumRetryCount = 0
    Assert-PlatformBootstrapRequest -Uri $arguments.Uri -Method $Method -Body $Body -NoChanges:$NoChanges `
        -Kind $(if ($Method -ceq 'GET') { 'Read' } else { 'Reconcile' }) -RequestPolicy $RequestPolicy
    $response = Invoke-WebRequest @arguments
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        throw "Azure federation $Method $Path failed (HTTP $($response.StatusCode)). $($response.Content)"
    }
    if ($Method -ne 'GET') {
        $changed.Add($Path)
        Register-GitHubBootstrapResource -Path $Path.Split('?')[0]
        Save-GitHubBootstrapInventory
    }
    return ConvertFrom-Json -InputObject $response.Content -AsHashtable
}

$selected = Get-PlatformModuleSelection -Instance $instance -Modules $modules
if ($AzureBootstrap['TenantId'] -cne $connection['tenantId'] -or
    $AzureBootstrap['SubscriptionId'] -cne $connection['managementSubscriptionId'] -or
    $AzureBootstrap['ResourceGroupName'] -cne "rg-$($instance['instance']['name'])-bootstrap" -or
    $AzureBootstrap['StorageAccountName'] -cne "st$($instance['instance']['name'])tfstate") {
    throw 'Azure bootstrap output does not match this instance.'
}
$identities = @{}
foreach ($module in $AzureBootstrap['Modules']) {
    if ($identities.ContainsKey($module['Name'])) { throw 'Azure bootstrap contains duplicate modules.' }
    $identities[$module['Name']] = @{} + $module
}
foreach ($name in $selected) {
    if (-not $identities.ContainsKey($name)) { throw "Azure bootstrap has no identity for '$name'." }
    foreach ($phase in @('plan', 'apply')) {
        $expectedId = "/subscriptions/$($connection['managementSubscriptionId'])/resourceGroups/$($AzureBootstrap['ResourceGroupName'])/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$($instance['instance']['name'])-$name-$phase"
        if ($identities[$name][$phase]['ResourceId'] -cne $expectedId -or
            $identities[$name][$phase]['ClientId'] -notmatch '^[0-9a-fA-F-]{36}$') {
            throw "Azure bootstrap identity '$name/$phase' does not match this instance."
        }
    }
}
$enterpriseQuery = 'query($slug:String!,$cursor:String){viewer{login} enterprise(slug:$slug){id viewerIsAdmin organizations(first:100,after:$cursor){nodes{login} pageInfo{hasNextPage endCursor}}}}'
$cursor = $null
$belongs = $false
$seen = [Collections.Generic.HashSet[string]]::new()
do {
    $reply = Invoke-GitHubBootstrapApi -Path '/graphql' -Method POST -Body @{
        query = $enterpriseQuery; variables = @{ slug = $connection['enterprise']; cursor = $cursor }
    }
    $enterprise = $reply['data']['enterprise']
    if (-not $enterprise -or -not $enterprise['viewerIsAdmin']) { throw 'The OAuth user must be an enterprise owner.' }
    $login = $reply['data']['viewer']['login']
    if ($organization -cin @($enterprise['organizations']['nodes'] | ForEach-Object { $_['login'] })) { $belongs = $true }
    $cursor = $enterprise['organizations']['pageInfo']['endCursor']
    if ($enterprise['organizations']['pageInfo']['hasNextPage'] -and (-not $cursor -or -not $seen.Add($cursor))) {
        throw 'Invalid enterprise organization pagination.'
    }
} while ($enterprise['organizations']['pageInfo']['hasNextPage'])
$org = Invoke-GitHubBootstrapApi -Path "/orgs/$organization" -AllowNotFound
if ($org -and -not $belongs) { throw "Organization '$organization' belongs to another enterprise; refusing to adopt it." }
if (-not $org) {
    $created = Invoke-GitHubBootstrapApi -Path '/graphql' -Method POST -Body @{
        query = 'mutation($input:CreateEnterpriseOrganizationInput!){createEnterpriseOrganization(input:$input){organization{login}}}'
        variables = @{ input = @{
            enterpriseId = $enterprise['id']; login = $organization; profileName = $organization
            billingEmail = $instance['teams']['platform'][0]; adminLogins = @($login)
        } }
    }
    if ($created['data']['createEnterpriseOrganization']['organization']['login'] -cne $organization) {
        throw 'GitHub did not confirm creation of the requested platform organization.'
    }
    Write-Warning "If SSO denies the next operation, sign in to https://$($connection['githubHost'])/$organization and refresh gh auth login. Rerun with the same inventory."
}
Register-GitHubBootstrapResource -Path "/orgs/$organization"
$repo = Invoke-GitHubBootstrapApi -Path "/repos/$repository" -AllowNotFound
if (-not $repo) {
    $inventory['initializationPending'] = $true
    $repo = Invoke-GitHubBootstrapApi -Path "/orgs/$organization/repos" -Method POST -Body @{
        name = 'instance'; private = $true; auto_init = $true; description = $ownership
    }
}
if ($repo['private'] -ne $true -or $repo['description'] -cne $ownership) {
    throw 'The instance repository is not a private bootstrap-owned repository; refusing to adopt it.'
}
Register-GitHubBootstrapResource -Path "/repos/$repository"
if ($inventory['initializationPending']) {
    Disable-GitHubBootstrapActionExecution
}
if ($inventory['initializationPending'] -and -not $inventory['seedCommit']) {
    $seed = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/ref/heads/$($repo['default_branch'])"
    $inventory['seedCommit'] = $seed['object']['sha']
    $inventory['seedBranch'] = $repo['default_branch']
    Save-GitHubBootstrapInventory
}
$teams = @{}
foreach ($name in @('platform', 'security')) {
    $teamPath = "/orgs/$organization/teams/$name"
    $team = Invoke-GitHubBootstrapApi -Path $teamPath -AllowNotFound
    if (-not $team) {
        $team = Invoke-GitHubBootstrapApi -Path "/orgs/$organization/teams" -Method POST -Body @{
            name = $name; privacy = 'closed'; description = $ownership
        }
    }
    if ($team['description'] -cne $ownership) { throw "Team '$name' is not bootstrap-owned; refusing to adopt it." }
    Register-GitHubBootstrapResource -Path $teamPath
    $teams[$name] = $team
    if ($inventory['initializationPending']) {
        $membership = Invoke-GitHubBootstrapApi -Path "$teamPath/memberships/$login" -AllowNotFound
        if (-not $membership -or $membership['state'] -cne 'active') {
            $membership = Invoke-GitHubBootstrapApi -Path "$teamPath/memberships/$login" -Method PUT -Body @{ role = 'maintainer' }
            if ($membership['state'] -cne 'active') { throw "Bootstrap user membership in '$name' is not active." }
        }
    }
    $accessPath = "$teamPath/repos/$repository"
    $access = Invoke-GitHubBootstrapApi -Path $accessPath -AllowNotFound
    if (-not $access -or $access['permissions']['push'] -ne $true) {
        $null = Invoke-GitHubBootstrapApi -Path $accessPath -Method PUT -Body @{ permission = 'push' }
        $access = Invoke-GitHubBootstrapApi -Path $accessPath
        if ($access['permissions']['push'] -ne $true) {
            throw "Team '$name' does not have push access after the repository permission update."
        }
    }
}
$files = @{}
$releaseHashes = @{}
$releaseFiles = @(Get-ChildItem -LiteralPath $ReleasePath -Recurse -Force -File |
    Where-Object { $_.FullName -notmatch '[\\/](\.git|\.terraform|artifacts|node_modules)[\\/]' })
foreach ($file in $releaseFiles) {
    if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or $file.Extension -in @('.pem', '.pfx', '.tfstate') -or
        $file.Name -in @('.env', 'keys.json', 'bootstrap-resources.json') -or $file.Name -like '*.tfstate.*') {
        throw "Release contains an unsupported file '$($file.Name)'. Use an approved release without credentials or runtime data."
    }
    $relative = [IO.Path]::GetRelativePath($ReleasePath, $file.FullName).Replace('\', '/')
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $files["platform/$relative"] = $bytes
    $releaseHashes[$relative] = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}
if ($releaseHashes.Count -eq 0) { throw 'The release is empty.' }
foreach ($file in Get-ChildItem -LiteralPath (Join-Path $ReleasePath 'templates/instance') -Recurse -Force -File) {
    $relative = [IO.Path]::GetRelativePath((Join-Path $ReleasePath 'templates/instance'), $file.FullName).Replace('\', '/')
    $files[$relative] = [IO.File]::ReadAllBytes($file.FullName)
}
$files['instance.yaml'] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Yaml $instance).Replace("`r", ''))
$files['.github/CODEOWNERS'] = [Text.Encoding]::UTF8.GetBytes("* @$organization/platform`n")
$marker = @{ instance = $instance['instance']['name']; releaseVersion = $ReleaseVersion; files = $releaseHashes }
$files['.platform-bootstrap.json'] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker) + "`n")
$main = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/ref/heads/main" -AllowNotFound
if ($NoChanges -and -not $main) { throw 'NoChanges requires an existing main branch.' }
if ($main) {
    $contentRef = if ($NoChanges) { $main['object']['sha'] } else { 'main' }
    $stored = Invoke-GitHubBootstrapApi -Path "/repos/$repository/contents/.platform-bootstrap.json?ref=$contentRef" -AllowNotFound
    if (-not $stored) {
        if (-not $inventory['initializationPending'] -or $main['object']['sha'] -cne $inventory['seedCommit']) {
            throw 'Existing main has no bootstrap marker or has changed during initialization; refusing to overwrite it.'
        }
        $main = $null
    }
    else {
        $previous = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($stored['content'])) | ConvertFrom-Json -AsHashtable
        $markerMatches = if ($NoChanges) {
            (ConvertTo-PlatformCanonicalJson $previous) -ceq (ConvertTo-PlatformCanonicalJson $marker)
        } else { Test-GitHubBootstrapValue -Actual $previous -Desired $marker }
        if (-not $markerMatches) {
            throw 'Repository bootstrap marker differs from the running release. Use the approved release; updates require a PR.'
        }
        $inventory['initializationPending'] = $false
        $storedConfiguration = Invoke-GitHubBootstrapApi -Path "/repos/$repository/contents/instance.yaml?ref=$contentRef"
        $configuration = ConvertFrom-Yaml ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($storedConfiguration['content'])))
        if ((ConvertTo-PlatformCanonicalJson $configuration) -cne (ConvertTo-PlatformCanonicalJson $instance)) {
            throw 'Local instance configuration differs from protected main. Apply configuration changes through a reviewed PR, not bootstrap.'
        }
    }
}
function Initialize-GitHubBootstrapRepositoryContent {
    [CmdletBinding()]
    param()

    if ($main) { return }
    $seed = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/ref/heads/$($inventory['seedBranch'])"
    if ($seed['object']['sha'] -cne $inventory['seedCommit']) {
        throw 'The initial repository branch changed during bootstrap. Refusing to replace instance contents.'
    }
    $tree = @(
        foreach ($path in @($files.Keys | Sort-Object -CaseSensitive)) {
            $blob = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/blobs" -Method POST -Body @{
                content = [Convert]::ToBase64String($files[$path]); encoding = 'base64'
            }
            @{ path = $path; mode = '100644'; type = 'blob'; sha = $blob['sha'] }
        }
    )
    $createdTree = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/trees" -Method POST -Body @{ tree = $tree }
    $commit = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/commits" -Method POST -Body @{
        message = "Bootstrap instance with platform release $ReleaseVersion"; tree = $createdTree['sha']; parents = @($inventory['seedCommit'])
    }
    if ($inventory['seedBranch'] -ceq 'main') {
        $null = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/refs/heads/main" -Method PATCH -Body @{ sha = $commit['sha']; force = $false }
    }
    else {
        $null = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/refs" -Method POST -Body @{ ref = 'refs/heads/main'; sha = $commit['sha'] }
    }
    $inventory['initializationPending'] = $false
    Save-GitHubBootstrapInventory
}
$ruleset = @{
    name = 'platform-instance-main'; target = 'branch'; enforcement = 'active'; bypass_actors = @()
    conditions = @{ ref_name = @{ include = @('refs/heads/main'); exclude = @() } }
    rules = @(
        @{ type = 'deletion' }, @{ type = 'non_fast_forward' },
        @{ type = 'pull_request'; parameters = @{
            required_approving_review_count = 1; dismiss_stale_reviews_on_push = $true
            require_code_owner_review = $true; require_last_push_approval = $true; required_review_thread_resolution = $true
            required_reviewers = @(
                @{ reviewer = @{ id = $teams['security']['id']; type = 'Team' }; minimum_approvals = 1
                    file_patterns = @('instance.yaml', 'platform/**', '.github/**') }
            )
        } }
    )
}
function Initialize-GitHubBootstrapMainProtection {
    [CmdletBinding()]
    param()

    $existingRules = @(Get-GitHubBootstrapCollection -Path "/repos/$repository/rulesets?includes_parents=false" |
        Where-Object { $_['name'] -ceq $ruleset['name'] })
    if ($existingRules.Count -gt 1) { throw 'Duplicate bootstrap main rulesets.' }
    $rule = if ($existingRules.Count) { Invoke-GitHubBootstrapApi -Path "/repos/$repository/rulesets/$($existingRules[0]['id'])" } else { $null }
    if (-not (Test-GitHubBootstrapValue -Actual $rule -Desired $ruleset)) {
        $rulePath = if ($rule) { "/repos/$repository/rulesets/$($rule['id'])" } else { "/repos/$repository/rulesets" }
        $method = if ($rule) { 'PUT' } else { 'POST' }
        $rule = Invoke-GitHubBootstrapApi -Path $rulePath -Method $method -Body $ruleset
        Register-GitHubBootstrapResource -Path "/repos/$repository/rulesets/$($rule['id'])"
        if (-not (Test-GitHubBootstrapValue -Actual $rule -Desired $ruleset)) {
            throw 'GHE.com did not enforce the required security-team PR reviews. Do not deploy modules.'
        }
    }
    Register-GitHubBootstrapResource -Path "/repos/$repository/rulesets/$($rule['id'])"
}
if ($NoChanges) { Initialize-GitHubBootstrapMainProtection }
$environmentNames = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
foreach ($name in @('pr-authorization', 'approve-apply', 'approve-teardown-platform', 'teardown')) {
    $null = $environmentNames.Add($name)
}
$environmentBindings = [Collections.Generic.List[object]]::new()
foreach ($name in $selected) {
    foreach ($phase in @('plan', 'apply', 'rulesetPlan')) {
        if (-not $instance['credentials'][$name].Contains($phase)) { continue }
        $environment = $instance['credentials'][$name][$phase]['environment']
        $names = @($environment)
        if ($phase -ne 'apply') { $names += "$environment-drift" }
        foreach ($target in $names) {
            if ($target.Length -gt 255 -or -not $environmentNames.Add($target)) {
                throw "Environment '$target' collides with another phase or a workflow gate, or exceeds 255 characters."
            }
            $environmentBindings.Add(@{ name = $target; module = $name; phase = $phase })
        }
    }
}
$repositorySubject = ''
if ($selected.Count) {
    $oidc = Invoke-GitHubBootstrapApi -Path "/repos/$repository/actions/oidc/customization/sub"
    if ($oidc -isnot [Collections.IDictionary] -or
        $oidc['use_default'] -isnot [bool] -or -not $oidc['use_default'] -or
        $oidc['use_immutable_subject'] -isnot [bool]) {
        throw 'Repository OIDC must expose its default template and an explicit immutable-subject mode. Custom templates require an approved trust change.'
    }
    if ($repo['owner'] -isnot [Collections.IDictionary] -or $repo['name'] -cne 'instance' -or
        $repo['full_name'] -cne $repository -or $repo['owner']['login'] -cne $organization -or
        $repo['owner']['type'] -cne 'Organization' -or
        ($repo['id'] -isnot [long] -and $repo['id'] -isnot [int]) -or $repo['id'] -le 0 -or
        ($repo['owner']['id'] -isnot [long] -and $repo['owner']['id'] -isnot [int]) -or $repo['owner']['id'] -le 0) {
        throw 'Repository OIDC requires the exact organization owner and positive numeric repository and owner IDs.'
    }
    $repositorySubject = if ($oidc['use_immutable_subject']) {
        "repo:$organization@$($repo['owner']['id'])/instance@$($repo['id'])"
    } else { "repo:$repository" }
    if ($oidc['sub_claim_prefix'] -isnot [string] -or $oidc['sub_claim_prefix'] -cne $repositorySubject) {
        throw 'Repository OIDC subject prefix does not match its declared mode and exact repository identity.'
    }
}
$azureToken = ''
if ($selected.Count) {
    $text = & az account get-access-token --tenant $connection['tenantId'] --resource 'https://management.azure.com/' --output json --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'Azure login failed while preparing environment federation.' }
    $token = ConvertFrom-Json -InputObject $text -AsHashtable
    if ($token['tenant'] -cne $connection['tenantId'] -or -not $token['accessToken']) { throw 'Azure token belongs to another tenant.' }
    $azureToken = $token['accessToken']
}
Initialize-GitHubBootstrapEnvironment -Name 'pr-authorization'
Initialize-GitHubBootstrapVariable -Environment 'pr-authorization' -Variables @{ PLATFORM_TEAM_SLUG = 'platform' }
Initialize-GitHubBootstrapEnvironment -Name 'approve-apply' -ReviewerId $teams['platform']['id'] -CredentialFree
Initialize-GitHubBootstrapEnvironment -Name 'approve-teardown-platform' -ReviewerId $teams['platform']['id'] -CredentialFree
Initialize-GitHubBootstrapEnvironment -Name 'teardown' -ReviewerId $teams['security']['id'] -CredentialFree
foreach ($binding in $environmentBindings) {
    $reviewer = if ($binding['phase'] -ceq 'apply' -and $binding['module'] -ceq 'enterprise-baseline') { $teams['security']['id'] } else { 0 }
    Initialize-GitHubBootstrapEnvironment -Name $binding['name'] -ReviewerId $reviewer
    $azurePhase = if ($binding['phase'] -ceq 'apply') { 'apply' } else { 'plan' }
    Initialize-GitHubBootstrapVariable -Environment $binding['name'] -Variables @{
        AZURE_CLIENT_ID = $identities[$binding['module']][$azurePhase]['ClientId']
        AZURE_TENANT_ID = $connection['tenantId']; AZURE_SUBSCRIPTION_ID = $connection['managementSubscriptionId']
        PLATFORM_STATE_STORAGE_ACCOUNT = $AzureBootstrap['StorageAccountName']; PLATFORM_STATE_RESOURCE_GROUP = $AzureBootstrap['ResourceGroupName']
    }
}
foreach ($name in $selected) {
    foreach ($phase in @('plan', 'apply')) {
        $identity = $identities[$name][$phase]
        $identityPath = $identity['ResourceId']
        $actual = Invoke-GitHubBootstrapAzure -Path "$identityPath`?api-version=2023-01-31"
        if ($actual['properties']['clientId'] -cne $identity['ClientId'] -or
            -not (Test-GitHubBootstrapValue -Actual $actual['tags'] -Desired @{
                platformInstance = $instance['instance']['name']; platformComponent = 'bootstrap'; platformModule = $name; platformPhase = $phase
            })) {
            throw "Actual Azure identity '$name/$phase' differs from the Azure bootstrap output."
        }
        $desired = @{}
        foreach ($binding in @($environmentBindings | Where-Object {
            $_['module'] -ceq $name -and (($_['phase'] -ceq 'apply') -eq ($phase -ceq 'apply'))
        })) {
            $subject = "${repositorySubject}:environment:$($binding['name'])"
            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($subject))).ToLowerInvariant()
            $desired["fic-$($digest.Substring(0, 24))"] = @{ properties = @{
                issuer = "https://token.actions.$($connection['githubHost'])"
                subject = $subject; audiences = @('api://AzureADTokenExchange')
            } }
        }
        $current = @{}
        $path = "$identityPath/federatedIdentityCredentials"
        $pagePath = "$path`?api-version=2023-01-31"
        $visited = [Collections.Generic.HashSet[string]]::new()
        while ($pagePath) {
            if (-not $visited.Add($pagePath)) { throw 'Azure federation pagination cycle.' }
            $page = Invoke-GitHubBootstrapAzure -Path $pagePath
            if ($page['value'] -isnot [Collections.IList]) { throw 'Azure federation API did not return a collection.' }
            foreach ($credential in $page['value']) {
                $credentialName = $credential['name']
                if (-not $desired.ContainsKey($credentialName) -or
                    -not (Test-GitHubBootstrapValue -Actual $credential -Desired $desired[$credentialName])) {
                    throw "Identity '$name/$phase' has an unexpected federated credential. Remove it through an approved access change."
                }
                $current[$credentialName] = $credential
            }
            $pagePath = $null
            if ($page['nextLink']) {
                $next = [uri] $page['nextLink']
                if ($next.Scheme -cne 'https' -or $next.Host -cne 'management.azure.com' -or -not $next.IsDefaultPort -or $next.UserInfo -or $next.Fragment) {
                    throw 'Untrusted Azure federation continuation URL.'
                }
                $pagePath = $next.PathAndQuery
            }
        }
        foreach ($credentialName in $desired.Keys) {
            if (-not $current.ContainsKey($credentialName)) {
                $null = Invoke-GitHubBootstrapAzure -Path "$path/$credentialName`?api-version=2023-01-31" -Method PUT -Body $desired[$credentialName]
            }
        }
    }
}
if ($NoChanges) {
    $currentMain = Invoke-GitHubBootstrapApi -Path "/repos/$repository/git/ref/heads/main"
    if ($currentMain['object']['sha'] -cne $main['object']['sha']) {
        throw 'Repository main changed during NoChanges verification. Review the new main before retrying.'
    }
}
$configured = $false
if (-not $ResourcesOnly) {
    $inherited = @(Get-GitHubBootstrapCollection -Path "/repos/$repository/actions/secrets" -Property 'secrets') +
        @(Get-GitHubBootstrapCollection -Path "/orgs/$organization/actions/secrets" -Property 'secrets')
    if (@($inherited | Where-Object { $_['name'] -ceq 'PLATFORM_APP_PRIVATE_KEY' }).Count) {
        throw 'PLATFORM_APP_PRIVATE_KEY must not exist as a repository or organization secret.'
    }
    $keys = Get-Content -LiteralPath (Assert-GitHubBootstrapExternalPath -Path $AppKeysPath) -Raw | ConvertFrom-Json -AsHashtable
    if ($keys -isnot [Collections.IDictionary] -or -not $instance['githubApps'].Contains($AuthorizationApp)) {
        throw 'App key manifest or authorization App alias is invalid.'
    }
    $authorization = $instance['githubApps'][$AuthorizationApp]
    if ($authorization['enterprise'] -cne $connection['enterprise'] -or
        -not (Test-GitHubBootstrapValue -Actual $authorization['permissions'] -Desired @{ members = 'read' }) -or
        $authorization['permissions'].Count -ne 1 -or
        -not (Test-GitHubBootstrapValue -Actual $authorization['resources']['organizations'] -Desired @($organization)) -or
        ($authorization['resources']['repositories'] -and $authorization['resources']['repositories'].Count)) {
        throw 'Authorization requires an isolated members: read enterprise App in the platform organization without repository access.'
    }
    $appBindings = @(@{ alias = $AuthorizationApp; environment = 'pr-authorization'; phase = 'authorization' })
    foreach ($binding in $environmentBindings) {
        $credential = $instance['credentials'][$binding['module']][$binding['phase']]
        if ($credential.Contains('githubApp')) {
            $alias = $credential['githubApp']
            if ($instance['githubApps'][$alias]['appId'] -ceq $authorization['appId']) {
                throw 'Authorization App must not share its identity with any module phase.'
            }
            $appBindings += @{ alias = $alias; environment = $binding['name']; phase = $binding['phase'] }
        }
        else {
            $secrets = @(Get-GitHubBootstrapCollection -Path "/repos/$repository/environments/$($binding['name'])/secrets" -Property 'secrets')
            if ($secrets.Count) { throw "Environment '$($binding['name'])' has an App key without an App binding." }
        }
    }
    $verifiedApps = @{}
    foreach ($binding in $appBindings) {
        $alias = $binding['alias']
        if ($verifiedApps.ContainsKey($alias)) { continue }
        $app = $instance['githubApps'][$alias]
        $key = $keys[$alias]
        if (-not $key -or $key['owner'] -cne 'platform' -or $app['enterprise'] -cne $connection['enterprise']) {
            throw "App '$alias' requires the platform owner, enterprise ownership and a local key manifest entry."
        }
        $created = if ($key['createdAt'] -is [DateTime]) { [DateTimeOffset] $key['createdAt'] } else { [DateTimeOffset]::Parse($key['createdAt']) }
        $deadline = if ($key['rotateBy'] -is [DateTime]) { [DateTimeOffset] $key['rotateBy'] } else { [DateTimeOffset]::Parse($key['rotateBy']) }
        if ($created -gt [DateTimeOffset]::UtcNow -or $deadline -le [DateTimeOffset]::UtcNow -or
            $deadline -gt $created.AddDays(90) -or $deadline -le $created) {
            throw "App '$alias' key rotation must be due within 90 days of creation and must not be overdue."
        }
        $keyPath = Assert-GitHubBootstrapExternalPath -Path $key['privateKeyPath']
        $privateKey = Get-Content -LiteralPath $keyPath -Raw
        $result = & (Join-Path $PSScriptRoot 'New-PlatformGitHubToken.ps1') -BootstrapApp $app `
            -PrivateKey $privateKey -Phase $(if ($binding['phase'] -eq 'authorization') { 'plan' } else { $binding['phase'] }) `
            -Authorization:($binding['phase'] -eq 'authorization') -ValidateOnly -ApiUrl $api `
            -RequestPolicy $RequestPolicy -TokenLifecycle $TokenLifecycle -VerifyRevocation:$VerifyTokenRevocation
        if (-not $result.Verified) { throw "App '$alias' verification did not complete." }
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $rsa.ImportFromPem($privateKey)
            $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
        }
        finally { $rsa.Dispose() }
        if ($inventory['apps'].Contains($alias) -and $inventory['apps'][$alias]['fingerprint'] -ceq $fingerprint) {
            $known = $inventory['apps'][$alias]
            $knownCreated = if ($known['createdAt'] -is [DateTime]) { [DateTimeOffset] $known['createdAt'] } else { [DateTimeOffset]::Parse($known['createdAt']) }
            $knownDeadline = if ($known['rotateBy'] -is [DateTime]) { [DateTimeOffset] $known['rotateBy'] } else { [DateTimeOffset]::Parse($known['rotateBy']) }
            if ($known['appId'] -cne $app['appId'] -or $knownCreated -ne $created -or $knownDeadline -ne $deadline) {
                throw 'An unchanged App key must keep its recorded identity, creation date and rotation deadline. Generate a new key to rotate.'
            }
        }
        foreach ($other in $verifiedApps.Keys) {
            if ($verifiedApps[$other]['fingerprint'] -ceq $fingerprint -and
                $instance['githubApps'][$other]['appId'] -cne $app['appId']) {
                throw 'Different App identities must not reuse the same private key.'
            }
        }
        $verifiedApps[$alias] = @{ key = $privateKey; fingerprint = $fingerprint }
        if (-not $inventory['apps'].Contains($alias) -or $inventory['apps'][$alias]['fingerprint'] -cne $fingerprint) {
            $history = @()
            if ($inventory['apps'].Contains($alias)) {
                $history = @($inventory['apps'][$alias]['previousKeys']) + @(@{
                    appId = $inventory['apps'][$alias]['appId']; fingerprint = $inventory['apps'][$alias]['fingerprint']; revocationRequired = $true
                })
            }
            $inventory['apps'][$alias] = @{
                appId = $app['appId']; installationIds = $result.Installations; enterprise = $app['enterprise']
                owner = 'platform'; createdAt = $created.ToString('o'); rotateBy = $deadline.ToString('o')
                fingerprint = $fingerprint; verifiedAt = [DateTimeOffset]::UtcNow.ToString('o')
                previousKeys = $history; removalRequired = $true
            }
            Save-GitHubBootstrapInventory
        }
    }
    Initialize-GitHubBootstrapRepositoryContent
    if ($repo['default_branch'] -cne 'main') {
        $null = Invoke-GitHubBootstrapApi -Path "/repos/$repository" -Method PATCH -Body @{ default_branch = 'main' }
    }
    Initialize-GitHubBootstrapMainProtection
    foreach ($binding in $appBindings) {
        $app = $instance['githubApps'][$binding['alias']]
        $verified = $verifiedApps[$binding['alias']]
        $environment = $binding['environment']
        $path = "/repos/$repository/environments/$environment"
        $variables = @(Get-GitHubBootstrapCollection -Path "$path/variables" -Property 'variables')
        $fingerprint = @($variables | Where-Object { $_['name'] -ceq 'PLATFORM_APP_KEY_FINGERPRINT' })
        $secrets = @(Get-GitHubBootstrapCollection -Path "$path/secrets" -Property 'secrets')
        if (-not @($secrets | Where-Object { $_['name'] -ceq 'PLATFORM_APP_PRIVATE_KEY' }).Count -or
            $fingerprint.Count -ne 1 -or $fingerprint[0]['value'] -cne $verified['fingerprint']) {
            if ($NoChanges) { throw "NoChanges refuses to encrypt or upload a changed App key for '$environment'." }
            $publicKey = Invoke-GitHubBootstrapApi -Path "$path/secrets/public-key"
            # gh uses libsodium sealed boxes; the private key is stdin, never a process argument or file.
            $encrypted = ($verified['key'] | & gh secret set PLATFORM_APP_PRIVATE_KEY --repo "https://$($connection['githubHost'])/$repository" `
                --env $environment --no-store 2>&1 | Out-String).Trim()
            if ($LASTEXITCODE -ne 0 -or -not $encrypted) { throw "Encrypting the App key for '$environment' failed. No key was uploaded." }
            $null = Invoke-GitHubBootstrapApi -Path "$path/secrets/PLATFORM_APP_PRIVATE_KEY" -Method PUT -Body @{
                encrypted_value = $encrypted; key_id = $publicKey['key_id']
            }
        }
        Initialize-GitHubBootstrapVariable -Environment $environment -Variables @{
            PLATFORM_APP_ID = $app['appId']; PLATFORM_APP_INSTALLATION_ID = $app['installationId']
            PLATFORM_APP_ENTERPRISE = $app['enterprise']; PLATFORM_APP_KEY_FINGERPRINT = $verified['fingerprint']
        }
    }
    if ($AcceptanceOnly) {
        $isolationAttempted = $false
        try {
            $workflowsPath = "/repos/$repository/actions/workflows"
            $acceptancePath = '.github/workflows/bootstrap-acceptance.yml'
            $workflowStates = @('active', 'disabled_manually', 'disabled_inactivity', 'disabled_fork', 'deleted')
            $workflows = @(Get-GitHubBootstrapCollection -Path $workflowsPath -Property 'workflows')
            foreach ($path in @($files.Keys | Where-Object { $_ -cmatch '^\.github/workflows/[^/]+\.ya?ml$' })) {
                if (@($workflows | Where-Object { $_['path'] -ceq $path }).Count -ne 1) {
                    throw "The acceptance candidate workflow '$path' is not uniquely registered. Actions must remain disabled."
                }
            }
            foreach ($workflow in $workflows) {
                if ($workflow['path'] -cnotmatch '^\.github/workflows/[^/]+\.ya?ml$' -or
                    $workflow['state'] -cnotin $workflowStates) {
                    throw 'GitHub returned an unsupported workflow path or state. Actions must remain disabled.'
                }
                if ($workflow['path'] -ceq $acceptancePath) { continue }
                if ($workflow['state'] -ceq 'active') {
                    if (-not $isolationAttempted -and -not $NoChanges) {
                        $isolationAttempted = $true
                        Disable-GitHubBootstrapActionExecution
                    }
                    $workflowPath = "$workflowsPath/$([uri]::EscapeDataString($workflow['path'].Split('/')[-1]))"
                    $null = Invoke-GitHubBootstrapApi -Path "$workflowPath/disable" -Method PUT
                    $disabled = Invoke-GitHubBootstrapApi -Path $workflowPath
                    if ($disabled['state'] -cne 'disabled_manually') {
                        throw "Workflow '$($workflow['path'])' was not disabled. Actions must remain disabled."
                    }
                }
            }
            $workflows = @(Get-GitHubBootstrapCollection -Path $workflowsPath -Property 'workflows')
            if (@($workflows | Where-Object { $_['state'] -cnotin $workflowStates }).Count) {
                throw 'GitHub returned an unsupported workflow state. Actions must remain disabled.'
            }
            $active = @($workflows | Where-Object { $_['state'] -ceq 'active' })
            if ($active.Count -ne 1 -or $active[0]['path'] -cne $acceptancePath) {
                throw 'Only bootstrap-acceptance.yml may be active in the acceptance candidate. Actions must remain disabled.'
            }
        }
        catch {
            $failure = $_
            if (-not $isolationAttempted -and -not $NoChanges) {
                try { Disable-GitHubBootstrapActionExecution }
                catch {
                    throw "Acceptance workflow isolation failed: $failure Repository Actions isolation also failed: $_"
                }
            }
            throw $failure
        }
    }
    $permissions = Invoke-GitHubBootstrapApi -Path "/repos/$repository/actions/permissions"
    if ($permissions['enabled'] -ne $true) {
        $null = Invoke-GitHubBootstrapApi -Path "/repos/$repository/actions/permissions" -Method PUT -Body @{ enabled = $true }
    }
    $configured = $true
}
Save-GitHubBootstrapInventory
[pscustomobject]@{
    Repository = $repository; ReleaseVersion = $ReleaseVersion
    InventoryPath = $inventoryFile; CredentialsConfigured = $configured; HasChanges = $changed.Count -gt 0
}
