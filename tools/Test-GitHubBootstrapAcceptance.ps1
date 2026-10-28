#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [Parameter(Mandatory)][ValidateSet('plan', 'apply', 'rulesetPlan', 'wrongSubject')][string] $Phase,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [Parameter(Mandatory)][string] $ResultPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
$instance = Get-PlatformYaml -Path $InstancePath
if (Test-Path -LiteralPath $ResultPath) { Remove-Item -LiteralPath $ResultPath }
$diagnosticPath = [IO.Path]::ChangeExtension([IO.Path]::GetFullPath($ResultPath), 'state-isolation.json')
if (Test-Path -LiteralPath $diagnosticPath) { Remove-Item -LiteralPath $diagnosticPath }
$federationPath = [IO.Path]::ChangeExtension([IO.Path]::GetFullPath($ResultPath), 'federation.json')
if (Test-Path -LiteralPath $federationPath) { Remove-Item -LiteralPath $federationPath }
$checks = [ordered]@{}
$keyFingerprint = ''

function Invoke-AcceptanceGitHubRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    try {
        Invoke-RestMethod -Uri "$($ApiUrl.TrimEnd('/'))$Path" -Headers @{
            Authorization = "Bearer $token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10'
        } -MaximumRedirection 0 -TimeoutSec 60
    }
    catch { throw "Acceptance API GET $Path failed. $($_.Exception.Message)" }
}

