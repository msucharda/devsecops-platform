BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-Module.ps1'
    $nativeTerraform = (Get-Command terraform -CommandType Application).Source
}

Describe 'Organization-scoped module execution' {
    BeforeEach {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $modules = Join-Path $directory 'modules'
        $null = New-Item -ItemType Directory -Path $modules -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/organization-module') -Destination (Join-Path $modules 'scoped') -Recurse
        $organizations = @('demo-platform', 'demo-actions', 'demo-workloads')
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ scoped = @{ parameters = @{ target_organizations = $organizations } } }
        $instance.githubApps = @{
            reader = @{ appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ organization_administration = 'read' }; resources = @{ organizations = $organizations } }
            writer = @{ appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ organization_administration = 'write' }; resources = @{ organizations = $organizations } }
        }
        $instance.credentials = @{
            scoped = @{
                plan = @{ environment = 'scoped-plan'; githubApp = 'reader' }
                apply = @{ environment = 'scoped-apply'; githubApp = 'writer' }
            }
        }
        $instancePath = Join-Path $directory 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $arguments = @{
            Module = 'scoped'
            ModulesPath = $modules
            InstancePath = $instancePath
            PlatformOrganization = 'demo-platform'
            Backend = 'local'
            StatePath = (Join-Path $directory 'state')
            ArtifactsPath = (Join-Path $directory 'outputs')
            JobSummaryPath = (Join-Path $directory 'summary.md')
        }
        $previousTokens = $env:PLATFORM_GITHUB_TOKENS
        $previousToken = $env:GITHUB_TOKEN
        $previousTfTokens = $env:TF_VAR_github_tokens
        $previousGhToken = $env:GH_TOKEN
        $previousBearer = $env:REST_API_BEARER
        $env:PLATFORM_GITHUB_TOKENS = '{"demo-platform":"platform-token","demo-actions":"actions-token","demo-workloads":"workloads-token"}'
        $env:GITHUB_TOKEN = 'unrelated-token'
        $env:REST_API_BEARER = 'outer-bearer'
    }

    AfterEach {
        $env:PLATFORM_GITHUB_TOKENS = $previousTokens
        $env:GITHUB_TOKEN = $previousToken
        $env:TF_VAR_github_tokens = $previousTfTokens
        $env:GH_TOKEN = $previousGhToken
        $env:REST_API_BEARER = $previousBearer
    }

    It 'removes a stale aggregate prerequisite before an unreadable instance can fail the run' {
        $null = New-Item -ItemType Directory -Path $arguments.ArtifactsPath -Force
        $stale = Join-Path $arguments.ArtifactsPath 'scoped.json'
        Set-Content -LiteralPath $stale -Value '{"organizations":["demo-platform","demo-actions","demo-workloads"]}'
        # Deliberately invalid instance input must not preserve a successful artifact from an earlier run.
        Set-Content -LiteralPath $instancePath -Value 'instance: ['

        { & $runner -Action plan @arguments 6>$null } | Should -Throw

        Test-Path -LiteralPath $stale | Should -BeFalse
    }

    It 'applies every organization in its own state and publishes the complete prerequisite output' {
        $result = & $runner -Action apply @arguments 6>$null

        $output = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json -AsHashtable
        $output.organizations | Should -Be @('demo-platform', 'demo-actions', 'demo-workloads')
        foreach ($organization in $organizations) {
            $state = Join-Path $arguments.StatePath "scoped/organizations/$organization/terraform.tfstate"
            Test-Path -LiteralPath $state | Should -BeTrue
            $output.organization_outputs[$organization].organizations | Should -Be @($organization)
            $output.organization_outputs[$organization].identity | Should -Not -BeNullOrEmpty
        }
        @($output.organization_outputs.PSBase.Values.identity | Sort-Object -Unique).Count | Should -Be 3
        $result.OrganizationResults.Count | Should -Be 3
        $env:GITHUB_TOKEN | Should -BeExactly 'unrelated-token'
        $env:REST_API_BEARER | Should -BeExactly 'outer-bearer'
    }

    It 'selects only the requested organization token even for a direct organization invocation' {
        $observations = [Collections.Generic.List[object]]::new()
        function terraform {
            $observations.Add(@{
                Bearer = $env:REST_API_BEARER
                Tokens = ConvertFrom-Json -InputObject $env:PLATFORM_GITHUB_TOKENS -AsHashtable
                TerraformTokens = ConvertFrom-Json -InputObject $env:TF_VAR_github_tokens -AsHashtable
                GitHubToken = $env:GITHUB_TOKEN
                GhToken = $env:GH_TOKEN
            })
            & $nativeTerraform @args
            $global:LASTEXITCODE = $LASTEXITCODE
        }
        $env:PLATFORM_GITHUB_TOKENS = '{"demo-actions":"actions-token"}'
        try {
            $null = & $runner -Action apply -Organization demo-actions @arguments 6>$null

            $observations.Count | Should -BeGreaterThan 0
            foreach ($observed in $observations) {
                $observed.Bearer | Should -BeExactly 'actions-token'
                $observed.GitHubToken | Should -BeExactly 'actions-token'
                $observed.GhToken | Should -BeExactly 'actions-token'
                @($observed.Tokens.Keys) | Should -Be @('demo-actions')
                @($observed.TerraformTokens.Keys) | Should -Be @('demo-actions')
            }
            $env:GITHUB_TOKEN | Should -BeExactly 'unrelated-token'
            $env:REST_API_BEARER | Should -BeExactly 'outer-bearer'
        }
        finally { Remove-Item -LiteralPath Function:\terraform }
    }

    It 'passes only the organization-local parameter value to each root' {
        $manifestPath = Join-Path $modules 'scoped/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.organizationParameters = @('reviewers')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $instance.modules.scoped.parameters.reviewers = @{ 'demo-platform' = @(11); 'demo-actions' = @(22); 'demo-workloads' = @(33) }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $runner -Action apply @arguments 6>$null

        $output = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json -AsHashtable
        $output.organization_outputs['demo-platform'].reviewers | Should -Be @(11)
        $output.organization_outputs['demo-actions'].reviewers | Should -Be @(22)
        $output.organization_outputs['demo-workloads'].reviewers | Should -Be @(33)
    }

    It 'resumes the first organization state after the second organization fails without publishing a partial prerequisite' {
        $interrupt = $true
        function terraform {
            if ($interrupt -and $env:GITHUB_TOKEN -ceq 'actions-token' -and $args -contains 'plan') {
                $global:LASTEXITCODE = 1
                return 'Injected failure of the second organization.'
            }
            & $nativeTerraform @args
            $global:LASTEXITCODE = $LASTEXITCODE
        }
        try {
            { & $runner -Action apply @arguments 6>$null } | Should -Throw '*Injected failure of the second organization*'
            Test-Path -LiteralPath (Join-Path $arguments.ArtifactsPath 'scoped.json') | Should -BeFalse
            $first = Get-Content -LiteralPath (Join-Path $arguments.ArtifactsPath 'organizations/demo-platform/scoped.json') -Raw |
                ConvertFrom-Json
            Test-Path -LiteralPath (Join-Path $arguments.StatePath 'scoped/organizations/demo-workloads/terraform.tfstate') |
                Should -BeFalse
            $interrupt = $false

            $result = & $runner -Action apply @arguments 6>$null

            $output = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json -AsHashtable
            $output.organization_outputs['demo-platform'].identity | Should -BeExactly $first.identity
            $output.organizations | Should -Be $organizations
        }
        finally { Remove-Item -LiteralPath Function:\terraform }
    }

    It 'reads every state without credentials and repeats a completed teardown without tokens' {
        $null = & $runner -Action apply @arguments 6>$null
        $env:PLATFORM_GITHUB_TOKENS = $null
        $state = & $runner -Action state @arguments 6>$null
        $state.Empty | Should -BeFalse
        $state.OrganizationResults.Count | Should -Be 3
        $instance.teardown = @{ allowed = $true }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $env:PLATFORM_GITHUB_TOKENS = '{"demo-platform":"platform-token","demo-actions":"actions-token","demo-workloads":"workloads-token"}'
        $null = & $runner -Action destroy @arguments 6>$null
        $env:PLATFORM_GITHUB_TOKENS = $null

        $repeated = & $runner -Action destroy @arguments 6>$null
        $state = & $runner -Action state @arguments 6>$null

        $repeated.HasChanges | Should -BeFalse
        $state.Empty | Should -BeTrue
    }
}
