BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $scripts = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline/scripts'
    Import-Module (Join-Path $scripts 'Rulesets.psm1') -Force
}

Describe 'Organization ruleset detail contract' {
    BeforeEach {
        $previousTokens = $env:PLATFORM_GITHUB_TOKENS
        $env:PLATFORM_GITHUB_TOKENS = '{"demo":"installation-token"}'
        $listed = Get-GitHubApiFixture -Name repos/get-org-rulesets -Set @{
            '0.id' = 21; '0.name' = 'platform-default-branch'; '0.source_type' = 'Organization'; '0.source' = 'demo'
        }
        $detail = Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{
            name = 'platform-default-branch'; source = 'demo'
        }
        Mock -ModuleName CodeSecurity Invoke-WebRequest {
            $json = if ($Uri -like '*/rulesets`?*') {
                ConvertTo-Json -InputObject @($listed) -Depth 50 -Compress
            } else { ConvertTo-Json -InputObject $detail -Depth 50 -Compress }
            [pscustomobject]@{ StatusCode = 200; Content = $json; Headers = @{} }
        }
    }

    AfterEach { $env:PLATFORM_GITHUB_TOKENS = $previousTokens }

    It 'reads full detail with the organization installation token, including a nonempty bypass list' {
        $state = Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch

        $state.bypass_actors.Count | Should -Be 1
        $state.bypass_actors[0].actor_type | Should -Be 'Team'
        Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/demo/rulesets/21' -and
            $Headers['Authorization'] -eq 'Bearer installation-token' -and $Headers['X-GitHub-Api-Version'] -eq '2026-03-10'
        }
    }

    It 'rejects a missing bypass list instead of treating it as empty' {
        # Deliberately invalid/incomplete detail returned without write access.
        $detail.Remove('bypass_actors')

        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch } |
            Should -Throw '*bypass_actors*'
    }

    It 'accepts an explicitly empty bypass list and case-insensitive organization name' {
        $listed[0].source = 'DEMO'
        $detail.source = 'DEMO'
        $detail.bypass_actors = @()
        (Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch).bypass_actors.Count |
            Should -Be 0
    }

    It 'rejects malformed detail: <Case>' -ForEach @(
        @{ Case = 'wrong ID'; Field = 'id'; Value = 22; Error = '*mismatched identity*' }
        @{ Case = 'wrong name'; Field = 'name'; Value = 'other'; Error = '*mismatched identity*' }
        @{ Case = 'wrong name case'; Field = 'name'; Value = 'PLATFORM-DEFAULT-BRANCH'; Error = '*mismatched identity*' }
        @{ Case = 'wrong source'; Field = 'source'; Value = 'other'; Error = '*mismatched identity*' }
        @{ Case = 'wrong source type'; Field = 'source_type'; Value = 'Repository'; Error = '*mismatched identity*' }
        @{ Case = 'missing source'; Field = 'source'; Missing = $true; Error = '*mismatched identity*' }
        @{ Case = 'missing source type'; Field = 'source_type'; Missing = $true; Error = '*mismatched identity*' }
        @{ Case = 'null bypass'; Field = 'bypass_actors'; Value = $null; Error = '*bypass_actors*' }
        @{ Case = 'object bypass'; Field = 'bypass_actors'; Value = @{}; Error = '*bypass_actors*' }
        @{ Case = 'missing target'; Field = 'target'; Missing = $true; Error = "*no 'target'*" }
        @{ Case = 'missing rules'; Field = 'rules'; Missing = $true; Error = "*no 'rules'*" }
        @{ Case = 'null conditions'; Field = 'conditions'; Value = $null; Error = "*no 'conditions'*" }
    ) {
        param([bool] $Missing = $false)

        # Deliberately invalid identity or incomplete response; all other fixture properties remain valid.
        if ($Missing) { $detail.Remove($Field) } else { $detail[$Field] = $Value }
        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch } |
            Should -Throw $Error
    }

    It 'rejects malformed list metadata: <Case>' -ForEach @(
        @{ Case = 'zero ID'; Field = 'id'; Value = 0; Error = '*invalid identity*' }
        @{ Case = 'empty name'; Field = 'name'; Value = ''; Error = '*invalid identity*' }
        @{ Case = 'empty source'; Field = 'source'; Value = ''; Error = '*invalid identity*' }
        @{ Case = 'wrong organization'; Field = 'source'; Value = 'other'; Error = '*mismatched source*' }
        @{ Case = 'wrong source type'; Field = 'source_type'; Value = 'Repository'; Error = '*mismatched source*' }
        @{ Case = 'unknown source type'; Field = 'source_type'; Value = 'Other'; Error = '*mismatched source*' }
        @{ Case = 'missing source type'; Field = 'source_type'; Missing = $true; Error = '*mismatched source*' }
        @{ Case = 'different name case'; Field = 'name'; Value = 'PLATFORM-DEFAULT-BRANCH'; Error = '*differently cased*' }
    ) {
        param([bool] $Missing = $false)

        # Deliberately invalid metadata; an incomplete list cannot prove absence before a POST or DELETE.
        if ($Missing) { $listed[0].Remove($Field) } else { $listed[0][$Field] = $Value }
        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch } |
            Should -Throw $Error
    }

    It 'rejects duplicate local names instead of arbitrarily updating or deleting one' {
        $listed += Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{ id = 22; name = 'platform-default-branch'; source = 'demo' }
        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch } |
            Should -Throw '*duplicate rulesets*'
        Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'does not adopt an inherited enterprise ruleset with the managed name' {
        $listed[0].source_type = 'Enterprise'
        $listed[0].source = 'example'
        Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch |
            Should -BeNullOrEmpty
        Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*/rulesets/21' }
    }

    It 'explicitly rejects unsupported condition variant <Variant>' -ForEach @(
        @{ Variant = 'repository_id'; Value = @{ repository_ids = @(1) } }
        @{ Variant = 'repository_property'; Value = @{ include = @(@{ name = 'type'; property_values = @('app') }); exclude = @() } }
    ) {
        $detail.conditions.Remove('repository_name')
        $detail.conditions[$Variant] = $Value
        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch } |
            Should -Throw '*Unsupported organization ruleset conditions*'
    }

    It 'uses the matching organization token and restores the previous bearer even after an API error' {
        $env:PLATFORM_GITHUB_TOKENS = '{"other":"wrong-token","demo":"installation-token"}'
        $oldBearer = $env:REST_API_BEARER
        try {
            $env:REST_API_BEARER = 'previous-bearer'
            Mock -ModuleName CodeSecurity Invoke-WebRequest { throw 'Connection lost' }
            { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch } |
                Should -Throw '*Connection lost*'
            $env:REST_API_BEARER | Should -Be 'previous-bearer'
            Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Headers['Authorization'] -eq 'Bearer installation-token'
            }
        }
        finally { $env:REST_API_BEARER = $oldBearer }
    }

    It 'refuses a missing or invalid token map: <Map>' -ForEach @(
        @{ Map = '' }, @{ Map = '{}' }, @{ Map = '[]' }, @{ Map = '{"other":"token"}' },
        @{ Map = '{"demo":""}' }, @{ Map = '{"demo":null}' }, @{ Map = '{"demo":12}' }
    ) {
        $env:PLATFORM_GITHUB_TOKENS = $Map
        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch } |
            Should -Throw '*No installation token*'
        Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 0 -Exactly
    }

    It 'does not normalize invalid dismissal restriction enabled value <Value>' -ForEach @(
        @{ Value = 0 }, @{ Value = 'False' }
    ) {
        # Deliberately invalid API types: enabled is documented as boolean, not integer or string.
        $detail.rules = @(@{ type = 'pull_request'; parameters = @{ dismissal_restriction = @{ enabled = $Value; allowed_actors = @() } } })
        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch } |
            Should -Throw '*dismissal_restriction.enabled must be boolean*'
    }

    It 'rejects deletion by recorded ID with changed <Field>' -ForEach @(
        @{ Field = 'source'; Value = 'other' }
        @{ Field = 'source_type'; Value = 'Enterprise' }
        @{ Field = 'id'; Value = 22 }
    ) {
        # Deliberately invalid ID/source response for a destructive request.
        $detail[$Field] = $Value
        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch -Id 21 } |
            Should -Throw '*mismatched identity or source*'
        Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'rejects a successful GET with <Case> instead of treating it like HTTP 404' -ForEach @(
        @{ Case = 'empty body'; Body = '' }, @{ Case = 'JSON null'; Body = 'null' }
    ) {
        Mock -ModuleName CodeSecurity Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = $Body; Headers = @{} }
        } -ParameterFilter { $Uri -like '*/rulesets/21' }
        { Get-OrganizationRulesetState -ApiUrl 'https://api.example.test' -Organization demo -Name platform-default-branch -Id 21 } |
            Should -Throw '*empty successful GET*'
    }
}
