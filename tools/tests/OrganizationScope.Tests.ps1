BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PlatformTools.psm1') -Force
}

Describe 'Organization-scoped execution contract' {
    BeforeEach {
        $targets = @('demo-platform', 'demo-actions', 'demo-workloads')
        $manifest = @{ name = 'scoped' }
        $instance = @{ instance = @{ name = 'demo' }; modules = @{ scoped = @{ parameters = @{ target_organizations = $targets } } } }
    }

    It 'accepts all instance organizations in a deterministic execution order' {
        $instance.modules.scoped.parameters.target_organizations = @('demo-workloads', 'demo-platform', 'demo-actions')
        @(Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform) |
            Should -Be @('demo-platform', 'demo-actions', 'demo-workloads')
    }

    It 'accepts deployment-specific organization names' {
        $instance.modules.scoped.parameters.target_organizations = @('demo-a1b2c3-platform', 'demo-a1b2c3-actions', 'demo-a1b2c3-workloads')
        @(Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-a1b2c3-platform) |
            Should -Be @('demo-a1b2c3-platform', 'demo-a1b2c3-actions', 'demo-a1b2c3-workloads')
    }

    It 'accepts an explicit instance organization selector' {
        @(Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform -Organization demo-actions) |
            Should -Be $targets
    }

    It 'rejects an organization selector outside the exact instance set: <Organization>' -ForEach @(
        @{ Organization = 'foreign' }
        @{ Organization = 'DEMO-ACTIONS' }
    ) {
        { Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform -Organization $Organization } |
            Should -Throw "*is not an instance organization*"
    }

    It 'rejects missing module parameters' {
        $instance.modules.scoped.Remove('parameters')
        { Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform } |
            Should -Throw '*requires module parameters*'
    }

    It 'rejects a non-list target value: <Case>' -ForEach @(
        @{ Case = 'missing'; Value = $null }
        @{ Case = 'scalar'; Value = 'demo-platform' }
        @{ Case = 'mapping'; Value = @{ platform = 'demo-platform' } }
    ) {
        $instance.modules.scoped.parameters.target_organizations = $Value
        { Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform } |
            Should -Throw '*requires a target_organizations list*'
    }

    It 'rejects a target list that is not exactly the instance set: <Case>' -ForEach @(
        @{ Case = 'missing platform'; Value = @('demo-actions', 'demo-workloads') }
        @{ Case = 'missing actions'; Value = @('demo-platform', 'demo-workloads') }
        @{ Case = 'missing workloads'; Value = @('demo-platform', 'demo-actions') }
        @{ Case = 'extra organization'; Value = @('demo-platform', 'demo-actions', 'demo-workloads', 'foreign') }
        @{ Case = 'duplicate organization'; Value = @('demo-platform', 'demo-actions', 'demo-workloads', 'demo-actions') }
        @{ Case = 'different case'; Value = @('demo-platform', 'DEMO-ACTIONS', 'demo-workloads') }
        @{ Case = 'empty'; Value = @() }
    ) {
        $instance.modules.scoped.parameters.target_organizations = $Value
        { Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform } |
            Should -Throw '*must contain exactly all instance organizations*'
    }

    It 'rejects a null target member before ordinal ordering' {
        $instance.modules.scoped.parameters.target_organizations = @('demo-platform', 'demo-actions', $null)
        { Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform } |
            Should -Throw "*Cannot bind argument to parameter 'Value' because it is null*"
    }

    It 'accepts distinct per-organization values without requiring them to be identical' {
        $manifest.organizationParameters = @('reviewers')
        $instance.modules.scoped.parameters.reviewers = @{ 'demo-platform' = @(11); 'demo-actions' = @(22); 'demo-workloads' = @(33) }
        @(Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform) |
            Should -Be $targets
    }

    It 'rejects a shared organization parameter value: <Case>' -ForEach @(
        @{ Case = 'missing'; Value = $null }
        @{ Case = 'list'; Value = @(11) }
        @{ Case = 'scalar'; Value = 'security' }
    ) {
        $manifest.organizationParameters = @('reviewers')
        $instance.modules.scoped.parameters.reviewers = $Value
        { Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform } |
            Should -Throw '*reviewers*must be a mapping keyed by organization*'
    }

    It 'rejects mismatched organization parameter keys: <Case>' -ForEach @(
        @{ Case = 'missing organization'; Value = @{ 'demo-platform' = @(11); 'demo-actions' = @(22) } }
        @{ Case = 'extra organization'; Value = @{ 'demo-platform' = @(11); 'demo-actions' = @(22); 'demo-workloads' = @(33); foreign = @(44) } }
        @{ Case = 'different case'; Value = @{ 'demo-platform' = @(11); 'DEMO-ACTIONS' = @(22); 'demo-workloads' = @(33) } }
    ) {
        $manifest.organizationParameters = @('reviewers')
        $instance.modules.scoped.parameters.reviewers = $Value
        { Get-PlatformModuleOrganization -Instance $instance -Manifest $manifest -PlatformOrganization demo-platform } |
            Should -Throw '*reviewers*must contain exactly all instance organization keys*'
    }
}

