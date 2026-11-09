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

# security-check: github-command-deadline
function Get-GitHubHostDeadlineRemaining {
    param([datetime] $Deadline)

    $remaining = $Deadline.ToUniversalTime() - [datetime]::UtcNow
    if ($remaining -le [TimeSpan]::Zero) { throw [TimeoutException]::new('GitHub CLI deadline reached.') }
    return $remaining
}

# security-check: github-command-process
function Invoke-GitHubHostProcess {
    [CmdletBinding()]
    param([string[]] $Arguments, [Nullable[datetime]] $Deadline)

    if ($null -eq $Deadline) {
        $output = @(& gh @Arguments 2>&1)
        return @{
            ExitCode = $LASTEXITCODE
            Stdout = @($output | Where-Object { $_ -isnot [System.Management.Automation.ErrorRecord] }) -join "`n"
            Stderr = @($output | Where-Object { $_ -is [System.Management.Automation.ErrorRecord] }) -join ' '
        }
    }

    $remaining = Get-GitHubHostDeadlineRemaining -Deadline $Deadline
    $cancellation = [Threading.CancellationTokenSource]::new($remaining)
    $process = [Diagnostics.Process]::new()
    $started = $false
    try {
        Import-Module (Join-Path $PSScriptRoot 'GitHubProcessLifetime.psm1')
        $command = Get-Command gh -ErrorAction Stop | Select-Object -First 1
        if ($command.CommandType -eq 'Alias') { $command = $command.ResolvedCommand }
        if ($command.CommandType -notin @('Application', 'ExternalScript')) {
            throw 'Deadline-bounded gh requires an executable or PowerShell script.'
        }
        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.UseShellExecute = $false
        $start.CreateNoWindow = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        $start.FileName = Join-Path $PSHOME 'pwsh'
        $worker = Join-Path $PSScriptRoot 'GitHubHost.Worker.ps1'
        $nativePath = $command.Source
        $nativeArguments = @($Arguments)
        if ($command.CommandType -eq 'ExternalScript') {
            $nativePath = (Get-Command $start.FileName -CommandType Application -ErrorAction Stop).Source
            $nativeArguments = @('-NoLogo', '-NoProfile', '-File', $command.Source) + $nativeArguments
        }
        $argumentsJson = ConvertTo-Json -InputObject $nativeArguments -Compress
        foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $worker, '-FilePath', $nativePath, '-ArgumentsJson', $argumentsJson,
                '-DeadlineUtcTicks', $Deadline.ToUniversalTime().Ticks.ToString([Globalization.CultureInfo]::InvariantCulture), '-ParentProcessId', $PID)) {
            $start.ArgumentList.Add($argument)
        }
        $process.StartInfo = $start
        $started = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync($cancellation.Token)
        $stderr = $process.StandardError.ReadToEndAsync($cancellation.Token)
        $null = $process.WaitForExitAsync($cancellation.Token).GetAwaiter().GetResult()
        $standardOutput = $stdout.GetAwaiter().GetResult()
        $standardError = $stderr.GetAwaiter().GetResult()
        $null = Get-GitHubHostDeadlineRemaining -Deadline $Deadline
        return @{ ExitCode = $process.ExitCode; Stdout = $standardOutput; Stderr = $standardError }
    }
    catch {
        for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
            if ($exception -is [OperationCanceledException] -and $cancellation.IsCancellationRequested) {
                throw [TimeoutException]::new('GitHub CLI deadline reached.')
            }
        }
        throw
    }
    finally {
        try {
            if ($started) {
                try { Stop-GitHubHostProcessGroup -ProcessId $process.Id }
                finally {
                    try {
                        if (-not $process.HasExited) {
                            try { $process.Kill($true) }
                            catch [InvalidOperationException] { $process.WaitForExit() }
                            $process.WaitForExit()
                        }
                    }
                    finally { Stop-GitHubHostProcessGroup -ProcessId $process.Id }
                }
            }
        }
        finally {
            $process.Dispose()
            $cancellation.Dispose()
        }
    }
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
        [Parameter(Mandatory)][string[]] $Arguments,
        [Nullable[datetime]] $Deadline
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
            $credential = Invoke-GitHubHostProcess -Arguments @('auth', 'token', '--hostname', $Hostname, '--user', $User) -Deadline $Deadline
            if ($credential.ExitCode -ne 0) { throw "No stored GitHub credential for account '$User' on '$Hostname'." }
            $token = $credential.Stdout.Trim()
            if ([string]::IsNullOrWhiteSpace($token)) { throw "The stored GitHub credential for '$User' on '$Hostname' is empty." }
            $variable = if ($Hostname -eq 'github.com' -or $Hostname.EndsWith('.ghe.com', [StringComparison]::OrdinalIgnoreCase)) { 'GH_TOKEN' } else { 'GH_ENTERPRISE_TOKEN' }
            [Environment]::SetEnvironmentVariable($variable, $token)
        }
        $output = Invoke-GitHubHostProcess -Arguments $Arguments -Deadline $Deadline
    }
    finally {
        foreach ($name in $tokenVariables) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }
    if ($output.ExitCode -ne 0) { throw "gh $($Arguments[0]) failed with exit code $($output.ExitCode): $($output.Stderr)" }
    return $output.Stdout
}

Export-ModuleMember -Function ConvertTo-GitHubRepositoryTarget, Resolve-GitHubCloudTarget, Invoke-GitHubHostGh
