BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $moduleRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline'
    Import-Module (Join-Path $moduleRoot 'scripts/CodeSecurity.psm1') -Force
}

Describe 'Repository Code Security coverage' {
    BeforeEach {
        $previousBearer = $env:REST_API_BEARER
        $env:REST_API_BEARER = 'stub-token'
        Mock -ModuleName CodeSecurity Start-Sleep {}
        $inventory = Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{
            total_count = 1; 'repositories.0.id' = 101; 'repositories.0.full_name' = 'demo/app'; 'repositories.0.owner.login' = 'demo'
        }
        $inventory['repositories'] = @($inventory['repositories'][0])
        $configuration = Get-GitHubApiFixture -Name code-security/get-configuration -Set @{
            id = 42; name = 'platform-baseline'; advanced_security = 'enabled'; code_scanning_default_setup = 'enabled'
        }
        $attachments = Get-GitHubApiFixture -Name code-security/get-repositories-for-configuration -Set @{
            '0.status' = 'attached'; '0.repository.id' = 101; '0.repository.full_name' = 'demo/app'
        }
        $attachments = @($attachments[0])
        $repository = Get-GitHubApiFixture -Name repos/get -Set @{
            id = 101; full_name = 'demo/app'; 'security_and_analysis.advanced_security.status' = 'enabled'
        }
        $repository['security_and_analysis'].Remove('code_security')
        $repositoryStatus = 200
        Mock -ModuleName CodeSecurity Invoke-WebRequest {
            $path = ([Uri] $Uri).PathAndQuery
            $status = 200
            $value = switch -Exact ($path) {
                '/installation/repositories?per_page=100' { $inventory }
                '/orgs/demo/code-security/configurations?target_type=all&per_page=100' { , @($configuration) }
                '/orgs/demo/code-security/configurations/42/repositories?status=all&per_page=100' { , $attachments }
                '/repos/demo/app' { $status = $repositoryStatus; $repository }
                default { throw "Unexpected test API path '$path'." }
            }
            [pscustomobject]@{
                StatusCode = $status
                Content = ConvertTo-Json -InputObject $value -Depth 100 -Compress
                Headers = @{}
            }
        }
    }

    AfterEach { $env:REST_API_BEARER = $previousBearer }

    It 'reports compliant only with successful coverage and readable enabled repository security' {
        $result = Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo

        $result.repositories.Count | Should -Be 1
        $result.repositories[0].repository | Should -BeExactly 'demo/app'
        $result.repositories[0].status | Should -BeExactly 'compliant'
        $result.compliant | Should -Be 1
        $result.drift | Should -Be 0
        $result.unverified | Should -Be 0
    }

    It 'accepts successful attachment <Status> with <Product> configuration security' -ForEach @(
        foreach ($status in @('attached', 'enforced', 'enterprise_enforced')) {
            foreach ($product in @('enabled', 'code_security')) { @{ Status = $status; Product = $product } }
        }

    ) {
        $attachments[0]['status'] = $Status
        $configuration['advanced_security'] = $Product
        (Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo).repositories[0].status |
            Should -BeExactly 'compliant'
    }

    It 'reads the dedicated Code Security product when available' {
        $repository = Get-GitHubApiFixture -Name repos/get -Set @{
            id = 101; full_name = 'demo/app'; 'security_and_analysis.code_security.status' = 'enabled'
        }
        $repository['security_and_analysis'].Remove('advanced_security')
        (Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo).repositories[0].status |
            Should -BeExactly 'compliant'
    }

    It 'does not let legacy security override a disabled dedicated Code Security product' {
        $repository = Get-GitHubApiFixture -Name repos/get -Set @{
            id = 101; full_name = 'demo/app'; 'security_and_analysis.code_security.status' = 'disabled'
        }
        (Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo).repositories[0].status |
            Should -BeExactly 'drift'
    }

    It 'does not let legacy security hide an unreadable dedicated product status' {
        $repository = Get-GitHubApiFixture -Name repos/get -Set @{ id = 101; full_name = 'demo/app' }
        $repository['security_and_analysis']['code_security'].Remove('status')
        (Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo).repositories[0].status |
            Should -BeExactly 'unverified'
    }

    It 'rejects differently cased internal binding <Case>' -ForEach @(
        @{ Case = 'attachment status'; AttachmentStatus = 'Attached'; SecurityStatus = 'enabled'; Expected = 'drift' }
        @{ Case = 'security status'; AttachmentStatus = 'attached'; SecurityStatus = 'Enabled'; Expected = 'unverified' }
    ) {
        # Deliberately invalid enum in the internal binding built from the contract configuration.
        $actual = InModuleScope CodeSecurity -Parameters @{
            Configuration = $configuration; AttachmentStatus = $AttachmentStatus; SecurityStatus = $SecurityStatus
        } {
            param($Configuration, $AttachmentStatus, $SecurityStatus)
            Get-CodeSecurityCoverageStatus -Attachments @(@{
                configuration = $Configuration; status = $AttachmentStatus
            }) -SecurityStatus $SecurityStatus
        }
        $actual | Should -BeExactly $Expected
    }

    It 'does not call ambiguous multiple configuration attachments compliant' {
        $actual = InModuleScope CodeSecurity -Parameters @{ Configuration = $configuration } {
            param($Configuration)
            $binding = @{ configuration = $Configuration; status = 'attached' }
            Get-CodeSecurityCoverageStatus -Attachments @($binding, $binding.Clone()) -SecurityStatus enabled
        }
        $actual | Should -BeExactly 'drift'
    }

    It 'names the repository with <Case> as drift' -ForEach @(
        @{ Case = 'no attachment'; Change = { $attachments = @() } }
        @{ Case = 'a failed attachment'; Change = { $attachments[0]['status'] = 'failed' } }
        @{ Case = 'a pending attachment'; Change = { $attachments[0]['status'] = 'attaching' } }
        @{ Case = 'an updating attachment'; Change = { $attachments[0]['status'] = 'updating' } }
        @{ Case = 'a detached configuration'; Change = { $attachments[0]['status'] = 'detached' } }
        @{ Case = 'a removed configuration'; Change = { $attachments[0]['status'] = 'removed' } }
        @{ Case = 'enterprise removal'; Change = { $attachments[0]['status'] = 'removed_by_enterprise' } }
        @{ Case = 'disabled configuration security'; Change = { $configuration['advanced_security'] = 'disabled' } }
        @{ Case = 'differently cased configuration security'; Change = { $configuration['advanced_security'] = 'Enabled' } }
        @{ Case = 'secret protection without Code Security'; Change = { $configuration['advanced_security'] = 'secret_protection' } }
        @{ Case = 'disabled configuration CodeQL'; Change = { $configuration['code_scanning_default_setup'] = 'disabled' } }
        @{ Case = 'differently cased configuration CodeQL'; Change = { $configuration['code_scanning_default_setup'] = 'Enabled' } }
        @{ Case = 'unset configuration CodeQL'; Change = { $configuration['code_scanning_default_setup'] = 'not_set' } }
        @{ Case = 'disabled repository security'; Change = { $repository['security_and_analysis']['advanced_security']['status'] = 'disabled' } }
    ) {
        . $Change
        $result = Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo

        $result.repositories[0].repository | Should -BeExactly 'demo/app'
        $result.repositories[0].status | Should -BeExactly 'drift'
        $result.drift | Should -Be 1
        $result.compliant | Should -Be 0
    }

    It 'never calls missing configuration <Field> compliant' -ForEach @(
        @{ Field = 'advanced_security' }, @{ Field = 'code_scanning_default_setup' }
    ) {
        # Deliberately incomplete configuration.
        $configuration.Remove($Field)
        (Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo).repositories[0].status |
            Should -BeExactly 'drift'
    }

    It 'never calls malformed configuration <Field> compliant' -ForEach @(
        @{ Field = 'advanced_security' }, @{ Field = 'code_scanning_default_setup' }
    ) {
        # Deliberately invalid array in place of a scalar enum.
        $configuration[$Field] = @('enabled')
        (Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo).repositories[0].status |
            Should -BeExactly 'drift'
    }

    It 'reports unverified instead of compliant on repository HTTP <Status>' -ForEach @(
        @{ Status = 403 }, @{ Status = 404 }
    ) {
        $repositoryStatus = $Status
        $result = Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo

        $result.repositories[0].status | Should -BeExactly 'unverified'
        $result.repositories[0].security_status | Should -BeExactly 'unverified'
        $result.unverified | Should -Be 1
        $result.compliant | Should -Be 0
    }

    It 'reports unverified for <Case> repository security' -ForEach @(
        @{ Case = 'missing'; Change = { $repository.Remove('security_and_analysis') } }
        @{ Case = 'null'; Change = { $repository['security_and_analysis'] = $null } }
        @{ Case = 'missing product'; Change = { $repository['security_and_analysis'].Remove('advanced_security') } }
        @{ Case = 'missing status'; Change = { $repository['security_and_analysis']['advanced_security'].Remove('status') } }
        @{ Case = 'invalid status'; Change = { $repository['security_and_analysis']['advanced_security']['status'] = 'unknown' } }
        @{ Case = 'differently cased status'; Change = { $repository['security_and_analysis']['advanced_security']['status'] = 'Enabled' } }
        @{ Case = 'non-scalar status'; Change = { $repository['security_and_analysis']['advanced_security']['status'] = @('enabled') } }
    ) {
        # Omitted optional fields are valid; unknown/non-scalar enums deliberately violate the schema.
        . $Change
        $result = Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo
        $result.repositories[0].status | Should -BeExactly 'unverified'
        $result.unverified | Should -Be 1
        $result.compliant | Should -Be 0
    }

    It 'keeps known coverage drift visible when direct security is unreadable' {
        $attachments = @()
        $repositoryStatus = 403
        $result = Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo
        $result.repositories[0].status | Should -BeExactly 'drift'
        $result.repositories[0].security_status | Should -BeExactly 'unverified'
    }

    It 'fails on repository HTTP 503 rather than hiding a failed request' {
        $repositoryStatus = 503
        { Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo } | Should -Throw '*HTTP 503*'
    }

    It 'rejects a repository response for a different identity' {
        $repository['id'] = 102
        { Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo } | Should -Throw '*mismatched identity*'
    }

    It 'rejects a differently named attachment for the same repository ID' {
        $attachments[0]['repository']['full_name'] = 'demo/other'
        { Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*mismatched repository identity*'
    }

    It 'rejects a differently named repository response with the same ID' {
        $repository['full_name'] = 'demo/other'
        { Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*mismatched identity*'
    }

    It 'rejects repository identity with <Case>' -ForEach @(
        @{ Case = 'a string ID'; Field = 'id'; Value = '101' }
        @{ Case = 'an array ID'; Field = 'id'; Value = @(101) }
        @{ Case = 'a null ID'; Field = 'id'; Value = $null }
        @{ Case = 'a boolean ID'; Field = 'id'; Value = $true }
        @{ Case = 'an array full name'; Field = 'full_name'; Value = @('demo/app') }
        @{ Case = 'a null full name'; Field = 'full_name'; Value = $null }
        @{ Case = 'an empty full name'; Field = 'full_name'; Value = '' }
    ) {
        # Deliberately invalid identity type or value in an otherwise valid contract response.
        $repository[$Field] = $Value
        { Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*mismatched identity*'
    }

    It 'rejects an array response with an explicit identity error' {
        # Deliberately invalid array root instead of the contract repository object.
        $invalidRepositoryBody = @($repository)
        Mock -ModuleName CodeSecurity Invoke-WebRequest {
            [pscustomobject]@{
                StatusCode = 200
                Content = ConvertTo-Json -InputObject $invalidRepositoryBody -Depth 100 -Compress
                Headers = @{}
            }
        } -ParameterFilter { ([Uri] $Uri).AbsolutePath -ceq '/repos/demo/app' }
        { Get-CodeSecurityCoverage -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*mismatched identity*'
    }

    It 'publishes separate coverage counters and restores the caller token' {
        $checker = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-CodeSecurityCoverage.ps1'
        $artifact = Join-Path $TestDrive 'coverage.json'
        $result = & $checker -TokensJson '{"demo":"test-plan-token"}' -ApiUrl 'https://api.example.ghe.com' -ReportPath $artifact

        $result.organizations.demo.compliant | Should -Be 1
        $result.organizations.demo.drift | Should -Be 0
        $result.organizations.demo.unverified | Should -Be 0
        $env:REST_API_BEARER | Should -BeExactly 'stub-token'
        (Get-Content -LiteralPath $artifact -Raw | ConvertFrom-Json).organizations.demo.compliant | Should -Be 1
    }

    It 'keeps more than 128 KiB of repository details in an artifact, not GITHUB_OUTPUT' {
        $checker = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-CodeSecurityCoverage.ps1'
        $artifact = Join-Path $TestDrive 'large-coverage.json'
        $jobOutput = Join-Path $TestDrive 'large-coverage.out'
        $previousOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = $jobOutput
        [IO.File]::WriteAllText($jobOutput, 'existing=small')
        $repositories = @(1..2000 | ForEach-Object {
            @{ repository = "demo/repository-$_"; status = 'unverified'; security_status = 'unverified'; attachment_status = @('attached') }
        })
        Mock Get-CodeSecurityCoverage { @{ compliant = 0; drift = 0; unverified = 2000; repositories = $repositories } }
        try {
            $result = & $checker -TokensJson '{"demo":"test-plan-token"}' -ApiUrl 'https://api.example.ghe.com' -ReportPath $artifact
            [IO.File]::ReadAllBytes($artifact).Length | Should -BeGreaterThan 131072
            (Get-Content -LiteralPath $artifact -Raw | ConvertFrom-Json).organizations.demo.repositories.Count | Should -Be 2000
            $result.organizations.demo.repositories.Count | Should -Be 2000
            [IO.File]::ReadAllText($jobOutput) | Should -BeExactly 'existing=small'
        }
        finally { $env:GITHUB_OUTPUT = $previousOutput }
    }

    It 'removes a previous coverage artifact before token validation can fail' {
        $checker = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-CodeSecurityCoverage.ps1'
        $artifact = Join-Path $TestDrive 'stale-coverage.json'
        [IO.File]::WriteAllText($artifact, '{"organizations":{}}')

        { & $checker -TokensJson '{}' -ApiUrl 'https://api.example.ghe.com' -ReportPath $artifact } |
            Should -Throw '*installation token map*'

        Test-Path -LiteralPath $artifact | Should -BeFalse
    }
}