if ($Phase -eq 'wrongSubject') {
    if (-not $env:ACTIONS_ID_TOKEN_REQUEST_URL -or -not $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN -or
        $env:AZURE_CLIENT_ID -notmatch '^[a-fA-F0-9-]{36}$' -or $env:AZURE_TENANT_ID -notmatch '^[a-fA-F0-9-]{36}$') {
        throw 'The negative federation probe requires a GitHub OIDC request and the plan identity metadata.'
    }
    $address = [uri] $env:ACTIONS_ID_TOKEN_REQUEST_URL
    if ($address.Scheme -cne 'https' -or -not $address.IsDefaultPort -or $address.UserInfo) { throw 'Untrusted GitHub OIDC request URL.' }
    $separator = if ($address.Query) { '&' } else { '?' }
    $oidc = Invoke-RestMethod -Uri "$address${separator}audience=api%3A%2F%2FAzureADTokenExchange" `
        -Headers @{ Authorization = "Bearer $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN" } -MaximumRedirection 0 -TimeoutSec 60
    if (-not $oidc.value) { throw 'GitHub did not return an OIDC assertion.' }
    Write-Information "::add-mask::$($oidc.value)" -InformationAction Continue
    $federation = [ordered]@{
        version = 1; phase = $Phase; outcome = 'UnrecognizedFailure'; httpStatus = $null
        error_codes = @(); error = 'not-observed'; trace_id = $null; correlation_id = $null
    }
    try {
        try {
            $response = Invoke-WebRequest -Uri "https://login.microsoftonline.com/$env:AZURE_TENANT_ID/oauth2/v2.0/token" `
                -Method POST -ContentType 'application/x-www-form-urlencoded' -Body @{
                    client_id = $env:AZURE_CLIENT_ID; grant_type = 'client_credentials'; scope = 'https://management.azure.com/.default'
                    client_assertion_type = 'urn:ietf:params:oauth:client-assertion-type:jwt-bearer'; client_assertion = $oidc.value
                } -SkipHttpErrorCheck -MaximumRetryCount 0 -MaximumRedirection 0 -TimeoutSec 60
        }
        catch {
            $federation.outcome = 'TransportFailure'
            throw 'The wrong-subject token request failed. See the federation diagnostic.'
        }
        if (-not $response -or -not $response.PSObject.Properties['StatusCode'] -or
            $response.StatusCode -isnot [int] -or $response.StatusCode -lt 100 -or $response.StatusCode -gt 599) {
            $federation.outcome = 'InvalidResponse'
            throw 'The wrong-subject response has no valid HTTP status. See the federation diagnostic.'
        }
        $federation.httpStatus = $response.StatusCode
        try { $errorBody = ConvertFrom-Json -InputObject $response.Content -AsHashtable -ErrorAction Stop }
        catch {
            $federation.outcome = 'InvalidResponse'
            throw 'The wrong-subject response is not a JSON object. See the federation diagnostic.'
        }
        if ($errorBody -isnot [Collections.IDictionary]) {
            $federation.outcome = 'InvalidResponse'
            throw 'The wrong-subject response is not a JSON object. See the federation diagnostic.'
        }
        $codes = $errorBody['error_codes']
        if ($codes -is [Collections.IList] -and $codes.Count -le 16 -and
            -not @($codes | Where-Object { ($_ -isnot [int] -and $_ -isnot [long]) -or $_ -lt 0 -or $_ -gt 999999999 }).Count) {
            $federation.error_codes = @($codes)
        }
        $knownErrors = @('invalid_client', 'invalid_request', 'invalid_grant', 'invalid_scope', 'unauthorized_client',
            'unsupported_grant_type', 'server_error', 'temporarily_unavailable', 'access_denied')
        $federation.error = if ($errorBody['error'] -cin $knownErrors) { $errorBody['error'] } else { 'unrecognized' }
        foreach ($name in @('trace_id', 'correlation_id')) {
            if ($errorBody[$name] -is [string] -and $errorBody[$name] -cmatch '^[0-9a-fA-F]{8}(-[0-9a-fA-F]{4}){3}-[0-9a-fA-F]{12}$') {
                $federation[$name] = $errorBody[$name]
            }
        }
        if ($response.StatusCode -notin @(400, 401) -or $federation.error -cne 'invalid_client' -or
            $federation.error_codes.Count -ne 1 -or $federation.error_codes[0] -ne 700213) {
            throw 'The wrong-subject probe did not fail specifically with AADSTS700213. Do not treat a generic login failure as isolation proof.'
        }
        $federation.outcome = 'SubjectRejected'
    }
    finally {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($federationPath))
        $federationJson = ConvertTo-Json $federation -Compress
        [IO.File]::WriteAllText($federationPath, $federationJson + "`n", [Text.UTF8Encoding]::new($false))
        Write-Information "Federation diagnostic: $federationJson" -InformationAction Continue
    }
    $checks['wrongSubjectRejected'] = $true
}
else {
    if (-not $ApiUrl -or ([uri] $ApiUrl).Scheme -cne 'https') { throw 'Acceptance requires the HTTPS GHE.com API URL.' }
    # The workflow runs in the instance repository, so its owner is the platform organization.
    $organization = [string] $env:GITHUB_REPOSITORY_OWNER
    if ($organization -cnotmatch "^$([regex]::Escape($instance['instance']['name']))(-[a-z0-9]{6})?-platform$") {
        throw 'The repository owner is not the platform organization of this instance.'
    }
    $tokens = ConvertFrom-Json -InputObject $env:PLATFORM_GITHUB_TOKENS -AsHashtable
    $token = $tokens[$organization]
    if (-not $token -or $tokens.Count -ne 1) { throw 'The acceptance token must be scoped only to the platform organization.' }
    if ($Phase -eq 'rulesetPlan') {
        $rules = @(Invoke-AcceptanceGitHubRequest -Path "/orgs/$organization/rulesets?includes_parents=false&per_page=100")
        $probeRule = @($rules | Where-Object { $_.name -ceq 'bootstrap-acceptance-probe' })
        if ($probeRule.Count -ne 1) { throw 'Create the disabled bootstrap-acceptance-probe organization ruleset before the ruleset test.' }
        $detail = Invoke-AcceptanceGitHubRequest -Path "/orgs/$organization/rulesets/$($probeRule[0].id)"
        if ($detail.enforcement -cne 'disabled' -or @($detail.bypass_actors | Where-Object { $_.actor_type -ceq 'OrganizationAdmin' }).Count -ne 1) {
            throw 'The ruleset detail did not expose the expected nonempty probe bypass configuration.'
        }
        $checks['rulesetBypassRead'] = $true
    }
    else {
        $policy = Invoke-AcceptanceGitHubRequest -Path "/orgs/$organization/actions/permissions"
        if (-not $policy.enabled_repositories) { throw 'The Actions permissions API returned no organization policy.' }
        $null = Invoke-AcceptanceGitHubRequest -Path "/orgs/$organization/code-security/configurations"
        $null = Invoke-AcceptanceGitHubRequest -Path "/orgs/$organization/code-security/configurations/defaults"
        $checks['organizationApisRead'] = $true
    }
    if (-not $env:AZURE_CLIENT_ID -or -not $env:PLATFORM_STATE_STORAGE_ACCOUNT) { throw 'The environment has no Azure phase identity or state backend metadata.' }
    $text = & az account get-access-token --resource 'https://storage.azure.com/' --output json --only-show-errors 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw 'The environment identity could not issue an Azure Storage token.' }
    $access = ConvertFrom-Json -InputObject $text -AsHashtable
    $segment = $access['accessToken'].Split('.')[1].Replace('-', '+').Replace('_', '/')
    $segment = $segment.PadRight($segment.Length + (4 - $segment.Length % 4) % 4, '=')
    $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json -AsHashtable
    if ($claims['appid'] -cne $env:AZURE_CLIENT_ID -or $claims['tid'] -cne $instance['bootstrap']['tenantId']) {
        throw 'Azure authenticated another client or tenant, not this protected phase identity.'
    }
    $module = if ($Phase -eq 'rulesetPlan') { 'organization-rulesets' } else { 'enterprise-baseline' }
    $null = & az storage blob list --account-name $env:PLATFORM_STATE_STORAGE_ACCOUNT --container-name $module `
        --auth-mode login --output json --only-show-errors 2>&1
    if ($LASTEXITCODE -ne 0) { throw "The phase identity cannot read its own $module state container." }
    $diagnostic = [ordered]@{
        version = 1; phase = $Phase; outcome = 'UnrecognizedFailure'
        nativeExitCode = $null; httpStatus = $null; errorCode = 'not-observed'
    }
    try {
        try {
            $null = & az storage blob list --account-name $env:PLATFORM_STATE_STORAGE_ACCOUNT --container-name bootstrap-probe `
                --auth-mode login --num-results 1 --output json --only-show-errors 2>&1
            $negativeExitCode = $LASTEXITCODE
        }
        catch {
            $diagnostic.outcome = 'NativeInvocationFailure'
            throw 'The cross-module state command could not be executed. See the state isolation diagnostic.'
        }
        if ($negativeExitCode -isnot [int]) { throw 'The cross-module state read returned no valid native exit status.' }
        $diagnostic.nativeExitCode = $negativeExitCode
        if ($negativeExitCode -eq 0) {
            $diagnostic.outcome = 'UnexpectedSuccess'
            throw 'The cross-module state read succeeded unexpectedly.'
        }
        if ($env:PLATFORM_STATE_STORAGE_ACCOUNT -cnotmatch '^[a-z0-9]{3,24}$') {
            throw 'The cross-module state check requires a valid Azure Storage account name.'
        }
        try {
            $response = [pscustomobject](Invoke-WebRequest -Method GET `
                -Uri "https://$env:PLATFORM_STATE_STORAGE_ACCOUNT.blob.core.windows.net/bootstrap-probe?restype=container&comp=list&maxresults=1" `
                -Headers @{
                    Authorization = "Bearer $($access['accessToken'])"
                    'x-ms-date' = [DateTime]::UtcNow.ToString('R', [Globalization.CultureInfo]::InvariantCulture)
                    'x-ms-version' = '2023-11-03'
                } -SkipHttpErrorCheck -MaximumRedirection 0 -MaximumRetryCount 0 -TimeoutSec 60)
        }
        catch {
            $diagnostic.outcome = 'TransportFailure'
            throw 'The cross-module state authorization request failed. See the state isolation diagnostic.'
        }
        if (-not $response -or -not $response.PSObject.Properties['StatusCode'] -or
            $response.StatusCode -isnot [int] -or $response.StatusCode -lt 100 -or $response.StatusCode -gt 599 -or
            -not $response.PSObject.Properties['Headers'] -or $response.Headers -isnot [Collections.IDictionary]) {
            $diagnostic.outcome = 'InvalidResponse'
            throw 'The cross-module state authorization response is malformed. See the state isolation diagnostic.'
        }
        $diagnostic.httpStatus = $response.StatusCode
        $codes = @($response.Headers['x-ms-error-code'])
        $knownCodes = @('AuthorizationPermissionMismatch', 'AuthorizationFailure', 'AuthenticationFailed',
            'InvalidAuthenticationInfo', 'ContainerNotFound', 'ResourceNotFound', 'AccountIsDisabled',
            'InsufficientAccountPermissions', 'OperationTimedOut', 'ServerBusy', 'InternalError')
        $diagnostic.errorCode = if ($codes.Count -eq 1 -and $codes[0] -cin $knownCodes) { $codes[0] }
            elseif ($codes.Count -eq 0 -or $null -eq $codes[0]) { 'missing' } else { 'unrecognized' }
        if ($response.StatusCode -ge 200 -and $response.StatusCode -lt 300) {
            $diagnostic.outcome = 'UnexpectedSuccess'
            throw 'The cross-module state REST read succeeded unexpectedly.'
        }
        if ($response.StatusCode -ne 403 -or $diagnostic.errorCode -cne 'AuthorizationPermissionMismatch') {
            throw 'The cross-module state check did not prove an authorization permission denial. See the state isolation diagnostic.'
        }
        $diagnostic.outcome = 'AuthorizationDenied'
    }
    finally {
        $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($diagnosticPath))
        $diagnosticJson = ConvertTo-Json $diagnostic -Compress
        [IO.File]::WriteAllText($diagnosticPath, $diagnosticJson + "`n", [Text.UTF8Encoding]::new($false))
        Write-Information "State isolation diagnostic: $diagnosticJson" -InformationAction Continue
    }
    $checks['phaseIdentityVerified'] = $true
    $checks['otherModuleStateDenied'] = $true
    $key = [Security.Cryptography.RSA]::Create()
    try {
        $key.ImportFromPem($env:PLATFORM_APP_PRIVATE_KEY)
        $keyFingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($key.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
    }
    finally { $key.Dispose() }
}
$result = [ordered]@{
    version = 1; phase = $Phase; passed = $true; checks = $checks
    revision = $env:GITHUB_SHA; runId = $env:GITHUB_RUN_ID
    runAttempt = $env:GITHUB_RUN_ATTEMPT; keyFingerprint = $keyFingerprint
    authorizationFingerprint = $env:AUTHORIZATION_KEY_FINGERPRINT
}
$directory = [IO.Path]::GetDirectoryName([IO.Path]::GetFullPath($ResultPath))
$null = [IO.Directory]::CreateDirectory($directory)
[IO.File]::WriteAllText([IO.Path]::GetFullPath($ResultPath), (ConvertTo-Json $result -Depth 10) + "`n", [Text.UTF8Encoding]::new($false))
[pscustomobject] $result
# The expected native denial must not become the successful pwsh step exit status.
exit 0
