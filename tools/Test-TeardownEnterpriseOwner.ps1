#Requires -Version 7.4
<#
.SYNOPSIS
Verifies before the first teardown destroy that a platform team member holds a direct Enterprise Owner app role assignment.
.DESCRIPTION
Destroying emu-identity removes the platform team group, so group-inherited Enterprise Owner rights disappear.
The local bootstrap removal then needs a direct assignment that an Entra ID administrator restores manually.
The check runs as the emu-identity plan identity and only reads Microsoft Graph.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules')
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')

$graph = 'https://graph.microsoft.com/v1.0'
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
$connection = if ($instance.Contains('bootstrap')) { $instance['bootstrap'] } else { $null }
if ($connection -isnot [System.Collections.IDictionary]) {
    throw 'The Enterprise Owner check requires $.bootstrap with tenantId and enterpriseApplicationObjectId.'
}
$tenantId = [string] $connection['tenantId']
$applicationId = [string] $connection['enterpriseApplicationObjectId']
$platformUsers = @($instance['teams']['platform'])
$manualStep = 'Before teardown, an Entra ID administrator must assign the Enterprise Owner app role of the EMU enterprise application ' +
    'directly to a user listed in $.teams.platform; group-inherited assignments are insufficient. Then rerun the teardown workflow.'

$text = & az account get-access-token --tenant $tenantId --resource 'https://graph.microsoft.com/' --output json --only-show-errors 2>&1 | Out-String
if ($LASTEXITCODE -ne 0) {
    throw 'Azure authentication failed for Microsoft Graph. The teardown owner check requires the emu-identity plan identity login.'
}
$token = ConvertFrom-Json -InputObject $text -AsHashtable
if ($token -isnot [System.Collections.IDictionary] -or $token['tenant'] -ne $tenantId -or [string]::IsNullOrWhiteSpace($token['accessToken'])) {
    throw 'The Microsoft Graph token does not belong to $.bootstrap.tenantId.'
}
$authorization = "Bearer $($token['accessToken'])"

function Invoke-OwnerCheckRequest {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [switch] $AllowNotFound
    )

    $address = [uri] $Uri
    if (-not $address.IsAbsoluteUri -or $address.Scheme -cne 'https' -or $address.Host -cne 'graph.microsoft.com' -or
        -not $address.IsDefaultPort -or $address.UserInfo -or $address.Fragment -or -not $address.AbsolutePath.StartsWith('/v1.0/', [StringComparison]::Ordinal)) {
        throw "Untrusted Graph address '$Uri'."
    }
    for ($attempt = 1; ; $attempt++) {
        $response = Invoke-WebRequest -Uri $Uri -Method GET -Headers @{ Authorization = $authorization; Accept = 'application/json' } `
            -SkipHttpErrorCheck -MaximumRedirection 0 -TimeoutSec 60 -MaximumRetryCount 0
        if ($response.StatusCode -in @(429, 503) -and $attempt -lt 6) {
            Write-Verbose "Retrying GET '$Uri' after HTTP $($response.StatusCode)."
            Start-Sleep -Seconds 5
            continue
        }
        break
    }
    if ($response.StatusCode -eq 404 -and $AllowNotFound) { return $null }
    $data = $null
    if (-not [string]::IsNullOrWhiteSpace($response.Content)) {
        try { $data = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop }
        catch { throw "Graph GET '$Uri' returned invalid JSON (HTTP $($response.StatusCode))." }
    }
    if ($response.StatusCode -lt 200 -or $response.StatusCode -ge 300) {
        $detail = if ($data -is [System.Collections.IDictionary] -and $data.Contains('error')) { ConvertTo-Json -InputObject $data['error'] -Compress } else { 'no error detail' }
        throw "Graph GET '$Uri' failed (HTTP $($response.StatusCode)): $detail."
    }
    if ($data -isnot [System.Collections.IDictionary]) { throw "Graph GET '$Uri' did not return a JSON object." }
    return $data
}

$application = Invoke-OwnerCheckRequest -Uri "$graph/servicePrincipals/$([uri]::EscapeDataString($applicationId))?`$select=id,appRoles"
if ([string] $application['id'] -ne $applicationId) {
    throw 'Graph returned another service principal than $.bootstrap.enterpriseApplicationObjectId.'
}
$ownerRoles = @($application['appRoles'] | Where-Object {
    $_ -is [System.Collections.IDictionary] -and $_['displayName'] -ceq 'Enterprise Owner' -and $_['isEnabled'] -eq $true -and
    @($_['allowedMemberTypes']) -ccontains 'User'
})
if (@($application['appRoles'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['displayName'] -ceq 'Enterprise Owner' }).Count -ne 1 -or
    $ownerRoles.Count -ne 1) {
    throw 'The EMU enterprise application must expose one enabled Enterprise Owner app role for users.'
}
$ownerRoleId = [string] $ownerRoles[0]['id']

$platformUserIds = @{}
foreach ($upn in $platformUsers) {
    $user = Invoke-OwnerCheckRequest -Uri "$graph/users/$([uri]::EscapeDataString($upn))?`$select=id,userPrincipalName" -AllowNotFound
    if ($null -eq $user) {
        Write-Warning "Platform team member '$upn' does not exist in Entra ID."
        continue
    }
    if ([string] $user['userPrincipalName'] -ne $upn -or [string]::IsNullOrWhiteSpace([string] $user['id'])) {
        throw "Graph returned an invalid user for platform team member '$upn'."
    }
    $platformUserIds[([string] $user['id']).ToLowerInvariant()] = $upn
}

$visited = [System.Collections.Generic.HashSet[string]]::new()
$uri = "$graph/servicePrincipals/$([uri]::EscapeDataString($applicationId))/appRoleAssignedTo"
$owners = [System.Collections.Generic.List[string]]::new()
while ($uri) {
    if (-not $visited.Add($uri)) { throw "Graph pagination cycle at '$uri'." }
    $page = Invoke-OwnerCheckRequest -Uri $uri
    if (-not $page.Contains('value') -or $page['value'] -isnot [System.Collections.IList]) {
        throw "Graph GET '$uri' did not return a collection."
    }
    foreach ($assignment in $page['value']) {
        if ($assignment -isnot [System.Collections.IDictionary]) { throw "Graph GET '$uri' returned an invalid assignment." }
        $principalId = ([string] $assignment['principalId']).ToLowerInvariant()
        if ($assignment['principalType'] -ceq 'User' -and $platformUserIds.ContainsKey($principalId) -and
            [string] $assignment['appRoleId'] -eq $ownerRoleId -and [string] $assignment['resourceId'] -eq $applicationId) {
            $owners.Add($platformUserIds[$principalId])
        }
    }
    $uri = if ($page.Contains('@odata.nextLink')) { [string] $page['@odata.nextLink'] } else { $null }
}

if ($owners.Count -eq 0) {
    throw "No platform team member has a direct Enterprise Owner app role assignment. $manualStep"
}
Write-Information "Direct Enterprise Owner assignment verified for: $(@($owners | Sort-Object -Unique) -join ', ')." -InformationAction Continue
