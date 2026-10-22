#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [Parameter(DontShow)][switch] $AllowUnboundApps,
    # Read-only report used by Test-BootstrapPrerequisites.ps1; stops before the first change.
    [Parameter(DontShow)][switch] $Preflight,
    [switch] $NoChanges,
    [scriptblock] $RequestPolicy
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
if ($NoChanges -and $Preflight) { throw 'NoChanges executes the real bootstrap; it cannot be combined with Preflight.' }
$requestPolicyCallback = $RequestPolicy
$checkResults = [System.Collections.Generic.List[object]]::new()
$checkTitles = @{}
$checkWarnings = [System.Collections.Generic.List[string]]::new()
$completedChecks = [System.Collections.Generic.HashSet[string]]::new()

function Invoke-BootstrapCheck {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $CheckId,
        [Parameter(Mandatory)][string] $CheckArea,
        [Parameter(Mandatory)][string] $CheckTitle,
        [string[]] $RequiredCheck = @(),
        [string] $PassDetail = '',
        [Parameter(Mandatory)][scriptblock] $CheckScript
    )

    # Bootstrap keeps its original fail-fast behavior; preflight records every check and continues.
    if (-not $Preflight) { return & $CheckScript }
    $checkTitles[$CheckId] = $CheckTitle
    $blocking = @($RequiredCheck | Where-Object { -not $completedChecks.Contains($_) })
    if ($blocking.Count -gt 0) {
        $names = @($blocking | ForEach-Object { if ($checkTitles.ContainsKey($_)) { $checkTitles[$_] } else { $_ } })
        $checkResults.Add([pscustomobject]@{
            Area = $CheckArea; Check = $CheckTitle; Status = 'Skip'; Detail = "Requires a completed check: $($names -join '; ')."
        })
        return
    }
    $checkWarnings.Clear()
    try {
        $value = & $CheckScript
    }
    catch {
        $checkResults.Add([pscustomobject]@{ Area = $CheckArea; Check = $CheckTitle; Status = 'Fail'; Detail = $_.Exception.Message })
        return
    }
    $null = $completedChecks.Add($CheckId)
    $status = if ($checkWarnings.Count -gt 0) { 'Manual' } else { 'Pass' }
    $detail = if ($checkWarnings.Count -gt 0) { $checkWarnings -join ' ' } else { $PassDetail }
    $checkResults.Add([pscustomobject]@{ Area = $CheckArea; Check = $CheckTitle; Status = $status; Detail = $detail })
    return $value
}

function Write-BootstrapCheckWarning {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Message)

    if ($Preflight) { $checkWarnings.Add($Message) } else { Write-Warning -Message $Message }
}

function Get-BootstrapMissingAction {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Scope,
        [Parameter(Mandatory)][string[]] $Action
    )

    # The permissions API omits ABAC conditions and deny assignments, so a match is necessary but not sufficient.
    $permissionSets = @(Get-BootstrapCollection -Uri "$arm$Scope/providers/Microsoft.Authorization/permissions?api-version=2022-04-01")
    foreach ($operation in $Action) {
        $allowed = @($permissionSets | Where-Object {
            $permissionSet = $_
            @($permissionSet['actions'] | Where-Object { $operation -like $_ }).Count -gt 0 -and
            @($permissionSet['notActions'] | Where-Object { $operation -like $_ }).Count -eq 0
        }).Count -gt 0
        if (-not $allowed) { $operation }
    }
}

function Get-BootstrapAzureToken {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $Resource)

    $text = & az account get-access-token --tenant $connection['tenantId'] --resource $Resource --output json --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) {
        throw "Azure authentication failed for '$Resource'. Run az login --tenant $($connection['tenantId']) with the bootstrap user."
    }
    $token = ConvertFrom-Json -InputObject $text -AsHashtable
    if ($token['tenant'] -ne $connection['tenantId'] -or [string]::IsNullOrWhiteSpace($token['accessToken'])) {
        throw "Azure token does not belong to $.bootstrap.tenantId for '$Resource'."
    }
    return $token['accessToken']
}

