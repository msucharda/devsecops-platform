BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'CodeSecurityStub.psm1') -Force
    $scriptRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline/scripts'
    Import-Module (Join-Path $scriptRoot 'CodeSecurity.psm1') -Force

    $apiUrl = 'https://api.example.ghe.com'
    $token = 'test-installation-token'

    function Get-TestConfiguration {
        [ordered]@{
            advanced_security                        = 'enabled'
            dependency_graph                         = 'enabled'
            dependabot_alerts                        = 'enabled'
            dependabot_security_updates              = 'enabled'
            code_scanning_default_setup              = 'enabled'
            secret_scanning                          = 'enabled'
            secret_scanning_push_protection          = 'enabled'
            secret_scanning_validity_checks          = 'enabled'
            secret_scanning_delegated_bypass         = 'enabled'
            enforcement                              = 'enforced'
            name                                     = 'platform-baseline'
            description                              = 'Platform baseline managed by the enterprise-baseline module.'
            secret_scanning_delegated_bypass_options = @{ reviewers = @(@{ reviewer_type = 'TEAM'; reviewer_id = 5678; mode = 'ALWAYS' }) }
        }
    }

    function Get-TestPattern {
        param([string] $Pattern = 'plat_[A-Za-z0-9]{32}')
        @{ name = 'Platform token'; pattern = $Pattern; start_delimiter = '\A|[^0-9A-Za-z]'; end_delimiter = '\z|[^0-9A-Za-z]' }
    }

    function Edit-TestBypassMode {
        param([AllowNull()][object] $Mode)
        Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)
        $reviewer = ($stub.Configurations | Where-Object { $_['name'] -ceq 'platform-baseline' })['secret_scanning_delegated_bypass_options']['reviewers'][0]
        $reviewer['mode'] = $Mode
    }
    function Get-StubWrite {
        param([string] $Method, [string] $PathPattern)
        @($stub.Bodies | Where-Object { $_.Method -ceq $Method -and $_.Path -cmatch $PathPattern })
    }
}

