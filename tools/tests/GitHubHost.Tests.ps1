BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'GitHubHost.psm1') -Force
}

Describe 'GitHub cloud repository targets' {
    It 'resolves <Repository> to its exact API origin' -ForEach @(
        @{ Repository = 'demo/source'; ApiUrl = ''; Hostname = 'github.com'; ExpectedApi = 'https://api.github.com' }
        @{ Repository = 'example.ghe.com/demo/source'; ApiUrl = ''; Hostname = 'example.ghe.com'; ExpectedApi = 'https://api.example.ghe.com' }
        @{ Repository = 'EXAMPLE.GHE.COM/demo/source'; ApiUrl = ''; Hostname = 'example.ghe.com'; ExpectedApi = 'https://api.example.ghe.com' }
        @{ Repository = 'demo/source'; ApiUrl = 'https://api.example.ghe.com/'; Hostname = 'example.ghe.com'; ExpectedApi = 'https://api.example.ghe.com' }
        @{ Repository = 'example.ghe.com/demo/source'; ApiUrl = 'https://api.example.ghe.com'; Hostname = 'example.ghe.com'; ExpectedApi = 'https://api.example.ghe.com' }
    ) {
        $target = Resolve-GitHubCloudTarget -Repository $Repository -ApiUrl $ApiUrl
        $target.Host | Should -BeExactly $Hostname
        $target.Slug | Should -BeExactly 'demo/source'
        $target.ApiUrl | Should -BeExactly $ExpectedApi
    }

    It 'rejects an API override with <Case> before retrieving credentials' -ForEach @(
        @{ Case = 'HTTP'; ApiUrl = 'http://api.example.ghe.com' }
        @{ Case = 'userinfo'; ApiUrl = 'https://user@api.example.ghe.com' }
        @{ Case = 'a port'; ApiUrl = 'https://api.example.ghe.com:444' }
        @{ Case = 'a path'; ApiUrl = 'https://api.example.ghe.com/other' }
        @{ Case = 'a query'; ApiUrl = 'https://api.example.ghe.com?x=1' }
        @{ Case = 'a fragment'; ApiUrl = 'https://api.example.ghe.com#x' }
        @{ Case = 'a foreign host'; ApiUrl = 'https://api.example.net' }
        @{ Case = 'a suffix lookalike'; ApiUrl = 'https://api.example.ghe.com.attacker.test' }
        @{ Case = 'an empty enterprise label'; ApiUrl = 'https://api..ghe.com' }
    ) {
        { Resolve-GitHubCloudTarget -Repository demo/source -ApiUrl $ApiUrl } |
            Should -Throw '*HTTPS API origin*'
    }

    It 'rejects an explicit repository on a different API host' {
        { Resolve-GitHubCloudTarget -Repository github.com/demo/source -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*different GitHub hosts*'
    }

    It 'rejects a non-cloud repository host' {
        { Resolve-GitHubCloudTarget -Repository github.example.net/demo/source } |
            Should -Throw '*only github.com and GHE.com*'
    }

    It 'rejects an invalid repository: <Repository>' -ForEach @(
        @{ Repository = '' }
        @{ Repository = 'source' }
        @{ Repository = 'demo/source extra' }
        @{ Repository = 'demo/.' }
        @{ Repository = 'demo/..' }
        @{ Repository = 'example.ghe.com/demo/source/extra' }
    ) {
        { ConvertTo-GitHubRepositoryTarget -Repository $Repository } | Should -Throw "*must be 'owner/repo'*"
    }
}

Describe 'Host-scoped GitHub CLI credentials' {
    It 'uses the stored GHE login without either cloud token override and restores the caller environment' {
        InModuleScope GitHubHost {
            $savedGh = $env:GH_TOKEN
            $savedGitHub = $env:GITHUB_TOKEN
            try {
                $env:GH_TOKEN = 'public-gh-token'
                $env:GITHUB_TOKEN = 'public-actions-token'
                Mock gh {
                    $env:GH_TOKEN | Should -BeNullOrEmpty
                    $env:GITHUB_TOKEN | Should -BeNullOrEmpty
                    $args | Should -Contain 'example.ghe.com'
                    $global:LASTEXITCODE = 0
                    'host-scoped-result'
                }

                Invoke-GitHubHostGh -Hostname example.ghe.com -Arguments @('auth', 'token', '--hostname', 'example.ghe.com') |
                    Should -BeExactly 'host-scoped-result'

                $env:GH_TOKEN | Should -BeExactly 'public-gh-token'
                $env:GITHUB_TOKEN | Should -BeExactly 'public-actions-token'
            }
            finally {
                $env:GH_TOKEN = $savedGh
                $env:GITHUB_TOKEN = $savedGitHub
            }
        }
    }

    It 'selects a named stored account on <Hostname> with the <Variant> response without changing the globally active account' -ForEach @(
        @{ Hostname = 'github.com'; TokenVariable = 'GH_TOKEN'; Variant = 'private-user' }
        @{ Hostname = 'github.com'; TokenVariable = 'GH_TOKEN'; Variant = 'public-user' }
        @{ Hostname = 'example.ghe.com'; TokenVariable = 'GH_TOKEN'; Variant = 'private-user' }
        @{ Hostname = 'example.ghe.com'; TokenVariable = 'GH_TOKEN'; Variant = 'public-user' }
        @{ Hostname = 'github.example.net'; TokenVariable = 'GH_ENTERPRISE_TOKEN'; Variant = 'private-user' }
        @{ Hostname = 'github.example.net'; TokenVariable = 'GH_ENTERPRISE_TOKEN'; Variant = 'public-user' }
    ) {
        $response = Get-GitHubApiFixture -Name "users/get-authenticated-user.$Variant" -Set @{ login = 'pilot-owner' } |
            ConvertTo-Json -Depth 100 -Compress
        InModuleScope GitHubHost -Parameters @{ Hostname = $Hostname; TokenVariable = $TokenVariable; Response = $response } {
            $saved = $env:GH_TOKEN
            try {
                $env:GH_TOKEN = 'public-gh-token'
                Mock gh {
                    if ($args[0] -eq 'auth') {
                        $args | Should -Be @('auth', 'token', '--hostname', $Hostname, '--user', 'pilot-owner')
                        $env:GH_TOKEN | Should -BeNullOrEmpty
                        $global:LASTEXITCODE = 0
                        return 'named-account-token'
                    }
                    $args | Should -Be @('api', '--hostname', $Hostname, 'user')
                    [Environment]::GetEnvironmentVariable($TokenVariable) | Should -BeExactly 'named-account-token'
                    $global:LASTEXITCODE = 0
                    $Response
                }

                Invoke-GitHubHostGh -Hostname $Hostname -User pilot-owner -Arguments @('api', '--hostname', $Hostname, 'user') |
                    Should -BeExactly $Response

                $env:GH_TOKEN | Should -BeExactly 'public-gh-token'
            }
            finally { $env:GH_TOKEN = $saved }
        }
    }

    It 'preserves public-cloud environment credentials for the existing default behavior' {
        InModuleScope GitHubHost {
            $saved = $env:GH_TOKEN
            try {
                $env:GH_TOKEN = 'public-gh-token'
                Mock gh {
                    $env:GH_TOKEN | Should -BeExactly 'public-gh-token'
                    $global:LASTEXITCODE = 0
                    'public-result'
                }
                Invoke-GitHubHostGh -Hostname github.com -Arguments @('api', '--hostname', 'github.com', 'user') |
                    Should -BeExactly 'public-result'
            }
            finally { $env:GH_TOKEN = $saved }
        }
    }

    It 'uses only stdout when a named credential lookup succeeds with a stderr warning' {
        InModuleScope GitHubHost {
            Mock gh {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'auth') {
                    [System.Management.Automation.ErrorRecord]::new([Exception]::new('Credential expires soon'), 'warning', 'NotSpecified', $null)
                    return 'named-account-token'
                }
                $env:GH_TOKEN | Should -BeExactly 'named-account-token'
                'api-result'
            }

            Invoke-GitHubHostGh -Hostname example.ghe.com -User pilot-owner -Arguments @('api', '--hostname', 'example.ghe.com', 'user') |
                Should -BeExactly 'api-result'
        }
    }

    It 'restores all overrides after <Case> without running the requested API call' -ForEach @(
        @{ Case = 'a missing named account'; Code = 1; Value = 'authentication failed'; ExpectedError = '*No stored GitHub credential*' }
        @{ Case = 'an empty named credential'; Code = 0; Value = ' '; ExpectedError = '*credential*is empty*' }
    ) {
        InModuleScope GitHubHost -Parameters $_ {
            $names = @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')
            $saved = @{}
            foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, "original-$name") }
            try {
                Mock gh {
                    $args[0] | Should -BeExactly 'auth'
                    foreach ($name in $names) { [Environment]::GetEnvironmentVariable($name) | Should -BeNullOrEmpty }
                    $global:LASTEXITCODE = $Code
                    $Value
                }
                { Invoke-GitHubHostGh -Hostname example.ghe.com -User pilot-owner -Arguments @('api', '--hostname', 'example.ghe.com', 'user') } |
                    Should -Throw $ExpectedError
                foreach ($name in $names) { [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "original-$name" }
                Should -Invoke gh -Times 1 -Exactly
            }
            finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
        }
    }

    It 'restores the environment when gh throws or exits unsuccessfully: <Case>' -ForEach @(
        @{ Case = 'exception'; Throws = $true }
        @{ Case = 'nonzero exit'; Throws = $false }
    ) {
        InModuleScope GitHubHost -Parameters $_ {
            $saved = $env:GH_TOKEN
            try {
                $env:GH_TOKEN = 'public-gh-token'
                Mock gh {
                    if ($Throws) { throw 'native launch failed' }
                    $global:LASTEXITCODE = 1
                    [System.Management.Automation.ErrorRecord]::new([Exception]::new('HTTP 403'), 'gh', 'NotSpecified', $null)
                }
                { Invoke-GitHubHostGh -Hostname example.ghe.com -Arguments @('api', '--hostname', 'example.ghe.com', 'user') } |
                    Should -Throw
                $env:GH_TOKEN | Should -BeExactly 'public-gh-token'
            }
            finally { $env:GH_TOKEN = $saved }
        }
    }
}