function Invoke-BootstrapRequest {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('GET', 'POST', 'PUT', 'PATCH')][string] $Method = 'GET',
        [System.Collections.IDictionary] $Body,
        [switch] $AllowNotFound,
        [switch] $WaitForPrincipal
    )

    $address = [uri] $Uri
    if ($address.Scheme -ne 'https' -or -not $tokens.ContainsKey($address.Host) -or -not $address.IsDefaultPort -or
        $address.UserInfo -or $address.Fragment) {
        throw "Untrusted bootstrap API address '$Uri'."
    }
    $arguments = @{
        Uri = $Uri
        Method = $Method
        Headers = @{ Authorization = "Bearer $($tokens[$address.Host])"; Accept = 'application/json' }
        ContentType = 'application/json'
        SkipHttpErrorCheck = $true
        MaximumRedirection = 0
        TimeoutSec = 60
        MaximumRetryCount = 0
    }
    if ($Body) {
        $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
    }
    $attemptLimit = if ($NoChanges) { 1 } else { 12 }
    for ($attempt = 0; $attempt -lt $attemptLimit; $attempt++) {
        $readOnlyPost = $Method -ceq 'POST' -and (
            ($Uri -ceq "https://$githubApi/graphql" -and $Body -and $Body['query'] -ceq $ownerQuery) -or
            ($address.Host -ceq 'management.azure.com' -and $address.AbsolutePath -ceq '/providers/Microsoft.Management/getEntities' -and -not $Body))
        $kind = if ($Method -ceq 'GET' -or $readOnlyPost) { 'Read' } else { 'Reconcile' }
        Assert-PlatformBootstrapRequest -Uri $Uri -Method $Method -Body $Body -NoChanges:$NoChanges `
            -ReadOnlyPost:$readOnlyPost -Kind $kind -RequestPolicy $requestPolicyCallback
        $response = Invoke-WebRequest @arguments
        if ($response.StatusCode -eq 404 -and $AllowNotFound -and $Method -eq 'GET') {
            return $null
        }
        $transientResponse = $response.StatusCode -in @(429, 503)
        $data = @{}
        if (-not $transientResponse -and -not [string]::IsNullOrWhiteSpace($response.Content)) {
            try {
                $data = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop
            }
            catch {
                throw "Bootstrap API $Method '$Uri' returned invalid JSON (HTTP $($response.StatusCode)): $($_.Exception.Message)"
            }
            if ($data -isnot [System.Collections.IDictionary]) {
                throw "Bootstrap API $Method '$Uri' did not return a JSON object (HTTP $($response.StatusCode))."
            }
        }
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) { return $data }
        $replicating = $WaitForPrincipal -and $data.Contains('error') -and
            $data['error']['code'] -in @('PrincipalNotFound', 'Request_ResourceNotFound', 'ResourceNotFound')
        if ($attempt -lt ($attemptLimit - 1) -and ($replicating -or $transientResponse)) {
            Write-Verbose "Retrying $Method '$Uri' after HTTP $($response.StatusCode)."
            Start-Sleep -Seconds 5
            continue
        }
        $detail = if ($data.Contains('error')) { ConvertTo-Json -InputObject $data['error'] -Compress } else { $response.Content }
        throw "Bootstrap API $Method '$Uri' failed (HTTP $($response.StatusCode)): $detail. Rerun bootstrap after correcting the cause."
    }
}

function Get-BootstrapCollection {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [ValidateSet('GET', 'POST')][string] $Method = 'GET',
        [switch] $WaitForPrincipal
    )

    $visited = [System.Collections.Generic.HashSet[string]]::new()
    while ($Uri) {
        if (-not $visited.Add($Uri)) { throw "API pagination cycle at '$Uri'." }
        $page = Invoke-BootstrapRequest -Uri $Uri -Method $Method -WaitForPrincipal:$WaitForPrincipal
        if ($page['value'] -isnot [System.Collections.IList]) { throw "API '$Uri' did not return a collection." }
        foreach ($item in $page['value']) {
            if ($item -isnot [System.Collections.IDictionary]) { throw "API '$Uri' returned an invalid collection item." }
            $item
        }
        $Uri = if ($page.Contains('@odata.nextLink')) { $page['@odata.nextLink'] } else { $page['nextLink'] }
    }
}

function Test-BootstrapDesiredValue {
    [CmdletBinding()]
    [OutputType([bool])]
    param($Actual, $Desired)

    if ($Desired -is [System.Collections.IDictionary]) {
        if ($Actual -isnot [System.Collections.IDictionary]) { return $false }
        foreach ($key in $Desired.Keys) {
            if (-not $Actual.Contains($key) -or -not (Test-BootstrapDesiredValue -Actual $Actual[$key] -Desired $Desired[$key])) {
                return $false
            }
        }
        return $true
    }
    if ($Desired -is [System.Collections.IList]) {
        if ($Actual -isnot [System.Collections.IList] -or $Actual.Count -ne $Desired.Count) { return $false }
        for ($index = 0; $index -lt $Desired.Count; $index++) {
            if (-not (Test-BootstrapDesiredValue -Actual $Actual[$index] -Desired $Desired[$index])) { return $false }
        }
        return $true
    }
    return $Actual -ceq $Desired
}

# security-check: azure-unconditional-role
function Assert-BootstrapUnconditionalRole {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Assignment)

    if (-not [string]::IsNullOrWhiteSpace($Assignment['properties']['condition'])) {
        throw "Bootstrap does not support conditional Azure role assignment '$($Assignment['id'])'. Remove its condition through an approved access change before rerunning bootstrap."
    }
}

function Initialize-BootstrapResource {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Body
    )

    $current = Invoke-BootstrapRequest -Uri $Uri -AllowNotFound
    if ($current -and $Uri -like '*/providers/Microsoft.Authorization/roleAssignments/*') {
        Assert-BootstrapUnconditionalRole -Assignment $current
    }
    if ($current -and $Uri -match '/storageAccounts/[^/?]+\?') {
        # These features are enabled only by true; Shared Key and TLS have different defaults.
        foreach ($property in @('allowBlobPublicAccess', 'isHnsEnabled', 'isNfsV3Enabled', 'isSftpEnabled', 'isLocalUserEnabled')) {
            if (-not $current['properties'].Contains($property) -or $null -eq $current['properties'][$property]) {
                $current['properties'][$property] = $false
            }
        }
    }
    if ($current -and $Body.Contains('tags') -and -not (Test-BootstrapDesiredValue -Actual $current['tags'] -Desired $Body['tags'])) {
        throw "Existing resource '$Uri' does not have the expected bootstrap ownership tags; refusing to adopt it."
    }
    if (-not (Test-BootstrapDesiredValue -Actual $current -Desired $Body)) {
        $current = Invoke-BootstrapRequest -Uri $Uri -Method PUT -Body $Body -WaitForPrincipal:($Uri -like '*/roleAssignments/*')
        $changedResources.Add($Uri)
    }
    if ($Uri -match '/storageAccounts/[^/?]+\?') {
        for ($attempt = 0; $attempt -lt 120; $attempt++) {
            $current = Invoke-BootstrapRequest -Uri $Uri
            $state = $current['properties']['provisioningState']
            if ($state -eq 'Succeeded') {
                if ($current['properties']['publicNetworkAccess'] -ne 'Enabled') {
                    throw "State backend requires publicNetworkAccess 'Enabled' for GitHub-hosted runners (ADR 0011). Check Azure Policy and storage network settings before rerunning bootstrap."
                }
                return $current
            }
            if ($state -in @('Failed', 'Canceled')) { throw "Provisioning '$Uri' ended with '$state'." }
            Start-Sleep -Seconds 5
        }
        throw "Timed out waiting for provisioning '$Uri'. Rerun bootstrap to resume."
    }
    return $current
}

function Initialize-BootstrapRoleAssignment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Scope,
        [Parameter(Mandatory)][string] $PrincipalId,
        [Parameter(Mandatory)][string] $RoleDefinitionId
    )

    $filter = [uri]::EscapeDataString("principalId eq '$PrincipalId'")
    $assignments = @(Get-BootstrapCollection -Uri "$arm$Scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=$filter")
    $matchingAssignments = @($assignments | Where-Object {
        $_['properties']['principalId'] -eq $PrincipalId -and
        $_['properties']['scope'] -eq $Scope -and
        ($_['properties']['roleDefinitionId'] -split '/')[-1] -eq ($RoleDefinitionId -split '/')[-1]
    })
    foreach ($assignment in $matchingAssignments) {
        Assert-BootstrapUnconditionalRole -Assignment $assignment
    }
    if ($matchingAssignments.Count -gt 0) { return }
    $hash = [System.Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes("$Scope|$PrincipalId|$RoleDefinitionId".ToLowerInvariant())
    )
    $assignmentId = [guid]::new([byte[]] $hash[0..15]).ToString()
    $null = Initialize-BootstrapResource -Uri "$arm$Scope/providers/Microsoft.Authorization/roleAssignments/$assignmentId`?api-version=2022-04-01" -Body @{
        properties = @{ principalId = $PrincipalId; principalType = 'ServicePrincipal'; roleDefinitionId = $RoleDefinitionId }
    }
}

