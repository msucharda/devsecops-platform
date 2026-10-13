#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $Module,
    [ValidateSet('plan', 'apply', 'rulesetPlan')][string] $Phase = 'plan',
    [string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [switch] $Authorization,
    [System.Collections.IDictionary] $BootstrapApp,
    [string] $PrivateKey = $env:PLATFORM_APP_PRIVATE_KEY,
    [switch] $ValidateOnly,
    [string] $EnvironmentPath = $env:GITHUB_ENV,
    [string] $ApiUrl = $env:GITHUB_API_URL
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')

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
    }
    if ($Body) {
        $arguments.Body = ConvertTo-Json -InputObject $Body -Depth 100 -Compress
        $arguments.ContentType = 'application/json'
    }
    try {
        $response = Invoke-RestMethod @arguments
        if ($null -ne $response) {
            ConvertTo-Json -InputObject $response -Depth 100 -Compress | ConvertFrom-Json -AsHashtable
        }
    }
    catch {
        throw "GitHub App API $Method $Path failed. Verify GHE.com API availability and declared permissions. $($_.Exception.Message)"
    }
}

function ConvertTo-JwtSegment {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][byte[]] $Bytes)

    [Convert]::ToBase64String($Bytes).TrimEnd('=').Replace('+', '-').Replace('/', '_')
}

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

if ($BootstrapApp) {
    if (-not $ValidateOnly) { throw '-BootstrapApp is only supported with -ValidateOnly.' }
    $expected = $BootstrapApp
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
if (($Authorization -or $Phase -eq 'plan') -and 'write' -cin @($expected['permissions'].PSBase.Values)) {
    throw 'Read-only plan and authorization must not receive write-capable App keys.'
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
$inheritedRulesetsNotDetailValidated = 0
try {
    $app = Invoke-GitHubAppRequest -Path '/app' -Token $jwt
    if ([string] $app['id'] -cne $expected['appId'] -or -not (Test-PlatformGitHubAppOwner -Owner $app['owner'] -Enterprise $expected['enterprise'])) {
        throw 'GitHub App is not owned by the declared enterprise.'
    }
    Assert-AppPermission -Actual $app['permissions']
    $installations = [Collections.Generic.List[object]]::new()
    $page = 1
    do {
        $batch = @(Invoke-GitHubAppRequest -Path "/app/installations?per_page=100&page=$page" -Token $jwt)
        foreach ($installation in $batch) { $installations.Add($installation) }
        $page++
    } while ($batch.Count -eq 100)
    $organizations = @($installations | ForEach-Object { $_['account']['login'] } | Sort-Object -CaseSensitive)
    if ((ConvertTo-PlatformCanonicalJson $organizations) -cne
        (ConvertTo-PlatformCanonicalJson @($expected['resources']['organizations'] | Sort-Object -CaseSensitive)) -or
        $expected['installationId'] -cnotin @($installations | ForEach-Object { [string] $_['id'] })) {
        throw 'Actual App installations differ from the declared target organizations or installation ID.'
    }
    foreach ($installation in $installations) {
        $organization = $installation['account']['login']
        if ($installation['target_type'] -cne 'Organization' -or $installation['suspended_at']) {
            throw "App installation for '$organization' is not an active organization installation."
        }
        Assert-AppPermission -Actual $installation['permissions']
        $repositoryResourcesDeclared = $expected['resources'].Contains('repositories')
        $repositories = $expected['resources']['repositories']
        $selected = $repositories -and $repositories.Contains($organization)
        $noRepositoryAccess = $repositoryResourcesDeclared -and $repositories.Count -eq 0
        $selection = if ($selected) { 'selected' } else { 'all' }
        if (-not $Authorization -and -not $noRepositoryAccess -and $installation['repository_selection'] -cne $selection) {
            throw "Actual App repository scope for '$organization' differs from the declared scope."
        }
        $issued = Invoke-GitHubAppRequest -Path "/app/installations/$($installation['id'])/access_tokens" -Method POST `
            -Token $jwt -Body @{ permissions = $expected['permissions'] }
        if (-not $issued['token']) { throw "GitHub did not issue an installation token for '$organization'." }
        $tokens[$organization] = $issued['token']
        if (-not $ValidateOnly) { Write-Information "::add-mask::$($issued['token'])" -InformationAction Continue }
        Assert-AppPermission -Actual $issued['permissions']
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
        if ($ValidateOnly -and $expected['permissions'].Contains('organization_administration')) {
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
            $null = Invoke-GitHubAppRequest -Path '/installation/token' -Method DELETE -Token $token
        }
        $tokens.Clear()
        return [pscustomobject]@{
            AppId = $expected['appId']
            Installations = @($installations | ForEach-Object { [string] $_['id'] })
            Verified = $true
            InheritedRulesetsNotDetailValidated = $inheritedRulesetsNotDetailValidated
        }
    }
    $json = ConvertTo-Json -InputObject $tokens -Depth 100 -Compress
    $content = "PLATFORM_GITHUB_TOKENS=$json`nTF_VAR_github_tokens=$json`n"
    if ($tokens.Count -eq 1) {
        $token = @($tokens.PSBase.Values)[0]
        $content += "GH_TOKEN=$token`n"
    }
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($EnvironmentPath), $content, [Text.UTF8Encoding]::new($false))
}
catch {
    $failure = $_
    foreach ($token in $tokens.PSBase.Values) {
        try { $null = Invoke-GitHubAppRequest -Path '/installation/token' -Method DELETE -Token $token }
        catch { Write-Warning "Failed to revoke an installation token after issuance failed: $($_.Exception.Message)" }
    }
    throw $failure
}
