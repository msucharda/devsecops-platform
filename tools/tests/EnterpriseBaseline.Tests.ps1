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
        $stubState = [hashtable]::Synchronized(@{ Organization = $null; DropNextPatch = $false; Requests = [Collections.Generic.List[string]]::new() })
        $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
        $listener.Start()
        $port = $listener.LocalEndpoint.Port
        # Serves GET and PATCH /orgs/demo; DropNextPatch applies a PATCH and closes the connection without a response.
        $stub = Start-ThreadJob -ScriptBlock {
            $listener = $using:listener
            $state = $using:stubState
            while ($true) {
                $client = $listener.AcceptTcpClient()
                try {
                    $stream = $client.GetStream()
                    $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
                    $requestLine = $reader.ReadLine()
                    $length = 0
                    while ($line = $reader.ReadLine()) {
                        if ($line -match '^Content-Length:\s*(\d+)$') { $length = [int] $Matches[1] }
                    }
                    $buffer = [char[]]::new($length)
                    $read = 0
                    while ($read -lt $length) { $read += $reader.Read($buffer, $read, $length - $read) }
                    $method, $path = $requestLine.Split(' ')[0, 1]
                    $state.Requests.Add("$method $path")
                    if ($path -cne '/orgs/demo' -or $method -notin @('GET', 'PATCH')) {
                        $status = '404 Not Found'
                        $body = '{"message":"Not Found"}'
                    }
                    else {
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
                    $header = "HTTP/1.1 $status`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
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

        function Invoke-StubTerraform {
            $output = & terraform "-chdir=$root" @args -no-color 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
        }
    }

    AfterAll {
        $listener.Stop()
        $stub | Stop-Job -PassThru | Remove-Job -Force
    }

    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        New-Item -ItemType Directory -Path $root | Out-Null
        Copy-Item -Path (Join-Path $moduleRoot '*.tf'), (Join-Path $moduleRoot '.terraform.lock.hcl') -Destination $root
        Set-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @"
terraform {
  backend "local" {}
}

provider "restapi" {
  uri = "http://127.0.0.1:$port"
}
"@
        Set-Content -LiteralPath (Join-Path $root 'terraform.tfvars.json') -Value (ConvertTo-Json -Depth 10 -InputObject @{
            instance = @{ name = 'demo'; github = @{ host = 'example.ghe.com'; enterprise = 'example' } }
            target_organizations = @('demo')
            prerequisites = @{}
        })
        $stubState.Organization = Get-GitHubApiFixture -Name orgs/get -Set @{
            login = 'demo'
            members_can_change_repo_visibility = $false
            members_can_delete_repositories = $false
        }
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
}
