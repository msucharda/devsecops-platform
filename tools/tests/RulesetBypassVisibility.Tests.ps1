BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $checker = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-RulesetBypassVisibility.ps1'
}

Describe 'Ruleset bypass visibility during drift detection' {
    BeforeEach {
        $tokens = '{"platform":"platform-token"}'
        $outputPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $arguments = @{ TokensJson = $tokens; Enterprise = 'example'; ApiUrl = 'https://api.example.test'; GitHubOutputPath = $outputPath }
        $listed = @(
            (Get-GitHubApiFixture -Name repos/get-org-rulesets -Set @{ '0.id' = 11; '0.source_type' = 'Organization'; '0.source' = 'platform' })[0]
            (Get-GitHubApiFixture -Name repos/get-org-rulesets -Set @{ '0.id' = 12; '0.source_type' = 'Enterprise'; '0.source' = 'example' })[0]
        )
        $detail = Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{ id = 11; source_type = 'Organization'; source = 'platform' }
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like 'https://api.example.test/orgs/platform/rulesets`?includes_parents=true&per_page=100&page=1') { return , $listed }
            if ($Uri -like 'https://api.example.test/orgs/platform/rulesets`?*') { return , @() }
            if ($Uri -eq 'https://api.example.test/orgs/platform/rulesets/11') { return $detail }
            throw "Unexpected GitHub API request: $Uri"
        }
    }

    It 'reads every local ruleset detail with bypass actors and counts inherited enterprise rulesets as uncovered' {
        $result = & $checker @arguments

        $result.LocalRulesetsVerified | Should -Be 1
        $result.InheritedRulesets | Should -Be 1
        [IO.File]::ReadAllText($outputPath) | Should -BeExactly "inheritedRulesets=1`n"
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.example.test/orgs/platform/rulesets/11' -and
            $Headers['X-GitHub-Api-Version'] -eq '2026-03-10' -and $Headers['Authorization'] -eq 'Bearer platform-token' -and
            $MaximumRetryCount -eq 0
        }
    }

    It 'accepts an explicitly empty bypass actor collection as a verified state without bypass' {
        $detail.bypass_actors = @()

        $result = & $checker @arguments

        $result.LocalRulesetsVerified | Should -Be 1
    }

    It 'pages through the ruleset list until an empty page' {
        $fullPage = @(1..100 | ForEach-Object {
            (Get-GitHubApiFixture -Name repos/get-org-rulesets -Set @{ '0.id' = 12; '0.source_type' = 'Enterprise'; '0.source' = 'example' })[0]
        })
        Mock Invoke-RestMethod { return , $fullPage } -ParameterFilter { $Uri -like '*page=1' }
        Mock Invoke-RestMethod { return , $listed } -ParameterFilter { $Uri -like '*page=2' }

        $result = & $checker @arguments

        $result.InheritedRulesets | Should -Be 101
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*page=3' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*page=4' }
    }

    It 'continues after a short page and fails on hidden bypass actors on the next page' {
        $hidden = Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{ id = 13; source_type = 'Organization'; source = 'platform' }
        $hidden.Remove('bypass_actors')
        Mock Invoke-RestMethod {
            return , @((Get-GitHubApiFixture -Name repos/get-org-rulesets -Set @{ '0.id' = 13; '0.source_type' = 'Organization'; '0.source' = 'platform' })[0])
        } -ParameterFilter { $Uri -like '*page=2' }
        Mock Invoke-RestMethod { return $hidden } -ParameterFilter { $Uri -eq 'https://api.example.test/orgs/platform/rulesets/13' }

        { & $checker @arguments } | Should -Throw '*complete bypass configuration of ruleset 13*'
    }

    It 'fails closed when the ruleset list never ends' {
        Mock Invoke-RestMethod {
            return , @((Get-GitHubApiFixture -Name repos/get-org-rulesets -Set @{ '0.id' = 12; '0.source_type' = 'Enterprise'; '0.source' = 'example' })[0])
        } -ParameterFilter { $Uri -like '*rulesets`?*' }

        { & $checker @arguments } | Should -Throw '*within 1000 pages*'
    }

    It 'checks each organization covered by the job token' {
        $arguments.TokensJson = '{"platform":"platform-token","workloads":"workloads-token"}'
        Mock Invoke-RestMethod { return , @() } -ParameterFilter { $Uri -like 'https://api.example.test/orgs/workloads/rulesets`?*' }

        $null = & $checker @arguments

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Uri -like '*/orgs/workloads/rulesets?*' -and $Headers['Authorization'] -eq 'Bearer workloads-token'
        }
    }

    It 'treats a missing bypass actor field as incomplete, not as a ruleset without bypass' {
        $detail.Remove('bypass_actors')

        { & $checker @arguments } | Should -Throw '*did not expose*bypass*'
        Test-Path -LiteralPath $outputPath | Should -BeFalse
    }

    It 'treats a non-list bypass actor field as incomplete' {
        $detail.bypass_actors = 'hidden'

        { & $checker @arguments } | Should -Throw '*did not expose*bypass*'
    }

    It 'rejects a detail response for another ruleset' {
        $detail.id = 99

        { & $checker @arguments } | Should -Throw '*detail*does not match*'
    }

    It 'rejects <Case> ruleset source metadata instead of skipping it' -ForEach @(
        @{ Case = 'repository'; Type = 'Repository'; Source = 'platform/instance' }
        @{ Case = 'another organization'; Type = 'Organization'; Source = 'other' }
        @{ Case = 'another enterprise'; Type = 'Enterprise'; Source = 'other' }
        @{ Case = 'missing'; Type = $null; Source = 'platform' }
    ) {
        $listed[0].source_type = $Type
        $listed[0].source = $Source

        { & $checker @arguments } | Should -Throw '*unknown or mismatched source metadata*'
    }

    It 'fails closed when the ruleset API fails' {
        Mock Invoke-RestMethod { throw 'Ruleset API unavailable' } -ParameterFilter { $Uri -eq 'https://api.example.test/orgs/platform/rulesets/11' }

        { & $checker @arguments } | Should -Throw '*GET /orgs/platform/rulesets/11 failed*Ruleset API unavailable*'
        Test-Path -LiteralPath $outputPath | Should -BeFalse
    }

    It 'requires <Case>' -ForEach @(
        @{ Case = 'an installation token map'; Name = 'TokensJson'; Value = '' }
        @{ Case = 'a non-empty token map'; Name = 'TokensJson'; Value = '{}' }
        @{ Case = 'a token map object'; Name = 'TokensJson'; Value = '["token"]' }
        @{ Case = 'the App enterprise'; Name = 'Enterprise'; Value = '' }
        @{ Case = 'an HTTPS API URL'; Name = 'ApiUrl'; Value = 'http://api.example.test' }
    ) {
        $arguments[$Name] = $Value

        { & $checker @arguments } | Should -Throw '*Ruleset bypass check requires*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}
