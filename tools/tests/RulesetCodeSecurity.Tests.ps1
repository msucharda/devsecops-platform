BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $moduleRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/organization-rulesets'
    Import-Module (Join-Path $moduleRoot 'scripts/Rulesets.psm1') -Force

    function Get-TestSecurityDefaults {
        $configuration = Get-GitHubApiFixture -Name code-security/get-configuration -Set @{
            id = 42; name = 'platform-baseline'; target_type = 'organization'
            advanced_security = 'enabled'; code_scanning_default_setup = 'enabled'; enforcement = 'enforced'
        }
        $defaults = Get-GitHubApiFixture -Name code-security/get-default-configurations
        $entry = $defaults[0]
        $entry['default_for_new_repos'] = 'all'
        $entry['configuration'] = $configuration
        return , @($entry)
    }
}

Describe 'Ruleset Code Security prerequisite' {
    BeforeEach {
        $previousTokens = $env:PLATFORM_GITHUB_TOKENS
        $env:PLATFORM_GITHUB_TOKENS = '{"demo":"stub-token"}'
        $defaults = Get-TestSecurityDefaults
        Mock -ModuleName Rulesets Invoke-WebRequest {
            $Uri | Should -BeExactly 'https://api.example.ghe.com/orgs/demo/code-security/configurations/defaults'
            [string] $Method | Should -Be 'GET'
            $Headers['X-GitHub-Api-Version'] | Should -BeExactly '2026-03-10'
            [pscustomobject]@{
                StatusCode = 200
                Content = ConvertTo-Json -InputObject $defaults -Depth 100 -Compress
                Headers = @{}
            }
        }
    }

    AfterEach { $env:PLATFORM_GITHUB_TOKENS = $previousTokens }

    It 'accepts the enforced platform baseline for all new repositories' {
        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } | Should -Not -Throw
    }

    It 'accepts separate public and private/internal defaults with the same configuration ID' {
        $other = (Get-TestSecurityDefaults)[0]
        $defaults[0]['default_for_new_repos'] = 'public'
        $other['default_for_new_repos'] = 'private_and_internal'
        $defaults += $other

        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } | Should -Not -Throw
    }

    It 'rejects a configuration with <Case>' -ForEach @(
        @{ Case = 'a different name'; Field = 'name'; Value = 'other' }
        @{ Case = 'a differently cased name'; Field = 'name'; Value = 'Platform-baseline' }
        @{ Case = 'a global target'; Field = 'target_type'; Value = 'global' }
        @{ Case = 'an enterprise target'; Field = 'target_type'; Value = 'enterprise' }
        @{ Case = 'a differently cased target'; Field = 'target_type'; Value = 'Organization' }
        @{ Case = 'unenforced settings'; Field = 'enforcement'; Value = 'unenforced' }
        @{ Case = 'enterprise enforcement'; Field = 'enforcement'; Value = 'enterprise_enforced' }
        @{ Case = 'differently cased enforcement'; Field = 'enforcement'; Value = 'Enforced' }
        @{ Case = 'disabled security'; Field = 'advanced_security'; Value = 'disabled' }
        @{ Case = 'secret protection only'; Field = 'advanced_security'; Value = 'secret_protection' }
        @{ Case = 'deprecated partial security'; Field = 'advanced_security'; Value = 'code_security' }
        @{ Case = 'differently cased security'; Field = 'advanced_security'; Value = 'Enabled' }
        @{ Case = 'disabled CodeQL'; Field = 'code_scanning_default_setup'; Value = 'disabled' }
        @{ Case = 'unset CodeQL'; Field = 'code_scanning_default_setup'; Value = 'not_set' }
        @{ Case = 'differently cased CodeQL'; Field = 'code_scanning_default_setup'; Value = 'Enabled' }
    ) {
        $defaults[0]['configuration'][$Field] = $Value

        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw "*invalid '$Field'*Deploy the enterprise-baseline Code Security phase*"
    }

    It 'rejects <Case> for required setting <Field>' -ForEach @(
        foreach ($field in @('name', 'target_type', 'enforcement', 'advanced_security', 'code_scanning_default_setup')) {
            foreach ($value in @(
                    @{ Case = 'a missing field'; Remove = $true; Value = $null }
                    @{ Case = 'a null value'; Remove = $false; Value = $null }
                    @{ Case = 'an empty value'; Remove = $false; Value = '' }
                    @{ Case = 'an array'; Remove = $false; Value = @('enabled') }
                )) { @{ Field = $field; Case = $value.Case; Remove = $value.Remove; Value = $value.Value } }
        }
    ) {
        # Deliberately incomplete or malformed responses must fail closed.
        if ($Remove) { $defaults[0]['configuration'].Remove($Field) }
        else { $defaults[0]['configuration'][$Field] = $Value }

        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw "*invalid '$Field'*"
    }

    It 'rejects <Case> instead of treating it as coverage' -ForEach @(
        @{ Case = 'an object instead of an array'; Value = @{}; Error = '*not an array*' }
        @{ Case = 'an empty defaults array'; Value = @(); Error = '*no enforced platform-baseline*' }
        @{ Case = 'a non-object default'; Value = @('all'); Error = '*invalid entry*' }
    ) {
        # Deliberately malformed responses.
        $defaults = $Value
        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } | Should -Throw $Error
    }

    It 'rejects visibility <Case>' -ForEach @(
        @{ Case = 'public-only'; Value = 'public'; Error = '*no enforced platform-baseline*' }
        @{ Case = 'private/internal-only'; Value = 'private_and_internal'; Error = '*no enforced platform-baseline*' }
        @{ Case = 'unknown'; Value = 'private'; Error = '*unknown visibility*' }
        @{ Case = 'differently cased'; Value = 'All'; Error = '*unknown visibility*' }
        @{ Case = 'empty'; Value = ''; Error = '*unknown visibility*' }
        @{ Case = 'missing'; Value = $null; Error = '*unknown visibility*' }
        @{ Case = 'array'; Value = @('all'); Error = '*unknown visibility*' }
    ) {
        # Null/array/unknown visibility deliberately violate the response schema.
        $defaults[0]['default_for_new_repos'] = $Value
        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } | Should -Throw $Error
    }

    It 'rejects a configuration ID of <Case>' -ForEach @(
        @{ Case = 'zero'; Value = 0 }
        @{ Case = 'negative'; Value = -1 }
        @{ Case = 'missing'; Value = $null }
        @{ Case = 'string'; Value = '42' }
        @{ Case = 'fractional'; Value = 42.5 }
        @{ Case = 'array'; Value = @(42) }
    ) {
        # Deliberately invalid identity metadata.
        $defaults[0]['configuration']['id'] = $Value
        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*no valid configuration ID*'
    }

    It 'rejects a missing configuration object' {
        # Deliberately incomplete response.
        $defaults[0].Remove('configuration')
        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*no configuration object*'
    }

    It 'rejects different configuration IDs across the two visibility defaults' {
        $other = (Get-TestSecurityDefaults)[0]
        $defaults[0]['default_for_new_repos'] = 'public'
        $other['default_for_new_repos'] = 'private_and_internal'
        $other['configuration']['id'] = 43
        $defaults += $other

        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*different configuration IDs*'
    }

    It 'rejects overlapping default records' {
        $defaults += (Get-TestSecurityDefaults)[0]
        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*overlap*'
    }

    It 'fails closed on HTTP <Status>' -ForEach @(@{ Status = 403 }, @{ Status = 404 }, @{ Status = 503 }) {
        Mock -ModuleName Rulesets Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = $Status; Content = '{"message":"unavailable"}'; Headers = @{} }
        }
        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw "*HTTP $Status*"
    }

    It 'fails closed on a successful empty response' {
        Mock -ModuleName Rulesets Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = 'null'; Headers = @{} }
        }
        { Assert-RulesetCodeSecurityPrerequisite -ApiUrl 'https://api.example.ghe.com' -Organization demo } |
            Should -Throw '*empty successful GET*'
    }
}