function Get-BootstrapIdentityGrant {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][ValidateSet('plan', 'apply')][string] $Phase,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Identity
    )

    if (-not $Identity['properties']['principalId'] -or -not $Identity['properties']['clientId'] -or
        $Identity['properties']['tenantId'] -ne $connection['tenantId']) {
        throw "Managed identity '$Name/$Phase' has no usable principal or belongs to another tenant. Rerun bootstrap to resume."
    }
    $principalId = $Identity['properties']['principalId']
    $expectedAzure = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
    $containerId = "$storageAccountId/blobServices/default/containers/$Name"
    $null = $expectedAzure.Add("$containerId|ba92f5b4-2d11-453d-a403-e96b0029c9fe")
    foreach ($grant in $azureGrants[$Name][$Phase].Values) {
        $null = $expectedAzure.Add("$($grant['scope'])|$(($grant['roleDefinitionId'] -split '/')[-1])")
    }
    $filter = [uri]::EscapeDataString("principalId eq '$principalId'")
    foreach ($scope in $azureAuditScopes) {
        $existing = @(Get-BootstrapCollection -Uri "$arm$scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=$filter")
        foreach ($assignment in $existing) {
            $key = "$($assignment['properties']['scope'])|$(($assignment['properties']['roleDefinitionId'] -split '/')[-1])"
            if (-not $expectedAzure.Contains($key)) {
                throw "Identity '$Name/$Phase' has an unexpected Azure role at '$($assignment['properties']['scope'])'. Remove it through an approved access change before rerunning bootstrap."
            }
            Assert-BootstrapUnconditionalRole -Assignment $assignment
        }
    }
    $graphAssignments = @(Get-BootstrapCollection -Uri "$graph/servicePrincipals/$principalId/appRoleAssignments" -WaitForPrincipal)
    foreach ($assignment in $graphAssignments) {
        if (-not $graphServicePrincipal -or $assignment['resourceId'] -ne $graphServicePrincipal['id'] -or
            -not $graphGrants[$Name][$Phase].ContainsKey($assignment['appRoleId'])) {
            throw "Identity '$Name/$Phase' has an unexpected application permission '$($assignment['appRoleId'])'. Remove it through an approved access change before rerunning bootstrap."
        }
    }
    return $graphAssignments
}

function Get-BootstrapDirectoryRoleAssignment {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][ValidateSet('plan', 'apply')][string] $Phase,
        [Parameter(Mandatory)][string] $PrincipalId
    )

    $expected = $directoryRoles[$Name][$Phase]
    $filter = [uri]::EscapeDataString("principalId eq '$PrincipalId'")
    $assignments = @(Get-BootstrapCollection -Uri "$graph/roleManagement/directory/roleAssignments?`$filter=$filter" -WaitForPrincipal)
    foreach ($assignment in $assignments) {
        if (-not $expected -or -not $expected['Definition'] -or $assignment['roleDefinitionId'] -ne $expected['Definition']['id'] -or
            $assignment['directoryScopeId'] -ne $expected['ScopeId']) {
            throw "Identity '$Name/$Phase' has an unexpected Entra directory role '$($assignment['roleDefinitionId'])' at '$($assignment['directoryScopeId'])'. Remove it through an approved access change before rerunning bootstrap."
        }
    }
    return $assignments
}

