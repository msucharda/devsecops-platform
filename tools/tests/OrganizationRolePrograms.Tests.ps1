BeforeAll {
    $stubFile = Join-Path $PSScriptRoot 'OrganizationRoles.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlock = $stubAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'BeforeAll' -and
            $node.CommandElements.Count -eq 2 -and $node.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true) | Select-Object -First 1
    if (-not $stubBlock) { throw "$stubFile has no BeforeAll block for the organization-role stub." }
    . $stubBlock.CommandElements[1].ScriptBlock.GetScriptBlock()
    $stubDefinition = "function Invoke-RoleApiStub { $((Get-Item Function:\Invoke-RoleApiStub).ScriptBlock) }"
    $fixtureModule = Join-Path $PSScriptRoot 'GitHubApiFixture.psm1'
    $readerScript = Join-Path $PSScriptRoot '..\..\modules\organization-roles\scripts\Read-OrganizationRoleState.ps1'
    $changeScript = Join-Path $PSScriptRoot '..\..\modules\organization-roles\scripts\Invoke-OrganizationRoleChange.ps1'

    function Invoke-RoleProgram {
        param([string] $Script, [string] $InputJson, [string] $Action)

        $start = [Diagnostics.ProcessStartInfo]::new()
        $start.FileName = (Get-Command pwsh).Source
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $Script)) { $start.ArgumentList.Add($argument) }
        if ($Action) {
            $start.ArgumentList.Add('-Action')
            $start.ArgumentList.Add($Action)
        }
        $start.Environment['REST_API_BEARER'] = 'test-role-cli-token'
        $start.Environment['ORGANIZATION_ROLES_INPUT'] = $InputJson
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            $process.StandardInput.Write($InputJson)
            $process.StandardInput.Close()
            if (-not $process.WaitForExit(60000)) {
                Stop-Process -Id $process.Id -Force
                throw 'The organization-role program exceeded 60 seconds.'
            }
            @{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult(); Error = $stderr.GetAwaiter().GetResult() }
        }
        finally { $process.Dispose() }
    }
}

