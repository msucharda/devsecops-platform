BeforeAll {
    $moduleRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/organization-rulesets'
    $stubModule = Join-Path $PSScriptRoot 'RulesetsStub.psm1'
    Import-Module $stubModule -Force
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $port = $listener.LocalEndpoint.Port
    $server = [hashtable]::Synchronized(@{ State = $null; Stop = $false })
    $job = Start-ThreadJob -ScriptBlock {
        $listener = $using:listener
        $server = $using:server
        Import-Module $using:stubModule
        while (-not $server.Stop) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 10; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
                $request = $reader.ReadLine()
                $headers = @{}
                while ($line = $reader.ReadLine()) {
                    if ($line -match '^(?<name>[^:]+):\s*(?<value>.*)$') { $headers[$Matches['name']] = $Matches['value'] }
                }
                $length = if ($headers['Content-Length']) { [int] $headers['Content-Length'] } else { 0 }
                $buffer = [char[]]::new($length)
                $read = 0
                while ($read -lt $length) { $read += $reader.Read($buffer, $read, $length - $read) }
                $method, $path = $request.Split(' ')[0, 1]
                $reply = Invoke-RulesetsStubRequest -State $server.State -Method $method -Path $path -Headers $headers -Body ([string]::new($buffer))
                if ($reply.Drop) { continue }
                $bytes = [Text.Encoding]::UTF8.GetBytes([string] $reply.Body)
                $link = if ($reply.Link) { "Link: $($reply.Link)`r`n" } else { '' }
                $header = "HTTP/1.1 $($reply.Status) Stub`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`n${link}Connection: close`r`n`r`n"
                $headerBytes = [Text.Encoding]::ASCII.GetBytes($header)
                $stream.Write($headerBytes)
                $stream.Write($bytes)
                $stream.Flush()
            }
            finally { $client.Close() }
        }
    }
    $previousTokens = $env:PLATFORM_GITHUB_TOKENS
    $previousBearer = $env:REST_API_BEARER
    $env:PLATFORM_GITHUB_TOKENS = '{"demo":"stub-token"}'
    $env:REST_API_BEARER = 'stub-token'
    $recovery = Join-Path (Split-Path $PSScriptRoot -Parent) 'Restore-RulesetState.ps1'

    function Invoke-RulesetTerraform {
        $terraformArguments = @($args)
        if ($args[0] -ceq 'destroy') {
            try { & $recovery -TerraformRoot $root -VariableFile (Join-Path $root 'terraform.tfvars.json') }
            catch { return @{ Code = 1; Text = $_.Exception.Message } }
            $terraformArguments += '-var=ruleset_destroy_started=true'
        }
        $output = & terraform "-chdir=$root" @terraformArguments -no-color 2>&1 | Out-String
        return @{ Code = $LASTEXITCODE; Text = $output }
    }
}

AfterAll {
    $env:PLATFORM_GITHUB_TOKENS = $previousTokens
    $env:REST_API_BEARER = $previousBearer
    $server.Stop = $true
    $job | Wait-Job -Timeout 10 | Out-Null
    $listener.Stop()
    $job | Remove-Job -Force
}

