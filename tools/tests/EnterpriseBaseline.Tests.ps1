BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'TerraformTestProcess.psm1') -Force
    $mainPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline/main.tf'
    $main = Get-Content -LiteralPath $mainPath -Raw
    $patchAllowList = Get-Content -LiteralPath (Join-Path (Split-Path $mainPath -Parent) 'organization-patch-allowlist.json') -Raw | ConvertFrom-Json -AsHashtable

    function Get-TerraformLocalMap {
        param([Parameter(Mandatory)][string] $Name)

        $block = [regex]::Match($main, "(?ms)^\s*$Name\s*=\s*\{(?<body>.*?)^\s*\}")
        if (-not $block.Success) { throw "Local '$Name' is missing in main.tf." }
        $map = [ordered]@{}
        foreach ($line in [regex]::Matches($block.Groups['body'].Value, '(?m)^\s*(?<key>[a-z_]+)\s*=\s*(?<value>"[^"]*"|true|false)\s*$')) {
            $raw = $line.Groups['value'].Value
            $map[$line.Groups['key'].Value] = if ($raw -in @('true', 'false')) { $raw -eq 'true' } else { $raw.Trim('"') }
        }
        return $map
    }

    $managed = Get-TerraformLocalMap -Name organization_settings
    $defaults = Get-TerraformLocalMap -Name github_defaults
    $enterpriseEnforced = Get-TerraformLocalMap -Name enterprise_enforced_settings
    $organization = Get-GitHubApiFixture -Name orgs/get
    $update = Get-GitHubApiFixtureContract -Name orgs/update
}

Describe 'enterprise-baseline organization settings contract' {
    It 'manages the documented baseline fields' {
        @($managed.Keys) | Should -Be @(
            'default_repository_permission', 'members_can_create_repositories', 'members_can_create_private_repositories',
            'members_can_create_internal_repositories')
        @($enterpriseEnforced.Keys) | Should -Be @('members_can_change_repo_visibility', 'members_can_delete_repositories')
        @($defaults.Keys) | Should -Be @($managed.Keys)
    }

    It 'only sends fields that PATCH /orgs/{org} documents' {
        foreach ($field in $managed.Keys) {
            $update.requestProperties | Should -Contain $field
        }
    }

    It 'reads every managed field from GET /orgs/{org} with the type the module sends' {
        foreach ($field in $managed.Keys) {
            $organization.Contains($field) | Should -BeTrue -Because "the postcondition reads '$field'"
            $organization[$field].GetType() | Should -Be $managed[$field].GetType() -Because "api_data stringifies '$field'"
            $organization[$field].GetType() | Should -Be $defaults[$field].GetType()
        }
    }

    It 'reads but cannot set the fields enforced by the enterprise prerequisite' {
        foreach ($field in $enterpriseEnforced.Keys) {
            $organization.Contains($field) | Should -BeTrue -Because "the check reads '$field'"
            $organization[$field] | Should -BeOfType [bool]
            $update.requestProperties | Should -Not -Contain $field -Because 'the module cannot enforce it, so it is a manual prerequisite'
        }
    }

    It 'reads the nullable fork policy but never sends it even though PATCH documents it' {
        $organization['members_can_fork_private_repositories'] | Should -BeOfType [bool]
        $update.requestProperties | Should -Contain 'members_can_fork_private_repositories'
        @($managed.Keys) | Should -Not -Contain 'members_can_fork_private_repositories'
        @($defaults.Keys) | Should -Not -Contain 'members_can_fork_private_repositories'
    }
}