Describe 'Organization token isolation' {
    It 'accepts exactly the selected organization tokens' {
        $tokens = Get-PlatformOrganizationToken -Organization @('demo-platform', 'demo-actions', 'demo-workloads') `
            -Json '{"demo-platform":"platform-token","demo-actions":"actions-token","demo-workloads":"workloads-token"}'
        $tokens['demo-platform'] | Should -BeExactly 'platform-token'
        $tokens['demo-actions'] | Should -BeExactly 'actions-token'
        $tokens['demo-workloads'] | Should -BeExactly 'workloads-token'
    }

    It 'rejects an unreadable token map: <Case>' -ForEach @(
        @{ Case = 'empty'; Json = '' }
        @{ Case = 'whitespace'; Json = ' ' }
        @{ Case = 'invalid JSON'; Json = '{' }
    ) {
        { Get-PlatformOrganizationToken -Organization @('demo-platform') -Json $Json } |
            Should -Throw '*requires a readable PLATFORM_GITHUB_TOKENS object*'
    }

    It 'rejects a non-object token map: <Case>' -ForEach @(
        @{ Case = 'null'; Json = 'null' }
        @{ Case = 'array'; Json = '[]' }
        # Deliberately invalid: a singleton array must not be unwrapped into a valid token object.
        @{ Case = 'singleton object array'; Json = '[{"demo-platform":"token"}]' }
        @{ Case = 'string'; Json = '"token"' }
    ) {
        { Get-PlatformOrganizationToken -Organization @('demo-platform') -Json $Json } |
            Should -Throw '*requires a PLATFORM_GITHUB_TOKENS object*'
    }

    It 'rejects token keys outside the exact execution scope: <Case>' -ForEach @(
        @{ Case = 'missing'; Json = '{}' }
        @{ Case = 'foreign'; Json = '{"foreign":"token"}' }
        @{ Case = 'extra'; Json = '{"demo-platform":"token","foreign":"token"}' }
        @{ Case = 'different case'; Json = '{"DEMO-PLATFORM":"token"}' }
    ) {
        { Get-PlatformOrganizationToken -Organization @('demo-platform') -Json $Json } |
            Should -Throw '*token keys must match exactly the execution organizations*'
    }

    It 'rejects invalid installation tokens: <Case>' -ForEach @(
        @{ Case = 'empty'; Json = '{"demo-platform":""}' }
        @{ Case = 'whitespace'; Json = '{"demo-platform":" "}' }
        @{ Case = 'null'; Json = '{"demo-platform":null}' }
        @{ Case = 'number'; Json = '{"demo-platform":101}' }
    ) {
        { Get-PlatformOrganizationToken -Organization @('demo-platform') -Json $Json } |
            Should -Throw "*demo-platform*requires a non-blank installation token*"
    }

    It 'validates the token of every execution organization: <Organization>' -ForEach @(
        @{ Organization = 'demo-platform' }
        @{ Organization = 'demo-actions' }
        @{ Organization = 'demo-workloads' }
    ) {
        $tokens = @{ 'demo-platform' = 'platform-token'; 'demo-actions' = 'actions-token'; 'demo-workloads' = 'workloads-token' }
        $tokens[$Organization] = ' '
        $json = ConvertTo-Json -InputObject $tokens -Compress

        { Get-PlatformOrganizationToken -Organization @('demo-platform', 'demo-actions', 'demo-workloads') -Json $json } |
            Should -Throw "*$Organization*requires a non-blank installation token*"
    }
}