Describe 'CodeSecurity module against the documented GitHub API' {
    BeforeEach {
        $env:REST_API_BEARER = $token
        $stub = Initialize-CodeSecurityStub -Organization demo -Origin $apiUrl -Token $token
        Mock -ModuleName CodeSecurity Start-Sleep {}
        Mock -ModuleName CodeSecurity Invoke-WebRequest {
            $target = [Uri] $Uri
            "$($target.Scheme)://$($target.Authority)" | Should -Be $apiUrl
            $reply = Invoke-CodeSecurityStubRequest -State $stub -Method ([string] $Method).ToUpperInvariant() -PathAndQuery $target.PathAndQuery -Headers $Headers -Body (Get-Variable -Name Body -ValueOnly -ErrorAction Ignore)
            if ($reply.Drop) { throw 'The connection was closed before the response arrived.' }
            [pscustomobject]@{ StatusCode = $reply.Status; Content = $reply.Body; Headers = @{ Link = $reply.Link } }
        }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    Context 'Invoke-CodeSecurityApi' {
        It 'refuses an API URL that is not an HTTPS origin' -ForEach @(
            @{ Url = 'http://api.example.ghe.com' }
            @{ Url = 'https://api.example.ghe.com/api/v3' }
            @{ Url = 'https://user@api.example.ghe.com' }
            @{ Url = 'https://api.example.ghe.com/?x=1' }
            @{ Url = 'api.example.ghe.com' }
        ) {
            { Invoke-CodeSecurityApi -ApiUrl $Url -Method GET -Path '/orgs/demo/code-security/configurations' } | Should -Throw '*HTTPS origin*'
            Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 0 -Exactly
        }

        It 'accepts plain HTTP only for a loopback stub' {
            InModuleScope CodeSecurity { { Assert-CodeSecurityApiUrl -ApiUrl 'http://127.0.0.1:8080' } | Should -Not -Throw }
        }

        It 'refuses to call GitHub without the installation token' {
            Remove-Item Env:\REST_API_BEARER

            { Invoke-CodeSecurityApi -ApiUrl $apiUrl -Method GET -Path '/orgs/demo/code-security/configurations' } | Should -Throw '*REST_API_BEARER*'
            Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 0 -Exactly
        }

        It 'sends the installation token and the API version' {
            $env:REST_API_BEARER = 'another-token'

            { Invoke-CodeSecurityApi -ApiUrl $apiUrl -Method GET -Path '/orgs/demo/code-security/configurations' } | Should -Throw '*HTTP 401*'
        }

        It 'follows pagination links on the API origin' {
            $stub.PageSize = 1
            $stub.Configurations.Add((Get-GitHubApiFixture -Name code-security/get-configuration -Set @{ id = 9; name = 'other' }))

            $items = Invoke-CodeSecurityApi -ApiUrl $apiUrl -Method GET -AllPages -Path '/orgs/demo/code-security/configurations?target_type=all&per_page=100'

            @($items | ForEach-Object { $_['id'] }) | Should -Be @(17, 9)
        }

        It 'refuses a pagination link to another origin' {
            Mock -ModuleName CodeSecurity Invoke-WebRequest {
                [pscustomobject]@{ StatusCode = 200; Content = '[]'; Headers = @{ Link = '<https://attacker.example/orgs/demo?after=1>; rel="next"' } }
            }

            { Invoke-CodeSecurityApi -ApiUrl $apiUrl -Method GET -AllPages -Path '/orgs/demo/code-security/configurations' } | Should -Throw '*outside*'
        }

        It 'refuses a paginated response that is not a JSON array' {
            Mock -ModuleName CodeSecurity Invoke-WebRequest { [pscustomobject]@{ StatusCode = 200; Content = '{}'; Headers = @{} } }

            { Invoke-CodeSecurityApi -ApiUrl $apiUrl -Method GET -AllPages -Path '/orgs/demo/code-security/configurations' } | Should -Throw '*no JSON array*'
        }

        It 'fails on an error status and returns nothing for 404 only when allowed' {
            { Invoke-CodeSecurityApi -ApiUrl $apiUrl -Method GET -Path '/orgs/demo/code-security/configurations/1' } | Should -Throw '*HTTP 404*'
            Invoke-CodeSecurityApi -ApiUrl $apiUrl -Method GET -Path '/orgs/demo/code-security/configurations/1' -AllowNotFound | Should -BeNullOrEmpty
        }
    }

    Context 'Set-CodeSecurityConfiguration' {
        It 'creates the configuration, makes it the default for all new repositories and attaches it to all repositories' {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            $created = @($stub.Configurations | Where-Object { $_['name'] -ceq 'platform-baseline' })
            $created.Count | Should -Be 1
            $created[0]['target_type'] | Should -Be 'organization'
            $stub.Defaults.public | Should -Be $created[0]['id']
            $stub.Defaults.private_and_internal | Should -Be $created[0]['id']
            @($stub.Repositories.Values | Where-Object { $_.configuration -ne $created[0]['id'] -or $_.status -cne 'attached' }) | Should -BeNullOrEmpty
            (Get-StubWrite PUT '/defaults$')[0].Body['default_for_new_repos'] | Should -Be 'all'
            (Get-StubWrite POST '/attach$')[0].Body['scope'] | Should -Be 'all'
        }

        It 'sends only documented request properties' {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            foreach ($case in @(
                    @{ Method = 'POST'; Path = '/configurations$'; Fixture = 'code-security/create-configuration' }
                    @{ Method = 'PATCH'; Path = '/configurations/[0-9]+$'; Fixture = 'code-security/update-configuration' }
                    @{ Method = 'PUT'; Path = '/defaults$'; Fixture = 'code-security/set-configuration-as-default' })) {
                $documented = (Get-GitHubApiFixtureContract -Name $case.Fixture).requestProperties
                $writes = Get-StubWrite $case.Method $case.Path
                $writes | Should -Not -BeNullOrEmpty
                foreach ($write in $writes) { foreach ($key in $write.Body.Keys) { $documented | Should -Contain $key } }
            }
        }

        It 'updates an existing configuration by name instead of creating another' {
            $existing = Get-GitHubApiFixture -Name code-security/get-configuration -Set @{ id = 42; name = 'platform-baseline'; secret_scanning = 'disabled' }
            $stub.Configurations.Add($existing)

            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            Get-StubWrite POST '/configurations$' | Should -BeNullOrEmpty
            (Get-StubWrite PATCH '/configurations/42$').Count | Should -Be 1
            $existing['secret_scanning'] | Should -Be 'enabled'
            $stub.Defaults.public | Should -Be 42
        }

        It 'accepts the documented 204 response of an update without changes' {
            $stub.PatchReturnsNoContent = $true
            $stub.Configurations.Add((Get-GitHubApiFixture -Name code-security/get-configuration -Set @{ id = 42; name = 'platform-baseline' }))

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) } | Should -Not -Throw
            $stub.Defaults.public | Should -Be 42
        }

        It 'does not adopt a global configuration with the managed name' {
            $stub.Configurations[0]['name'] = 'platform-baseline'

            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            (Get-StubWrite POST '/configurations$').Count | Should -Be 1
            Get-StubWrite PATCH '/configurations/17$' | Should -BeNullOrEmpty
        }

        It 'refuses two organization configurations with the managed name' {
            foreach ($id in 42, 43) {
                $stub.Configurations.Add((Get-GitHubApiFixture -Name code-security/get-configuration -Set @{ id = $id; name = 'platform-baseline' }))
            }

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) } | Should -Throw '*2 code security configurations*'
            Get-StubWrite PATCH '.' | Should -BeNullOrEmpty
        }

        It 'converges without a duplicate when the create response is lost' {
            $stub.DropNext = '^POST .*/code-security/configurations$'

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) } | Should -Throw
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            @($stub.Configurations | Where-Object { $_['name'] -ceq 'platform-baseline' }).Count | Should -Be 1
            $stub.Defaults.public | Should -Not -BeNullOrEmpty
            @($stub.Repositories.Values | Where-Object { $_.status -cne 'attached' }) | Should -BeNullOrEmpty
        }

        It 'converges when the attach response is lost' {
            $stub.DropNext = '^POST .*/attach$'

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) } | Should -Throw
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            @($stub.Configurations | Where-Object { $_['name'] -ceq 'platform-baseline' }).Count | Should -Be 1
            @($stub.Repositories.Values | Where-Object { $_.status -cne 'attached' }) | Should -BeNullOrEmpty
        }

        It 'converges when the run stops after the default is set and before the attach' {
            $stub.DropNext = '^PUT .*/defaults$'

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) } | Should -Throw
            $stub.Defaults.public | Should -Not -BeNullOrEmpty
            Get-StubWrite POST '/attach$' | Should -BeNullOrEmpty
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            @($stub.Repositories.Values | Where-Object { $_.status -cne 'attached' }) | Should -BeNullOrEmpty
        }

        It 'fails when an attachment ends as <Status> and converges on the next run' -ForEach @(
            @{ Status = 'failed' }, @{ Status = 'detached' }, @{ Status = 'removed' }, @{ Status = 'removed_by_enterprise' }, @{ Status = 'enterprise_enforced' }
        ) {
            $stub.AttachStatus = $Status

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) } |
                Should -Throw "*did not attach to: demo/app ($Status), demo/lib ($Status)*"
            $stub.AttachStatus = 'attached'
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            @($stub.Repositories.Values | Where-Object { $_.status -cne 'attached' }) | Should -BeNullOrEmpty
        }

        It 'accepts an attachment that ends as enforced' {
            $stub.AttachStatus = 'enforced'

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) } | Should -Not -Throw
        }

        It 'fails when the attach leaves a repository of the installation without the configuration' {
            $stub.AttachSkip = @('demo/lib')

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) } |
                Should -Throw '*is not attached to: demo/lib.'
        }

        It 'waits until no repository is attaching' {
            $stub.AttachPendingReads = 2

            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) -AttachmentIntervalSeconds 0

            Should -Invoke -ModuleName CodeSecurity Start-Sleep -Times 2 -Exactly
            @($stub.Repositories.Values | Where-Object { $_.status -cne 'attached' }) | Should -BeNullOrEmpty
        }

        It 'fails when repositories are still attaching at the timeout' {
            $stub.AttachPendingReads = 1000

            { Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration) -AttachmentTimeoutSeconds 0 } |
                Should -Throw '*still has 2 repositories attaching*'
        }
    }

    Context 'Remove-CodeSecurityConfiguration' {
        It 'removes the default role and deletes the configuration' {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            Remove-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Name platform-baseline

            @($stub.Configurations | Where-Object { $_['name'] -ceq 'platform-baseline' }) | Should -BeNullOrEmpty
            $stub.Defaults.public | Should -BeNullOrEmpty
            (Get-StubWrite PUT '/defaults$')[-1].Body['default_for_new_repos'] | Should -Be 'none'
            @($stub.Configurations | Where-Object { $_['target_type'] -ceq 'global' }).Count | Should -Be 1
        }

        It 'treats a missing configuration as removed' {
            Remove-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Name platform-baseline

            @($stub.Bodies | Where-Object { $_.Method -cne 'GET' }) | Should -BeNullOrEmpty
        }

        It 'can be repeated when the delete response is lost' {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)
            $stub.DropNext = '^DELETE '

            { Remove-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Name platform-baseline } | Should -Throw
            { Remove-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Name platform-baseline } | Should -Not -Throw
            @($stub.Configurations | Where-Object { $_['name'] -ceq 'platform-baseline' }) | Should -BeNullOrEmpty
        }
    }

    Context 'Set-CustomPattern' {
        It 'creates the pattern with documented fields and enables push protection by token type' {
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)

            $stub.Patterns.Count | Should -Be 1
            $stub.Patterns[0]['push_protection_enabled'] | Should -BeTrue
            $create = (Get-StubWrite POST '/custom-patterns$')[0].Body
            @($create.Keys) | Should -Be @('patterns')
            $create['patterns'][0]['name'] | Should -Be 'Platform token'
            $create['patterns'][0]['start_delimiter'] | Should -Be '\A|[^0-9A-Za-z]'
            $setting = (Get-StubWrite PATCH '/pattern-configurations$')[0].Body
            $documented = (Get-GitHubApiFixtureContract -Name secret-scanning/update-org-pattern-configs).requestProperties
            foreach ($key in $setting.Keys) { $documented | Should -Contain $key }
            $setting['custom_pattern_settings'][0]['token_type'] | Should -Be "cp_$($stub.Patterns[0]['id'])"
            $setting['custom_pattern_settings'][0]['push_protection_setting'] | Should -Be 'enabled'
        }

        It 'writes nothing when the pattern matches and push protection is enabled' {
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
            $stub.Bodies.Clear()

            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)

            @($stub.Bodies | Where-Object { $_.Method -cne 'GET' }) | Should -BeNullOrEmpty
        }

        It 'treats documented null delimiters as the defaults' {
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
            $stub.Patterns[0]['start_delimiter'] = $null
            $stub.Patterns[0]['end_delimiter'] = $null
            $stub.Bodies.Clear()

            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)

            Get-StubWrite PATCH '/custom-patterns/' | Should -BeNullOrEmpty
        }

        It 'updates a changed pattern with the version from <Source>' -ForEach @(
            @{ Source = 'the pattern configuration'; IncludePatternVersion = $false }
            @{ Source = 'the pattern list'; IncludePatternVersion = $true }
        ) {
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
            $stub.IncludePatternVersion = $IncludePatternVersion

            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern -Pattern 'plat_[a-z]{40}')

            $stub.Patterns.Count | Should -Be 1
            $stub.Patterns[0]['pattern'] | Should -Be 'plat_[a-z]{40}'
            $update = (Get-StubWrite PATCH '/custom-patterns/[0-9]+$')[0].Body
            $documented = (Get-GitHubApiFixtureContract -Name secret-scanning/update-org-custom-pattern).requestProperties
            foreach ($key in $update.Keys) { $documented | Should -Contain $key }
            @($update['must_match']).Count | Should -Be 0
        }

        It 'enables push protection that someone disabled' {
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
            $stub.Patterns[0]['push_protection_enabled'] = $false

            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)

            $stub.Patterns[0]['push_protection_enabled'] | Should -BeTrue
        }

        It 'converges without a duplicate when the create response is lost' {
            $stub.DropNext = '^POST .*/custom-patterns$'

            { Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern) } | Should -Throw
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)

            $stub.Patterns.Count | Should -Be 1
            $stub.Patterns[0]['push_protection_enabled'] | Should -BeTrue
        }

        It 'converges when the run stops after the pattern is created and before push protection is enabled' {
            $stub.DropNext = '^GET .*/pattern-configurations$'

            { Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern) } | Should -Throw
            $stub.Patterns[0]['push_protection_enabled'] | Should -BeFalse
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)

            $stub.Patterns.Count | Should -Be 1
            $stub.Patterns[0]['push_protection_enabled'] | Should -BeTrue
        }

        It 'converges when the push protection response is lost' {
            $stub.DropNext = '^PATCH .*/pattern-configurations$'

            { Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern) } | Should -Throw
            $stub.Bodies.Clear()
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)

            $stub.Patterns[0]['push_protection_enabled'] | Should -BeTrue
            @($stub.Bodies | Where-Object { $_.Method -cne 'GET' }) | Should -BeNullOrEmpty
        }

        It 'fails when the pattern does not report push protection after it was enabled' {
            $stub.PushProtectionIgnored = $true

            { Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern) } | Should -Throw '*does not report push protection*'
        }

        It 'fails with a publish instruction when GitHub creates an unpublished pattern' {
            $stub.CreatedPatternState = 'unpublished'

            { Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern) } | Should -Throw "*state 'unpublished'*Publish*"
        }

        It 'fails when the pattern configuration has no setting for the pattern' {
            $stub.PatternConfigOverride = $false

            { Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern) } | Should -Throw '*no push protection setting*'
        }

        It 'refuses two patterns with the managed name' {
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
            $duplicate = @{} + $stub.Patterns[0]
            $duplicate['id'] = 999
            $stub.Patterns.Add($duplicate)

            { Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern) } | Should -Throw '*more than one custom pattern*'
        }

        It 'refuses a pattern without <Field>' -ForEach @(@{ Field = 'name' }, @{ Field = 'pattern' }) {
            $pattern = Get-TestPattern
            $pattern[$Field] = ''

            { Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern $pattern } | Should -Throw '*needs a name, a pattern*'
            Should -Invoke -ModuleName CodeSecurity Invoke-WebRequest -Times 0 -Exactly
        }
    }

    Context 'Remove-CustomPattern' {
        It 'deletes the pattern by ID and resolves its alerts' -ForEach @(@{ IncludePatternVersion = $false }, @{ IncludePatternVersion = $true }) {
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
            $id = $stub.Patterns[0]['id']
            $stub.IncludePatternVersion = $IncludePatternVersion

            Remove-CustomPattern -ApiUrl $apiUrl -Organization demo -Name 'Platform token'

            $stub.Patterns.Count | Should -Be 0
            $delete = (Get-StubWrite DELETE '/custom-patterns$')[0].Body
            $delete['post_delete_action'] | Should -Be 'resolve_alerts'
            $delete['patterns'][0]['pattern_id'] | Should -Be $id
            $delete['patterns'][0].Contains('custom_pattern_version') | Should -Be $IncludePatternVersion
        }

        It 'treats a missing pattern as removed' {
            Remove-CustomPattern -ApiUrl $apiUrl -Organization demo -Name 'Platform token'

            @($stub.Bodies | Where-Object { $_.Method -cne 'GET' }) | Should -BeNullOrEmpty
        }

        It 'can be repeated when the delete response is lost' {
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
            $stub.DropNext = '^DELETE '

            { Remove-CustomPattern -ApiUrl $apiUrl -Organization demo -Name 'Platform token' } | Should -Throw
            { Remove-CustomPattern -ApiUrl $apiUrl -Organization demo -Name 'Platform token' } | Should -Not -Throw
            $stub.Patterns.Count | Should -Be 0
        }
    }

    Context 'Get-CodeSecurityState' {
        It 'reports an organization without the managed objects' {
            $state = Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline

            $state.configuration | Should -BeNullOrEmpty
            @($state.defaults).Count | Should -Be 0
            @($state.repositories).Count | Should -Be 0
            @($state.foreign_attachments).Count | Should -Be 0
            @($state.uncovered_repositories) | Should -Be @('demo/app', 'demo/lib')
            $state.custom_patterns.Count | Should -Be 0
        }

        It 'reports no uncovered repository in an organization without repositories' {
            $stub.Repositories.Clear()
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            @((Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline).uncovered_repositories).Count | Should -Be 0
        }

        It 'reports a repository of the installation that <Case>' -ForEach @(
            @{ Case = 'has no configuration'; Break = { $stub.Repositories['demo/lib'].configuration = $null; $stub.Repositories['demo/lib'].status = $null } }
            @{ Case = 'has a failed attachment'; Break = { $stub.Repositories['demo/lib'].status = 'failed' } }
            @{ Case = 'is detached'; Break = { $stub.Repositories['demo/lib'].status = 'detached' } }
            @{ Case = 'is newer than the attach'; Break = { $stub.Repositories['demo/new'] = @{ id = 999; name = 'new'; configuration = $null; status = $null } } }
        ) {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)
            & $Break

            $state = Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline

            @($state.uncovered_repositories) | Should -HaveCount 1
        }

        It 'follows pagination of the installation repositories and accepts a response <Variant>' -ForEach @(
            @{ Variant = 'with repository_selection all'; Selection = 'all' }
            @{ Variant = 'without the optional repository_selection'; Selection = $null }
        ) {
            $stub.PageSize = 1
            $stub.RepositorySelection = $Selection
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)

            $state = Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline

            @($state.uncovered_repositories).Count | Should -Be 0
            @($stub.Requests | Where-Object { $_ -ceq 'GET /installation/repositories' }).Count | Should -BeGreaterThan 2
        }

        It 'reads a bypass reviewer <Case>' -ForEach @(
            @{ Case = 'without the optional mode as ALWAYS'; Remove = $true; Mode = $null; Expected = 'ALWAYS' }
            @{ Case = 'with mode EXEMPT'; Remove = $false; Mode = 'EXEMPT'; Expected = 'EXEMPT' }
        ) {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)
            $reviewer = ($stub.Configurations | Where-Object { $_['name'] -ceq 'platform-baseline' })['secret_scanning_delegated_bypass_options']['reviewers'][0]
            if ($Remove) { $reviewer.Remove('mode') } else { $reviewer['mode'] = $Mode }

            $state = Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline

            $state.configuration['secret_scanning_delegated_bypass_options']['reviewers'][0]['mode'] | Should -BeExactly $Expected
        }

        It 'reads the configuration, defaults, attachments and custom patterns' {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)
            Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
            $id = ($stub.Configurations | Where-Object { $_['name'] -ceq 'platform-baseline' })['id']

            $state = Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline

            $state.configuration['id'] | Should -Be $id
            $state.configuration['secret_scanning_delegated_bypass_options']['reviewers'][0]['reviewer_id'] | Should -Be 5678
            $state.defaults | Should -HaveCount 1
            $state.defaults[0].default_for_new_repos | Should -Be 'all'
            $state.defaults[0].configuration_id | Should -Be ([string] $id)
            @($state.repositories | ForEach-Object { "$($_.repository)=$($_.status)" }) | Should -Be @('demo/app=attached', 'demo/lib=attached')
            @($state.foreign_attachments).Count | Should -Be 0
            $state.custom_patterns['Platform token'].pattern | Should -Be 'plat_[A-Za-z0-9]{32}'
            $state.custom_patterns['Platform token'].state | Should -Be 'published'
            $state.custom_patterns['Platform token'].push_protection_enabled | Should -BeTrue
        }

        It 'reports repositories bound to another configuration' {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)
            $stub.Repositories['demo/lib'].configuration = 17
            $stub.Repositories['demo/lib'].status = 'enforced'

            $state = Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline

            $state.foreign_attachments | Should -HaveCount 1
            $state.foreign_attachments[0].configuration | Should -Be 'GitHub recommended'
            $state.foreign_attachments[0].repository | Should -Be 'demo/lib'
        }

        It 'ignores repositories that another configuration lists as <Status>' -ForEach @(@{ Status = 'detached' }, @{ Status = 'removed' }) {
            $stub.Repositories['demo/lib'].configuration = 17
            $stub.Repositories['demo/lib'].status = $Status

            $state = Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline

            @($state.foreign_attachments).Count | Should -Be 0
        }

        It 'reports separate defaults per visibility' {
            Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Configuration (Get-TestConfiguration)
            $stub.Defaults.public = 17

            $state = Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline

            @($state.defaults | ForEach-Object { "$($_.default_for_new_repos)=$($_.configuration_id)" }) |
                Should -Be @('public=17', "private_and_internal=$($stub.Defaults.private_and_internal)")
        }

        It 'fails when GitHub returns <Case>' -ForEach @(
            @{ Case = 'a configuration without ID'; Break = { $stub.Configurations[0]['id'] = $null }; Message = '*no valid ID*' }
            @{ Case = 'a foreign repository with an empty status'; Break = { $stub.Repositories['demo/lib'].configuration = 17; $stub.Repositories['demo/lib'].status = '' }; Message = "*unknown attachment status ''*" }
            @{ Case = 'a foreign repository with an unknown status'; Break = { $stub.Repositories['demo/lib'].configuration = 17; $stub.Repositories['demo/lib'].status = 'unknown' }; Message = "*unknown attachment status 'unknown'*" }
            @{ Case = 'a foreign repository with an upper-case status'; Break = { $stub.Repositories['demo/lib'].configuration = 17; $stub.Repositories['demo/lib'].status = 'ATTACHED' }; Message = "*unknown attachment status 'ATTACHED'*" }
            @{ Case = 'a bypass reviewer with null mode'; Break = { (Edit-TestBypassMode $null) }; Message = "*unknown bypass mode ''*" }
            @{ Case = 'a bypass reviewer with empty mode'; Break = { (Edit-TestBypassMode '') }; Message = "*unknown bypass mode ''*" }
            @{ Case = 'a bypass reviewer with lower-case mode'; Break = { (Edit-TestBypassMode 'always') }; Message = "*unknown bypass mode 'always'*" }
            @{ Case = 'installation repositories with selected access'; Break = { $stub.RepositorySelection = 'selected' }; Message = "*repository access 'selected'*" }
            @{ Case = 'a total_count that differs from the listed repositories'; Break = { $stub.TotalCountOffset = 1 }; Message = '*reported 3 repositories but listed 2*' }
            @{ Case = 'a pattern without name'; Break = { $stub.Patterns.Add(@{ id = 1; revision = 1; name = ''; pattern = 'x'; slug = 'x'; state = 'published'; push_protection_enabled = $true; start_delimiter = $null; end_delimiter = $null; must_match = $null; must_not_match = $null }) }; Message = '*without name*' }
        ) {
            & $Break

            { Get-CodeSecurityState -ApiUrl $apiUrl -Organization demo -ConfigurationName platform-baseline } | Should -Throw $Message
        }
    }
}
