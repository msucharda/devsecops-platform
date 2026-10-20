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