Describe 'Organization role Terraform programs' {
    BeforeEach {
        $roleStub = [hashtable]::Synchronized(@{
                Stop = $false
                Versions = [Collections.Generic.List[string]]::new()
                Writes = [Collections.Generic.List[string]]::new()
                Roles = Get-GitHubApiFixture -Name org-roles/list-org-roles.organization-null -Set @{
                    'roles.0.name' = 'security_manager'; 'roles.0.source' = 'Predefined'
                }
                Team = Get-GitHubApiFixture -Name org-roles/get-by-name -Set @{
                    slug = 'security'; 'organization.login' = 'demo-actions'
                }
                Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{ '0.slug' = 'security' }
            })
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $apiUrl = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
        $query = @{ api_url = $apiUrl; organization = 'demo-actions'; team = 'security' }
        $server = Start-ThreadJob -ScriptBlock {
            $socket = $using:listener
            $roleStub = $using:roleStub
            Import-Module $using:fixtureModule -Force
            . ([scriptblock]::Create($using:stubDefinition))
            try {
                while (-not $roleStub.Stop) {
                    try { $client = $socket.AcceptTcpClient() }
                    catch [Net.Sockets.SocketException] {
                        if ($roleStub.Stop) { break }
                        throw
                    }
                    try {
                        $stream = $client.GetStream()
                        $stream.ReadTimeout = 5000
                        $reader = [IO.StreamReader]::new($stream, [Text.Encoding]::Latin1, $false, 1024, $true)
                        $request = $reader.ReadLine().Split(' ')
                        $contentLength = 0
                        while ($line = $reader.ReadLine()) {
                            if ($line -match '^X-GitHub-Api-Version: (.+)$') { $roleStub.Versions.Add($Matches[1]) }
                            if ($line -match '^Content-Length: (\d+)$') { $contentLength = [int] $Matches[1] }
                        }
                        $requestBody = ''
                        if ($contentLength -gt 0) {
                            $characters = [char[]]::new($contentLength)
                            if ($reader.ReadBlock($characters, 0, $contentLength) -ne $contentLength) {
                                throw 'The offline server received an incomplete request body.'
                            }
                            $requestBody = [Text.Encoding]::UTF8.GetString([Text.Encoding]::Latin1.GetBytes($characters))
                        }
                        if (($request[0] -ceq 'PUT' -and $roleStub['CaptureBeforePut']) -or
                            ($request[0] -ceq 'DELETE' -and $roleStub['CaptureBeforeDelete'])) {
                            $saved = if ($roleStub['UseRemoteTerraformState']) { $roleStub.RemoteTerraformState }
                            elseif (Test-Path -LiteralPath $roleStub.TerraformStateFile) {
                                Get-Content -LiteralPath $roleStub.TerraformStateFile -Raw -ErrorAction Stop
                            }
                            else { '' }
                            if ($request[0] -ceq 'PUT') { $roleStub.BeforePutSnapshots.Add($saved) }
                            else { $roleStub.BeforeDeleteSnapshots.Add($saved) }
                        }
                        if ($request[1] -ceq '/terraform-state') {
                            if ($request[0] -ceq 'GET') {
                                $status = if ($roleStub.RemoteTerraformState) { 200 } else { 404 }
                                $reply = [pscustomobject]@{ StatusCode = $status; Content = $roleStub.RemoteTerraformState }
                            }
                            elseif ($request[0] -ceq 'POST') {
                                $roleStub.RemoteTerraformState = $requestBody
                                $reply = [pscustomobject]@{ StatusCode = 200; Content = '' }
                            }
                            else { throw "Unexpected Terraform state request: $($request[0])." }
                        }
                        elseif ($roleStub['RejectNext'] -ceq $request[0]) {
                            $roleStub['RejectNext'] = $null
                            $reply = [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption before applying the write."}' }
                        }
                        elseif ($roleStub['TeamMissing'] -and $request[0] -ceq 'GET' -and
                            $request[1] -ceq '/orgs/demo-actions/teams/security') {
                            $notFound = Get-GitHubApiFixture -Name org-roles/get-by-name.not-found
                            $reply = [pscustomobject]@{ StatusCode = 404; Content = (ConvertTo-Json $notFound -Compress) }
                        }
                        elseif ($roleStub['FailNextRoleRead'] -and $request[0] -ceq 'GET' -and
                            $request[1] -ceq '/orgs/demo-actions/organization-roles') {
                            # Intentionally unsupported response at the first apply-time identity read.
                            $roleStub['FailNextRoleRead'] = $false
                            $reply = [pscustomobject]@{ StatusCode = 500; Content = '' }
                        }
                        else { $reply = Invoke-RoleApiStub -Method $request[0] -Path $request[1] }
                        if ($roleStub['DropNext'] -ceq $request[0]) {
                            $roleStub['DropNext'] = $null
                            $reply = [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption after applying the write."}' }
                        }
                        $body = [Text.Encoding]::UTF8.GetBytes($reply.Content)
                        $headers = [Text.Encoding]::ASCII.GetBytes("HTTP/1.1 $($reply.StatusCode) OK`r`nContent-Type: application/json`r`nContent-Length: $($body.Length)`r`nConnection: close`r`n`r`n")
                        $stream.Write($headers)
                        $stream.Write($body)
                        $stream.Flush()
                    }
                    finally { $client.Dispose() }
                }
            }
            finally { $socket.Stop() }
        }
    }

    AfterEach {
        $roleStub.Stop = $true
        $listener.Stop()
        $null = Wait-Job -Job $server -Timeout 10
        Receive-Job -Job $server
        Remove-Job -Job $server -Force
    }

    It 'returns a complete string map from the real stdin reader and documented HTTP responses' {
        $result = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)

        $result.ExitCode | Should -Be 0 -Because $result.Error
        $state = ConvertFrom-Json -InputObject $result.Output -AsHashtable
        $state.Count | Should -Be 3
        $state.role_id | Should -BeExactly '8030'
        $state.team_id | Should -BeExactly '1'
        $state.assigned | Should -BeExactly 'true'
        @($state.Values | Where-Object { $_ -isnot [string] }).Count | Should -Be 0
        $roleStub.Versions.Count | Should -Be 3
        foreach ($version in $roleStub.Versions) { $version | Should -BeExactly '2026-03-10' }
    }

    It 'assigns the bound role through the real change program without emitting a fake external result' {
        $roleStub.Assignments = @()
        $request = $query + @{ role_id = 8030; team_id = 1 }

        $result = Invoke-RoleProgram -Script $changeScript -InputJson ($request | ConvertTo-Json -Compress) -Action Assign

        $result.ExitCode | Should -Be 0 -Because $result.Error
        $result.Output | Should -BeNullOrEmpty
        $roleStub.Writes.ToArray() | Should -Be @('PUT')
        $read = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)
        $read.ExitCode | Should -Be 0 -Because $read.Error
        (ConvertFrom-Json -InputObject $read.Output -AsHashtable).assigned | Should -BeExactly 'true'
    }

    It 'reports an absent direct assignment as false' {
        $roleStub.Assignments = @()

        $result = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)

        $result.ExitCode | Should -Be 0 -Because $result.Error
        (ConvertFrom-Json -InputObject $result.Output -AsHashtable).assigned | Should -BeExactly 'false'
    }

    It 'removes the declared assignment through the real change program' {
        $request = $query + @{ role_id = 8030; team_id = 1 }

        $result = Invoke-RoleProgram -Script $changeScript -InputJson ($request | ConvertTo-Json -Compress) -Action Remove

        $result.ExitCode | Should -Be 0 -Because $result.Error
        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
        $read = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)
        (ConvertFrom-Json -InputObject $read.Output -AsHashtable).assigned | Should -BeExactly 'false'
    }

    It 'adopts a pre-existing assignment and removes it through the real change program' {
        $request = $query + @{ role_id = 8030; team_id = 1 }
        foreach ($action in @('Assign', 'Remove')) {
            $result = Invoke-RoleProgram -Script $changeScript -InputJson ($request | ConvertTo-Json -Compress) -Action $action
            $result.ExitCode | Should -Be 0 -Because $result.Error
        }

        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
        $read = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)
        (ConvertFrom-Json -InputObject $read.Output -AsHashtable).assigned | Should -BeExactly 'false'
    }

    It 'validates the pre-existing identity without changing an assignment' {
        $request = $query + @{ role_id = 8030; team_id = 1 }

        $result = Invoke-RoleProgram -Script $changeScript -InputJson ($request | ConvertTo-Json -Compress) -Action AssertIdentity

        $result.ExitCode | Should -Be 0 -Because $result.Error
        $result.Output | Should -BeNullOrEmpty
        $roleStub.Writes.Count | Should -Be 0
    }

    It 'validates identity when the declared assignment is absent' {
        $roleStub.Assignments = @()
        $request = $query + @{ role_id = 8030; team_id = 1 }

        $result = Invoke-RoleProgram -Script $changeScript -InputJson ($request | ConvertTo-Json -Compress) -Action AssertIdentity

        $result.ExitCode | Should -Be 0 -Because $result.Error
        $roleStub.Writes.Count | Should -Be 0
    }

    It 'rejects a non-object reader input: <Case>' -ForEach @(
        @{ Case = 'empty stdin'; Json = '' }
        @{ Case = 'whitespace'; Json = ' ' }
        @{ Case = 'null'; Json = 'null' }
        @{ Case = 'empty array'; Json = '[]' }
        @{ Case = 'number'; Json = '1' }
        @{ Case = 'string'; Json = '"query"' }
    ) {
        $result = Invoke-RoleProgram -Script $readerScript -InputJson $Json

        $result.ExitCode | Should -Be 1
        $result.Error | Should -BeLike '*input must be a JSON object*'
        $result.Output | Should -BeNullOrEmpty
        $roleStub.Versions.Count | Should -Be 0
    }

    It 'rejects a single-element array instead of unwrapping it as a query' {
        $result = Invoke-RoleProgram -Script $readerScript -InputJson (ConvertTo-Json -InputObject @($query) -Compress)

        $result.ExitCode | Should -Be 1
        $result.Error | Should -BeLike '*input must be a JSON object*'
        $roleStub.Versions.Count | Should -Be 0
    }

    It 'rejects an invalid reader field <Field>: <Case>' -ForEach @(
        @{ Field = 'api_url'; Case = 'number'; Value = 1 }
        @{ Field = 'api_url'; Case = 'whitespace'; Value = ' ' }
        @{ Field = 'api_url'; Case = 'missing'; Value = $null }
        @{ Field = 'organization'; Case = 'number'; Value = 1 }
        @{ Field = 'organization'; Case = 'whitespace'; Value = ' ' }
        @{ Field = 'organization'; Case = 'missing'; Value = $null }
        @{ Field = 'team'; Case = 'number'; Value = 1 }
        @{ Field = 'team'; Case = 'whitespace'; Value = ' ' }
        @{ Field = 'team'; Case = 'missing'; Value = $null }
    ) {
        if ($Case -ceq 'missing') { $query.Remove($Field) } else { $query[$Field] = $Value }

        $result = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)

        $result.ExitCode | Should -Be 1
        $result.Error | Should -BeLike "*input field '$Field' must be a nonempty string*"
        $roleStub.Versions.Count | Should -Be 0
    }

    It 'rejects an invalid persisted ID <Field>: <Case>' -ForEach @(
        @{ Field = 'role_id'; Case = 'zero'; Value = 0 }
        @{ Field = 'role_id'; Case = 'string'; Value = '8030' }
        @{ Field = 'role_id'; Case = 'missing'; Value = $null }
        @{ Field = 'team_id'; Case = 'zero'; Value = 0 }
        @{ Field = 'team_id'; Case = 'string'; Value = '1' }
        @{ Field = 'team_id'; Case = 'missing'; Value = $null }
    ) {
        $request = $query + @{ role_id = 8030; team_id = 1 }
        if ($Case -ceq 'missing') { $request.Remove($Field) } else { $request[$Field] = $Value }

        $result = Invoke-RoleProgram -Script $changeScript -InputJson ($request | ConvertTo-Json -Compress) -Action AssertIdentity

        $result.ExitCode | Should -Be 1
        $result.Error | Should -BeLike "*input field '$Field' must be a valid numeric ID*"
        $roleStub.Versions.Count | Should -Be 0
    }

    It 'rejects an unknown or differently cased action: <Action>' -ForEach @(
        @{ Action = 'assign' }
        @{ Action = 'DeleteAll' }
    ) {
        $request = $query + @{ role_id = 8030; team_id = 1 }

        $result = Invoke-RoleProgram -Script $changeScript -InputJson ($request | ConvertTo-Json -Compress) -Action $Action

        $result.ExitCode | Should -Not -Be 0
        $roleStub.Versions.Count | Should -Be 0
        $roleStub.Writes.Count | Should -Be 0
    }

    Context 'Offline Terraform lifecycle' -Tag Terraform {
        BeforeAll {
            $moduleRoot = Split-Path (Split-Path $readerScript -Parent) -Parent
            function Invoke-RoleTerraform {
                $command = $args[0]
                $arguments = @($args | Select-Object -Skip 1)
                $output = & terraform "-chdir=$root" $command -no-color @arguments 2>&1 | Out-String
                $code = $LASTEXITCODE
                $global:LASTEXITCODE = 0
                @{ ExitCode = $code; Output = $output }
            }
        }

        BeforeEach {
            $oldRoleToken = $env:REST_API_BEARER
            $oldRoleCache = $env:TF_PLUGIN_CACHE_DIR
            $env:REST_API_BEARER = 'test-role-terraform-token'
            $env:TF_PLUGIN_CACHE_DIR = Join-Path $TestDrive 'role-provider-cache'
            New-Item -ItemType Directory -Path $env:TF_PLUGIN_CACHE_DIR -Force | Out-Null
            $parent = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            $root = Join-Path $parent 'organization-roles'
            New-Item -ItemType Directory -Path $root | Out-Null
            Copy-Item -Path (Join-Path $moduleRoot '*.tf'), (Join-Path $moduleRoot '.terraform.lock.hcl') -Destination $root
            Copy-Item -LiteralPath (Join-Path $moduleRoot 'scripts') -Destination $root -Recurse
            $organizations = Join-Path $parent 'organizations'
            New-Item -ItemType Directory -Path $organizations | Out-Null
            Copy-Item -LiteralPath (Join-Path $moduleRoot '..\organizations\scripts') -Destination $organizations -Recurse
            Set-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @"
terraform {
  backend "local" {}
}
locals { api_url = "$apiUrl" }
"@
            Set-Content -LiteralPath (Join-Path $root 'terraform.tfvars.json') -Value @'
{"instance":{"name":"demo","github":{"host":"example.ghe.com"},"organizations":{"platform":"demo-platform","actions":"demo-actions","workloads":"demo-workloads"}},"prerequisites":{},"target_organizations":["demo-actions"]}
'@
            $roleStub.TerraformStateFile = Join-Path $root 'terraform.tfstate'
            $roleStub.BeforePutSnapshots = [Collections.Generic.List[string]]::new()
            $roleStub.BeforeDeleteSnapshots = [Collections.Generic.List[string]]::new()
            $init = Invoke-RoleTerraform init -input=false
            $init.ExitCode | Should -Be 0 -Because $init.Output
        }

        AfterEach {
            $env:REST_API_BEARER = $oldRoleToken
            $env:TF_PLUGIN_CACHE_DIR = $oldRoleCache
        }

        It 'adopts and removes a pre-existing assignment across real apply and destroy' {
            $apply = Invoke-RoleTerraform apply -input=false -auto-approve
            $apply.ExitCode | Should -Be 0 -Because $apply.Output
            $outputs = Invoke-RoleTerraform output -json
            (ConvertFrom-Json -InputObject $outputs.Output -AsHashtable).security_manager.value.assigned | Should -BeTrue

            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve
            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output

            $roleStub.Writes.ToArray() | Should -Be @('DELETE')
            $read = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)
            $read.ExitCode | Should -Be 0 -Because $read.Error
            (ConvertFrom-Json -InputObject $read.Output -AsHashtable).assigned | Should -BeExactly 'false'
        }

        It 'publishes complete known outputs from the first saved plan' -Tag RoleOutputs {
            $roleStub.Assignments = @()
            $plan = Invoke-RoleTerraform plan -input=false '-out=role.plan'
            $plan.ExitCode | Should -Be 0 -Because $plan.Output
            $show = Invoke-RoleTerraform show -json role.plan
            $show.ExitCode | Should -Be 0 -Because $show.Output
            $outputs = (ConvertFrom-Json -InputObject $show.Output -AsHashtable).planned_values.outputs

            $outputs.organization.value | Should -BeExactly 'demo-actions'
            $outputs.security_manager.Keys | Should -Contain 'value'
            $assignment = $outputs.security_manager.value
            $assignment.team | Should -BeExactly 'security'
            $assignment.role_id | Should -Be 8030
            $assignment.team_id | Should -Be 1
            $assignment.assigned | Should -BeTrue
            $roleStub.Writes.Count | Should -Be 0
        }

        It 'applies a missing assignment and retains it across refresh and destroy' {
            $roleStub.Assignments = @()

            $apply = Invoke-RoleTerraform apply -input=false -auto-approve
            $apply.ExitCode | Should -Be 0 -Because $apply.Output

            $plan = Invoke-RoleTerraform plan -input=false -detailed-exitcode
            $plan.ExitCode | Should -Be 0 -Because $plan.Output
            $outputs = Invoke-RoleTerraform output -json
            (ConvertFrom-Json -InputObject $outputs.Output -AsHashtable).security_manager.value.assigned | Should -BeTrue

            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve
            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.ToArray() | Should -Be @('PUT', 'DELETE')
            $read = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)
            (ConvertFrom-Json -InputObject $read.Output -AsHashtable).assigned | Should -BeExactly 'false'
        }

        It 'adopts a role after a lost PUT with no persisted remote state and preserves other teams on destroy' -Tag RoleRemote {
            $roleStub.Assignments = @()
            $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                '0.id' = 2; '0.slug' = 'other'
            }
            $roleStub.RemoteTerraformState = ''
            $roleStub.UseRemoteTerraformState = $true
            $roleStub.CaptureBeforePut = $true
            $roleStub.DropNext = 'PUT'
            Set-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @"
