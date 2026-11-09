Set-StrictMode -Version Latest

# security-check: github-repository-target
function ConvertTo-GitHubRepositoryTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Repository)

    $match = [regex]::Match($Repository, '^(?:(?<host>[A-Za-z0-9-]+(?:\.[A-Za-z0-9-]+)+)/)?(?<owner>[A-Za-z0-9][A-Za-z0-9-]{0,38})/(?<name>[A-Za-z0-9._-]{1,100})$')
    if (-not $match.Success -or $match.Groups['name'].Value -in @('.', '..')) {
        throw "Repository '$Repository' must be 'owner/repo' or 'host/owner/repo'."
    }
    $hostname = if ($match.Groups['host'].Success) { $match.Groups['host'].Value.ToLowerInvariant() } else { 'github.com' }
    $owner = $match.Groups['owner'].Value
    $name = $match.Groups['name'].Value
    return @{ Host = $hostname; Owner = $owner; Name = $name; Slug = "$owner/$name"; Repository = "$hostname/$owner/$name" }
}

# security-check: github-cloud-target
function Resolve-GitHubCloudTarget {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [Parameter(Mandatory)][string] $Repository,
        [string] $ApiUrl
    )

    $target = ConvertTo-GitHubRepositoryTarget -Repository $Repository
    if ($ApiUrl) {
        $apiMatch = [regex]::Match($ApiUrl, '^https://api\.(?<host>github\.com|[a-z][a-z0-9]*(?:-[a-z0-9]+)*\.ghe\.com)/?$')
        if (-not $apiMatch.Success) { throw 'ApiUrl must be the HTTPS API origin of github.com or a GHE.com host.' }
        $apiHost = $apiMatch.Groups['host'].Value
        if ($Repository.Split('/').Count -eq 3 -and $target.Host -ne $apiHost) { throw 'ApiUrl and Repository identify different GitHub hosts.' }
        $target.Host = $apiHost
        $target.Repository = "$apiHost/$($target.Slug)"
    }
    if ($target.Host -notmatch '^(github\.com|[a-z][a-z0-9]*(?:-[a-z0-9]+)*\.ghe\.com)$') {
        throw 'The checks waiter supports only github.com and GHE.com hosts.'
    }
    $target.ApiUrl = "https://api.$($target.Host)"
    return $target
}

# security-check: github-host-credentials
function Invoke-GitHubHostGh {
    <#
    .SYNOPSIS
    Runs gh for a host, without letting public-cloud token overrides replace a stored GHE login.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $Hostname,
        [string] $User,
        [Parameter(Mandatory)][string[]] $Arguments
    )

    $tokenVariables = @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')
    $saved = @{}
    foreach ($name in $tokenVariables) { $saved[$name] = [Environment]::GetEnvironmentVariable($name) }
    try {
        if ($Hostname -ne 'github.com') {
            Remove-Item Env:\GH_TOKEN, Env:\GITHUB_TOKEN -ErrorAction SilentlyContinue
        }
        if ($User) {
            foreach ($name in $tokenVariables) { [Environment]::SetEnvironmentVariable($name, $null) }
            $credential = @(& gh auth token --hostname $Hostname --user $User 2>&1)
            if ($LASTEXITCODE -ne 0) { throw "No stored GitHub credential for account '$User' on '$Hostname'." }
            $token = ($credential -join "`n").Trim()
            if ([string]::IsNullOrWhiteSpace($token)) { throw "The stored GitHub credential for '$User' on '$Hostname' is empty." }
            $variable = if ($Hostname -eq 'github.com' -or $Hostname.EndsWith('.ghe.com', [StringComparison]::OrdinalIgnoreCase)) { 'GH_TOKEN' } else { 'GH_ENTERPRISE_TOKEN' }
            [Environment]::SetEnvironmentVariable($variable, $token)
        }
        $output = @(& gh @Arguments 2>&1)
        $exitCode = $LASTEXITCODE
    }
    finally {
        foreach ($name in $tokenVariables) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    $stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
    $stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '
    if ($exitCode -ne 0) { throw "gh $($Arguments[0]) failed with exit code ${exitCode}: $stderr" }
    return $stdout
}

Export-ModuleMember -Function ConvertTo-GitHubRepositoryTarget, Resolve-GitHubCloudTarget, Invoke-GitHubHostGh
