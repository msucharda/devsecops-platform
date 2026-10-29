BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../ToolDependencies.psm1') -Force
    $root = Join-Path $PSScriptRoot '../..'
    $savedToken = $env:REST_API_BEARER
    $savedOrganizationTokens = $env:PLATFORM_GITHUB_TOKENS
    $env:REST_API_BEARER = 'module-token-secret'
    $env:PLATFORM_GITHUB_TOKENS = '{"my-org":"module-token-secret"}'
    $runtime = Join-Path $TestDrive 'platform'
    $null = New-Item -Path (Join-Path $runtime 'modules') -ItemType Directory -Force
    foreach ($directory in @('shared', 'actions-catalog', 'enterprise-baseline', 'organization-rulesets', 'organizations')) {
        Copy-Item -LiteralPath (Join-Path $root "modules/$directory") -Destination (Join-Path $runtime 'modules') -Recurse
    }
    foreach ($entry in @(
        @{ Directory = 'actions-catalog'; Name = 'ActionsCatalog' },
        @{ Directory = 'enterprise-baseline'; Name = 'ActionsPolicy' },
        @{ Directory = 'enterprise-baseline'; Name = 'CodeSecurity' },
        @{ Directory = 'organization-rulesets'; Name = 'Rulesets' },
        @{ Directory = 'organizations'; Name = 'Organizations' }
    )) {
        $source = Join-Path $runtime "modules/$($entry.Directory)/scripts/$($entry.Name).psm1"
        Copy-Item -LiteralPath $source -Destination (Join-Path (Split-Path $source -Parent) "Retry$($entry.Name).psm1")
    }
}

AfterAll {
    Get-Module | Where-Object { $_.ModuleBase -like "$runtime*" } | Remove-Module -Force
    $env:REST_API_BEARER = $savedToken
    $env:PLATFORM_GITHUB_TOKENS = $savedOrganizationTokens
}

Describe 'Bundled module GitHub retry integration' {
    It 'includes the shared helper in the release file selection' {
        Test-PlatformReleaseFile -RelativePath 'modules/shared/scripts/GitHubRetry.ps1' | Should -BeTrue
    }

    It 'loads shared retry without tools and recovers in <ModuleName>' -ForEach @(
        @{ ModuleName = 'RetryActionsCatalog'; Directory = 'actions-catalog'; Function = 'Invoke-RetryIntegrationCatalogApi'; Wrapped = $true }
        @{ ModuleName = 'RetryActionsPolicy'; Directory = 'enterprise-baseline'; Function = 'Invoke-RetryIntegrationActionsPolicyApi'; Wrapped = $false }
        @{ ModuleName = 'RetryCodeSecurity'; Directory = 'enterprise-baseline'; Function = 'Invoke-RetryIntegrationCodeSecurityApi'; Wrapped = $false }
        @{ ModuleName = 'RetryOrganizations'; Directory = 'organizations'; Function = 'Invoke-RetryIntegrationOrganizationsApi'; Wrapped = $true }
    ) {
        $module = Import-Module (Join-Path $runtime "modules/$Directory/scripts/$ModuleName.psm1") -Prefix RetryIntegration -Force -PassThru -DisableNameChecking
        $retryState = @{ Attempt = 0; Json = (Get-GitHubApiFixture -Name orgs/get | ConvertTo-Json -Depth 100 -Compress) }
        Mock Start-Sleep {} -ModuleName $ModuleName
        Mock Invoke-WebRequest {
            $retryState.Attempt++
            [pscustomobject]@{
                StatusCode = $(if ($retryState.Attempt -eq 1) { 503 } else { 200 })
                Content = $retryState.Json
                Headers = @{}
            }
        } -ModuleName $ModuleName

        $reply = & $Function -ApiUrl https://api.example.test -Method GET -Path '/orgs/github'
        if ($Wrapped) { $reply.Body.login | Should -BeExactly 'github' }
        else { $reply.login | Should -BeExactly 'github' }
        Should -Invoke Invoke-WebRequest -ModuleName $ModuleName -Times 2 -Exactly
        Should -Invoke Start-Sleep -ModuleName $ModuleName -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        $module.ModuleBase | Should -BeLike "$runtime*"
        Test-Path -LiteralPath (Join-Path $runtime 'tools') | Should -BeFalse
    }

    It 'loads shared retry without tools and recovers in Rulesets' {
        Import-Module (Join-Path $runtime 'modules/organization-rulesets/scripts/RetryRulesets.psm1') -Prefix RetryIntegration -Force -DisableNameChecking
        $retryState = @{ Attempt = 0; Json = (Get-GitHubApiFixture -Name repos/get-org-rulesets | ConvertTo-Json -Depth 100 -Compress) }
        Mock Start-Sleep {} -ModuleName RetryRulesets
        Mock Invoke-WebRequest {
            $retryState.Attempt++
            [pscustomobject]@{
                StatusCode = $(if ($retryState.Attempt -eq 1) { 503 } else { 200 })
                Content = $retryState.Json
                Headers = @{}
            }
        } -ModuleName RetryRulesets

        Get-RetryIntegrationOrganizationRulesetState -ApiUrl https://api.example.test -Organization my-org -Name 'absent' |
            Should -BeNullOrEmpty
        Should -Invoke Invoke-WebRequest -ModuleName RetryRulesets -Times 2 -Exactly
        Should -Invoke Start-Sleep -ModuleName RetryRulesets -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'keeps Terraform external program stdout JSON-only after a 503' {
        $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @(
            '-NoLogo', '-NoProfile', '-NonInteractive', '-File',
            (Join-Path $PSScriptRoot 'fixtures/GitHubRetryProcess.ps1'),
            '-Program', (Join-Path $root 'modules/enterprise-baseline/scripts/Read-ActionsPolicyState.ps1'),
            '-TestsRoot', $PSScriptRoot
        )) { $start.ArgumentList.Add($argument) }
        $start.Environment['REST_API_BEARER'] = 'process-token-secret'
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdoutTask = $process.StandardOutput.ReadToEndAsync()
            $stderrTask = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.Write('{"api_url":"https://api.example.test","organization":"example","enabled_repositories":"all","allowed_actions":"all","sha_pinning_required":"true","default_workflow_permissions":"read","can_approve_pull_request_reviews":"false"}')
            $process.StandardInput.Close()
            $process.WaitForExit()
            $stdout = $stdoutTask.GetAwaiter().GetResult()
            $stderr = $stderrTask.GetAwaiter().GetResult()
            $process.ExitCode | Should -Be 0 -Because $stderr
            $result = $stdout | ConvertFrom-Json -AsHashtable
            $result.Keys | Sort-Object | Should -Be @('state', 'violations')
            $result.state | Should -BeOfType [string]
            $result.violations | Should -BeOfType [string]
            $stderr.Trim() | Should -BeExactly 'GET /orgs/example/actions/permissions status=503 attempt=1'
        }
        finally {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
    }
}