terraform {
  backend "http" {
    address = "$apiUrl/terraform-state"
  }
}
locals { api_url = "$apiUrl" }
"@
            $init = Invoke-RoleTerraform init -input=false -reconfigure
            $init.ExitCode | Should -Be 0 -Because $init.Output

            $oldPersistInterval = $env:TF_STATE_PERSIST_INTERVAL
            try {
                # Disable intermediate remote checkpoints to exercise the worst-case abrupt interruption.
                $env:TF_STATE_PERSIST_INTERVAL = '0'
                $interrupted = Invoke-RoleTerraform apply -input=false -auto-approve
                $interrupted.ExitCode | Should -Be 1 -Because $interrupted.Output
                $roleStub.BeforePutSnapshots.Count | Should -Be 1
                $roleStub.BeforePutSnapshots[0] | Should -BeNullOrEmpty
                $roleStub.Writes.ToArray() | Should -Be @('PUT')
                $roleStub.Assignments.Count | Should -Be 2
                # Discard Terraform's error/finally checkpoint, retaining the remote role write.
                $roleStub.RemoteTerraformState = $roleStub.BeforePutSnapshots[0]
                $roleStub.CaptureBeforePut = $false

                $emptyDestroy = Invoke-RoleTerraform destroy -input=false -auto-approve
                $emptyDestroy.ExitCode | Should -Be 0 -Because $emptyDestroy.Output
                $roleStub.Writes.ToArray() | Should -Be @('PUT')
                $roleStub.Assignments.Count | Should -Be 2

                $resumed = Invoke-RoleTerraform apply -input=false -auto-approve
                $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
                $roleStub.Writes.ToArray() | Should -Be @('PUT')
                $plan = Invoke-RoleTerraform plan -input=false -detailed-exitcode
                $plan.ExitCode | Should -Be 0 -Because $plan.Output

                $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve
                $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
                $roleStub.Writes.ToArray() | Should -Be @('PUT', 'DELETE')
                $roleStub.Assignments.Count | Should -Be 1
                $roleStub.Assignments[0].slug | Should -BeExactly 'other'
            }
            finally { $env:TF_STATE_PERSIST_INTERVAL = $oldPersistInterval }
        }

        It 'recovers a <Fault> PUT after <Termination> interruption without repeating the write' -ForEach @(
            @{ Fault = 'BeforeApply'; Termination = 'Error' }
            @{ Fault = 'BeforeApply'; Termination = 'Abrupt' }
            @{ Fault = 'LoseResponse'; Termination = 'Error' }
            @{ Fault = 'LoseResponse'; Termination = 'Abrupt' }
        ) {
            $roleStub.Assignments = @()
            if ($Fault -ceq 'BeforeApply') { $roleStub.RejectNext = 'PUT' } else { $roleStub.DropNext = 'PUT' }
            $roleStub.CaptureBeforePut = $true

            $interrupted = Invoke-RoleTerraform apply -input=false -auto-approve -lock=false
            $interrupted.ExitCode | Should -Be 1 -Because $interrupted.Output
            $roleStub.BeforePutSnapshots.Count | Should -Be 1
            if ($Termination -ceq 'Abrupt') {
                # Match the interruption harness: discard local catch/finally writes, retain the applied remote write.
                Set-Content -LiteralPath $roleStub.TerraformStateFile -Value $roleStub.BeforePutSnapshots[0] -NoNewline
            }
            $roleStub.CaptureBeforePut = $false

            $resumed = Invoke-RoleTerraform apply -input=false -auto-approve
            $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
            $outputs = Invoke-RoleTerraform output -json
            (ConvertFrom-Json -InputObject $outputs.Output -AsHashtable).security_manager.value.assigned | Should -BeTrue
            $roleStub.Writes.ToArray() | Should -Be @('PUT')

            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve
            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.ToArray() | Should -Be @('PUT', 'DELETE')
        }

        It 'recovers a <Fault> DELETE after <Termination> interruption' -Tag RoleDelete -ForEach @(
            @{ Fault = 'BeforeApply'; Termination = 'Error' }
            @{ Fault = 'BeforeApply'; Termination = 'Abrupt' }
            @{ Fault = 'LoseResponse'; Termination = 'Error' }
            @{ Fault = 'LoseResponse'; Termination = 'Abrupt' }
        ) {
            $roleStub.Assignments = @()
            $apply = Invoke-RoleTerraform apply -input=false -auto-approve
            $apply.ExitCode | Should -Be 0 -Because $apply.Output
            if ($Fault -ceq 'BeforeApply') { $roleStub.RejectNext = 'DELETE' } else { $roleStub.DropNext = 'DELETE' }
            $roleStub.CaptureBeforeDelete = $true

            $interrupted = Invoke-RoleTerraform destroy -input=false -auto-approve -lock=false
            $interrupted.ExitCode | Should -Be 1 -Because $interrupted.Output
            $roleStub.BeforeDeleteSnapshots.Count | Should -Be 1
            if ($Termination -ceq 'Abrupt') {
                Set-Content -LiteralPath $roleStub.TerraformStateFile -Value $roleStub.BeforeDeleteSnapshots[0] -NoNewline
            }
            $roleStub.CaptureBeforeDelete = $false

            $resumed = Invoke-RoleTerraform destroy -input=false -auto-approve
            $resumed.ExitCode | Should -Be 0 -Because $resumed.Output
            $roleStub.Writes.ToArray() | Should -Be @('PUT', 'DELETE')
            $read = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)
            (ConvertFrom-Json -InputObject $read.Output -AsHashtable).assigned | Should -BeExactly 'false'
        }

        It 'keeps the assignment when only the configured team slug case changes' -Tag RoleCase {
            $roleStub.Assignments = @()
            $apply = Invoke-RoleTerraform apply -input=false -auto-approve
            $apply.ExitCode | Should -Be 0 -Because $apply.Output
            $variablesPath = Join-Path $root 'terraform.tfvars.json'
            $variables = Get-Content -LiteralPath $variablesPath -Raw | ConvertFrom-Json -AsHashtable
            $variables.security_team = 'SECURITY'
            ConvertTo-Json $variables -Depth 10 | Set-Content -LiteralPath $variablesPath

            $changed = Invoke-RoleTerraform apply -input=false -auto-approve
            $changed.ExitCode | Should -Be 0 -Because $changed.Output
            $outputs = Invoke-RoleTerraform output -json
            (ConvertFrom-Json -InputObject $outputs.Output -AsHashtable).security_manager.value.assigned | Should -BeTrue
            $roleStub.Writes.ToArray() | Should -Be @('PUT')
            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve
            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.ToArray() | Should -Be @('PUT', 'DELETE')
        }

        It 'removes the declared assignment even when its creation resource is tainted' -Tag RoleState {
            $roleStub.Assignments = @()
            $roleStub.DropNext = 'PUT'
            $interrupted = Invoke-RoleTerraform apply -input=false -auto-approve
            $interrupted.ExitCode | Should -Be 1 -Because $interrupted.Output

            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve

            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.ToArray() | Should -Be @('PUT', 'DELETE')
            $read = Invoke-RoleProgram -Script $readerScript -InputJson ($query | ConvertTo-Json -Compress)
            (ConvertFrom-Json -InputObject $read.Output -AsHashtable).assigned | Should -BeExactly 'false'
        }

        It 'removes a pre-existing role after the apply-time identity read fails' -Tag RoleGuardTaint {
            $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                '0.id' = 2; '0.slug' = 'other'
            }
            $plan = Invoke-RoleTerraform plan -input=false '-out=identity.plan'
            $plan.ExitCode | Should -Be 0 -Because $plan.Output
            $roleStub.FailNextRoleRead = $true

            $interrupted = Invoke-RoleTerraform apply -input=false -auto-approve identity.plan

            $interrupted.ExitCode | Should -Be 1 -Because $interrupted.Output
            $interrupted.Output | Should -Match 'HTTP 500'
            $roleStub.Writes.Count | Should -Be 0
            $state = Invoke-RoleTerraform show -json
            $state.ExitCode | Should -Be 0 -Because $state.Output
            $addresses = (ConvertFrom-Json -InputObject $state.Output -AsHashtable).values.root_module.resources |
                ForEach-Object { $_['address'] }
            @($addresses) | Should -Contain 'terraform_data.role_guard'

            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve

            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.ToArray() | Should -Be @('DELETE')
            @($roleStub.Assignments.id) | Should -Be @(2)
        }

        It 'detects removal of a <Origin> assignment during a real plan' -Tag RoleState -ForEach @(
            @{ Origin = 'new'; Existing = $false }
            @{ Origin = 'pre-existing'; Existing = $true }
        ) {
            if (-not $Existing) { $roleStub.Assignments = @() }
            $apply = Invoke-RoleTerraform apply -input=false -auto-approve
            $apply.ExitCode | Should -Be 0 -Because $apply.Output
            $outputs = Invoke-RoleTerraform output -json
            (ConvertFrom-Json -InputObject $outputs.Output -AsHashtable).security_manager.value.assigned | Should -BeTrue
            $roleStub.Assignments = @()

            $plan = Invoke-RoleTerraform plan -input=false -detailed-exitcode

            $plan.ExitCode | Should -Be 1
            $plan.Output | Should -Match 'no direct security_manager role\s+assignment'
        }

        It 'repairs detected role removal only after explicit assignment replacement' -Tag RoleRepair {
            $variableFile = Join-Path $parent 'inputs.tfvars.json'
            Move-Item -LiteralPath (Join-Path $root 'terraform.tfvars.json') -Destination $variableFile
            $roleStub.Assignments = @()
            $apply = Invoke-RoleTerraform apply -input=false -auto-approve "-var-file=$variableFile"
            $apply.ExitCode | Should -Be 0 -Because $apply.Output
            $roleStub.Assignments = @()

            $plan = Invoke-RoleTerraform plan -input=false -detailed-exitcode "-var-file=$variableFile"
            $plan.ExitCode | Should -Be 1
            $plan.Output | Should -Match 'no direct security_manager role\s+assignment'
            $ordinaryApply = Invoke-RoleTerraform apply -input=false -auto-approve "-var-file=$variableFile"
            $ordinaryApply.ExitCode | Should -Be 1
            $ordinaryApply.Output | Should -Match 'no direct security_manager role\s+assignment'
            $roleStub.Writes.ToArray() | Should -Be @('PUT')

            $repair = Invoke-RoleTerraform apply -input=false -auto-approve "-var-file=$variableFile" '-replace=terraform_data.assignment'

            $repair.ExitCode | Should -Be 0 -Because $repair.Output
            $roleStub.Writes.ToArray() | Should -Be @('PUT', 'PUT')
            $subsequentPlan = Invoke-RoleTerraform plan -input=false -detailed-exitcode "-var-file=$variableFile"
            $subsequentPlan.ExitCode | Should -Be 0 -Because $subsequentPlan.Output
            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve "-var-file=$variableFile"
            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.ToArray() | Should -Be @('PUT', 'PUT', 'DELETE')
        }

        It 'adopts a role appearing after a saved plan and removes it during destroy' -Tag RoleState {
            $roleStub.Assignments = @()
            $plan = Invoke-RoleTerraform plan -input=false '-out=role.plan'
            $plan.ExitCode | Should -Be 0 -Because $plan.Output
            $roleStub.Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{ '0.slug' = 'security' }

            $stale = Invoke-RoleTerraform apply -input=false -auto-approve role.plan

            $stale.ExitCode | Should -Be 0 -Because $stale.Output
            $roleStub.Writes.Count | Should -Be 0
            $fresh = Invoke-RoleTerraform apply -input=false -auto-approve
            $fresh.ExitCode | Should -Be 0 -Because $fresh.Output
            $outputs = Invoke-RoleTerraform output -json
            (ConvertFrom-Json -InputObject $outputs.Output -AsHashtable).security_manager.value.assigned | Should -BeTrue
            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve
            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.ToArray() | Should -Be @('DELETE')
        }

        It 'rejects plan but completes destroy after the security team is deleted' -Tag RoleTeamMissing {
            $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                '0.id' = 2; '0.slug' = 'other'
            }
            $apply = Invoke-RoleTerraform apply -input=false -auto-approve
            $apply.ExitCode | Should -Be 0 -Because $apply.Output
            $roleStub.TeamMissing = $true
            $roleStub.Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                '0.id' = 2; '0.slug' = 'other'
            }
            $plan = Invoke-RoleTerraform plan -input=false -detailed-exitcode
            $plan.ExitCode | Should -Be 1
            $plan.Output | Should -Match 'The organization security team does not exist'
            $missingApply = Invoke-RoleTerraform apply -input=false -auto-approve
            $missingApply.ExitCode | Should -Be 1
            $roleStub.Writes.Count | Should -Be 0

            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve

            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.Count | Should -Be 0
            @($roleStub.Assignments.id) | Should -Be @(2)
        }

        It 'destroys only the saved identity after the security team is recreated' -Tag RoleTeamIdentity {
            $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                '0.id' = 2; '0.slug' = 'other'
            }
            $apply = Invoke-RoleTerraform apply -input=false -auto-approve
            $apply.ExitCode | Should -Be 0 -Because $apply.Output
            $roleStub.Team.id = 99
            $roleStub.Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{
                '0.id' = 99; '0.slug' = 'security'
            }
            $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                '0.id' = 2; '0.slug' = 'other'
            }

            $destroy = Invoke-RoleTerraform destroy -input=false -auto-approve

            $destroy.ExitCode | Should -Be 0 -Because $destroy.Output
            $roleStub.Writes.Count | Should -Be 0
            @($roleStub.Assignments.id) | Should -Be @(99, 2)
        }

        It 'rejects a changed team ID after a saved plan before any role write' -Tag RoleState {
            $roleStub.Assignments = @()
            $plan = Invoke-RoleTerraform plan -input=false '-out=role.plan'
            $plan.ExitCode | Should -Be 0 -Because $plan.Output
            $roleStub.Team.id = 99

            $changed = Invoke-RoleTerraform apply -input=false -auto-approve role.plan

            $changed.ExitCode | Should -Be 1
            $changed.Output | Should -Match 'security team identity\s+changed'
            $roleStub.Writes.Count | Should -Be 0
        }
    }
}
