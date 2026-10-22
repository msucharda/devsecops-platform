BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $mainPath = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline/main.tf'
    $main = Get-Content -LiteralPath $mainPath -Raw

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
            'members_can_create_internal_repositories', 'members_can_fork_private_repositories')
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
}

Describe 'enterprise-baseline against a local GitHub API stub' -Tag 'Terraform' {
    BeforeAll {
        $moduleRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline'
        $stubState = [hashtable]::Synchronized(@{ Organization = $null; DropNextPatch = $false; Requests = [Collections.Generic.List[string]]::new(); CodeSecurity = $null; ActionsPolicy = $null })
        $codeSecurityStub = Join-Path $PSScriptRoot 'CodeSecurityStub.psm1'
        Import-Module $codeSecurityStub -Force
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        # Serves GET and PATCH /orgs/demo; DropNextPatch applies a PATCH and closes the connection without a response.
        # GET and PUT of the actions policy apply DropNext (a request regex) by writing and closing the connection.
        # Other paths go to the code security stub, whose Drop also closes the connection without a response.
        $stub = Start-ThreadJob -ScriptBlock {
            $listener = $using:listener
            $state = $using:stubState
            Import-Module $using:codeSecurityStub
            while ($true) {
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
                    while ($read -lt $length) { $read += $reader.Read($buffer, $read, $length - $read) }
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
                    elseif ($path -cne '/orgs/demo' -and $state.CodeSecurity) {
                        $reply = Invoke-CodeSecurityStubRequest -State $state.CodeSecurity -Method $method -PathAndQuery $path -Headers $headers -Body ([string]::new($buffer))
                        if ($reply.Drop) { continue }
                        $status = "$($reply.Status) Stub"
                        $body = [string] $reply.Body
                        $link = $reply.Link
                    }
                    elseif ($path -cne '/orgs/demo' -or $method -notin @('GET', 'PATCH')) {
                        $state.Requests.Add("$method $path")
                        $status = '404 Not Found'
                        $body = '{"message":"Not Found"}'
                    }
                    else {
                        $state.Requests.Add("$method $path")
                        if ($method -eq 'PATCH') {
                            $changes = ([string]::new($buffer)) | ConvertFrom-Json -AsHashtable
                            foreach ($key in $changes.Keys) { $state.Organization[$key] = $changes[$key] }
                            if ($state.DropNextPatch) {
                                $state.DropNextPatch = $false
                                continue
                            }
                        }
                        $status = '200 OK'
                        $body = ConvertTo-Json -InputObject $state.Organization -Depth 20 -Compress
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

        $previousBearer = $env:REST_API_BEARER
        $previousTimeout = $env:CODE_SECURITY_ATTACHMENT_TIMEOUT
        $env:REST_API_BEARER = 'stub-token'
        $env:CODE_SECURITY_ATTACHMENT_TIMEOUT = '0'

        function Invoke-StubTerraform {
            $output = & terraform "-chdir=$root" @args -no-color 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
    }

    AfterAll {
        $env:REST_API_BEARER = $previousBearer
        $env:CODE_SECURITY_ATTACHMENT_TIMEOUT = $previousTimeout
        $listener.Stop()
        $stub | Stop-Job -PassThru | Remove-Job -Force
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root | Out-Null
        Copy-Item -Path (Join-Path $moduleRoot '*.tf'), (Join-Path $moduleRoot '.terraform.lock.hcl') -Destination $root
        Copy-Item -Path (Join-Path $moduleRoot 'scripts') -Destination $root -Recurse
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
data "external" "code_security_state" {
  program = ["cmd", "/c", "pwsh", "-NoProfile", "-NonInteractive", "-File", "./scripts/Read-CodeSecurityState.ps1"]
}

data "external" "actions_policy_state" {
  program = ["cmd", "/c", "pwsh", "-NoProfile", "-NonInteractive", "-File", "./scripts/Read-ActionsPolicyState.ps1"]
}
'@
        }
        Set-Content -LiteralPath (Join-Path $root 'terraform.tfvars.json') -Value (ConvertTo-Json -Depth 10 -InputObject @{
            instance = @{
                name = 'demo'; github = @{ host = 'example.ghe.com'; enterprise = 'example' }
                customPatterns = @(@{ name = 'Internal token'; secretRegex = 'itk_[0-9a-f]{32}' })
            }
            target_organizations = @('demo')
            prerequisites = @{}
            secret_scanning_bypass_reviewers = @(@{ reviewer_type = 'TEAM'; reviewer_id = 42 })
        })
        $stubState.CodeSecurity = Initialize-CodeSecurityStub -Organization demo -Origin "http://127.0.0.1:$port" -Token stub-token
        $stubState.Organization = Get-GitHubApiFixture -Name orgs/get -Set @{
            login = 'demo'
            members_can_change_repo_visibility = $false
            members_can_delete_repositories = $false
        }
        $stubState.ActionsPolicy = [hashtable]::Synchronized(@{
            Paths = @{ '/orgs/demo/actions/permissions' = 'Actions'; '/orgs/demo/actions/permissions/workflow' = 'Workflow' }
            # A new organization: GitHub defaults with the enterprise default of read-only workflow permissions.
            Actions = Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization -Set @{ allowed_actions = 'all'; sha_pinning_required = $false }
            Workflow = Get-GitHubApiFixture -Name actions/get-github-actions-default-workflow-permissions-organization -Set @{ can_approve_pull_request_reviews = $false }
            DropNext = $null
            Requests = [Collections.Generic.List[string]]::new()
        })
        $stubState.ActionsPolicy.Actions.Remove('selected_actions_url')
        $stubState.DropNextPatch = $false
        $stubState.Requests.Clear()
        $managed = @{
            default_repository_permission            = 'none'
            members_can_create_repositories          = $false
            members_can_create_private_repositories  = $false
            members_can_create_internal_repositories = $false
            members_can_fork_private_repositories    = $false
        }
        $defaults = @{
            default_repository_permission            = 'read'
            members_can_create_repositories          = $true
            members_can_create_private_repositories  = $true
            members_can_create_internal_repositories = $true
            members_can_fork_private_repositories    = $false
        }
        $unmanaged = @{
            description = $stubState.Organization['description']
            members_can_create_pages = $stubState.Organization['members_can_create_pages']
        }
        $init = Invoke-StubTerraform init -input=false
        $init.ExitCode | Should -Be 0 -Because $init.Output
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
        (Invoke-StubTerraform apply -input=false -auto-approve).ExitCode | Should -Be 0
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
        (Invoke-StubTerraform apply -input=false -auto-approve).ExitCode | Should -Be 0
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
        (Invoke-StubTerraform apply -input=false -auto-approve).ExitCode | Should -Be 0
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
        $policy.Actions['sha_pinning_required'] | Should -BeFalse
        $policy.Workflow['default_workflow_permissions'] | Should -BeExactly 'read'
        $policy.Workflow['can_approve_pull_request_reviews'] | Should -BeFalse
    }

    It 'restores the GitHub defaults when a destroy loses the PUT response and is repeated' {
        (Invoke-StubTerraform apply -input=false -auto-approve).ExitCode | Should -Be 0
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
        $policy.Workflow['default_workflow_permissions'] | Should -BeExactly 'read'
        $policy.Workflow['can_approve_pull_request_reviews'] | Should -BeFalse
    }

    It 'fails the plan when the actions policy drifts: <Case>' -ForEach @(
        @{ Case = 'all actions allowed'; Message = 'allowed actions policy of demo is not local_only'; Drift = { param($p) $p.Actions['allowed_actions'] = 'all' } }
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
