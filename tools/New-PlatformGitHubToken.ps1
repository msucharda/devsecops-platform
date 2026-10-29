#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Module,
    [ValidateSet('plan', 'apply', 'rulesetPlan')][string] $Phase = 'plan',
    [string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [string] $PlatformOrganization = $env:GITHUB_REPOSITORY_OWNER,
    [switch] $Authorization,
    [System.Collections.IDictionary] $BootstrapApp,
    [string] $PrivateKey = $env:PLATFORM_APP_PRIVATE_KEY,
    [switch] $ValidateOnly,
    [ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $VendoringRepository,
    [switch] $ReadOnlySource,
    [switch] $DriftReport,
    [string] $EnvironmentPath = $env:GITHUB_ENV,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [scriptblock] $RequestPolicy,
    [scriptblock] $TokenLifecycle,
    [switch] $VerifyRevocation,
    [string] $IssuanceStatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
Import-Module (Join-Path $PSScriptRoot 'GitHubTokenIssuance.psm1')
if (($TokenLifecycle -or $VerifyRevocation) -and -not $ValidateOnly) {
    throw 'Token lifecycle supervision and revocation proof require ValidateOnly.'
}
$requestPolicyCallback = $RequestPolicy
$issuanceUncertaintyMessage = "Unresolved installation token issuance: a token may have been created and cannot be revoked without the response token. Do not retry issuance. Stop the issuing process and wait until the possible token's one hour lifetime has elapsed; cleanup is not verified."

function Invoke-GitHubAppRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][string] $Token,
        [ValidateSet('GET', 'POST', 'DELETE')][string] $Method = 'GET',
        [System.Collections.IDictionary] $Body
    )

    $arguments = @{
        Uri = "$($ApiUrl.TrimEnd('/'))$Path"
        Method = $Method
        Headers = @{
            Authorization = "Bearer $Token"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2026-03-10'
        }
        MaximumRedirection = 0
        TimeoutSec = 60
        MaximumRetryCount = 0
    }
    $kind = if ($Method -ceq 'POST') { 'TokenIssue' } elseif ($Method -ceq 'DELETE') { 'TokenRevoke' } else { 'Read' }
    Assert-PlatformBootstrapRequest -Uri $arguments.Uri -Method $Method -Body $Body -Kind $kind -RequestPolicy $requestPolicyCallback
    if ($Body) {
        $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
        $arguments.ContentType = 'application/json'
    }
    try {
        if ($kind -ceq 'TokenIssue') {
            Save-PlatformGitHubTokenIssuance -Context $issuanceContext -ApiUrl $ApiUrl -AppId $expected['appId'] `
                -InstallationIds @($installations | ForEach-Object { [string] $_['id'] })
            $script:issuanceUncertain = $true
        }
        $response = Invoke-RestMethod @arguments
        if ($null -ne $response) {
            ConvertTo-Json -InputObject $response -Depth 100 -Compress | ConvertFrom-Json -AsHashtable
        }
    }
    catch {
        if ($kind -ceq 'TokenIssue') {
            throw "$issuanceUncertaintyMessage $(Get-PlatformGitHubTokenPendingDescription -Context $issuanceContext) GitHub App API $Method $Path failed. $($_.Exception.Message)"
        }
        throw "GitHub App API $Method $Path failed. Verify GHE.com API availability and declared permissions. $($_.Exception.Message)"
    }
}

# security-check: token-issuance-response
function Assert-GitHubAppIssuedToken {
    [CmdletBinding()]
    param([AllowNull()][object] $Response)

    if ($Response -isnot [System.Collections.IDictionary] -or $Response['token'] -isnot [string] -or
        [string]::IsNullOrWhiteSpace($Response['token'])) {
        throw "$issuanceUncertaintyMessage $(Get-PlatformGitHubTokenPendingDescription -Context $issuanceContext) GitHub did not return a usable installation token."
    }
}

function Send-GitHubAppTokenEvent {
    [CmdletBinding()]
    param([string] $EventName, [string] $Token)

    if ($TokenLifecycle) {
        $decision = @(& $TokenLifecycle ([pscustomobject]@{
            Event = $EventName; Token = $Token; ApiUrl = $ApiUrl; AppId = $expected['appId']
            RevocationProofRequired = [bool] $VerifyRevocation
            TokenSha256 = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($Token))).ToLowerInvariant()
        }))
        if ($decision.Count -ne 1 -or $decision[0] -isnot [bool] -or -not $decision[0]) {
            throw "The token lifecycle supervisor did not acknowledge '$EventName'."
        }
    }
}

# security-check: token-issuance-cleanup
function Test-GitHubAppTokenCleanupComplete {
    [CmdletBinding()]
    param([bool] $Uncertain)

    return (-not $Uncertain -and @($tokens.PSBase.Values | Where-Object { -not $revokedTokens.Contains($_) }).Count -eq 0)
}

function Revoke-GitHubAppValidationToken {
    [CmdletBinding()]
    param([string] $Token)

    if (-not $revocationAttempts.Add($Token)) { throw 'Token revocation was already attempted; no blind retry.' }
    Send-GitHubAppTokenEvent -EventName Revoking -Token $Token
    if ($VerifyRevocation) {
        $uri = "$($ApiUrl.TrimEnd('/'))/installation/token"
        Assert-PlatformBootstrapRequest -Uri $uri -Method DELETE -Kind TokenRevoke -RequestPolicy $requestPolicyCallback
        $headers = @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' }
        $reply = Invoke-WebRequest -Uri $uri -Method DELETE -Headers $headers -SkipHttpErrorCheck `
            -MaximumRetryCount 0 -MaximumRedirection 0 -TimeoutSec 60
        if ($reply.StatusCode -ne 204) { throw 'Installation token revocation did not return HTTP 204; no retry.' }
        $proofPath = if ($enterpriseInstallation) {
            "/enterprises/$($expected['enterprise'])/apps/installable_organizations?per_page=1"
        } else { '/installation/repositories?per_page=1' }
        $uri = "$($ApiUrl.TrimEnd('/'))$proofPath"
        Assert-PlatformBootstrapRequest -Uri $uri -Method GET -Kind Read -RequestPolicy $requestPolicyCallback
        $reply = Invoke-WebRequest -Uri $uri -Method GET -Headers $headers -SkipHttpErrorCheck `
            -MaximumRetryCount 0 -MaximumRedirection 0 -TimeoutSec 60
        if ($reply.StatusCode -ne 401) { throw 'A revoked installation token was not rejected with HTTP 401; stop.' }
        $script:revocationsVerified++
    }
    else {
        $null = Invoke-GitHubAppRequest -Path '/installation/token' -Method DELETE -Token $Token
    }
    Send-GitHubAppTokenEvent -EventName Revoked -Token $Token
    $null = $revokedTokens.Add($Token)
}

function ConvertTo-JwtSegment {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]] $Bytes)

    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

# security-check: token-app-repository-selection
function Assert-AppRepositorySelection {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Installation,
        [Parameter(Mandatory)][string[]] $Expected,
        [Parameter(Mandatory)][string] $Organization
    )

    if ($Installation['repository_selection'] -isnot [string] -or
        $Installation['repository_selection'] -cnotin $Expected) {
        throw "Actual App repository scope for '$Organization' differs from the declared scope."
    }
}

# security-check: token-app-permission
function Assert-AppPermission {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Actual)

    $normalized = @{} + $Actual
    if (-not $expected['permissions'].Contains('metadata') -and $normalized['metadata'] -ceq 'read') {
        $normalized.Remove('metadata')
    }
    if ((ConvertTo-PlatformCanonicalJson $normalized) -cne (ConvertTo-PlatformCanonicalJson $expected['permissions'])) {
        throw 'Actual GitHub App permissions differ from the phase contract. Narrowing a write-capable App token does not isolate its private key.'
    }
}

if ($ReadOnlySource -and -not $VendoringRepository) {
    throw '-ReadOnlySource requires -VendoringRepository.'
}
if ($DriftReport -and ($Authorization -or $Module -or $InstancePath -or $VendoringRepository)) {
    throw 'Drift report credentials cannot share an authorization, deployment or vendoring phase.'
}
if ($BootstrapApp) {
    if (-not $ValidateOnly) { throw '-BootstrapApp is only supported with -ValidateOnly.' }
    if ($VendoringRepository -or $Module -or $InstancePath) {
        throw 'Bootstrap App validation cannot share vendoring or deployment inputs.'
    }
    if ($DriftReport) {
        $repositories = $BootstrapApp['resources']['repositories']
        $organizations = @($BootstrapApp['resources']['organizations'])
        if ((ConvertTo-PlatformCanonicalJson $BootstrapApp['permissions']) -cne (ConvertTo-PlatformCanonicalJson @{ issues = 'write' }) -or
            $organizations.Count -ne 1 -or $BootstrapApp['resources'].Count -ne 2 -or
            $repositories -isnot [System.Collections.IDictionary] -or $repositories.Count -ne 1 -or
            -not $repositories.Contains($organizations[0]) -or @($repositories[$organizations[0]]).Count -ne 1) {
            throw 'The drift report App contract must be exactly issues: write on one instance repository.'
        }
    }
    $expected = $BootstrapApp
}
elseif ($DriftReport) {
    $repository = "$env:GITHUB_REPOSITORY".Split('/')
    if ($repository.Count -ne 2 -or $repository[0] -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*$' -or $repository[1] -cnotmatch '^[A-Za-z0-9_.-]+$') {
        throw 'Drift reporting requires the instance repository owner/name.'
    }
    $expected = @{
        appId = $env:PLATFORM_APP_ID
        installationId = $env:PLATFORM_APP_INSTALLATION_ID
        enterprise = $env:PLATFORM_APP_ENTERPRISE
        permissions = @{ issues = 'write' }
        resources = @{
            organizations = @($repository[0])
            repositories = @{ $repository[0] = @($repository[1]) }
        }
    }
}
elseif ($VendoringRepository) {
    if ($Authorization -or $Module -or $InstancePath) { throw 'Vendoring credentials cannot share a deployment or authorization phase.' }
    $repository = $VendoringRepository.Split('/')
    $permissions = if ($ReadOnlySource) { @{ contents = 'read'; attestations = 'read' } } else { @{ contents = 'write'; pull_requests = 'write' } }
    $expected = @{
        appId = $env:PLATFORM_APP_ID
        installationId = $env:PLATFORM_APP_INSTALLATION_ID
        enterprise = $env:PLATFORM_APP_ENTERPRISE
        permissions = $permissions
        resources = @{
            organizations = @($repository[0])
            repositories = @{ $repository[0] = @($repository[1]) }
        }
    }
}
elseif ($Authorization) {
    $repository = $env:GITHUB_REPOSITORY.Split('/')
    if ($repository.Count -ne 2) { throw 'Authorization requires the instance repository owner/name.' }
    $expected = @{
        appId = $env:PLATFORM_APP_ID
        installationId = $env:PLATFORM_APP_INSTALLATION_ID
        enterprise = $env:PLATFORM_APP_ENTERPRISE
        permissions = @{ members = 'read' }
        resources = @{
            organizations = @($repository[0])
            repositories = @{}
        }
    }
}
else {
    if (-not $Module -or -not $InstancePath) { throw 'Module token issuance requires -Module and -InstancePath.' }
    $modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
    $instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
    if ($Module -cnotin (Get-PlatformModuleSelection -Instance $instance -Modules $modules)) {
        throw "Module '$Module' is not selected."
    }
    if ($modules[$Module].Contains('organizationScoped')) {
        $null = Get-PlatformModuleOrganization -Instance $instance -Manifest $modules[$Module] -PlatformOrganization $PlatformOrganization
    }
    $binding = $instance['credentials'][$Module][$Phase]
    if (-not $binding -or -not $binding.Contains('githubApp')) {
        if ($modules[$Module]['permissions']['githubApp'].Contains($Phase)) {
            throw "Module '$Module' requires an App for phase '$Phase'."
        }
        Write-Information "Module '$Module' declares no GitHub API access for '$Phase'." -InformationAction Continue
        return
    }
    $expected = $instance['githubApps'][$binding['githubApp']]
    if ($expected['appId'] -cne $env:PLATFORM_APP_ID -or $expected['installationId'] -cne $env:PLATFORM_APP_INSTALLATION_ID -or
        $expected['enterprise'] -cne $env:PLATFORM_APP_ENTERPRISE) {
        throw 'Protected environment App identity differs from the instance credential binding.'
    }
}
if (-not $ApiUrl -or ([uri] $ApiUrl).Scheme -cne 'https' -or (-not $ValidateOnly -and -not $EnvironmentPath) -or
    $expected['appId'] -cnotmatch '^[1-9][0-9]*$' -or $expected['installationId'] -cnotmatch '^[1-9][0-9]*$' -or
    -not $expected['enterprise'] -or -not $PrivateKey) {
    throw 'GitHub App token issuance requires HTTPS API URL, environment output, enterprise ownership, App/installation IDs and the phase private key. PAT fallback is not supported.'
}
if (-not $DriftReport -and ($Authorization -or (-not $VendoringRepository -and $Phase -eq 'plan') -or $ReadOnlySource) -and 'write' -cin @($expected['permissions'].PSBase.Values)) {
    throw 'Read-only plan and authorization must not receive write-capable App keys.'
}
$enterpriseInstallation = $expected['resources'].Contains('enterprise')
if ($enterpriseInstallation -and ($expected['resources']['enterprise'] -isnot [bool] -or
    -not $expected['resources']['enterprise'] -or $expected['resources'].Count -ne 1 -or
    $Authorization -or $VendoringRepository -or $Phase -eq 'rulesetPlan')) {
    throw 'Enterprise installation requires resources: { enterprise: true } and a plan or apply module phase.'
}
$now = [DateTimeOffset]::UtcNow.ToUnixTimeSeconds()
$header = ConvertTo-JwtSegment ([Text.Encoding]::UTF8.GetBytes('{"alg":"RS256","typ":"JWT"}'))
$payload = ConvertTo-JwtSegment ([Text.Encoding]::UTF8.GetBytes(
    (ConvertTo-Json -InputObject @{ iat = $now - 60; exp = $now + 540; iss = $expected['appId'] } -Compress)))
$unsigned = "$header.$payload"
$rsa = [Security.Cryptography.RSA]::Create()
try {
    $rsa.ImportFromPem($PrivateKey)
    $signature = $rsa.SignData([Text.Encoding]::UTF8.GetBytes($unsigned),
        [Security.Cryptography.HashAlgorithmName]::SHA256, [Security.Cryptography.RSASignaturePadding]::Pkcs1)
}
finally {
    $rsa.Dispose()
}
$jwt = "$unsigned.$(ConvertTo-JwtSegment $signature)"
if (-not $ValidateOnly) { Write-Information "::add-mask::$jwt" -InformationAction Continue }
$tokens = @{}
$revocationAttempts = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$revokedTokens = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
$issuanceContext = $null
$issuanceUncertain = $false
$revocationsVerified = 0
$inheritedRulesetsNotDetailValidated = 0
try {
    if (-not $IssuanceStatePath) {
        $IssuanceStatePath = Get-PlatformGitHubTokenIssuancePath -ApiUrl $ApiUrl -AppId $expected['appId']
    }
    $issuanceContext = Open-PlatformGitHubTokenIssuance -Path $IssuanceStatePath
    Assert-PlatformGitHubTokenIssuanceClear -Context $issuanceContext
    $app = Invoke-GitHubAppRequest -Path '/app' -Token $jwt
    if ([string] $app['id'] -cne $expected['appId'] -or -not (Test-PlatformGitHubAppOwner -Owner $app['owner'] -Enterprise $expected['enterprise'])) {
        throw 'GitHub App is not owned by the declared enterprise.'
    }
    Assert-AppPermission -Actual $app['permissions']
    $appSlug = [string] $app['slug']
    if ($DriftReport -and $appSlug -cnotmatch '^[a-z0-9][a-z0-9-]*$') {
        throw 'GitHub App slug is missing or invalid; the drift report cannot identify its own issues.'
    }
    $installations = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $batch = @(Invoke-GitHubAppRequest -Path "/app/installations?per_page=100&page=$page" -Token $jwt)
        foreach ($installation in $batch) { $installations.Add($installation) }
        $page++
    } while ($batch.Count -eq 100)
    $organizations = @($installations | ForEach-Object { $_['account']['login'] } | Sort-Object -CaseSensitive)
    if ($enterpriseInstallation) {
        if ($installations.Count -ne 1 -or [string] $installations[0]['id'] -cne $expected['installationId'] -or
            $installations[0]['target_type'] -cne 'Enterprise' -or
            $installations[0]['account']['slug'] -cne $expected['enterprise'] -or
            [string] $app['owner']['id'] -cnotmatch '^[1-9][0-9]*$' -or
            [string] $installations[0]['account']['id'] -cnotmatch '^[1-9][0-9]*$' -or
            [string] $installations[0]['target_id'] -cnotmatch '^[1-9][0-9]*$' -or
            [string] $installations[0]['account']['id'] -cne [string] $app['owner']['id'] -or
            [string] $installations[0]['target_id'] -cne [string] $app['owner']['id'] -or
            [string] $installations[0]['app_id'] -cne $expected['appId']) {
            throw 'Actual App installations differ from the declared enterprise installation.'
        }
    }
    elseif ((ConvertTo-PlatformCanonicalJson $organizations) -cne
        (ConvertTo-PlatformCanonicalJson @($expected['resources']['organizations'] | Sort-Object -CaseSensitive)) -or
        $expected['installationId'] -cnotin @($installations | ForEach-Object { [string] $_['id'] })) {
        throw 'Actual App installations differ from the declared target organizations or installation ID.'
    }
    foreach ($installation in $installations) {
        $organization = if ($enterpriseInstallation) { 'enterprise' } else { $installation['account']['login'] }
        if ((-not $enterpriseInstallation -and $installation['target_type'] -cne 'Organization') -or $installation['suspended_at']) {
            throw "App installation for '$organization' is not an active installation of the declared target type."
        }
        Assert-AppPermission -Actual $installation['permissions']
        $repositoryResourcesDeclared = -not $enterpriseInstallation -and $expected['resources'].Contains('repositories')
        $repositories = if ($enterpriseInstallation) { @{} } else { $expected['resources']['repositories'] }
        $selected = $repositories -and $repositories.Contains($organization)
        $noRepositoryAccess = $repositoryResourcesDeclared -and $repositories.Count -eq 0
        $selection = if ($selected) { 'selected' } else { 'all' }
        if (-not $enterpriseInstallation -and -not $Authorization) {
            $allowedSelections = if ($noRepositoryAccess) { @('selected') } else { @($selection) }
            Assert-AppRepositorySelection -Installation $installation -Expected $allowedSelections -Organization $organization
        }
        $tokenRequest = if ($enterpriseInstallation) { $null } else { @{ permissions = $expected['permissions'] } }
        # The drift report token keeps the installation repository scope so that /installation/repositories
        # proves the installation itself reaches only the instance repository.
        if ($VendoringRepository) { $tokenRequest['repositories'] = @($repositories[$organization]) }
        $issued = Invoke-GitHubAppRequest -Path "/app/installations/$($installation['id'])/access_tokens" -Method POST `
            -Token $jwt -Body $tokenRequest
        Assert-GitHubAppIssuedToken -Response $issued
        $tokens[$organization] = $issued['token']
        $issuanceUncertain = $false
        Send-GitHubAppTokenEvent -EventName Issued -Token $issued['token']
        if (-not $ValidateOnly) { Write-Information "::add-mask::$($issued['token'])" -InformationAction Continue }
        Assert-AppPermission -Actual $issued['permissions']
        if ($ValidateOnly -and $enterpriseInstallation -and $expected['permissions'].Contains('enterprise_organization_installations')) {
            $null = Invoke-GitHubAppRequest -Path "/enterprises/$($expected['enterprise'])/apps/installable_organizations?per_page=1" `
                -Token $issued['token']
        }
        if ($selected -or $Authorization -or $noRepositoryAccess) {
            $actualRepositories = [Collections.Generic.List[string]]::new()
            $page = 1
            do {
                $result = Invoke-GitHubAppRequest -Path "/installation/repositories?per_page=100&page=$page" -Token $issued['token']
                foreach ($repository in $result['repositories']) { $actualRepositories.Add($repository['name']) }
                $page++
            } while ($result['repositories'].Count -eq 100)
            if (($Authorization -or $noRepositoryAccess) -and $actualRepositories.Count -gt 0) {
                $kind = if ($Authorization) { 'Authorization App' } else { 'Organization-only App' }
                throw "$kind for '$organization' must not have repository access."
            }
            if ($selected -and (ConvertTo-PlatformCanonicalJson @($actualRepositories | Sort-Object -CaseSensitive)) -cne
                (ConvertTo-PlatformCanonicalJson @($repositories[$organization] | Sort-Object -CaseSensitive))) {
                throw "Actual App repository access for '$organization' differs from the declared resources."
            }
        }
        if ($ValidateOnly -and $Authorization) {
            $null = Invoke-GitHubAppRequest -Path "/orgs/$organization/teams?per_page=1" -Token $issued['token']
        }
        if ($ValidateOnly -and -not $enterpriseInstallation -and $expected['permissions'].Contains('organization_administration')) {
            foreach ($path in @('actions/permissions', 'code-security/configurations', 'code-security/configurations/defaults')) {
                $null = Invoke-GitHubAppRequest -Path "/orgs/$organization/$path" -Token $issued['token']
            }
        }
        if ($ValidateOnly -and $Phase -eq 'rulesetPlan') {
            $page = 1
            do {
                $rules = @(Invoke-GitHubAppRequest -Path "/orgs/$organization/rulesets?includes_parents=true&per_page=100&page=$page" -Token $issued['token'])
                foreach ($rule in $rules) {
                    if ($rule['source_type'] -ceq 'Enterprise' -and $rule['source'] -ceq $expected['enterprise']) {
                        $inheritedRulesetsNotDetailValidated++
                        continue
                    }
                    if ($rule['source_type'] -cne 'Organization' -or $rule['source'] -cne $organization) {
                        throw "Ruleset API for '$organization' returned unknown or mismatched source metadata."
                    }
                    $detail = Invoke-GitHubAppRequest -Path "/orgs/$organization/rulesets/$($rule['id'])" -Token $issued['token']
                    if (-not $detail.Contains('bypass_actors') -or $detail['bypass_actors'] -isnot [Collections.IList]) {
                        throw "Ruleset API for '$organization' did not expose the complete bypass configuration."
                    }
                }
                $page++
            } while ($rules.Count -eq 100)
        }
    }
    if ($ValidateOnly) {
        if ($inheritedRulesetsNotDetailValidated -gt 0) {
            $rulesetNoun = if ($inheritedRulesetsNotDetailValidated -eq 1) { 'ruleset was' } else { 'rulesets were' }
            Write-Warning "$inheritedRulesetsNotDetailValidated inherited enterprise $rulesetNoun not detail-validated; only local organization rulesets were checked for complete bypass configuration."
        }
        foreach ($token in $tokens.PSBase.Values) {
            Revoke-GitHubAppValidationToken -Token $token
        }
        $tokens.Clear()
        Complete-PlatformGitHubTokenIssuance -Context $issuanceContext
        return [pscustomobject]@{
            AppId = $expected['appId']
            Installations = @($installations | ForEach-Object { [string] $_['id'] })
            Verified = $true
            InheritedRulesetsNotDetailValidated = $inheritedRulesetsNotDetailValidated
            RevocationsVerified = $revocationsVerified
        }
    }
    $json = ConvertTo-Json -InputObject $tokens -Depth 100 -Compress
    $content = "PLATFORM_GITHUB_TOKENS=$json`nTF_VAR_github_tokens=$json`n"
    if ($DriftReport) { $content += "PLATFORM_APP_SLUG=$appSlug`n" }
    if ($tokens.Count -eq 1) {
        $token = @($tokens.PSBase.Values)[0]
        $content += "GH_TOKEN=$token`n"
    }
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($EnvironmentPath), $content, [Text.UTF8Encoding]::new($false))
    Complete-PlatformGitHubTokenIssuance -Context $issuanceContext
}
catch {
    $failure = $_
    foreach ($token in $tokens.PSBase.Values) {
        if ($revocationAttempts.Contains($token)) { continue }
        try { Revoke-GitHubAppValidationToken -Token $token }
        catch { Write-Warning "Failed to revoke an installation token after issuance failed: $($_.Exception.Message)" }
    }
    if ($issuanceContext -and (Test-GitHubAppTokenCleanupComplete -Uncertain $issuanceUncertain)) {
        Complete-PlatformGitHubTokenIssuance -Context $issuanceContext
    }
    throw $failure
}
finally {
    if ($issuanceContext) { $issuanceContext.Lock.Dispose() }
}
