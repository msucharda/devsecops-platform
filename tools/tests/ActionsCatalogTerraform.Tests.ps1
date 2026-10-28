BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $moduleRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/actions-catalog'
    $organization = 'demo-actions'
    $repository = "$organization/actions-checkout"
    $expectedViolation = "Repository '$repository' does not use the default branch main."
    $sha = '11bd71901bbe5b1630ceea73d27597364c9af683'
    $repositoryBody = Get-GitHubApiFixture -Name repos/get -Set @{
        name = 'actions-checkout'; full_name = $repository; 'owner.login' = $organization
        visibility = 'internal'; private = $true; archived = $false; fork = $false; default_branch = 'main'
    }
    $responses = @{
        "/repos/$repository" = $repositoryBody
        "/repos/$repository/actions/permissions/access" = Get-GitHubApiFixture -Name actions/get-workflow-access-to-repository -Set @{
            access_level = 'enterprise'
        }
        "/orgs/$organization/teams/actions-security" = Get-GitHubApiFixture -Name teams/get-by-name
        "/orgs/$organization/teams/actions-security/repos/$repository" = Get-GitHubApiFixture -Name teams/check-permissions-for-repo-in-org -Set @{
            'permissions.push' = $true
        }
        "/repos/$repository/git/ref/heads/main" = Get-GitHubApiFixture -Name git/get-ref -Set @{
            ref = 'refs/heads/main'; 'object.sha' = $sha
        }
        "/repos/$repository/contents/.github/CODEOWNERS?ref=$sha" = Get-GitHubApiFixture -Name repos/get-content.file -Set @{
            path = '.github/CODEOWNERS'
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes("* @$organization/actions-security`n"))
        }
        "/repos/$repository/rules/branches/main?per_page=100" = Get-GitHubApiFixture -Name repos/get-branch-rules.pull-request -Set @{
            '0.ruleset_source' = $organization
        }
    }
    $server = [hashtable]::Synchronized(@{
        Stop = $false; Responses = $responses
        Unexpected = [Collections.Concurrent.ConcurrentQueue[string]]::new()
    })
    $listener = [Net.Sockets.TcpListener]::new([Net.IPAddress]::Loopback, 0)
    $listener.Start()
    $apiUrl = "http://127.0.0.1:$($listener.LocalEndpoint.Port)"
    $job = Start-ThreadJob -ScriptBlock {
        $listener = $using:listener
        $server = $using:server
        while (-not $server.Stop) {
            if (-not $listener.Pending()) { Start-Sleep -Milliseconds 10; continue }
            $client = $listener.AcceptTcpClient()
            try {
                $stream = $client.GetStream()
                $stream.ReadTimeout = 5000
                $reader = [IO.StreamReader]::new($stream, [Text.UTF8Encoding]::new($false), $false, 1024, $true)
                $request = $reader.ReadLine()
                $headers = @{}
                while ($line = $reader.ReadLine()) {
                    if ($line -match '^(?<name>[^:]+):\s*(?<value>.*)$') { $headers[$Matches['name']] = $Matches['value'] }
                }
                $method, $path = $request.Split(' ')[0, 1]
                $status = 200
                if ($method -ceq 'GET' -and $path -ceq '/health') { $body = '{}' }
                elseif ($method -ceq 'GET' -and $server.Responses.ContainsKey($path) -and
                    $headers['X-GitHub-Api-Version'] -ceq '2026-03-10' -and $headers['Authorization'] -ceq 'Bearer stub-token') {
                    $body = ConvertTo-Json -InputObject $server.Responses[$path] -Depth 100 -Compress
                }
                else {
                    $server.Unexpected.Enqueue("$method $path")
                    $status = 500
                    $body = '{"message":"Unexpected offline test request."}'
                }
                $bytes = [Text.Encoding]::UTF8.GetBytes($body)
                $header = "HTTP/1.1 $status Stub`r`nContent-Type: application/json`r`nContent-Length: $($bytes.Length)`r`nConnection: close`r`n`r`n"
                $stream.Write([Text.Encoding]::ASCII.GetBytes($header))
                $stream.Write($bytes)
                $stream.Flush()
                $reader.Dispose()
            }
            finally { $client.Dispose() }
        }
    }
    (Invoke-WebRequest -Uri "$apiUrl/health" -TimeoutSec 10).StatusCode | Should -Be 200
    $previousBearer = $env:REST_API_BEARER
    $env:REST_API_BEARER = 'stub-token'
    $root = Join-Path $TestDrive 'catalog'
    $null = New-Item -ItemType Directory -Path $root
    Copy-Item -Path (Join-Path $moduleRoot '*.tf'), (Join-Path $moduleRoot '.terraform.lock.hcl') -Destination $root
    Copy-Item -LiteralPath (Join-Path $moduleRoot 'scripts') -Destination $root -Recurse
    $vendoring = Join-Path $root 'vendoring'
    $null = New-Item -ItemType Directory -Path $vendoring
    Set-Content -LiteralPath (Join-Path $vendoring 'actions.json') -Value '{"version":1,"actions":{}}'
    # Only the provisioner is replaced: the external reader and its postcondition remain production code.
    Set-Content -LiteralPath (Join-Path $root 'stub_override.tf') -Value @"