$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules -AllowUnboundApps:$AllowUnboundApps
if (-not $Preflight) {
    Assert-PlatformManualPrerequisite -Instance $instance
}
if (-not $instance.Contains('bootstrap')) {
    throw 'Bootstrap requires $.bootstrap connection identifiers.'
}
$connection = $instance['bootstrap']
if ($connection['managementSubscriptionId'] -notin $connection['subscriptionIds']) {
    throw '$.bootstrap.subscriptionIds must include $.bootstrap.managementSubscriptionId.'
}
if ($connection['githubHost'] -cne "$($connection['enterprise']).ghe.com") {
    throw '$.bootstrap.githubHost must match $.bootstrap.enterprise on GHE.com.'
}
$githubApi = "api.$($connection['githubHost'])"
$graph = 'https://graph.microsoft.com/v1.0'
$arm = 'https://management.azure.com'
$tokens = @{}
$githubToken = Invoke-BootstrapCheck -CheckId 'github-login' -CheckArea 'GitHub' -CheckTitle 'gh OAuth login' `
    -PassDetail 'gh returns a stored OAuth token and no token environment variable overrides it.' -CheckScript {
    foreach ($variable in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
        if (-not [string]::IsNullOrEmpty([Environment]::GetEnvironmentVariable($variable))) {
            throw "Bootstrap refuses $variable. Use the stored OAuth login from gh auth login."
        }
    }
    $token = (& gh auth token --hostname $connection['githubHost'] 2>&1 | Out-String).Trim()
    if ($LASTEXITCODE -ne 0 -or $token -cnotmatch '^gho_[A-Za-z0-9_]+$') {
        throw "Bootstrap requires an OAuth token from gh auth login --hostname $($connection['githubHost']); PATs are not supported."
    }
    $token
}
if ($githubToken) { $tokens[$githubApi] = $githubToken }
$azureTokens = Invoke-BootstrapCheck -CheckId 'azure-login' -CheckArea 'Azure' -CheckTitle 'Azure CLI login' `
    -PassDetail 'Azure CLI issues Microsoft Graph and Azure Resource Manager tokens for the bootstrap tenant.' -CheckScript {
    @{
        'graph.microsoft.com' = Get-BootstrapAzureToken -Resource 'https://graph.microsoft.com/'
        'management.azure.com' = Get-BootstrapAzureToken -Resource 'https://management.azure.com/'
    }
}
if ($azureTokens) { foreach ($tokenHost in $azureTokens.Keys) { $tokens[$tokenHost] = $azureTokens[$tokenHost] } }
$user = Invoke-BootstrapCheck -CheckId 'azure-user' -CheckArea 'Entra ID' -CheckTitle 'Bootstrap user in teams.platform' `
    -RequiredCheck 'azure-login' -PassDetail 'The signed-in Azure user is listed in $.teams.platform.' -CheckScript {
    $signedInUser = Invoke-BootstrapRequest -Uri "$graph/me"
    if ($signedInUser['userPrincipalName'] -notin $instance['teams']['platform']) {
        throw 'The Azure bootstrap user must be a member of $.teams.platform.'
    }
    $signedInUser
}
$enterpriseApplication = Invoke-BootstrapCheck -CheckId 'enterprise-application' -CheckArea 'Entra ID' -CheckTitle 'EMU OIDC enterprise application' `
    -RequiredCheck 'azure-login' -PassDetail 'Graph reports OIDC launch mode and one enabled Enterprise Owner app role.' -CheckScript {
    $application = Invoke-BootstrapRequest -Uri "$graph/servicePrincipals/$($connection['enterpriseApplicationObjectId'])"
    $verified = $application['preferredSingleSignOnMode'] -eq 'oidc'
    if ($null -eq $application['preferredSingleSignOnMode']) {
        Write-BootstrapCheckWarning -Message 'Graph does not expose the OIDC launch mode. Using the required manual $.manualPrerequisites.enterpriseOidc confirmation; OIDC is not automatically verified.'
    }
    elseif (-not $verified) {
        throw '$.bootstrap.enterpriseApplicationObjectId must identify the EMU OIDC enterprise application.'
    }
    $ownerRoles = @($application['appRoles'] | Where-Object {
        $_['displayName'] -eq 'Enterprise Owner' -and $_['isEnabled'] -eq $true -and 'User' -in $_['allowedMemberTypes']
    })
    if ($ownerRoles.Count -ne 1) {
        throw 'The EMU enterprise application must expose one enabled Enterprise Owner app role.'
    }
    @{ OidcModeVerified = $verified; OwnerRoleId = $ownerRoles[0]['id'] }
}
$null = Invoke-BootstrapCheck -CheckId 'enterprise-owner' -CheckArea 'Entra ID' -CheckTitle 'Direct Enterprise Owner assignment' `
    -RequiredCheck 'azure-user', 'enterprise-application' -PassDetail 'The bootstrap user has a direct Enterprise Owner app role assignment.' -CheckScript {
    $assignments = @(Get-BootstrapCollection -Uri "$graph/servicePrincipals/$($connection['enterpriseApplicationObjectId'])/appRoleAssignedTo")
    $directOwner = @($assignments | Where-Object {
        $_['principalId'] -eq $user['id'] -and $_['principalType'] -eq 'User' -and $_['appRoleId'] -eq $enterpriseApplication['OwnerRoleId']
    })
    if ($directOwner.Count -eq 0) {
        throw 'The bootstrap user requires a direct Enterprise Owner app role assignment; group-inherited roles are insufficient.'
    }
}
$null = Invoke-BootstrapCheck -CheckId 'scim' -CheckArea 'Entra ID' -CheckTitle 'SCIM provisioning job' `
    -RequiredCheck 'enterprise-application' -PassDetail 'A provisioning job has an active schedule and status.' -CheckScript {
    $jobs = @(Get-BootstrapCollection -Uri "$graph/servicePrincipals/$($connection['enterpriseApplicationObjectId'])/synchronization/jobs")
    if (@($jobs | Where-Object { $_['schedule']['state'] -eq 'Active' -and $_['status']['code'] -eq 'Active' }).Count -eq 0) {
        throw 'The EMU enterprise application requires an active SCIM provisioning job.'
    }
}
$null = Invoke-BootstrapCheck -CheckId 'entra-license' -CheckArea 'Entra ID' -CheckTitle 'Entra ID P1 or P2 license' `
    -RequiredCheck 'azure-login' -PassDetail 'An enabled SKU provisions AAD_PREMIUM or AAD_PREMIUM_P2.' -CheckScript {
    $skus = @(Get-BootstrapCollection -Uri "$graph/subscribedSkus")
    $licensed = @($skus | Where-Object {
        $_['capabilityStatus'] -eq 'Enabled' -and $_['prepaidUnits']['enabled'] -gt 0 -and
        @($_['servicePlans'] | Where-Object {
            $_['servicePlanName'] -in @('AAD_PREMIUM', 'AAD_PREMIUM_P2') -and $_['provisioningStatus'] -eq 'Success'
        }).Count -gt 0
    })
    if ($licensed.Count -eq 0) {
        throw 'Bootstrap requires an enabled Entra ID P1 or P2 service plan; other licenses require $.manualPrerequisites.licenses.'
    }
}
$null = Invoke-BootstrapCheck -CheckId 'subscriptions' -CheckArea 'Azure' -CheckTitle 'Subscriptions in the bootstrap tenant' `
    -RequiredCheck 'azure-login' -PassDetail "All $(@($connection['subscriptionIds']).Count) configured subscriptions are enabled in the bootstrap tenant." -CheckScript {
    foreach ($subscriptionId in $connection['subscriptionIds']) {
        $subscription = Invoke-BootstrapRequest -Uri "$arm/subscriptions/$subscriptionId`?api-version=2022-12-01"
        if ($subscription['tenantId'] -ne $connection['tenantId'] -or $subscription['state'] -ne 'Enabled') {
            throw "Subscription '$subscriptionId' must be enabled and belong to $.bootstrap.tenantId."
        }
    }
}
$null = Invoke-BootstrapCheck -CheckId 'github-owner' -CheckArea 'GitHub' -CheckTitle 'Enterprise owner in GitHub' `
    -RequiredCheck 'github-login' -PassDetail 'The gh OAuth user is an owner of $.bootstrap.enterprise.' -CheckScript {
    $ownerQuery = 'query($enterprise:String!,$cursor:String){viewer{login} enterprise(slug:$enterprise){viewerIsAdmin ownerInfo{admins(first:100,role:OWNER,after:$cursor){nodes{login} pageInfo{hasNextPage endCursor}}}}}'
    $cursor = $null
    $githubOwner = $false
    $seenCursors = [System.Collections.Generic.HashSet[string]]::new()
    do {
        $reply = Invoke-BootstrapRequest -Uri "https://$githubApi/graphql" -Method POST -Body @{
            query = $ownerQuery
            variables = @{ enterprise = $connection['enterprise']; cursor = $cursor }
        }
        if ($reply.Contains('errors')) {
            throw "GitHub enterprise verification failed: $(ConvertTo-Json -InputObject $reply['errors'] -Compress)"
        }
        $enterprise = $reply['data']['enterprise']
        if (-not $enterprise -or -not $enterprise['viewerIsAdmin'] -or -not $enterprise['ownerInfo']) {
            throw 'The gh OAuth user must be an owner of $.bootstrap.enterprise.'
        }
        $admins = $enterprise['ownerInfo']['admins']
        if ($reply['data']['viewer']['login'] -in @($admins['nodes'] | ForEach-Object { $_['login'] })) {
            $githubOwner = $true
            break
        }
        $cursor = $admins['pageInfo']['endCursor']
        if ($admins['pageInfo']['hasNextPage'] -and (-not $cursor -or -not $seenCursors.Add($cursor))) {
            throw 'Invalid GitHub enterprise owner pagination.'
        }
    } while ($admins['pageInfo']['hasNextPage'])
    if (-not $githubOwner) { throw 'The gh OAuth user must be an owner of $.bootstrap.enterprise.' }
}

$resourceGroupName = "rg-$($instance['instance']['name'])-bootstrap"
$storageAccountName = "st$($instance['instance']['name'])tfstate"
$resourceGroupId = "/subscriptions/$($connection['managementSubscriptionId'])/resourceGroups/$resourceGroupName"
$storageAccountId = "$resourceGroupId/providers/Microsoft.Storage/storageAccounts/$storageAccountName"
$tags = @{ platformInstance = $instance['instance']['name']; platformComponent = 'bootstrap' }
$selected = Get-PlatformModuleSelection -Instance $instance -Modules $modules
$azureAuditScopes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
$azureGrants = @{}
$graphGrants = @{}
$directoryRoles = @{}
$graphServicePrincipal = $null
if ($Preflight) {
    $managementScope = "/subscriptions/$($connection['managementSubscriptionId'])"
    $null = Invoke-BootstrapCheck -CheckId 'resource-providers' -CheckArea 'Azure' -CheckTitle 'Resource providers in the management subscription' `
        -RequiredCheck 'azure-login' -PassDetail 'Microsoft.Storage and Microsoft.ManagedIdentity are registered.' -CheckScript {
        $unregistered = foreach ($namespace in @('Microsoft.Storage', 'Microsoft.ManagedIdentity')) {
            $provider = Invoke-BootstrapRequest -Uri "$arm$managementScope/providers/$namespace`?api-version=2021-04-01"
            if ($provider['registrationState'] -ne 'Registered') { "$namespace ($($provider['registrationState']))" }
        }
        if (@($unregistered).Count -gt 0) {
            throw "Register the resource providers in the management subscription: $(@($unregistered) -join ', ')."
        }
    }
    $null = Invoke-BootstrapCheck -CheckId 'azure-permissions' -CheckArea 'Azure' -CheckTitle 'Bootstrap user permissions in the management subscription' `
        -RequiredCheck 'azure-login' -PassDetail 'Effective role actions allow all bootstrap writes and role assignments. ABAC conditions and deny assignments are not evaluated.' -CheckScript {
        $missing = @(Get-BootstrapMissingAction -Scope $managementScope -Action @(
            'Microsoft.Resources/subscriptions/resourceGroups/write'
            'Microsoft.Storage/storageAccounts/write'
            'Microsoft.Storage/storageAccounts/blobServices/write'
            'Microsoft.Storage/storageAccounts/blobServices/containers/write'
            'Microsoft.Authorization/locks/write'
            'Microsoft.ManagedIdentity/userAssignedIdentities/write'
            'Microsoft.Authorization/roleAssignments/write'
            'Microsoft.Authorization/roleAssignments/read'
        ))
        if ($missing.Count -gt 0) {
            throw "The bootstrap user lacks actions in the management subscription: $($missing -join ', '). Assign the Owner role on the management subscription."
        }
    }
    $null = Invoke-BootstrapCheck -CheckId 'state-backend' -CheckArea 'Azure' -CheckTitle 'State backend names' `
        -RequiredCheck 'resource-providers' -PassDetail "Resource group '$resourceGroupName' and storage account '$storageAccountName' are free or carry this instance's bootstrap tags." -CheckScript {
        $resourceGroup = Invoke-BootstrapRequest -Uri "$arm$resourceGroupId`?api-version=2022-09-01" -AllowNotFound
        if ($resourceGroup -and -not (Test-BootstrapDesiredValue -Actual $resourceGroup['tags'] -Desired $tags)) {
            throw "Existing resource group '$resourceGroupName' does not have the expected bootstrap ownership tags; bootstrap would refuse to adopt it."
        }
        $storageAccount = if ($resourceGroup) { Invoke-BootstrapRequest -Uri "$arm$storageAccountId`?api-version=2023-05-01" -AllowNotFound }
        if ($storageAccount -and -not (Test-BootstrapDesiredValue -Actual $storageAccount['tags'] -Desired $tags)) {
            throw "Existing storage account '$storageAccountName' does not have the expected bootstrap ownership tags; bootstrap would refuse to adopt it."
        }
        if (-not $storageAccount) {
            $availability = Invoke-BootstrapRequest -Uri "$arm$managementScope/providers/Microsoft.Storage/checkNameAvailability?api-version=2023-05-01" `
                -Method POST -Body @{ name = $storageAccountName; type = 'Microsoft.Storage/storageAccounts' }
            if ($availability['nameAvailable'] -ne $true) {
                throw "Storage account name '$storageAccountName' is not available ($($availability['reason'])). Choose another $.instance.name."
            }
        }
    }
}
if (@($selected).Count -gt 0) {
    $null = Invoke-BootstrapCheck -CheckId 'management-group-ancestry' -CheckArea 'Azure' -CheckTitle 'Management-group ancestry' `
        -RequiredCheck 'azure-login' -PassDetail 'Every configured subscription has a complete management-group chain to the tenant root.' -CheckScript {
        foreach ($subscriptionId in $connection['subscriptionIds']) {
            $null = $azureAuditScopes.Add("/subscriptions/$subscriptionId")
            $filter = [uri]::EscapeDataString("name eq '$subscriptionId'")
            $entities = @(Get-BootstrapCollection -Uri "$arm/providers/Microsoft.Management/getEntities?api-version=2020-05-01&`$filter=$filter" -Method POST)
            $subscriptionEntities = @($entities | Where-Object {
                $_['id'] -eq "/subscriptions/$subscriptionId" -and $_['name'] -eq $subscriptionId -and $_['type'] -eq '/subscriptions'
            })
            if ($subscriptionEntities.Count -ne 1) {
                throw "Cannot determine management-group ancestors for subscription '$subscriptionId'."
            }
            $properties = $subscriptionEntities[0]['properties']
            $ancestors = $properties['parentNameChain']
            if ($properties['tenantId'] -ne $connection['tenantId'] -or
                $ancestors -isnot [System.Collections.IList] -or $ancestors.Count -eq 0 -or
                $ancestors[0] -ne $connection['tenantId']) {
                throw "Subscription '$subscriptionId' requires a complete management-group ancestor chain including its tenant root."
            }
            $seenGroups = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($group in $ancestors) {
                if ($group -isnot [string] -or $group -notmatch '^[A-Za-z0-9_.()-]+$' -or -not $seenGroups.Add($group)) {
                    throw "Subscription '$subscriptionId' has an invalid management-group ancestor chain."
                }
                $null = $azureAuditScopes.Add("/providers/Microsoft.Management/managementGroups/$group")
            }
        }
    }
    $graphServicePrincipal = Invoke-BootstrapCheck -CheckId 'module-permissions' -CheckArea 'Modules' -CheckTitle 'Module permission declarations' `
        -RequiredCheck 'azure-login' -PassDetail "Azure roles and Microsoft Graph permissions of $(@($selected).Count) selected modules resolve and keep state isolation." -CheckScript {
        $graphPrincipal = $null
        if (@($selected | Where-Object { $modules[$_]['permissions']['microsoftGraph'].Count -gt 0 }).Count -gt 0) {
            $filter = [uri]::EscapeDataString("appId eq '00000003-0000-0000-c000-000000000000'")
            $principals = @(Get-BootstrapCollection -Uri "$graph/servicePrincipals?`$filter=$filter")
            if ($principals.Count -ne 1) { throw 'The tenant must contain exactly one Microsoft Graph service principal.' }
            $graphPrincipal = $principals[0]
        }
        foreach ($name in $selected) {
            if ($name.Length -lt 3) { throw "Module '$name' cannot be used as an Azure state container; at least three characters are required." }
            $azureGrants[$name] = @{ plan = @{}; apply = @{} }
            $graphGrants[$name] = @{ plan = @{}; apply = @{} }
            foreach ($grant in $modules[$name]['permissions']['azure']) {
                $phase = if ($grant.Contains('phase')) { $grant['phase'] } else { 'apply' }
                $scope = $grant['scope'].TrimEnd('/')
                if ($scope -match '^/subscriptions/([0-9a-fA-F-]{36})(/[A-Za-z0-9_.()/\-]+)?$') {
                    if ($Matches[1] -notin $connection['subscriptionIds']) {
                        throw "Module '$name' role scope '$scope' requires its subscription in $.bootstrap.subscriptionIds."
                    }
                }
                elseif ($scope -notmatch '^/providers/Microsoft.Management/managementGroups/[A-Za-z0-9_.()-]+$') {
                    throw "Module '$name' role scope '$scope' must be an absolute ARM subscription or management group scope."
                }
                else {
                    $null = $azureAuditScopes.Add($scope)
                }
                if ($scope.StartsWith($resourceGroupId, [StringComparison]::OrdinalIgnoreCase)) {
                    throw "Module '$name' must not declare permissions on bootstrap resources; state access is assigned only to its own container."
                }
                $filter = [uri]::EscapeDataString("roleName eq '$($grant['role'].Replace("'", "''"))'")
                $definitions = @(Get-BootstrapCollection -Uri "$arm$scope/providers/Microsoft.Authorization/roleDefinitions?api-version=2022-04-01&`$filter=$filter")
                if ($definitions.Count -ne 1) { throw "Module '$name' Azure role '$($grant['role'])' is missing or ambiguous at '$scope'." }
                $definition = $definitions[0]
                $actions = @($definition['properties']['permissions'] | ForEach-Object { $_['actions']; $_['dataActions'] } | Where-Object { $_ })
                $readOnly = @($actions | Where-Object { $_ -notlike '*/read' }).Count -eq 0
                if ($phase -eq 'plan' -and -not $readOnly) {
                    throw "Module '$name' plan role '$($grant['role'])' is not read-only."
                }
                $coversStateBackend = $storageAccountId.StartsWith("$scope/", [StringComparison]::OrdinalIgnoreCase) -or
                    $scope -like '/providers/Microsoft.Management/managementGroups/*'
                $blobReadOperation = 'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'
                $canReadState = @($definition['properties']['permissions'] | Where-Object {
                    $permissionSet = $_
                    @($permissionSet['dataActions'] | Where-Object { $blobReadOperation -like $_ }).Count -gt 0 -and
                    @($permissionSet['notDataActions'] | Where-Object { $blobReadOperation -like $_ }).Count -eq 0
                }).Count -gt 0
                if ($coversStateBackend -and $canReadState) {
                    throw "Module '$name' role '$($grant['role'])' could read another module's state; choose a scope outside bootstrap."
                }
                if (-not $readOnly -and $coversStateBackend) {
                    throw "Module '$name' role '$($grant['role'])' could change the state backend or its access; choose a scope outside bootstrap."
                }
                $azureGrants[$name][$phase]["$scope|$($definition['id'])"] = @{ scope = $scope; roleDefinitionId = $definition['id'] }
            }
            foreach ($grant in $modules[$name]['permissions']['microsoftGraph']) {
                $phase = if ($grant -is [string]) { 'apply' } else { $grant['phase'] }
                $permission = if ($grant -is [string]) { $grant } else { $grant['permission'] }
                if ($phase -eq 'plan' -and $permission -notmatch '\.Read(Basic)?(\.|$)') {
                    throw "Module '$name' plan Microsoft Graph permission '$permission' is not read-only."
                }
                if ($name -eq 'emu-identity' -and $permission -eq 'AppRoleAssignment.ReadWrite.All') {
                    throw "Module 'emu-identity' must not receive AppRoleAssignment.ReadWrite.All (ADR 0015)."
                }
                $roles = @($graphPrincipal['appRoles'] | Where-Object {
                    $_['value'] -eq $permission -and $_['isEnabled'] -eq $true -and 'Application' -in $_['allowedMemberTypes']
                })
                if ($roles.Count -ne 1) { throw "Module '$name' Microsoft Graph application permission '$permission' is missing or disabled." }
                $graphGrants[$name][$phase][$roles[0]['id']] = $permission
            }
            $directoryRoles[$name] = @{}
            $declaredRoles = if ($modules[$name]['permissions'].Contains('entraDirectoryRoles')) { @($modules[$name]['permissions']['entraDirectoryRoles']) } else { @() }
            foreach ($role in $declaredRoles) {
                $phase = $role['phase']
                if ($directoryRoles[$name].ContainsKey($phase)) {
                    throw "Module '$name' declares more than one $phase Entra directory role."
                }
                [string[]] $actions = @($role['actions'] | Sort-Object -Unique -CaseSensitive)
                if ($phase -eq 'plan' -and @($actions | Where-Object { $_ -notlike '*/read' }).Count -gt 0) {
                    throw "Module '$name' plan Entra directory role is not read-only."
                }
                $displayName = "platform-$($instance['instance']['name'])-$name-$phase"
                $filter = [uri]::EscapeDataString("displayName eq '$displayName'")
                $definitions = @(Get-BootstrapCollection -Uri "$graph/roleManagement/directory/roleDefinitions?`$filter=$filter")
                if ($definitions.Count -gt 1) { throw "Entra directory role '$displayName' is ambiguous." }
                $definition = if ($definitions.Count -eq 1) { $definitions[0] } else { $null }
                if ($definition -and $definition['isBuiltIn'] -ne $false) {
                    throw "Entra directory role '$displayName' is built-in; refusing to adopt it."
                }
                $directoryRoles[$name][$phase] = @{
                    DisplayName = $displayName
                    Actions = $actions
                    Definition = $definition
                    ScopeId = "/$($connection['enterpriseApplicationObjectId'])"
                }
            }
        }
        $graphPrincipal
    }
    if ($Preflight) {
        $null = Invoke-BootstrapCheck -CheckId 'module-role-assignments' -CheckArea 'Azure' -CheckTitle 'Role assignment rights at module scopes' `
            -RequiredCheck 'module-permissions' -PassDetail 'Effective role actions allow role assignments at every module scope. ABAC conditions and deny assignments are not evaluated.' -CheckScript {
            $grantScopes = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            foreach ($name in $selected) {
                foreach ($phase in @('plan', 'apply')) {
                    foreach ($grant in $azureGrants[$name][$phase].Values) { $null = $grantScopes.Add($grant['scope']) }
                }
            }
            $deniedScopes = foreach ($scope in $grantScopes) {
                if ($scope -like '/providers/Microsoft.Management/managementGroups/*') {
                    Write-BootstrapCheckWarning -Message "Verify Microsoft.Authorization/roleAssignments/write at '$scope' manually; Azure does not report effective permissions for management groups."
                }
                elseif (@(Get-BootstrapMissingAction -Scope $scope -Action 'Microsoft.Authorization/roleAssignments/write').Count -gt 0) {
                    $scope
                }
            }
            if (@($deniedScopes).Count -gt 0) {
                throw "The bootstrap user cannot assign roles at module scopes: $(@($deniedScopes) -join ', ')."
            }
        }
    }
    $null = Invoke-BootstrapCheck -CheckId 'role-assignment-audit' -CheckArea 'Azure' -CheckTitle 'Role assignment audit' `
        -RequiredCheck 'azure-user', 'management-group-ancestry', 'module-permissions' -PassDetail 'The bootstrap user can list role assignments at every audited scope.' -CheckScript {
        $filter = [uri]::EscapeDataString("principalId eq '$($user['id'])'")
        foreach ($scope in $azureAuditScopes) {
            $null = @(Get-BootstrapCollection -Uri "$arm$scope/providers/Microsoft.Authorization/roleAssignments?api-version=2022-04-01&`$filter=$filter")
        }
    }
    $null = Invoke-BootstrapCheck -CheckId 'existing-identities' -CheckArea 'Modules' -CheckTitle 'Existing module identities' `
        -RequiredCheck 'management-group-ancestry', 'module-permissions' -PassDetail 'Existing module identities carry bootstrap tags and only expected grants.' -CheckScript {
        foreach ($name in $selected) {
            foreach ($phase in @('plan', 'apply')) {
                $identityId = "$resourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$($instance['instance']['name'])-$name-$phase"
                $identity = Invoke-BootstrapRequest -Uri "$arm$identityId`?api-version=2023-01-31" -AllowNotFound
                if ($identity) {
                    if (-not (Test-BootstrapDesiredValue -Actual $identity['tags'] -Desired ($tags + @{ platformModule = $name; platformPhase = $phase }))) {
                        throw "Existing resource '$identityId' does not have the expected bootstrap ownership tags; refusing to adopt it."
                    }
                    $null = @(Get-BootstrapIdentityGrant -Name $name -Phase $phase -Identity $identity)
                    $null = @(Get-BootstrapDirectoryRoleAssignment -Name $name -Phase $phase -PrincipalId $identity['properties']['principalId'])
                }
            }
        }
    }
}