Describe 'enterprise-baseline against a local GitHub API stub' -Tag 'Terraform' {
    BeforeAll {
        $moduleRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline'
        $baselineOrganizationLogin = 'demo'
        $baselineReviewerId = 42
        $pwshPath = (Get-Command pwsh -CommandType Application | Select-Object -First 1).Source
        $runtimeCacheRoot = Join-Path $TestDrive 'child-cache'
        $script:failedTestListener = $null
        $script:failedTestJob = $null

        function Invoke-StubTerraformAtRoot {
            param([string] $TerraformRoot, [string[]] $TerraformArguments)

            $processResult = Invoke-TerraformTestProcess -Executable terraform -ArgumentList @("-chdir=$TerraformRoot"; $TerraformArguments; '-no-color') -CacheRoot $runtimeCacheRoot
            $output = $processResult.Output
            $code = $processResult.ExitCode
            if ($code -notin @(0, 2)) {
                $childStatus = @([regex]::Matches($output, '(?im)exit status (?:0x[0-9a-f]+|\d+)|signal: [^\r\n]+') |
                        ForEach-Object { $_.Value } | Sort-Object -Unique) -join '; '
                if (-not $childStatus) { $childStatus = 'not reported by Terraform' }
                $output = "[terraform-test] root=$TerraformRoot; command=$($TerraformArguments -join ' '); terraformExit=$code; childStatus=$childStatus; childCache=$($processResult.CachePath); childAnalysisCache=$($processResult.AnalysisCachePath); $runtimeContext`n$output"
                # A runtime crash is not the expected API failure of a lost-response scenario.
                if ($output -match '(?im)signal:\s|Unhandled exception\.|Stack overflow\.|The PowerShell process will exit|exit status 0x[89a-f][0-9a-f]{7}(?![0-9a-f])') {
                    throw "Terraform child process crashed.`n$output"
                }
            }
            [pscustomobject]@{ ExitCode = $code; Output = $output }
        }

        function Invoke-StubTerraform {
            $roots = if (@($args | Where-Object { $_ -like '-target=*' }).Count) { @($root) }
            elseif ($args[0] -ceq 'destroy') { @($root, $securityRoot) }
            else { @($securityRoot, $root) }
            $text = [Text.StringBuilder]::new()
            $exitCode = 0
            foreach ($terraformRoot in $roots) {
                $result = Invoke-StubTerraformAtRoot -TerraformRoot $terraformRoot -TerraformArguments $args
                $null = $text.Append($result.Output)
                if ($result.ExitCode -notin @(0, 2)) { return [pscustomobject]@{ ExitCode = $result.ExitCode; Output = $text.ToString() } }
                $exitCode = [Math]::Max($exitCode, $result.ExitCode)
            }
            [pscustomobject]@{ ExitCode = $exitCode; Output = $text.ToString() }
        }
    }

    BeforeEach {
        $previousBearer = $env:REST_API_BEARER
        $previousTimeout = $env:CODE_SECURITY_ATTACHMENT_TIMEOUT
        $listener = $null
        $stub = $null
        $probe = Invoke-TerraformTestProcess -Executable $pwshPath -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', '$PSVersionTable.PSVersion.ToString(); [Runtime.InteropServices.RuntimeInformation]::FrameworkDescription') -CacheRoot $runtimeCacheRoot
        $pwshRuntime = $probe.Output
        $probeExitCode = $probe.ExitCode
        $runtimeContext = "pwsh=$pwshPath; runtime=$($pwshRuntime.Trim() -replace '\r?\n', '; '); PSModulePath=$env:PSModulePath; PSModuleAnalysisCachePath=$env:PSModuleAnalysisCachePath; XDG_CACHE_HOME=$env:XDG_CACHE_HOME; probeCache=$($probe.CachePath); probeAnalysisCache=$($probe.AnalysisCachePath); unixStartupCacheIsolated=$(-not $IsWindows)"
        if ($probeExitCode -ne 0) { throw "Cannot inspect child pwsh (exit=$probeExitCode): $runtimeContext" }
        Write-Information "[terraform-test] $runtimeContext" -InformationAction Continue
        $stubState = [hashtable]::Synchronized(@{ Organization = $null; DropNextPatch = $false; Requests = [Collections.Generic.List[string]]::new(); OrganizationPatches = [Collections.Generic.List[hashtable]]::new(); CodeSecurity = $null; ActionsPolicy = $null })
        $codeSecurityStub = Join-Path $PSScriptRoot 'CodeSecurityStub.psm1'
        Import-Module $codeSecurityStub -Force
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        # DropNextPatch applies the organization PATCH and closes the connection without a response.
        # GET and PUT of the actions policy apply DropNext (a request regex) by writing and closing the connection.
        # Other paths go to the code security stub, whose Drop also closes the connection without a response.
        $stub = Start-ThreadJob -ScriptBlock {
            $listener = $using:listener
            $state = $using:stubState
            try {
                Import-Module $using:codeSecurityStub
                while ($true) {
                    if (-not $listener.Pending()) { Start-Sleep -Milliseconds 10; continue }
                    $client = $listener.AcceptTcpClient()
                    try {
                        $stream = $client.GetStream()
                        $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
                        $requestLine = $reader.ReadLine()
                        $length = 0
                        $headers = @{}
                        while ($line = $reader.ReadLine()) {
                            if ($line -match '^Content-Length:\s*(\d+)$') { $length = [int] $Matches[1] }
                            if ($line -match '^(?<name>[^:]+):\s*(?<value>.*)$') { $headers[$Matches['name']] = $Matches['value'] }
                        }
                        $buffer = [char[]]::new($length)
                        $read = 0
                        while ($read -lt $length) {
                            $count = $reader.Read($buffer, $read, $length - $read)
                            if ($count -eq 0) { throw 'Stub client disconnected before sending the complete request body.' }
                            $read += $count
                        }
                        $method, $path = $requestLine.Split(' ')[0, 1]
                        $link = $null
                        $policy = $state.ActionsPolicy
                        if ($policy -and $policy.Paths.Contains($path)) {
                            $policy.Requests.Add("$method $path")
                            $resource = $policy.Paths[$path]
                            if ($method -ceq 'PUT') {
                                $changes = ([string]::new($buffer)) | ConvertFrom-Json -AsHashtable
                                foreach ($key in $changes.Keys) { $policy[$resource][$key] = $changes[$key] }
                                if ($policy.DropNext -and "$method $path" -cmatch $policy.DropNext) {
                                    $policy.DropNext = $null
                                    continue
                                }
                                $status = '204 No Content'
                                $body = ''
                            }
                            else {
                                $status = '200 OK'
                                $body = ConvertTo-Json -InputObject $policy[$resource] -Depth 5 -Compress
                            }
                        }
                        elseif ($path -cne "/orgs/$($state.Organization.login)" -and $state.CodeSecurity) {
                            $reply = Invoke-CodeSecurityStubRequest -State $state.CodeSecurity -Method $method -PathAndQuery $path -Headers $headers -Body ([string]::new($buffer))
                            if ($reply.Drop) { continue }
                            $status = "$($reply.Status) Stub"
                            $body = [string] $reply.Body
                            $link = $reply.Link
                        }
                        elseif ($path -cne "/orgs/$($state.Organization.login)" -or $method -notin @('GET', 'PATCH')) {
                            $state.Requests.Add("$method $path")
                            $status = '404 Not Found'
                            $body = '{"message":"Not Found"}'
                        }
                        else {
                            $state.Requests.Add("$method $path")
                            $status = '200 OK'
                            if ($method -eq 'PATCH') {
                                $changes = ([string]::new($buffer)) | ConvertFrom-Json -AsHashtable
                                $state.OrganizationPatches.Add($changes)
                                # Issue #147: enterprise policy rejects even an unchanged fork setting.
                                if ($changes.ContainsKey('members_can_fork_private_repositories')) {
                                    $status = '422 Unprocessable Entity'
                                    $body = '{"message":"Validation Failed","errors":"Forking policy has been set by enterprise administrators."}'
                                }
                                else {
                                    foreach ($key in $changes.Keys) { $state.Organization[$key] = $changes[$key] }
                                    if ($state.DropNextPatch) {
                                        $state.DropNextPatch = $false
                                        continue
                                    }
                                }
                            }
                            if ($status -ceq '200 OK') {
                                $body = ConvertTo-Json -InputObject $state.Organization -Depth 20 -Compress
                            }
                        }
                        $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                        $linkHeader = if ($link) { "Link: $link`r`n" } else { '' }
                        $header = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`n$($linkHeader)Connection: close`r`n`r`n"
                        $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                        $stream.Write($headerBytes, 0, $headerBytes.Length)
                        $stream.Write($bytes, 0, $bytes.Length)
                        $stream.Flush()
                    }
                    finally {
                        $client.Close()
                    }
                }
            }
            finally { $listener.Stop() }
        }

        $env:REST_API_BEARER = 'stub-token'
        $env:CODE_SECURITY_ATTACHMENT_TIMEOUT = '0'

        $parent = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $modules = Join-Path $parent 'modules'
        $root = Join-Path $modules 'enterprise-baseline'
        $securityRoot = Join-Path $root 'code-security'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        New-Item -ItemType Directory -Path $securityRoot | Out-Null
        Copy-Item -LiteralPath (Join-Path $moduleRoot '../shared') -Destination $modules -Recurse
        Copy-Item -Path (Join-Path $moduleRoot '*.tf'), (Join-Path $moduleRoot '.terraform.lock.hcl') -Destination $root
        Copy-Item -Path (Join-Path $moduleRoot 'scripts') -Destination $root -Recurse
        Copy-Item -Path (Join-Path $moduleRoot 'code-security/*.tf'), (Join-Path $moduleRoot 'code-security/.terraform.lock.hcl') -Destination $securityRoot
        Set-Content -LiteralPath (Join-Path $securityRoot 'stub_override.tf') -Value @"
terraform {
  backend "local" {}
}
locals {
  github_api_url = "http://127.0.0.1:$port"
}
"@
        Set-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @"
terraform {
  backend "local" {}
}

provider "restapi" {
  uri = "http://127.0.0.1:$port"
}

locals {
  github_api_url = "http://127.0.0.1:$port"
}
"@
        if ($IsWindows) {
            # The external provider cannot start the Microsoft Store app execution alias of pwsh directly.
            Add-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @'
data "external" "actions_policy_state" {
  program = ["cmd", "/c", "pwsh", "-NoProfile", "-NonInteractive", "-File", "./scripts/Read-ActionsPolicyState.ps1"]
}
'@
            Add-Content -LiteralPath (Join-Path $securityRoot 'stub_override.tf') -Value @'
data "external" "code_security_state" {
  program = ["cmd", "/c", "pwsh", "-NoProfile", "-NonInteractive", "-File", "../scripts/Read-CodeSecurityState.ps1"]
}
'@
        }
        $testOrganization = $baselineOrganizationLogin
        $testReviewer = $baselineReviewerId
        Set-Content -LiteralPath (Join-Path $root 'terraform.tfvars.json') -Value (ConvertTo-Json -Depth 10 -InputObject @{
                instance = @{
                    name = 'demo'; github = @{ host = 'example.ghe.com'; enterprise = 'example' }
                    customPatterns = @(@{ name = 'Internal token'; secretRegex = 'itk_[0-9a-f]{32}' })
                }
                target_organizations = @($testOrganization)
                prerequisites = @{}
                secret_scanning_bypass_reviewers = @(@{ reviewer_type = 'TEAM'; reviewer_id = $testReviewer })
            })
        Copy-Item -LiteralPath (Join-Path $root 'terraform.tfvars.json') -Destination $securityRoot
        $stubState.CodeSecurity = Initialize-CodeSecurityStub -Organization $testOrganization -Origin "http://127.0.0.1:$port" -Token stub-token
        $stubState.Organization = Get-GitHubApiFixture -Name orgs/get -Set @{
            login = $testOrganization
            members_can_change_repo_visibility = $false
            members_can_delete_repositories = $false
        }
        $stubState.ActionsPolicy = [hashtable]::Synchronized(@{
                Paths = @{ "/orgs/$testOrganization/actions/permissions" = 'Actions'; "/orgs/$testOrganization/actions/permissions/workflow" = 'Workflow' }
                # A new organization: GitHub defaults with the enterprise default of read-only workflow permissions.
                Actions = Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization -Set @{ allowed_actions = 'all'; sha_pinning_required = $false }
                Workflow = Get-GitHubApiFixture -Name actions/get-github-actions-default-workflow-permissions-organization -Set @{ can_approve_pull_request_reviews = $false }
                DropNext = $null
                Requests = [Collections.Generic.List[string]]::new()
            })
        $stubState.ActionsPolicy.Actions.Remove('selected_actions_url')
        $stubState.DropNextPatch = $false
        $stubState.Requests.Clear()
        $stubState.OrganizationPatches.Clear()
        $managed = @{
            default_repository_permission            = 'none'
            members_can_create_repositories          = $false
            members_can_create_private_repositories  = $false
            members_can_create_internal_repositories = $false
        }
        $defaults = @{
            default_repository_permission            = 'read'
            members_can_create_repositories          = $true
            members_can_create_private_repositories  = $true
            members_can_create_internal_repositories = $true
        }
        $unmanaged = @{
            description = $stubState.Organization['description']
            members_can_create_pages = $stubState.Organization['members_can_create_pages']
            members_can_fork_private_repositories = $stubState.Organization['members_can_fork_private_repositories']
        }
        $init = Invoke-StubTerraform init -input=false
        $init.ExitCode | Should -Be 0 -Because $init.Output
    }

    AfterEach {
        $env:REST_API_BEARER = $previousBearer
        $env:CODE_SECURITY_ATTACHMENT_TIMEOUT = $previousTimeout
        $serverFailed = $stub -and $stub.State -eq 'Failed'
        $serverError = if ($serverFailed) { "$($stub.JobStateInfo.Reason)`n$($stub.Error | Out-String)" } else { '' }
        try {
            if ($stub) { $stub | Stop-Job -PassThru | Remove-Job -Force }
        }
        finally {
            if ($listener) { $listener.Stop() }
        }
        if ($serverFailed) { throw "GitHub API stub failed: $serverError" }
    }

    It 'isolates an unconsumed POST after a child failure: <Case>' -Tag 'ChildProcessIsolation' -ForEach @(
        @{ Case = 'child fails before POST'; FailChild = $true; DiscardPrevious = $false }
        @{ Case = 'next test starts healthy'; FailChild = $false; DiscardPrevious = $false }
        @{ Case = 'previous test did not initialize its fixtures'; FailChild = $false; DiscardPrevious = $true }
    ) {
        if ($DiscardPrevious) {
            $script:failedTestJob = $null
            $script:failedTestListener = $null
        }
        $codeSecurity = $stubState.CodeSecurity
        $codeSecurity.DropNext | Should -BeNullOrEmpty
        @($codeSecurity.Requests) | Should -BeNullOrEmpty
        $stub.State | Should -BeExactly 'Running'
        if ($FailChild) {
            $script:failedTestListener = $listener
            $script:failedTestJob = $stub
            $codeSecurity.DropNext = '^POST /orgs/demo/code-security/configurations$'
            # Only the disposable module copy fails; production code is unchanged.
            Set-Content -LiteralPath (Join-Path $root 'scripts/Invoke-CodeSecurityChange.ps1') -Value @'
[Console]::Error.WriteLine('injected child failure before POST')
exit 73
'@
            $failed = Invoke-StubTerraform apply -input=false -auto-approve
            $failed.ExitCode | Should -Be 1 -Because $failed.Output
            $failed.Output | Should -Match 'injected child failure before POST'
            $failed.Output | Should -Match 'exit status 73'
            $failed.Output | Should -Match '\[terraform-test\].*pwsh='
            $codeSecurity.DropNext | Should -Not -BeNullOrEmpty
            @($codeSecurity.Requests | Where-Object { $_ -match '^POST ' }) | Should -BeNullOrEmpty
        }
        else {
            if ($script:failedTestJob) {
                $script:failedTestJob.State | Should -BeExactly 'Stopped'
                $script:failedTestListener.Server.IsBound | Should -BeFalse
            }
            $apply = Invoke-StubTerraform apply -input=false -auto-approve
            $apply.ExitCode | Should -Be 0 -Because $apply.Output
            @($codeSecurity.Requests | Where-Object { $_ -ceq 'POST /orgs/demo/code-security/configurations' }).Count | Should -Be 1
        }
    }

    It 'closes the listener when a client disconnects before sending its body' -Tag 'ChildProcessIsolation', 'StubDisconnect' {
        $failedJob = $stub
        # This test owns the intentionally failed job; AfterEach still owns the listener.
        $stub = $null
        try {
            $client = [Net.Sockets.TcpClient]::new()
            try {
                $client.Connect([Net.IPAddress]::Loopback, $port)
                $bytes = [Text.Encoding]::ASCII.GetBytes("PATCH /orgs/demo HTTP/1.1`r`nContent-Length: 5`r`n`r`n{")
                $client.GetStream().Write($bytes)
                $client.Client.Shutdown([Net.Sockets.SocketShutdown]::Send)
            }
            finally { $client.Dispose() }
            $failedJob | Wait-Job | Out-Null

            $failedJob.State | Should -BeExactly 'Failed'
            $failedJob.JobStateInfo.Reason.Message | Should -Match 'disconnected before sending the complete request body'
            $listener.Server.IsBound | Should -BeFalse -Because 'later Terraform requests must not connect to a dead server'
            $connection = [Net.Sockets.TcpClient]::new()
            try {
                { $connection.Connect([Net.IPAddress]::Loopback, $port) } | Should -Throw
            }
            finally { $connection.Dispose() }
        }
        finally { $failedJob | Stop-Job -PassThru | Remove-Job -Force }
    }

    It 'preserves a reported child status in diagnostic context: <ChildStatus>' -Tag 'ChildProcessDiagnostic' -ForEach @(
        @{ ChildStatus = 'exit status 0xc0000005'; Fatal = $true }
        @{ ChildStatus = 'exit status 0xe0434352'; Fatal = $true }
        @{ ChildStatus = 'exit status 139'; Fatal = $false }
    ) {
        # Replay status text from Terraform on either host without crashing a process.
        Set-Content -LiteralPath (Join-Path $root 'scripts/Invoke-CodeSecurityChange.ps1') -Value @"
[Console]::Error.WriteLine('$ChildStatus')
exit 73
"@
        $codeSecurity = $stubState.CodeSecurity
        $codeSecurity.DropNext = '^POST /orgs/demo/code-security/configurations$'
        if ($Fatal) {
            $failure = { Invoke-StubTerraform apply -input=false -auto-approve } |
                Should -Throw '*Terraform child process crashed*' -PassThru
            $context = ($failure.Exception.Message -split '\r?\n')[1]
            $stubState.Requests | Should -BeNullOrEmpty -Because 'a fatal Windows status must not start the late root'
        }
        else {
            $failed = Invoke-StubTerraform apply -input=false -auto-approve
            $failed.ExitCode | Should -Be 1 -Because $failed.Output
            $context = ($failed.Output -split '\r?\n')[0]
        }
        $context | Should -Match ([regex]::Escape($ChildStatus))
        $codeSecurity.DropNext | Should -Not -BeNullOrEmpty
        @($codeSecurity.Requests | Where-Object { $_ -match '^POST ' }) | Should -BeNullOrEmpty
    }

    It 'reports a runtime crash before checking an unconsumed POST: <Failure>' -Tag 'ChildProcessCrash' -ForEach @(
        @{ Failure = 'SIGSEGV'; Message = 'signal: segmentation fault (core dumped)' }
        @{ Failure = 'SIGABRT'; Message = 'signal: aborted (core dumped)' }
        @{ Failure = 'FileLoadException'; Message = 'Unhandled exception. System.IO.FileLoadException: The given assembly name was invalid.' }
        @{ Failure = 'StackOverflow'; Message = 'Stack overflow.' }
    ) {
        $codeSecurity = $stubState.CodeSecurity
        $codeSecurity.DropNext = '^POST /orgs/demo/code-security/configurations$'
        # Replay the historical crash text, without actually signalling pwsh or creating a core dump.
        Set-Content -LiteralPath (Join-Path $root 'scripts/Invoke-CodeSecurityChange.ps1') -Value @"
[Console]::Error.WriteLine('$Message')
[Console]::Error.WriteLine('testChildCache=' + `$env:XDG_CACHE_HOME)
[Console]::Error.WriteLine('testChildAnalysisCache=' + `$env:PSModuleAnalysisCachePath)
exit 139
"@

        $failure = { Invoke-StubTerraform apply -input=false -auto-approve } |
            Should -Throw '*Terraform child process crashed*' -PassThru

        $failure.Exception.Message | Should -Match ([regex]::Escape($Message))
        $failure.Exception.Message | Should -Match 'terraformExit=1'
        $failure.Exception.Message | Should -Match 'exit status 139'
        $failure.Exception.Message | Should -Match 'PSModulePath='
        $failure.Exception.Message | Should -Match 'PSModuleAnalysisCachePath='
        $failure.Exception.Message | Should -Match 'XDG_CACHE_HOME='
        $diagnosticLines = @($failure.Exception.Message -split '\r?\n' | Where-Object { $_ -cmatch '^\[terraform-test\] ' })
        $diagnosticLines | Should -HaveCount 1
        $cacheMatch = [regex]::Match($diagnosticLines[0], '; childCache=([^;]+);')
        $analysisCacheMatch = [regex]::Match($diagnosticLines[0], '; childAnalysisCache=([^;]+);')
        $cacheMatch.Success | Should -BeTrue -Because 'the diagnostic must report a non-empty child cache path'
        $analysisCacheMatch.Success | Should -BeTrue -Because 'the diagnostic must report a non-empty child analysis cache path'
        $contextCache = $cacheMatch.Groups[1].Value
        $contextAnalysisCache = $analysisCacheMatch.Groups[1].Value
        $failure.Exception.Message | Should -Match ([regex]::Escape("testChildCache=$contextCache"))
        $failure.Exception.Message | Should -Match ([regex]::Escape("testChildAnalysisCache=$contextAnalysisCache"))
        $codeSecurity.DropNext | Should -Not -BeNullOrEmpty
        @($codeSecurity.Requests | Where-Object { $_ -match '^POST ' }) | Should -BeNullOrEmpty
        $stubState.Requests | Should -BeNullOrEmpty -Because 'a crashed early root must not start the late root'
    }

    It 'adopts legacy Code Security state without deleting or recreating remote objects when <Case>' -Tag 'CodeSecurityTransition' -ForEach @(
        @{ Case = 'uninterrupted'; RepeatEarly = $false }
        @{ Case = 'interrupted after early adoption'; RepeatEarly = $true }
    ) {
        $removedPath = Join-Path $root 'removed.tf'
        Remove-Item -LiteralPath $removedPath
        $legacySource = Get-Content -LiteralPath (Join-Path $moduleRoot 'code-security/code_security.tf') -Raw
        $legacySource.Replace('${path.module}/../scripts/', '${path.module}/scripts/') |
            Set-Content -LiteralPath (Join-Path $root 'code_security.tf')
        $legacyWindowsOverride = Join-Path $root 'legacy_external_override.tf'
        if ($IsWindows) {
            Set-Content -LiteralPath $legacyWindowsOverride -Value @'
data "external" "code_security_state" {
  program = ["cmd", "/c", "pwsh", "-NoProfile", "-NonInteractive", "-File", "./scripts/Read-CodeSecurityState.ps1"]
}
'@
        }
        $legacy = Invoke-StubTerraformAtRoot -TerraformRoot $root -TerraformArguments @('apply', '-input=false', '-auto-approve')
        $legacy.ExitCode | Should -Be 0 -Because $legacy.Output
        $codeSecurity = $stubState.CodeSecurity
        $configuration = @($codeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' })
        $configuration.Count | Should -Be 1
        $configurationId = $configuration[0]['id']
        $patternId = $codeSecurity.Patterns[0]['id']
        $createdConfigurations = @($codeSecurity.Requests | Where-Object { $_ -ceq 'POST /orgs/demo/code-security/configurations' }).Count
        $createdPatterns = @($codeSecurity.Requests | Where-Object { $_ -ceq 'POST /orgs/demo/secret-scanning/custom-patterns' }).Count
        $createdConfigurations | Should -Be 1
        $createdPatterns | Should -Be 1

        Remove-Item -LiteralPath (Join-Path $root 'code_security.tf')
        if ($IsWindows) { Remove-Item -LiteralPath $legacyWindowsOverride }
        Copy-Item -LiteralPath (Join-Path $moduleRoot 'removed.tf') -Destination $removedPath
        $early = Invoke-StubTerraformAtRoot -TerraformRoot $securityRoot -TerraformArguments @('apply', '-input=false', '-auto-approve')
        $early.ExitCode | Should -Be 0 -Because $early.Output
        if ($RepeatEarly) {
            # The previous run ended after the early root adopted the objects, before the late state was updated.
            $earlyRetry = Invoke-StubTerraformAtRoot -TerraformRoot $securityRoot -TerraformArguments @('apply', '-input=false', '-auto-approve')
            $earlyRetry.ExitCode | Should -Be 0 -Because $earlyRetry.Output
        }
        $late = Invoke-StubTerraformAtRoot -TerraformRoot $root -TerraformArguments @('apply', '-input=false', '-auto-approve')
        $late.ExitCode | Should -Be 0 -Because $late.Output
        $lateRetry = Invoke-StubTerraformAtRoot -TerraformRoot $root -TerraformArguments @('apply', '-input=false', '-auto-approve')
        $lateRetry.ExitCode | Should -Be 0 -Because $lateRetry.Output

        @($codeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' }).Count | Should -Be 1
        ($codeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' })['id'] | Should -Be $configurationId
        @($codeSecurity.Patterns).Count | Should -Be 1
        $codeSecurity.Patterns[0]['id'] | Should -Be $patternId
        @($codeSecurity.Requests | Where-Object { $_ -match '^DELETE ' }).Count | Should -Be 0
        @($codeSecurity.Requests | Where-Object { $_ -ceq 'POST /orgs/demo/code-security/configurations' }).Count | Should -Be $createdConfigurations
        @($codeSecurity.Requests | Where-Object { $_ -ceq 'POST /orgs/demo/secret-scanning/custom-patterns' }).Count | Should -Be $createdPatterns
        $lateState = Invoke-StubTerraformAtRoot -TerraformRoot $root -TerraformArguments @('state', 'list')
        $lateState.ExitCode | Should -Be 0 -Because $lateState.Output
        $lateState.Output | Should -Not -Match 'terraform_data\.(code_security_configuration|code_security_configuration_settings|custom_pattern|custom_pattern_content)'
        $earlyState = Invoke-StubTerraformAtRoot -TerraformRoot $securityRoot -TerraformArguments @('state', 'list')
        $earlyState.ExitCode | Should -Be 0 -Because $earlyState.Output
        $earlyState.Output | Should -Match 'terraform_data\.code_security_configuration'
        $earlyState.Output | Should -Match 'terraform_data\.custom_pattern'
    }

    It 'omits enterprise-controlled fields from create, update and destroy PATCH requests: <Case>' -Tag 'ForkPolicy' -ForEach @(
        @{ Case = 'uninterrupted'; LoseUpdateResponse = $false }
        @{ Case = 'update response lost'; LoseUpdateResponse = $true }
    ) {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve '-target=restapi_object.organization_settings'
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $stubState.OrganizationPatches.Count | Should -Be 1
        $stubState.OrganizationPatches[0].default_repository_permission | Should -BeExactly 'none'

        # Change a managed value to force the provider's update path, not another create.
        Add-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @'
locals {
  organization_settings = {
    default_repository_permission            = "write"
    members_can_create_repositories          = false
    members_can_create_private_repositories  = false
    members_can_create_internal_repositories = false
  }
}
'@
        $stubState.DropNextPatch = $LoseUpdateResponse
        $update = Invoke-StubTerraform apply -input=false -auto-approve '-target=restapi_object.organization_settings'
        if ($LoseUpdateResponse) {
            $update.ExitCode | Should -Not -Be 0
            $stubState.DropNextPatch | Should -BeFalse -Because 'the stub must have applied the update and lost its response'
            $stubState.Organization.default_repository_permission | Should -BeExactly 'write'
            $update = Invoke-StubTerraform apply -input=false -auto-approve '-target=restapi_object.organization_settings'
        }
        $update.ExitCode | Should -Be 0 -Because $update.Output
        $patchesBeforeDestroy = $stubState.OrganizationPatches.Count
        $patchesBeforeDestroy | Should -BeGreaterOrEqual 2
        $stubState.OrganizationPatches[1].default_repository_permission | Should -BeExactly 'write'
        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode '-target=restapi_object.organization_settings'
        $plan.ExitCode | Should -Be 0 -Because $plan.Output

        $destroy = Invoke-StubTerraform destroy -input=false -auto-approve '-target=restapi_object.organization_settings'
        $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
        $stubState.OrganizationPatches.Count | Should -Be ($patchesBeforeDestroy + 1)
        $stubState.OrganizationPatches[-1].default_repository_permission | Should -BeExactly 'read'
        foreach ($patch in $stubState.OrganizationPatches) {
            foreach ($field in $patch.get_Keys()) {
                ($field -cin @($patchAllowList.allowedFields.get_Keys())) | Should -BeTrue -Because "the actual PATCH field '$field' must be explicitly allowed"
            }
            @($patch.Keys) | Should -Not -Contain 'members_can_fork_private_repositories'
            @($patch.Keys) | Should -Not -Contain 'members_can_change_repo_visibility'
            @($patch.Keys) | Should -Not -Contain 'members_can_delete_repositories'
        }
        $stubState.Organization.members_can_fork_private_repositories | Should -BeFalse
    }

    It 'fails the plan on an unreadable or noncompliant enterprise fork policy: <Case>' -Tag 'ForkPolicy' -ForEach @(
        @{ Case = 'forks enabled'; Value = $true }
        @{ Case = 'field omitted'; Value = $false }
        @{ Case = 'documented null'; Value = $null }
        # Deliberately invalid API values; only the documented boolean false is compliant.
        @{ Case = 'boolean-shaped string'; Value = 'false' }
        @{ Case = 'empty string'; Value = '' }
        @{ Case = 'wrong case'; Value = 'False' }
    ) {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve '-target=restapi_object.organization_settings'
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $stubState.Organization['members_can_fork_private_repositories'] = $Value
        if ($Case -ceq 'field omitted') { $stubState.Organization.Remove('members_can_fork_private_repositories') }

        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode '-target=restapi_object.organization_settings'

        $plan.ExitCode | Should -Be 1 -Because $plan.Output
        ($plan.Output -replace '\s+', ' ') | Should -Match 'members_can_fork_private_repositories.*privateInternalForksDisabled'
        $stubState.OrganizationPatches.Count | Should -Be 1 -Because 'plan must not write to the organization'
    }

    It 'converges, detects drift and tears down the baseline in <BaselineOrganizationLogin> with its local reviewers' -ForEach @(
        @{ BaselineOrganizationLogin = 'demo-platform'; BaselineReviewerId = 11 }
        @{ BaselineOrganizationLogin = 'demo-actions'; BaselineReviewerId = 22 }
        @{ BaselineOrganizationLogin = 'demo-workloads'; BaselineReviewerId = 33 }
    ) {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode
        $plan.ExitCode | Should -Be 0 -Because $plan.Output
        foreach ($field in $managed.Keys) { $stubState.Organization[$field] | Should -Be $managed[$field] }
        $stubState.Organization.login | Should -BeExactly $baselineOrganizationLogin
        $configuration = $stubState.CodeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' }
        $configuration.secret_scanning_delegated_bypass_options.reviewers[0].reviewer_id | Should -Be $baselineReviewerId
        $stubState.Organization.default_repository_permission = 'read'
        $drift = Invoke-StubTerraform plan -input=false -detailed-exitcode
        $drift.ExitCode | Should -Be 1 -Because $drift.Output
        $drift.Output | Should -Match 'does not match the managed baseline'
        $stubState.Organization.default_repository_permission = 'none'
        $destroy = Invoke-StubTerraform destroy -input=false -auto-approve
        $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
        (Invoke-StubTerraform state list).Output.Trim() | Should -BeNullOrEmpty
        foreach ($field in $defaults.Keys) { $stubState.Organization[$field] | Should -Be $defaults[$field] }
        @($stubState.CodeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' }) | Should -BeNullOrEmpty
    }

    It 'converges on the next apply when an apply loses the PATCH response' {
        $stubState.DropNextPatch = $true

        $interrupted = Invoke-StubTerraform apply -input=false -auto-approve
        $resumed = Invoke-StubTerraform apply -input=false -auto-approve
        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $interrupted.ExitCode | Should -Not -Be 0
        $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
        $plan.ExitCode | Should -Be 0 -Because $plan.Output
        foreach ($field in $managed.Keys) { $stubState.Organization[$field] | Should -Be $managed[$field] }
        foreach ($field in $unmanaged.Keys) { $stubState.Organization[$field] | Should -Be $unmanaged[$field] }
        @($stubState.Requests | Where-Object { $_ -notmatch '^(GET|PATCH) /orgs/demo$' }) | Should -BeNullOrEmpty
    }

    It 'restores only the managed defaults when a destroy loses the PATCH response and is repeated' {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $stubState.DropNextPatch = $true

        $interrupted = Invoke-StubTerraform destroy -input=false -auto-approve
        $resumed = Invoke-StubTerraform destroy -input=false -auto-approve
        $remaining = Invoke-StubTerraform state list

        $interrupted.ExitCode | Should -Not -Be 0
        $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
        $remaining.Output.Trim() | Should -BeNullOrEmpty
        foreach ($field in $defaults.Keys) { $stubState.Organization[$field] | Should -Be $defaults[$field] }
        foreach ($field in $unmanaged.Keys) { $stubState.Organization[$field] | Should -Be $unmanaged[$field] }
    }

    It 'fails the plan instead of reporting no changes when a managed field drifts' {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $stubState.Organization['default_repository_permission'] = 'read'

        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $plan.ExitCode | Should -Be 1
        $plan.Output | Should -Match 'does not match the managed baseline'
    }

    It 'converges on the next apply when the <Object> POST response is lost' -ForEach @(
        @{ Object = 'configuration'; Request = '^POST /orgs/demo/code-security/configurations$' }
        @{ Object = 'custom pattern'; Request = '^POST /orgs/demo/secret-scanning/custom-patterns$' }
    ) {
        $codeSecurity = $stubState.CodeSecurity
        $codeSecurity.DropNext = $Request

        $interrupted = Invoke-StubTerraform apply -input=false -auto-approve
        $resumed = Invoke-StubTerraform apply -input=false -auto-approve
        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $codeSecurity.DropNext | Should -BeNullOrEmpty -Because 'the stub must have lost the response'
        $interrupted.ExitCode | Should -Not -Be 0
        $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
        $plan.ExitCode | Should -Be 0 -Because $plan.Output
        $managed = @($codeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' })
        $managed.Count | Should -Be 1
        $managed[0]['name'] | Should -Be 'platform-baseline'
        $codeSecurity.Defaults.public | Should -Be $managed[0]['id']
        $codeSecurity.Defaults.private_and_internal | Should -Be $managed[0]['id']
        foreach ($repository in $codeSecurity.Repositories.Values) { $repository.status | Should -Be 'attached' }
        @($codeSecurity.Patterns).Count | Should -Be 1
        $codeSecurity.Patterns[0]['name'] | Should -Be 'Internal token'
        $codeSecurity.Patterns[0]['push_protection_enabled'] | Should -BeTrue
    }

    It 'removes the configuration and patterns when a destroy loses a DELETE response and is repeated' {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $codeSecurity = $stubState.CodeSecurity
        $codeSecurity.DropNext = '^DELETE /orgs/demo/code-security/configurations/[0-9]+$'

        $interrupted = Invoke-StubTerraform destroy -input=false -auto-approve
        $resumed = Invoke-StubTerraform destroy -input=false -auto-approve
        $remaining = Invoke-StubTerraform state list

        $interrupted.ExitCode | Should -Not -Be 0
        $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
        $remaining.Output.Trim() | Should -BeNullOrEmpty
        @($codeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' }) | Should -BeNullOrEmpty
        @($codeSecurity.Patterns) | Should -BeNullOrEmpty
        $codeSecurity.Defaults.public | Should -BeNullOrEmpty
    }

    It 'fails the plan when the code security state drifts: <Case>' -ForEach @(
        @{ Case = 'configuration deleted'; Message = 'has no organization code security configuration'; Drift = {
                param($s)
                # Deleting a configuration also removes its default role and its attachments.
                $c = $s.Configurations | Where-Object { $_['target_type'] -ceq 'organization' }
                $null = $s.Configurations.Remove($c)
                $s.Defaults.public = $null; $s.Defaults.private_and_internal = $null
                foreach ($repository in $s.Repositories.Values) { $repository.configuration = $null; $repository.status = $null } } }
        @{ Case = 'bypass reviewer changed'; Message = 'bypass reviewers'; Drift = {
                param($s) ($s.Configurations | Where-Object { $_['target_type'] -ceq 'organization' })['secret_scanning_delegated_bypass_options']['reviewers'][0]['reviewer_id'] = 43 } }
        @{ Case = 'default removed for public repositories'; Message = 'not the only default'; Drift = { param($s) $s.Defaults.public = $null } }
        @{ Case = 'repository attachment failed'; Message = 'pending or failed'; Drift = { param($s) $s.Repositories['demo/app'].status = 'failed' } }
        @{ Case = 'repository without any configuration'; Message = 'has no successful attachment'; Drift = { param($s) $s.Repositories['demo/app'].configuration = $null; $s.Repositories['demo/app'].status = $null } }
        @{ Case = 'repository moved to another configuration'; Message = 'attached to another code security configuration'; Drift = {
                param($s) $s.Repositories['demo/lib'].configuration = 17 } }
        @{ Case = 'pattern regex changed'; Message = 'missing or differs from customPatterns'; Drift = { param($s) $s.Patterns[0]['pattern'] = 'itk_.*' } }
        @{ Case = 'pattern deleted'; Message = 'missing or differs from customPatterns'; Drift = { param($s) $s.Patterns.RemoveAt(0) } }
        @{ Case = 'push protection disabled'; Message = 'push protection disabled'; Drift = { param($s) $s.Patterns[0]['push_protection_enabled'] = $false } }
        @{ Case = 'pattern unpublished'; Message = 'is not published or has push protection disabled'; Drift = {
                param($s) $s.Patterns[0]['state'] = 'unpublished'; $s.Patterns[0]['push_protection_enabled'] | Should -BeTrue } }
    ) {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        & $Drift $stubState.CodeSecurity

        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $plan.ExitCode | Should -Be 1 -Because $plan.Output
        ($plan.Output -replace '\s+', ' ') | Should -BeLike "*$Message*"
    }

    It 'fails the plan when the managed setting <Field> is changed or missing' -ForEach @(
        @{ Field = 'advanced_security'; Changed = 'disabled' }
        @{ Field = 'dependency_graph'; Changed = 'disabled' }
        @{ Field = 'dependabot_alerts'; Changed = 'disabled' }
        @{ Field = 'dependabot_security_updates'; Changed = 'not_set' }
        @{ Field = 'code_scanning_default_setup'; Changed = 'disabled' }
        @{ Field = 'secret_scanning'; Changed = 'disabled' }
        @{ Field = 'secret_scanning_push_protection'; Changed = 'disabled' }
        @{ Field = 'secret_scanning_validity_checks'; Changed = 'not_set' }
        @{ Field = 'secret_scanning_delegated_bypass'; Changed = 'disabled' }
        @{ Field = 'enforcement'; Changed = 'unenforced' }
    ) {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $configuration = $stubState.CodeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' }
        $managed = $configuration[$Field]

        $configuration[$Field] = $Changed
        $changedPlan = Invoke-StubTerraform plan -input=false -detailed-exitcode
        $configuration.Remove($Field)
        $missingPlan = Invoke-StubTerraform plan -input=false -detailed-exitcode
        $configuration[$Field] = $managed
        $restoredPlan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        foreach ($plan in $changedPlan, $missingPlan) {
            $plan.ExitCode | Should -Be 1 -Because $plan.Output
            ($plan.Output -replace '\s+', ' ') | Should -BeLike '*does not match the managed settings*'
            ($plan.Output -replace '\s+', ' ') | Should -Not -BeLike '*bypass reviewers*'
        }
        $restoredPlan.ExitCode | Should -Be 0 -Because $restoredPlan.Output
    }

    It 'fails the plan when the bypass reviewers drift: <Case>' -ForEach @(
        @{ Case = 'reviewer type changed'; Drift = { param($c) $c['secret_scanning_delegated_bypass_options']['reviewers'][0]['reviewer_type'] = 'ROLE' } }
        @{ Case = 'mode EXEMPT'; Drift = { param($c) $c['secret_scanning_delegated_bypass_options']['reviewers'][0]['mode'] = 'EXEMPT' } }
        @{ Case = 'extra reviewer'; Drift = {
                param($c) $o = $c['secret_scanning_delegated_bypass_options']; $o['reviewers'] = @($o['reviewers']) + @(@{ reviewer_type = 'ROLE'; reviewer_id = 4; mode = 'ALWAYS' }) } }
        @{ Case = 'duplicate reviewer'; Drift = {
                param($c) $o = $c['secret_scanning_delegated_bypass_options']; $o['reviewers'] = @($o['reviewers']) + @(@{} + $o['reviewers'][0]) } }
        @{ Case = 'reviewer removed'; Drift = { param($c) $c['secret_scanning_delegated_bypass_options']['reviewers'] = @() } }
        @{ Case = 'reviewer_type missing'; Drift = { param($c) $c['secret_scanning_delegated_bypass_options']['reviewers'][0].Remove('reviewer_type') } }
        @{ Case = 'reviewer_id missing'; Drift = { param($c) $c['secret_scanning_delegated_bypass_options']['reviewers'][0].Remove('reviewer_id') } }
        @{ Case = 'reviewers list missing'; Drift = { param($c) $c['secret_scanning_delegated_bypass_options'].Remove('reviewers') } }
        @{ Case = 'bypass options missing'; Drift = { param($c) $c.Remove('secret_scanning_delegated_bypass_options') } }
    ) {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        & $Drift ($stubState.CodeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' })

        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $plan.ExitCode | Should -Be 1 -Because $plan.Output
        ($plan.Output -replace '\s+', ' ') | Should -BeLike '*bypass reviewers*'
        ($plan.Output -replace '\s+', ' ') | Should -Not -BeLike '*does not match the managed settings*'
    }

    It 'accepts a bypass reviewer without mode as the documented default ALWAYS' {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $configuration = $stubState.CodeSecurity.Configurations | Where-Object { $_['target_type'] -ceq 'organization' }
        $configuration['secret_scanning_delegated_bypass_options']['reviewers'][0].Remove('mode')

        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $plan.ExitCode | Should -Be 0 -Because $plan.Output
    }

    It 'fails the plan when the custom pattern field <Field> drifts' -ForEach @(
        @{ Field = 'start_delimiter'; Value = 'key=' }
        @{ Field = 'end_delimiter'; Value = '\s' }
        @{ Field = 'must_match'; Value = @('itk_[0-9]{32}') }
        @{ Field = 'must_not_match'; Value = @('itk_0{32}') }
    ) {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $stubState.CodeSecurity.Patterns[0][$Field] = $Value

        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $plan.ExitCode | Should -Be 1 -Because $plan.Output
        ($plan.Output -replace '\s+', ' ') | Should -BeLike '*missing or differs from customPatterns*'
        ($plan.Output -replace '\s+', ' ') | Should -Not -BeLike '*push protection disabled*'
    }

    It 'converges on the next apply when the response of PUT <Request> is lost' -ForEach @(
        @{ Request = '/orgs/demo/actions/permissions' }
        @{ Request = '/orgs/demo/actions/permissions/workflow' }
    ) {
        $policy = $stubState.ActionsPolicy
        $policy.Workflow['can_approve_pull_request_reviews'] = $true
        $policy.Workflow['default_workflow_permissions'] = 'write'
        $policy.DropNext = "^PUT $([regex]::Escape($Request))$"

        $interrupted = Invoke-StubTerraform apply -input=false -auto-approve
        $resumed = Invoke-StubTerraform apply -input=false -auto-approve
        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $policy.DropNext | Should -BeNullOrEmpty -Because 'the stub must have lost the response'
        $interrupted.ExitCode | Should -Not -Be 0
        $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
        $plan.ExitCode | Should -Be 0 -Because $plan.Output
        $policy.Actions['enabled_repositories'] | Should -BeExactly 'all'
        $policy.Actions['allowed_actions'] | Should -BeExactly 'local_only'
        $policy.Actions['sha_pinning_required'] | Should -BeExactly $true
        $policy.Workflow['default_workflow_permissions'] | Should -BeExactly 'read'
        $policy.Workflow['can_approve_pull_request_reviews'] | Should -BeFalse
    }

    It 'restores the GitHub defaults when a destroy loses the PUT response and is repeated' {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        $policy = $stubState.ActionsPolicy
        $policy.DropNext = '^PUT /orgs/demo/actions/permissions$'

        $interrupted = Invoke-StubTerraform destroy -input=false -auto-approve
        $resumed = Invoke-StubTerraform destroy -input=false -auto-approve
        $remaining = Invoke-StubTerraform state list

        $policy.DropNext | Should -BeNullOrEmpty -Because 'the stub must have lost the response'
        $interrupted.ExitCode | Should -Not -Be 0
        $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
        $remaining.Output.Trim() | Should -BeNullOrEmpty
        $policy.Actions['enabled_repositories'] | Should -BeExactly 'all'
        $policy.Actions['allowed_actions'] | Should -BeExactly 'all'
        $policy.Actions['sha_pinning_required'] | Should -BeExactly $false
        $policy.Workflow['default_workflow_permissions'] | Should -BeExactly 'read'
        $policy.Workflow['can_approve_pull_request_reviews'] | Should -BeFalse
    }

    It 'resumes destroy from a policy identity stored before SHA pinning was managed' -Tag 'ShaPinning' {
        $overridePath = Join-Path $root 'stub_override.tf'
        $currentOverride = Get-Content -LiteralPath $overridePath -Raw
        # Reproduce the input saved by the pre-#82 resource, not a new identity with the SHA field.
        Add-Content -LiteralPath $overridePath -Value @'
locals {
  actions_policy_github_defaults = {
    enabled_repositories             = "all"
    allowed_actions                  = "all"
    default_workflow_permissions     = "read"
    can_approve_pull_request_reviews = false
  }
}
'@
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        Set-Content -LiteralPath $overridePath -Value $currentOverride
        $policy = $stubState.ActionsPolicy
        $policy.DropNext = '^PUT /orgs/demo/actions/permissions$'

        $interrupted = Invoke-StubTerraform destroy -input=false -auto-approve
        $resumed = Invoke-StubTerraform destroy -input=false -auto-approve

        $policy.DropNext | Should -BeNullOrEmpty
        $interrupted.ExitCode | Should -Not -Be 0
        $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
        $policy.Actions['allowed_actions'] | Should -BeExactly 'all'
        $policy.Actions['sha_pinning_required'] | Should -BeExactly $false
    }

    It 'fails the plan when the actions policy drifts: <Case>' -ForEach @(
        @{ Case = 'all actions allowed'; Message = 'allowed actions policy of demo is not local_only'; Drift = { param($p) $p.Actions['allowed_actions'] = 'all' } }
        @{ Case = 'SHA pinning disabled'; Message = 'Required SHA pinning of demo is not true'; Drift = { param($p) $p.Actions['sha_pinning_required'] = $false } }
        @{ Case = 'write token'; Message = 'GITHUB_TOKEN permissions of demo are not read'; Drift = { param($p) $p.Workflow['default_workflow_permissions'] = 'write' } }
        @{ Case = 'pull request approval'; Message = 'can create and approve pull requests is not false'; Drift = { param($p) $p.Workflow['can_approve_pull_request_reviews'] = $true } }
    ) {
        $apply = Invoke-StubTerraform apply -input=false -auto-approve
        $apply.ExitCode | Should -Be 0 -Because $apply.Output
        & $Drift $stubState.ActionsPolicy

        $plan = Invoke-StubTerraform plan -input=false -detailed-exitcode

        $plan.ExitCode | Should -Be 1 -Because $plan.Output
        ($plan.Output -replace '\s+', ' ') | Should -BeLike "*$Message*"
    }
}