terraform {
  backend "local" {}
}
locals {
  api_url = "$apiUrl"
}
resource "terraform_data" "repository" {
  provisioner "local-exec" {
    command = "echo offline-existing-repository"
  }
}
"@
    Set-Content -LiteralPath (Join-Path $root 'terraform.tfvars.json') -Value (ConvertTo-Json -Depth 10 -InputObject @{
        instance = @{
            name = 'demo'; github = @{ host = 'example.ghe.com'; enterprise = 'example' }
            organizations = @{ platform = 'demo-platform'; actions = $organization; workloads = 'demo-workloads' }
        }
        prerequisites = @{ 'organization-rulesets' = @{ organizations = @($organization) } }
        target_organizations = @($organization); security_team = 'actions-security'; catalog = @('actions/checkout')
        vendoring_catalog_path = (Join-Path $vendoring 'actions.json')
    })
    function Invoke-CatalogTerraform {
        $text = & terraform "-chdir=$root" @args -no-color 2>&1 | Out-String
        @{ Code = $LASTEXITCODE; Text = $text }
    }
    $init = Invoke-CatalogTerraform init -input=false
    $init.Code | Should -Be 0 -Because $init.Text
    # Seed the resource so depends_on cannot defer the reader and postcondition until apply.
    $seed = Invoke-CatalogTerraform apply -input=false -auto-approve '-target=terraform_data.repository'
    $seed.Code | Should -Be 0 -Because $seed.Text
    $baseline = Invoke-CatalogTerraform apply -input=false -auto-approve
    $baseline.Code | Should -Be 0 -Because $baseline.Text
}

AfterAll {
    $env:REST_API_BEARER = $previousBearer
    $server.Stop = $true
    $job | Wait-Job -Timeout 10 | Out-Null
    $listener.Stop()
    $job | Receive-Job -ErrorAction Stop
    $job | Remove-Job -Force
}

Describe 'Actions catalog real reader and plan postcondition' -Tag Terraform {
    BeforeEach { $repositoryBody.default_branch = 'main' }
    AfterEach { $server.Unexpected.ToArray() | Should -BeNullOrEmpty }

    It 'returns only the main-branch violation for master through the external-program protocol' {
        $query = @{
            api_url = $apiUrl; organization = $organization; upstream = 'actions/checkout'
            security_team = 'actions-security'; tag = ''; commit = ''
        } | ConvertTo-Json -Compress
        $reader = Join-Path $root 'scripts/Read-CatalogState.ps1'
        foreach ($branch in @('main', 'master')) {
            $repositoryBody.default_branch = $branch
            $output = $query | & pwsh -NoProfile -NonInteractive -File $reader 2>&1 | Out-String
            $LASTEXITCODE | Should -Be 0 -Because $output
            $result = ConvertFrom-Json $output -AsHashtable
            $result.state | Should -BeOfType ([string])
            $result.violations | Should -BeOfType ([string])
            (ConvertFrom-Json $result.state -AsHashtable).exists | Should -BeTrue
            $violations = @(ConvertFrom-Json $result.violations)
            if ($branch -ceq 'main') { $violations | Should -BeNullOrEmpty }
            else { $violations | Should -Be @($expectedViolation) }
        }
    }

    It 'stops an actual plan on the main-branch violation when master is the default branch' {
        $valid = Invoke-CatalogTerraform plan -input=false -detailed-exitcode
        $valid.Code | Should -Be 0 -Because $valid.Text
        $repositoryBody.default_branch = 'master'
        $plan = Invoke-CatalogTerraform plan -input=false -detailed-exitcode
        $plan.Code | Should -Be 1 -Because $plan.Text
        $plan.Text | Should -Match 'Resource postcondition failed'
        $plan.Text | Should -Match 'data\.external\.catalog_state'
        ($plan.Text -replace '\s+', ' ') | Should -Match ([regex]::Escape($expectedViolation))
    }
}