if ($Preflight) {
    foreach ($prerequisite in @(Get-PlatformManualPrerequisite -Instance $instance -Scope Bootstrap)) {
        $checkResults.Add([pscustomobject]@{
            Area = 'Manual prerequisites'
            Check = "`$.manualPrerequisites.$($prerequisite.Name)"
            Status = if ($prerequisite.Confirmed) { 'Confirmed' } else { 'Manual' }
            Detail = if ($prerequisite.Confirmed) { 'Confirmed in the instance configuration.' } else { 'Verify it, then set the flag to true.' }
        })
    }
    return $checkResults.ToArray()
}

$changedResources = [System.Collections.Generic.List[string]]::new()
$null = Initialize-BootstrapResource -Uri "$arm$resourceGroupId`?api-version=2022-09-01" -Body @{
    location = $instance['regions']['primary']
    tags = $tags
}
$null = Initialize-BootstrapResource -Uri "$arm$storageAccountId`?api-version=2023-05-01" -Body @{
    location = $instance['regions']['primary']
    tags = $tags
    kind = 'StorageV2'
    sku = @{ name = 'Standard_LRS' }
    properties = @{
        allowSharedKeyAccess = $false
        allowBlobPublicAccess = $false
        publicNetworkAccess = 'Enabled'
        isHnsEnabled = $false
        isSftpEnabled = $false
        isLocalUserEnabled = $false
        isNfsV3Enabled = $false
        defaultToOAuthAuthentication = $true
        supportsHttpsTrafficOnly = $true
        minimumTlsVersion = 'TLS1_2'
        encryption = @{
            keySource = 'Microsoft.Storage'
            services = @{ blob = @{ enabled = $true }; file = @{ enabled = $true } }
        }
    }
}
$null = Initialize-BootstrapResource -Uri "$arm$storageAccountId/blobServices/default?api-version=2023-05-01" -Body @{
    properties = @{
        isVersioningEnabled = $true
        deleteRetentionPolicy = @{ enabled = $true; days = 30 }
        containerDeleteRetentionPolicy = @{ enabled = $true; days = 30 }
    }
}
$null = Initialize-BootstrapResource -Uri "$arm$storageAccountId/providers/Microsoft.Authorization/locks/lock-state?api-version=2016-09-01" -Body @{
    properties = @{ level = 'CanNotDelete'; notes = 'Protect module state. Remove only during an approved local bootstrap teardown.' }
}

