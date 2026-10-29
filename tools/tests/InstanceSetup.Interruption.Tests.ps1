BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    # Global so that the stub running inside InModuleScope InstanceSetup can reach the harness and the fixtures.
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force -Global
    $shard = Get-InterruptionShard
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force -Global
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $modulesPath = Join-Path $PSScriptRoot 'fixtures/runner-modules'
    Import-Module (Join-Path $repoRoot 'tools/InstanceSetup.psm1') -Force
    InModuleScope InstanceSetup -Parameters @{ Root = $repoRoot } {
        param($Root)
        Import-Module (Join-Path $Root 'tools/PlatformTools.psm1') -Force
    }
}

Describe 'Instance setup interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $plan = Get-InterruptionPlan
        $stub = @{ Plan = $plan }
        InModuleScope InstanceSetup -Parameters @{ Stub = $stub } {
            param($Stub)
            $script:InterruptionStub = $Stub
            Mock Confirm-SetupAction { $true }
            Mock Add-SetupGitHubScope {}
            Mock Start-Sleep {}
            Mock Show-SetupMessage {}
            Mock Show-SetupGuidance {}
            Mock Get-Date { [datetime]::new(2026, 10, 21, 12, 0, 0, [DateTimeKind]::Utc) }
            # The documented user action after the organization creation: sign in again, which grants the
            # OAuth token SSO access to every organization that exists at that time.
            Mock Invoke-SetupGitHubLogin { foreach ($org in $script:InterruptionStub.Orgs.Values) { $org.Authorized = $true } }
            Mock Get-SetupProbeApp { @{ AppId = '301'; InstallationId = '401'; Slug = 'platform-probe-admin'; KeyPath = 'probe-admin.pem' } }
            Mock Get-SetupInstallationToken { 'ghs_probe' }
            Mock Revoke-SetupInstallationToken {}
            Mock Invoke-WebRequest {
                param([uri] $Uri, [string] $Method = 'GET', [string] $Body, [hashtable] $Headers)
                $null = $Headers
                $S = $script:InterruptionStub
                $Method = $Method.ToUpperInvariant()
                $path = $Uri.AbsolutePath
                $data = if ($Body) { ConvertFrom-Json -InputObject $Body -AsHashtable } else { @{} }
                $respond = {
                    param([int] $Code, $Value)
                    $content = if ($null -ne $Value) { ConvertTo-Json -InputObject $Value -Depth 20 -Compress } else { '' }
                    [pscustomobject]@{ StatusCode = $Code; Content = $content; Headers = @{} }
                }
                $notFound = { & $respond 404 @{ message = 'Not Found' } }
                # Ruleset responses come from the documented examples; only the stored fields replace the example values.
                $rulesetBody = {
                    param([string] $Fixture, [hashtable] $Ruleset, [string] $Prefix = '')
                    $set = @{ "${Prefix}id" = $Ruleset.id; "${Prefix}name" = $Ruleset.name; "${Prefix}source" = $Ruleset.org; "${Prefix}enforcement" = $Ruleset.enforcement }
                    if (-not $Prefix) {
                        foreach ($field in @('target', 'bypass_actors', 'conditions', 'rules')) { if ($Ruleset.ContainsKey($field)) { $set[$field] = $Ruleset[$field] } }
                    }
                    $body = Get-GitHubApiFixture -Name $Fixture -Set $set
                    if ($Prefix) { return , $body[0] }
                    return , $body
                }
                # https://docs.github.com/enterprise-cloud@latest/rest/orgs/orgs#get-an-organization
                # https://docs.github.com/enterprise-cloud@latest/rest/repos/repos#create-an-organization-repository (201, 422)
                # https://docs.github.com/enterprise-cloud@latest/rest/teams/teams#create-a-team (201, 422)
                # https://docs.github.com/enterprise-cloud@latest/rest/teams/members#add-or-update-team-membership-for-a-user (200)
                # https://docs.github.com/enterprise-cloud@latest/rest/orgs/rules (201, 204, 404, 422)
                # https://docs.github.com/enterprise-cloud@latest/graphql/reference/mutations#createenterpriseorganization
                $apply = {
                    if ($path -cmatch '^/(?:orgs|repos)/([^/]+)') {
                        $org = $S.Orgs[$Matches[1]]
                        if ($null -eq $org) { return & $notFound }
                        if ($Headers.Authorization -like '* gho_*' -and -not $org.Authorized) {
                            return & $respond 403 @{ message = 'Resource protected by organization SAML enforcement. You must grant your OAuth token access to this organization.' }
                        }
                    }
                    switch -Regex -CaseSensitive ("$Method $path") {
                        '^GET /user$' { return & $respond 200 (Get-GitHubApiFixture -Name users/get-authenticated-user.private-user -Set @{ login = 'owner' }) }
                        '^POST /graphql$' {
                            if ($data.query -cnotlike '*createEnterpriseOrganization*') { throw "Unexpected GraphQL request: $($data.query)" }
                            $login = $data.variables.input.login
                            if ($S.Orgs.ContainsKey($login)) {
                                return & $respond 200 @{ data = @{ createEnterpriseOrganization = $null }; errors = @(@{ type = 'UNPROCESSABLE'; message = 'Login has already been taken' }) }
                            }
                            $S.Orgs[$login] = @{ Authorized = $false }
                            return & $respond 200 @{ data = @{ createEnterpriseOrganization = @{ organization = @{ login = $login } } } }
                        }
                        '^GET /orgs/([^/]+)$' { return & $respond 200 (Get-GitHubApiFixture -Name orgs/get -Set @{ login = $Matches[1] }) }
                        '^GET /repos/([^/]+)/([^/]+)$' {
                            if (-not $S.Repos.ContainsKey("$($Matches[1])/$($Matches[2])")) { return & $notFound }
                            return & $respond 200 (Get-GitHubApiFixture -Name repos/get -Set @{
                                name = $Matches[2]; full_name = "$($Matches[1])/$($Matches[2])"
                                'owner.login' = $Matches[1]; private = $S.Repos["$($Matches[1])/$($Matches[2])"].private
                            })
                        }
                        '^POST /orgs/([^/]+)/repos$' {
                            $key = "$($Matches[1])/$($data.name)"
                            if ($S.Repos.ContainsKey($key)) { return & $respond 422 @{ message = 'Repository creation failed.' } }
                            $S.Repos[$key] = @{ private = $data.private }
                            return & $respond 201 (Get-GitHubApiFixture -Name repos/create-in-org -Set @{
                                name = $data.name; full_name = $key; 'owner.login' = $Matches[1]; private = $data.private
                            })
                        }
                        '^GET /orgs/([^/]+)/teams/([^/]+)$' {
                            if (-not $S.Teams.ContainsKey("$($Matches[1])/$($Matches[2])")) { return & $notFound }
                            return & $respond 200 (Get-GitHubApiFixture -Name teams/get-by-name -Set @{
                                name = $Matches[2]; slug = $Matches[2]; 'organization.login' = $Matches[1]
                                privacy = $S.Teams["$($Matches[1])/$($Matches[2])"].privacy
                            })
                        }
                        '^POST /orgs/([^/]+)/teams$' {
                            $key = "$($Matches[1])/$($data.name)"
                            if ($S.Teams.ContainsKey($key)) { return & $respond 422 @{ message = 'Validation Failed' } }
                            $S.Teams[$key] = @{ privacy = $data.privacy }
                            return & $respond 201 (Get-GitHubApiFixture -Name teams/create -Set @{
                                name = $data.name; slug = $data.name; 'organization.login' = $Matches[1]; privacy = $data.privacy
                            })
                        }
                        '^(GET|PUT) /orgs/([^/]+)/teams/([^/]+)/memberships/([^/]+)$' {
                            if (-not $S.Teams.ContainsKey("$($Matches[2])/$($Matches[3])")) { return & $notFound }
                            $key = "$($Matches[2])/$($Matches[3])/$($Matches[4])"
                            if ($Matches[1] -ceq 'PUT') { $S.Memberships[$key] = $data.role }
                            if (-not $S.Memberships.ContainsKey($key)) { return & $notFound }
                            return & $respond 200 (Get-GitHubApiFixture -Name teams/get-membership-for-user-in-org -Set @{
                                role = $S.Memberships[$key]; state = 'active'
                            })
                        }
                        '^GET /orgs/[^/]+/actions/permissions$' { return & $respond 200 (Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization) }
                        '^GET /orgs/[^/]+/code-security/configurations$' { return & $respond 200 @() }
                        '^GET /orgs/([^/]+)/rulesets$' {
                            $org = $Matches[1]
                            return & $respond 200 @($S.Rulesets.Values | Where-Object { $_.org -ceq $org } | Sort-Object id | ForEach-Object { & $rulesetBody 'repos/get-org-rulesets' $_ '0.' })
                        }
                        '^POST /orgs/([^/]+)/rulesets$' {
                            $org = $Matches[1]
                            if (@($S.Rulesets.Values | Where-Object { $_.org -ceq $org -and $_.name -ceq $data.name }).Count) {
                                return & $respond 422 @{ message = 'Validation Failed'; errors = @('Name must be unique') }
                            }
                            $S.NextRuleset++
                            $ruleset = @{} + $data
                            $ruleset.id = $S.NextRuleset
                            $ruleset.org = $org
                            $S.Rulesets[[string] $ruleset.id] = $ruleset
                            return & $respond 201 (& $rulesetBody 'repos/create-org-ruleset' $ruleset)
                        }
                        '^(GET|DELETE) /orgs/[^/]+/rulesets/([0-9]+)$' {
                            if (-not $S.Rulesets.ContainsKey($Matches[2])) { return & $notFound }
                            if ($Matches[1] -ceq 'DELETE') {
                                $S.Rulesets.Remove($Matches[2])
                                return & $respond 204 $null
                            }
                            return & $respond 200 (& $rulesetBody 'repos/get-org-ruleset' $S.Rulesets[$Matches[2]])
                        }
                    }
                    throw "Unexpected request $Method $path"
                }
                if ($Method -ceq 'GET') { return & $apply }
                Invoke-InterruptionStep -Plan $S.Plan -Request "$Method $path" -Apply $apply -Interrupt {
                    & $respond 503 @{ message = 'Injected interruption.' }
                }
            }
        }
        $reset = {
            $stub.Orgs = @{}
            $stub.Repos = @{}
            $stub.Teams = @{}
            $stub.Memberships = @{}
            $stub.Rulesets = @{}
            $stub.NextRuleset = 0
            if (Test-Path -LiteralPath $work) { Remove-Item -LiteralPath $work -Recurse -Force }
        }
        # Every run starts a new wizard process: it reads setup-state.json and signs in with the stored gh token.
        $run = {
            InModuleScope InstanceSetup -Parameters @{ Root = $repoRoot; Work = $work; Modules = $modulesPath } {
                param($Root, $Work, $Modules)
                $setup = Initialize-SetupContext -RepoPath $Root -WorkPath $Work -ModulesPath $Modules
                $setup.Settings = @{ enterprise = 'example'; githubHost = 'example.ghe.com' }
                $setup.Facts.Upn = 'owner@contoso.test'
                $setup.Facts.Login = 'owner'
                $setup.Facts.EnterpriseId = 'E_example'
                $setup.GitHubToken = 'gho_setup'
                $null = Invoke-StepProbeOrg -Setup $setup
                $null = Invoke-StepProbeAdmin -Setup $setup
            }
        }
        $statePath = Join-Path $work 'setup-state.json'
        $captureLocal = { if (Test-Path -LiteralPath $statePath) { [IO.File]::ReadAllText($statePath) } }.GetNewClosure()
        $restoreLocal = {
            param($Text)
            if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
            if ($null -ne $Text) { [IO.File]::WriteAllText($statePath, $Text) }
        }
        $snapshot = {
            $statePath = Join-Path $work 'setup-state.json'
            $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable } else { @{ probe = $null } }
            @{
                probe = $state['probe']
                orgs = @($stub.Orgs.Keys | Sort-Object)
                repos = $stub.Repos; teams = $stub.Teams; memberships = $stub.Memberships
                # Ruleset IDs differ when an interrupted run created and deleted a ruleset; compare the names.
                rulesets = @($stub.Rulesets.Values | ForEach-Object { "$($_.org)/$($_.name)" } | Sort-Object)
            }
        }
    }

    It 'recovers from an interruption at every mutating step of the probe organization and organization API probe' {
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'InstanceSetup.psm1 (ProbeOrg, ProbeAdmin)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