Describe 'Ruleset Terraform root against the documented and observed API' -Tag Terraform {
    AfterEach {
        # Restore-RulesetState imports the fixture copy into this process.
        Get-Module -Name Rulesets | Where-Object { $_.Path -eq (Join-Path $modules 'organization-rulesets/scripts/Rulesets.psm1') } |
            Remove-Module -Force
    }

    BeforeEach {
        $parent = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $modules = Join-Path $parent 'modules'
        $module = Join-Path $modules 'organization-rulesets'
        $root = Join-Path $module 'rulesets'
        New-Item -ItemType Directory -Path $root -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path $moduleRoot '../shared') -Destination $modules -Recurse
        Copy-Item -Path (Join-Path $moduleRoot 'rulesets/*.tf'), (Join-Path $moduleRoot 'rulesets/.terraform.lock.hcl') -Destination $root
        Copy-Item -LiteralPath (Join-Path $moduleRoot 'scripts') -Destination $module -Recurse
        Set-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @"
terraform {
  backend "local" {}
}
locals { github_api_url = "http://127.0.0.1:$port" }
"@
        if ($IsWindows) {
            Add-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @'
data "external" "ruleset_state" {
  program = ["cmd", "/c", "pwsh", "-NoProfile", "-NonInteractive", "-File", "../scripts/Read-RulesetState.ps1"]
}
data "external" "ruleset_plan_state" {
  program = ["cmd", "/c", "pwsh", "-NoProfile", "-NonInteractive", "-File", "../scripts/Read-RulesetState.ps1"]
}
'@
        }
        $testOrganization = if (Get-Variable Organization -ErrorAction SilentlyContinue) { $Organization } else { 'demo' }
        $testToken = if ($testOrganization -ceq 'demo') { 'stub-token' } else { "$testOrganization-token" }
        $env:REST_API_BEARER = $testToken
        $env:PLATFORM_GITHUB_TOKENS = ConvertTo-Json -InputObject @{ $testOrganization = $testToken } -Compress
        $instanceOrganizations = if ($testOrganization -ceq 'demo') { @{ actions = 'demo' } } else {
            @{ platform = 'demo-platform'; actions = 'demo-actions'; workloads = 'demo-workloads' }
        }
        Set-Content -LiteralPath (Join-Path $root 'terraform.tfvars.json') -Value (ConvertTo-Json -Depth 10 -InputObject @{
            instance = @{ github = @{ host = 'example.ghe.com' }; organizations = $instanceOrganizations }
            prerequisites = @{}; target_organizations = @($testOrganization)
        })
        $server.State = Initialize-RulesetsStub -Origin "http://127.0.0.1:$port" -Organization $testOrganization -Token $testToken
        $init = Invoke-RulesetTerraform init -input=false
        $init.Code | Should -Be 0 -Because $init.Text
    }

    It 'creates a ruleset, returns a second plan without changes and removes it on destroy in <Organization>' -ForEach @(
        @{ Organization = 'demo' }
        @{ Organization = 'demo-platform' }
        @{ Organization = 'demo-actions' }
        @{ Organization = 'demo-workloads' }
    ) {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $plan = Invoke-RulesetTerraform plan -input=false -detailed-exitcode
        $plan.Code | Should -Be 0 -Because $plan.Text
        $server.State.Items.Count | Should -Be 1
        $created = $server.State.Items[0]
        $created['source'] | Should -BeExactly $Organization
        $created['bypass_actors'].Count | Should -Be 0
        $created['rules'].Count | Should -Be 4
        $created['rules'][3]['parameters']['require_extra_approval_for_unattributed_changes'] | Should -BeTrue
        $created['conditions']['ref_name']['include'] | Should -Be @('~DEFAULT_BRANCH')
        $created['conditions']['repository_name']['include'] | Should -Be @('~ALL')
        Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
        $contract = Get-GitHubApiFixtureContract -Name repos/create-org-ruleset
        foreach ($write in $server.State.Writes) {
            @($write.Body.Keys | Sort-Object) | Should -Be @($contract.requestProperties | Sort-Object)
            foreach ($rule in $write.Body['rules']) {
                if ($contract.ruleParameters.Contains($rule['type'])) {
                    $parameters = $contract.ruleParameters[$rule['type']]
                    foreach ($field in $parameters.required) { $rule['parameters'].Contains($field) | Should -BeTrue }
                    $allowed = @($parameters.properties) + @($parameters['observedRequestProperties'])
                    foreach ($field in $rule['parameters'].Keys) { $allowed | Should -Contain $field }
                }
                else { $rule['type'] | Should -BeIn @('deletion', 'non_fast_forward') }
            }
        }
        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 0
    }

    It 'rejects the first plan before any write without an enforced Code Security default' -Tag CodeSecurityPrerequisite {
        $server.State.CodeSecurityDefaults = @()
        $plan = Invoke-RulesetTerraform plan -input=false -detailed-exitcode
        $plan.Code | Should -Be 1 -Because $plan.Text
        $plan.Text | Should -Match 'no enforced platform-baseline Code\s+Security default'
        $plan.Text | Should -Match 'Deploy the enterprise-baseline Code Security phase'
        $server.State.Items.Count | Should -Be 0
        $server.State.Writes.Count | Should -Be 0
    }

    It 'rejects disabled Code Security before modifying an existing ruleset' -Tag CodeSecurityPrerequisite {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.CodeSecurityDefaults[0]['configuration']['advanced_security'] = 'disabled'
        $writes = $server.State.Writes.Count

        $plan = Invoke-RulesetTerraform plan -input=false -detailed-exitcode
        $plan.Code | Should -Be 1 -Because $plan.Text
        $plan.Text | Should -Match "invalid\s+'advanced_security'"
        $server.State.Writes.Count | Should -Be $writes
    }

    It 'can destroy rulesets after the Code Security default was removed' -Tag CodeSecurityPrerequisite {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.CodeSecurityDefaults = @()

        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 0
    }

    It 'cannot bypass the prerequisite by using the teardown flag for deploy' -Tag CodeSecurityPrerequisite {
        $server.State.CodeSecurityDefaults = @()
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve -var=ruleset_destroy_started=true
        $apply.Code | Should -Be 1 -Because $apply.Text
        $apply.Text | Should -Match 'reserved for teardown recovery'
        $server.State.Writes.Count | Should -Be 0
    }

    It 'recovers and removes an interrupted create after the security default was removed' -Tag CodeSecurityPrerequisite {
        $server.State.DropNext = '^POST /orgs/demo/rulesets$'
        (Invoke-RulesetTerraform apply -input=false -auto-approve).Code | Should -Not -Be 0
        $server.State.Items.Count | Should -Be 1
        $server.State.CodeSecurityDefaults = @()

        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 0
    }

    It 'fails the plan closed without any write when the ruleset was deleted outside Terraform' {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.Items.Clear()
        $writes = $server.State.Writes.Count
        $plan = Invoke-RulesetTerraform plan -input=false -detailed-exitcode
        $plan.Code | Should -Be 1 -Because $plan.Text
        $plan.Text | Should -Match 'mismatched identity'
        $server.State.Items.Count | Should -Be 0
        $server.State.Writes.Count | Should -Be $writes
    }

    It 'removes the recorded remote ID even when the managed ruleset was renamed outside Terraform' {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.Items[0]['name'] = 'renamed-outside-terraform'
        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 0
    }

    It 'preserves an unrelated ruleset of the original name when the managed ID was renamed' {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.Items[0]['name'] = 'renamed-outside-terraform'
        Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
        $other = Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{
            id = 999; name = 'platform-default-branch'; source = 'demo'
        }
        $server.State.Items.Add($other)
        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 1
        $server.State.Items[0]['id'] | Should -Be 999
    }

    It 'imports an interrupted POST by persisted intent before destroy instead of leaving an orphan' {
        $server.State.DropNext = '^POST /orgs/demo/rulesets$'
        (Invoke-RulesetTerraform apply -input=false -auto-approve).Code | Should -Not -Be 0
        $server.State.Items.Count | Should -Be 1
        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 0
    }

    It 'retains the recovered ID across interruption between import and destroy' {
        $server.State.DropNext = '^POST /orgs/demo/rulesets$'
        (Invoke-RulesetTerraform apply -input=false -auto-approve).Code | Should -Not -Be 0
        & $recovery -TerraformRoot $root -VariableFile (Join-Path $root 'terraform.tfvars.json')
        # The process ends after the durable import; the next invocation sees a rename and a new object of the old name.
        $server.State.Items[0]['name'] = 'renamed-after-import'
        Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
        $server.State.Items.Add((Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{
            id = 999; name = 'platform-default-branch'; source = 'demo'
        }))
        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 1
        $server.State.Items[0]['id'] | Should -Be 999
    }

    It 'retains native identity when GET returns JSON null instead of the object before destroy' {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.EmptyDetail = $true
        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 1
        $destroy.Text | Should -Match 'empty successful GET'
        $server.State.Items.Count | Should -Be 1
        $remaining = Invoke-RulesetTerraform state list
        $remaining.Text | Should -Match 'restapi_object.ruleset'
        @($server.State.Requests | Where-Object { $_ -like 'DELETE *' }).Count | Should -Be 0
    }

    It 'never adopts another object after native deletion but before intent deletion' {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.Items[0]['name'] = 'renamed-before-destroy'
        Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
        $server.State.Items.Add((Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{
            id = 999; name = 'platform-default-branch'; source = 'demo'
        }))
        & $recovery -TerraformRoot $root -VariableFile (Join-Path $root 'terraform.tfvars.json')
        # Stop the destroy after the native resource leaves state, retaining its pre-POST intent.
        $partial = & terraform "-chdir=$root" destroy -input=false -auto-approve -no-color '-target=restapi_object.ruleset["demo"]' 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $partial
        (Invoke-RulesetTerraform state list).Text | Should -Match 'terraform_data.ruleset_intent'
        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 1
        $server.State.Items[0]['id'] | Should -Be 999
    }

    It 'checks an existing bypass during plan even when a pending resource change defers the post-apply reader' {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.Items[0]['bypass_actors'] = @(@{ actor_type = 'OrganizationAdmin'; actor_id = 1; bypass_mode = 'always' })
        $plan = Invoke-RulesetTerraform plan -input=false -detailed-exitcode '-replace=terraform_data.ruleset_intent["demo"]'
        $plan.Code | Should -Be 1 -Because $plan.Text
        $plan.Text | Should -Match 'bypass actors'
    }

    It 'accepts the documented disabled dismissal restriction without optional allowed_actors' {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        $server.State.Items[0]['rules'][3]['parameters']['dismissal_restriction'] = @{ enabled = $false }
        $plan = Invoke-RulesetTerraform plan -input=false -detailed-exitcode
        $plan.Code | Should -Be 0 -Because $plan.Text
    }

    It 'recovers interruption after the remote write but before its ID is captured in state' -Tag 'RulesetRecovery' {
        $server.State.FailNext = '^GET /orgs/demo/rulesets/[0-9]+$'
        $interrupted = Invoke-RulesetTerraform apply -input=false -auto-approve
        $server.State.FailNext | Should -BeNullOrEmpty
        $interrupted.Code | Should -Not -Be 0
        $interrupted.Text | Should -Match 'HTTP 500'
        $server.State.Items.Count | Should -Be 1
        $resumed = Invoke-RulesetTerraform apply -input=false -auto-approve
        $resumed.Code | Should -Be 0 -Because $resumed.Text
        $server.State.Items.Count | Should -Be 1
        @($server.State.Writes | Where-Object { $_.Method -ceq 'POST' }).Count | Should -Be 1
        $destroy = Invoke-RulesetTerraform destroy -input=false -auto-approve
        $destroy.Code | Should -Be 0 -Because $destroy.Text
        $server.State.Items.Count | Should -Be 0
    }

    It 'recovers a lost <Method> response without duplication or a leftover object' -ForEach @(
        @{ Method = 'POST'; Drop = '^POST /orgs/demo/rulesets$'; Destroy = $false }
        @{ Method = 'PUT'; Drop = '^PUT /orgs/demo/rulesets/[0-9]+$'; Destroy = $false }
        @{ Method = 'DELETE'; Drop = '^DELETE /orgs/demo/rulesets/[0-9]+$'; Destroy = $true }
    ) {
        $arguments = @('apply', '-input=false', '-auto-approve')
        if ($Method -ceq 'PUT') {
            $server.State.DropNext = '^POST /orgs/demo/rulesets$'
            (Invoke-RulesetTerraform @arguments).Code | Should -Not -Be 0
        }
        elseif ($Method -ceq 'DELETE') {
            $created = Invoke-RulesetTerraform @arguments
            $created.Code | Should -Be 0 -Because $created.Text
        }
        if ($Destroy) { $arguments[0] = 'destroy' }
        $server.State.DropNext = $Drop
        $interrupted = Invoke-RulesetTerraform @arguments
        $server.State.DropNext | Should -BeNullOrEmpty -Because 'the write must have happened before the connection was lost'
        $interrupted.Code | Should -Not -Be 0
        $resumed = Invoke-RulesetTerraform @arguments
        $resumed.Code | Should -Be 0 -Because $resumed.Text
        $server.State.Items.Count | Should -Be $(if ($Destroy) { 0 } else { 1 })
        $plan = Invoke-RulesetTerraform plan -input=false -detailed-exitcode
        $plan.Code | Should -Be $(if ($Destroy) { 2 } else { 0 }) -Because $plan.Text
        if ($Destroy) {
            $remaining = Invoke-RulesetTerraform state list
            $remaining.Text.Trim() | Should -BeNullOrEmpty
        }
    }

    It 'fails closed on drift: <Case>' -ForEach @(
        @{ Case = 'bypass added'; Change = { param($r) $r['bypass_actors'] = @(@{ actor_type = 'OrganizationAdmin'; actor_id = 1; bypass_mode = 'always' }) } }
        @{ Case = 'bypass missing'; Change = { param($r) $r.Remove('bypass_actors') } }
        @{ Case = 'bypass null'; Change = { param($r) $r['bypass_actors'] = $null } }
        @{ Case = 'bypass not a list'; Change = { param($r) $r['bypass_actors'] = @{} } }
        @{ Case = 'enforcement disabled'; Change = { param($r) $r['enforcement'] = 'disabled' } }
        @{ Case = 'enforcement missing'; Change = { param($r) $r.Remove('enforcement') } }
        @{ Case = 'tag instead of branch'; Change = { param($r) $r['target'] = 'tag' } }
        @{ Case = 'default branch excluded'; Change = { param($r) $r['conditions']['ref_name']['exclude'] = @('main') } }
        @{ Case = 'literal branch instead of default'; Change = { param($r) $r['conditions']['ref_name']['include'] = @('refs/heads/main') } }
        @{ Case = 'repository excluded'; Change = { param($r) $r['conditions']['repository_name']['exclude'] = @('instance') } }
        @{ Case = 'only selected repositories'; Change = { param($r) $r['conditions']['repository_name']['include'] = @('instance') } }
        @{ Case = 'deletion allowed'; Change = { param($r) $r['rules'] = @($r['rules'] | Where-Object { $_['type'] -cne 'deletion' }) } }
        @{ Case = 'force push allowed'; Change = { param($r) $r['rules'] = @($r['rules'] | Where-Object { $_['type'] -cne 'non_fast_forward' }) } }
        @{ Case = 'approval removed'; Change = { param($r) $r['rules'][3]['parameters']['required_approving_review_count'] = 0 } }
        @{ Case = 'stale reviews retained'; Change = { param($r) $r['rules'][3]['parameters']['dismiss_stale_reviews_on_push'] = $false } }
        @{ Case = 'CODEOWNERS not required'; Change = { param($r) $r['rules'][3]['parameters']['require_code_owner_review'] = $false } }
        @{ Case = 'extra approval for unattributed changes disabled'; Change = { param($r) $r['rules'][3]['parameters']['require_extra_approval_for_unattributed_changes'] = $false } }
        @{ Case = 'extra approval for unattributed changes missing'; Change = { param($r) $r['rules'][3]['parameters'].Remove('require_extra_approval_for_unattributed_changes') } }
        @{ Case = 'extra approval for unattributed changes null'; Change = { param($r) $r['rules'][3]['parameters']['require_extra_approval_for_unattributed_changes'] = $null } }
        @{ Case = 'extra approval for unattributed changes not boolean'; Change = { param($r) $r['rules'][3]['parameters']['require_extra_approval_for_unattributed_changes'] = 'true' } }
        @{ Case = 'high findings allowed'; Change = { param($r) $r['rules'][0]['parameters']['code_scanning_tools'][0]['security_alerts_threshold'] = 'critical' } }
        @{ Case = 'another scanning tool'; Change = { param($r) $r['rules'][0]['parameters']['code_scanning_tools'][0]['tool'] = 'Other' } }
        @{ Case = 'scan rule removed'; Change = { param($r) $r['rules'] = @($r['rules'] | Where-Object { $_['type'] -cne 'code_scanning' }) } }
        @{ Case = 'extra rule'; Change = { param($r) $r['rules'] += @{ type = 'required_signatures' } } }
        @{ Case = 'duplicate rule'; Change = { param($r) $r['rules'] += $r['rules'][1] } }
    ) {
        $apply = Invoke-RulesetTerraform apply -input=false -auto-approve
        $apply.Code | Should -Be 0 -Because $apply.Text
        # Each case changes one property of the otherwise valid contract response.
        $null = & $Change $server.State.Items[0]
        $plan = Invoke-RulesetTerraform plan -input=false -detailed-exitcode
        $plan.Code | Should -Be 1 -Because $plan.Text
        $plan.Text | Should -Match '(?s)(bypass_actors|differs from the baseline|bypass actors|no ''enforcement'')'
    }
}