$moduleResults = [System.Collections.Generic.List[object]]::new()
foreach ($name in $selected) {
    $containerId = "$storageAccountId/blobServices/default/containers/$name"
    $null = Initialize-BootstrapResource -Uri "$arm$containerId`?api-version=2023-05-01" -Body @{
        properties = @{ publicAccess = 'None' }
    }
    $result = [ordered]@{ Name = $name; ContainerName = $name }
    foreach ($phase in @('plan', 'apply')) {
        $identityId = "$resourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-$($instance['instance']['name'])-$name-$phase"
        $identity = Initialize-BootstrapResource -Uri "$arm$identityId`?api-version=2023-01-31" -Body @{
            location = $instance['regions']['primary']
            tags = $tags + @{ platformModule = $name; platformPhase = $phase }
        }
        $graphAssignments = @(Get-BootstrapIdentityGrant -Name $name -Phase $phase -Identity $identity)
        $principalId = $identity['properties']['principalId']
        $stateRoleId = "/subscriptions/$($connection['managementSubscriptionId'])/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe"
        # Terraform plan also needs blob leases and state writes, but never another module's container.
        Initialize-BootstrapRoleAssignment -Scope $containerId -PrincipalId $principalId -RoleDefinitionId $stateRoleId
        foreach ($grant in $azureGrants[$name][$phase].Values) {
            Initialize-BootstrapRoleAssignment -Scope $grant['scope'] -PrincipalId $principalId -RoleDefinitionId $grant['roleDefinitionId']
        }
        if ($graphGrants[$name][$phase].Count -gt 0) {
            foreach ($roleId in $graphGrants[$name][$phase].Keys) {
                if (@($graphAssignments | Where-Object {
                    $_['resourceId'] -eq $graphServicePrincipal['id'] -and $_['appRoleId'] -eq $roleId
                }).Count -eq 0) {
                    $null = Invoke-BootstrapRequest -Uri "$graph/servicePrincipals/$principalId/appRoleAssignments" -Method POST -WaitForPrincipal -Body @{
                        principalId = $principalId; resourceId = $graphServicePrincipal['id']; appRoleId = $roleId
                    }
                    $changedResources.Add("$graph/servicePrincipals/$principalId/appRoleAssignments/$roleId")
                }
            }
        }
        $directoryAssignments = @(Get-BootstrapDirectoryRoleAssignment -Name $name -Phase $phase -PrincipalId $principalId)
        $directoryRole = $directoryRoles[$name][$phase]
        if ($directoryRole) {
            $rolePermissions = @(@{ allowedResourceActions = $directoryRole['Actions'] })
            $definition = $directoryRole['Definition']
            if (-not $definition) {
                $definition = Invoke-BootstrapRequest -Uri "$graph/roleManagement/directory/roleDefinitions" -Method POST -Body @{
                    displayName = $directoryRole['DisplayName']
                    description = "Platform module $name ($phase) on the EMU enterprise application. Managed by bootstrap."
                    isEnabled = $true
                    rolePermissions = $rolePermissions
                }
                $directoryRole['Definition'] = $definition
                $changedResources.Add("$graph/roleManagement/directory/roleDefinitions/$($definition['id'])")
            }
            else {
                [string[]] $currentActions = @($definition['rolePermissions'] | ForEach-Object { $_['allowedResourceActions'] } | Sort-Object -Unique -CaseSensitive)
                if ($definition['isEnabled'] -ne $true -or @($definition['rolePermissions']).Count -ne 1 -or
                    ($currentActions -join "`n") -cne ($directoryRole['Actions'] -join "`n")) {
                    $null = Invoke-BootstrapRequest -Uri "$graph/roleManagement/directory/roleDefinitions/$($definition['id'])" -Method PATCH -Body @{
                        isEnabled = $true
                        rolePermissions = $rolePermissions
                    }
                    $changedResources.Add("$graph/roleManagement/directory/roleDefinitions/$($definition['id'])")
                }
            }
            if ($directoryAssignments.Count -eq 0) {
                $null = Invoke-BootstrapRequest -Uri "$graph/roleManagement/directory/roleAssignments" -Method POST -WaitForPrincipal -Body @{
                    principalId = $principalId
                    roleDefinitionId = $definition['id']
                    directoryScopeId = $directoryRole['ScopeId']
                }
                $changedResources.Add("$graph/roleManagement/directory/roleAssignments/$principalId")
            }
        }
        $result[$phase] = [pscustomobject]@{
            ResourceId = $identityId
            PrincipalId = $principalId
            ClientId = $identity['properties']['clientId']
        }
    }
    $moduleResults.Add([pscustomobject] $result)
}

[pscustomobject]@{
    TenantId = $connection['tenantId']
    SubscriptionId = $connection['managementSubscriptionId']
    ResourceGroupName = $resourceGroupName
    StorageAccountName = $storageAccountName
    OidcModeVerified = $enterpriseApplication['OidcModeVerified']
    Modules = $moduleResults.ToArray()
    HasChanges = $changedResources.Count -gt 0
}
