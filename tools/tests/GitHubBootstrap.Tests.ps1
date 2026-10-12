BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $tools = Split-Path $PSScriptRoot -Parent
    $bootstrap = Join-Path $tools 'Invoke-GitHubBootstrap.ps1'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()
}

Describe 'GitHub bootstrap public interface' {
    BeforeEach {
        $savedTokens = @{}
        foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
            $savedTokens[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $casePath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $release = Join-Path $casePath 'release'
        New-Item -ItemType Directory -Path $release -Force | Out-Null
        Copy-Item -LiteralPath (Join-Path (Split-Path $tools -Parent) 'templates') -Destination $release -Recurse
        Copy-Item -LiteralPath (Join-Path (Split-Path $tools -Parent) 'schemas') -Destination $release -Recurse
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/modules') -Destination (Join-Path $release 'modules') -Recurse
        $releaseTools = New-Item -ItemType Directory -Path (Join-Path $release 'tools')
        Get-ChildItem -LiteralPath $tools -File | Copy-Item -Destination $releaseTools.FullName
        & (Join-Path $releaseTools.FullName 'Generate-DeploymentWorkflow.ps1') -ModulesPath (Join-Path $release 'modules') `
            -OutputPath (Join-Path $release 'templates/instance/.github/workflows/deploy.yml')
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ application = @{} }
        $instance.bootstrap = @{
            tenantId = '11111111-1111-1111-1111-111111111111'
            managementSubscriptionId = '22222222-2222-2222-2222-222222222222'
            subscriptionIds = @('22222222-2222-2222-2222-222222222222')
            enterpriseApplicationObjectId = '33333333-3333-3333-3333-333333333333'
            githubHost = 'example.ghe.com'; enterprise = 'example'
        }
        $instance.githubApps = @{ authorization = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }; resources = @{ organizations = @('demo-platform'); repositories = @{} }
        } }
        $instancePath = Join-Path $casePath 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $keyPath = Join-Path $casePath 'authorization.pem'
        $privateKey | Set-Content -LiteralPath $keyPath
        $keysPath = Join-Path $casePath 'keys.json'
        @{ authorization = @{ privateKeyPath = $keyPath; owner = 'platform'
            createdAt = [DateTimeOffset]::UtcNow.ToString('o')
            rotateBy = [DateTimeOffset]::UtcNow.AddDays(89).ToString('o')
        } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $keysPath
        $azure = @{
            TenantId = $instance.bootstrap.tenantId; SubscriptionId = $instance.bootstrap.managementSubscriptionId
            ResourceGroupName = 'rg-demo-bootstrap'; StorageAccountName = 'stdemotfstate'
            Modules = @('application', 'foundation' | ForEach-Object {
                @{
                    Name = $_
                    Plan = @{ ResourceId = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-demo-bootstrap/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-demo-$_-plan"; ClientId = '44444444-4444-4444-4444-444444444444' }
                    Apply = @{ ResourceId = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-demo-bootstrap/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-demo-$_-apply"; ClientId = '55555555-5555-5555-5555-555555555555' }
                }
            })
        }
        $inventory = Join-Path $casePath 'bootstrap-resources.json'
        $arguments = @{
            InstancePath = $instancePath; AzureBootstrap = $azure
            ReleasePath = $release; ReleaseVersion = '1.0.0'; InventoryPath = $inventory
            ResourcesOnly = $true
            AuthorizationApp = 'authorization'; AppKeysPath = $keysPath
        }
        $cloud = @{
            resources = @{}; writes = [Collections.Generic.List[object]]::new()
            environments = @{}; variables = @{}; branchRules = @{}
            blobs = @{}; tree = @(); commit = $null; secrets = @{}
            appOwner = @{ login = 'example'; type = 'enterprise' }
            appPermissions = @{ members = 'read'; metadata = 'read' }
            apps = @{}
            defaultBranch = 'main'; failPath = ''; rejectSecurityReview = $false
        }
        foreach ($module in $azure.Modules) {
            foreach ($phase in @('plan', 'apply')) {
                $cloud.resources[$module[$phase].ResourceId] = @{
                    properties = @{ clientId = $module[$phase].ClientId }
                    tags = @{ platformInstance = 'demo'; platformComponent = 'bootstrap'; platformModule = $module.Name; platformPhase = $phase }
                }
            }
        }
        Mock gh {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'secret') { 'encrypted-key' } else { 'gho_test' }
        }
        Mock az {
            $global:LASTEXITCODE = 0
            '{"tenant":"11111111-1111-1111-1111-111111111111","accessToken":"azure-test"}'
        }
        Mock Invoke-WebRequest {
            $path = $Uri.AbsolutePath
            $data = if ($Body) { ConvertFrom-Json -InputObject $Body -AsHashtable } else { @{} }
            $status = 200
            $reply = @{}
            if ($cloud.failPath -ceq $path -and $Method -ne 'GET') {
                $cloud.failPath = ''
                return [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption."}' }
            }
            if ($Method -ne 'GET' -and ($path -ne '/graphql' -or $data.query -like 'mutation*')) {
                $cloud.writes.Add(@{ method = $Method; path = $path; body = $data })
            }
            if ($path -eq '/graphql') {
                if ($data.query -like '*createEnterpriseOrganization*') {
                    $cloud.resources['/orgs/demo-platform'] = @{ login = 'demo-platform'; id = 10 }
                    $reply = @{ data = @{ createEnterpriseOrganization = @{ organization = @{ login = 'demo-platform' } } } }
                }
                else {
                    $reply = @{ data = @{ viewer = @{ login = 'owner_example' }; enterprise = @{
                        id = 'enterprise-node'; viewerIsAdmin = $true
                        organizations = @{ nodes = @(@{ login = 'demo-platform' }); pageInfo = @{ hasNextPage = $false } }
                    } } }
                }
            }
            elseif ($path -eq '/orgs/demo-platform/repos' -and $Method -eq 'POST') {
                $cloud.resources['/repos/demo-platform/instance'] = @{ id = 20; name = 'instance'; private = $true; default_branch = $cloud.defaultBranch; description = $data.description }
                $reply = $cloud.resources['/repos/demo-platform/instance']
                if ($data.auto_init) {
                    $cloud.resources["/repos/demo-platform/instance/git/ref/heads/$($cloud.defaultBranch)"] = @{ object = @{ sha = 'seed-sha' } }
                }
            }
            elseif ($path -eq '/orgs/demo-platform/teams' -and $Method -eq 'POST') {
                $reply = @{ id = $(if ($data.name -eq 'platform') { 30 } else { 31 }); slug = $data.name; description = $data.description }
                $cloud.resources["/orgs/demo-platform/teams/$($data.name)"] = $reply
            }
            elseif ($path -like '*/git/blobs' -and $Method -eq 'POST') {
                $sha = [Convert]::ToHexString([Security.Cryptography.SHA1]::HashData([Convert]::FromBase64String($data.content))).ToLowerInvariant()
                $cloud.blobs[$sha] = [Convert]::FromBase64String($data.content)
                $reply = @{ sha = $sha }
            }
            elseif ($path -like '*/git/trees' -and $Method -eq 'POST') {
                $cloud.tree = $data.tree
                $reply = @{ sha = 'tree-sha' }
            }
            elseif ($path -like '*/git/commits' -and $Method -eq 'POST') {
                $cloud.commit = $data
                $reply = @{ sha = 'commit-sha' }
            }
            elseif ($path -like '*/git/refs' -and $Method -eq 'POST') {
                $cloud.resources['/repos/demo-platform/instance/git/ref/heads/main'] = @{ object = @{ sha = $data.sha } }
                $reply = @{ ref = $data.ref }
            }
            elseif ($path -like '*/git/refs/heads/main' -and $Method -eq 'PATCH') {
                $cloud.resources['/repos/demo-platform/instance/git/ref/heads/main'] = @{ object = @{ sha = $data.sha } }
                $reply = @{ ref = 'refs/heads/main' }
            }
            elseif ($path -like '*/environments/*' -and $path -notlike '*/variables*' -and $path -notlike '*/secrets*' -and $path -notlike '*/deployment-branch-policies*') {
                if ($Method -eq 'PUT') {
                    $reviewers = @($data.reviewers | ForEach-Object { @{ type = $_.type; reviewer = @{ id = $_.id } } })
                    $rules = @()
                    if ($reviewers.Count) { $rules += @{ type = 'required_reviewers'; reviewers = $reviewers; prevent_self_review = $data.prevent_self_review } }
                    $rules += @{ type = 'branch_policy' }
                    $reply = @{ id = 40; protection_rules = $rules; deployment_branch_policy = $data.deployment_branch_policy; can_admins_bypass = $data.can_admins_bypass }
                    $cloud.environments[$path] = $reply
                }
                elseif ($cloud.environments.ContainsKey($path)) { $reply = $cloud.environments[$path] }
                else { $status = 404 }
            }
            elseif ($path -like '*/deployment-branch-policies') {
                if ($Method -eq 'POST') { $cloud.branchRules[$path] = @(@{ id = 50; name = $data.name; type = $data.type }) }
                $reply = @{ branch_policies = @() }
                if ($cloud.branchRules.ContainsKey($path)) { $reply.branch_policies = $cloud.branchRules[$path] }
            }
            elseif ($path -like '*/variables') {
                if ($Method -eq 'POST') { $cloud.variables["$path/$($data.name)"] = $data.value }
                $reply = @{ variables = @($cloud.variables.Keys | Where-Object { $_.StartsWith("$path/") } | ForEach-Object { @{ name = $_.Split('/')[-1]; value = $cloud.variables[$_] } }) }
            }
            elseif ($path -like '*/variables/*' -and $Method -eq 'PATCH') { $cloud.variables[$path] = $data.value }
            elseif ($path -like '*/secrets') {
                $reply = @{ secrets = @($cloud.secrets.Keys | Where-Object { $_.StartsWith("$path/") } | ForEach-Object { @{ name = $_.Split('/')[-1] } }) }
            }
            elseif ($path -like '*/secrets/PLATFORM_APP_PRIVATE_KEY' -and $Method -eq 'PUT') { $cloud.secrets[$path] = $data }
            elseif ($path -like '*/secrets/public-key') { $reply = @{ key_id = 'public-key-id'; key = 'public-key' } }
            elseif ($path -like '*/rulesets' -and $Method -eq 'GET') {
                $reply = @($cloud.resources.Keys | Where-Object { $_ -like "$path/*" } | ForEach-Object { $cloud.resources[$_] })
            }
            elseif ($path -like '*/rulesets' -and $Method -eq 'POST') {
                if ($cloud.rejectSecurityReview) {
                    ($data.rules | Where-Object { $_.type -eq 'pull_request' }).parameters.required_reviewers = @()
                }
                $reply = @{} + $data + @{ id = 60 }
                $cloud.resources["$path/60"] = $reply
            }
            elseif ($path -like '*/federatedIdentityCredentials' -and $Method -eq 'GET') {
                $reply = @{ value = @($cloud.resources.Keys | Where-Object { $_ -like "$path/*" } | ForEach-Object { $cloud.resources[$_] }) }
            }
            elseif ($path -like '*/teams/*/repos/*' -and $Method -eq 'GET') {
                if ($cloud.resources.ContainsKey($path)) { $reply = @{ permissions = @{ push = $true } } } else { $status = 404 }
            }
            elseif ($Method -in @('PUT', 'PATCH')) {
                $reply = @{} + $data
                if ($Method -eq 'PATCH' -and $cloud.resources.ContainsKey($path)) {
                    $reply = @{} + $cloud.resources[$path]
                    foreach ($key in $data.Keys) { $reply[$key] = $data[$key] }
                }
                if ($path -like '*/memberships/*') { $reply.state = 'active' }
                if ($path -like '*/federatedIdentityCredentials/*') { $reply.name = $path.Split('/')[-1] }
                $cloud.resources[$path] = $reply
            }
            elseif ($cloud.resources.ContainsKey($path)) { $reply = $cloud.resources[$path] }
            elseif ($path -like '*/contents/*') {
                $relative = $path.Split('/contents/')[1]
                $blob = $cloud.tree | Where-Object { $_.path -eq $relative }
                if ($blob) { $reply = @{ content = [Convert]::ToBase64String($cloud.blobs[$blob.sha]) } }
                else { $status = 404 }
            }
            else { $status = 404 }
            [pscustomobject]@{ StatusCode = $status; Content = (ConvertTo-Json -InputObject $reply -Depth 100 -Compress) }
        }
        Mock Invoke-RestMethod {
            if ($Uri -like '*/installation/token' -and $Method -eq 'DELETE') { return }
            if ($Uri -like '*/installation/repositories`?*') { return @{ repositories = @() } }
            if ($Uri -like '*/orgs/demo-platform/rulesets`?*') { return ,@(@{ id = 7 }) }
            if ($Uri -like '*/orgs/demo-platform/rulesets/7') { return @{ id = 7; bypass_actors = @(@{ actor_type = 'Team'; actor_id = 123; bypass_mode = 'pull_request' }) } }
            $segment = $Headers.Authorization.Split(' ')[1].Split('.')[1].Replace('-', '+').Replace('_', '/')
            $segment = $segment.PadRight($segment.Length + (4 - $segment.Length % 4) % 4, '=')
            $claims = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json -AsHashtable
            $appId = [string] $claims.iss
            $permissions = $cloud.appPermissions
            $installationId = 201
            $selection = 'selected'
            if ($cloud.apps.ContainsKey($appId)) {
                $permissions = $cloud.apps[$appId].permissions
                $installationId = [int] $cloud.apps[$appId].installationId
                $selection = 'all'
            }
            if ($Uri -like '*/app') { return @{ id = [int] $appId; owner = $cloud.appOwner; permissions = $permissions } }
            if ($Uri -like '*/app/installations`?*') {
                return ,@(@{ id = $installationId; account = @{ login = 'demo-platform' }; target_type = 'Organization'
                    suspended_at = $null; permissions = $permissions; repository_selection = $selection })
            }
            if ($Uri -like '*/access_tokens') { return @{ token = 'installation-test'; permissions = $permissions } }
            throw "Unexpected App request: $Method $Uri"
        }
    }

    AfterEach {
        foreach ($name in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTokens[$name]) }
    }

    It 'creates the instance repository with the exact release and both organization teams' {
        $arguments.ResourcesOnly = $false
        $result = & $bootstrap @arguments

        $result.Repository | Should -Be 'demo-platform/instance'
        $result.CredentialsConfigured | Should -BeTrue
        $cloud.resources['/orgs/demo-platform/teams/platform/memberships/owner_example'].state | Should -Be 'active'
        $cloud.resources['/orgs/demo-platform/teams/security/memberships/owner_example'].state | Should -Be 'active'
        $cloud.tree.path | Should -Contain 'platform/schemas/instance.schema.json'
        $codeowners = $cloud.tree | Where-Object { $_.path -eq '.github/CODEOWNERS' }
        [Text.Encoding]::UTF8.GetString($cloud.blobs[$codeowners.sha]) | Should -Be "* @demo-platform/platform`n"
        $rules = $cloud.resources['/repos/demo-platform/instance/rulesets/60']
        $rules.enforcement | Should -Be 'active'
        $rules.bypass_actors.Count | Should -Be 0
        $cloud.commit.parents | Should -Be @('seed-sha')
        ($rules.rules | Where-Object { $_.type -eq 'pull_request' }).parameters.required_reviewers[0].reviewer.id | Should -Be 31
        Test-Path -LiteralPath $inventory | Should -BeTrue
    }

    It 'binds each Azure phase only to its protected environments and keeps both teardown gates credential-free' {
        & $bootstrap @arguments | Out-Null

        $plan = $cloud.environments['/repos/demo-platform/instance/environments/application-plan']
        $drift = $cloud.environments['/repos/demo-platform/instance/environments/application-plan-drift']
        @($plan.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }).Count | Should -Be 0
        @($drift.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }).Count | Should -Be 0
        $cloud.branchRules['/repos/demo-platform/instance/environments/application-plan-drift/deployment-branch-policies'][0].name | Should -Be 'main'
        $federation = @($cloud.resources.Values | Where-Object { $_.Contains('properties') -and $_.properties.Contains('subject') })
        $federation.properties.subject | Should -Contain 'repo:demo-platform/instance:environment:application-plan'
        $federation.properties.subject | Should -Contain 'repo:demo-platform/instance:environment:application-plan-drift'
        $federation.properties.subject | Should -Contain 'repo:demo-platform/instance:environment:application-apply'
        @($federation | Where-Object { $_.properties.issuer -ne 'https://token.actions.example.ghe.com' }).Count | Should -Be 0
        $teardown = $cloud.environments['/repos/demo-platform/instance/environments/teardown']
        ($teardown.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }).reviewers[0].reviewer.id | Should -Be 31
        $platformGate = $cloud.environments['/repos/demo-platform/instance/environments/approve-teardown-platform']
        ($platformGate.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }).reviewers[0].reviewer.id | Should -Be 30
        @($federation | Where-Object { $_.properties.subject -like '*teardown*' }).Count | Should -Be 0
        @($cloud.variables.Keys | Where-Object { $_ -like '*teardown*' }).Count | Should -Be 0
    }

    It 'performs no resource writes on a second run and never overwrites instance contents' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $seed = ConvertTo-Json -InputObject $cloud.commit -Compress

        $result = & $bootstrap @arguments

        $result.HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
        (ConvertTo-Json -InputObject $cloud.commit -Compress) | Should -Be $seed
    }

    It 'verifies the authorization App before uploading an encrypted key and records its rotation deadline' {
        $instance.githubApps = @{ authorization = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }; resources = @{ organizations = @('demo-platform'); repositories = @{} }
        } }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $keyPath = Join-Path $casePath 'authorization.pem'
        $privateKey | Set-Content -LiteralPath $keyPath
        $keysPath = Join-Path $casePath 'keys.json'
        @{ authorization = @{ privateKeyPath = $keyPath; owner = 'platform'
            createdAt = [DateTimeOffset]::UtcNow.ToString('o')
            rotateBy = [DateTimeOffset]::UtcNow.AddDays(89).ToString('o')
        } } | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $keysPath
        $arguments.ResourcesOnly = $false
        $arguments.AuthorizationApp = 'authorization'
        $arguments.AppKeysPath = $keysPath

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        $cloud.secrets['/repos/demo-platform/instance/environments/pr-authorization/secrets/PLATFORM_APP_PRIVATE_KEY'].encrypted_value | Should -Be 'encrypted-key'
        @($cloud.secrets.Keys).Count | Should -Be 1
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.apps.authorization.owner | Should -Be 'platform'
        $record.apps.authorization.rotateBy | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $inventory -Raw) | Should -Not -Match 'BEGIN.*PRIVATE KEY|installation-test|gho_test'
        $cloud.writes.Clear()
        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects a normal environment that collides with another phase nightly environment before any write' {
        $instance.credentials = @{
            application = @{ plan = @{ environment = 'application-plan' }; apply = @{ environment = 'foundation-plan-drift' } }
        }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $bootstrap @arguments } | Should -Throw '*environment*shares*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'isolates all three enterprise-baseline App identities including both nightly plans' {
        $instance.modules = @{ 'enterprise-baseline' = @{ parameters = @{ target_organizations = @('demo-platform') } } }
        $instance.credentials = @{ 'enterprise-baseline' = @{
            plan = @{ environment = 'enterprise-baseline-plan'; githubApp = 'reader' }
            apply = @{ environment = 'enterprise-baseline-apply'; githubApp = 'writer' }
            rulesetPlan = @{ environment = 'enterprise-baseline-ruleset-plan'; githubApp = 'rulesets' }
        } }
        $keyManifest = Get-Content -LiteralPath $keysPath -Raw | ConvertFrom-Json -AsHashtable
        $index = 102
        foreach ($alias in @('reader', 'writer', 'rulesets')) {
            $permissions = @{ organization_administration = $(if ($alias -eq 'reader') { 'read' } else { 'write' }) }
            $app = @{ appId = [string] $index; installationId = [string] ($index + 100); enterprise = 'example'
                permissions = $permissions; resources = @{ organizations = @('demo-platform') } }
            $instance.githubApps[$alias] = $app
            $cloud.apps[[string] $index] = $app
            $keyManifest[$alias] = @{} + $keyManifest.authorization
            $appKeyPath = Join-Path $casePath "$alias.pem"
            $appRsa = [Security.Cryptography.RSA]::Create(2048)
            $appRsa.ExportRSAPrivateKeyPem() | Set-Content -LiteralPath $appKeyPath
            $appRsa.Dispose()
            $keyManifest[$alias].privateKeyPath = $appKeyPath
            $index++
        }
        foreach ($name in @('service', 'enterprise-baseline')) {
            $module = @{ Name = $name }
            foreach ($phase in @('plan', 'apply')) {
                $module[$phase] = @{ ResourceId = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-demo-bootstrap/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-demo-$name-$phase"
                    ClientId = [guid]::NewGuid().ToString() }
                $cloud.resources[$module[$phase].ResourceId] = @{ properties = @{ clientId = $module[$phase].ClientId }
                    tags = @{ platformInstance = 'demo'; platformComponent = 'bootstrap'; platformModule = $name; platformPhase = $phase } }
            }
            $azure.Modules += $module
        }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        ConvertTo-Json -InputObject $keyManifest -Depth 20 | Set-Content -LiteralPath $keysPath
        $arguments.ResourcesOnly = $false

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        $prefix = '/repos/demo-platform/instance/environments'
        $cloud.variables["$prefix/enterprise-baseline-plan/variables/PLATFORM_APP_ID"] | Should -Be '102'
        $cloud.variables["$prefix/enterprise-baseline-plan-drift/variables/PLATFORM_APP_ID"] | Should -Be '102'
        $cloud.variables["$prefix/enterprise-baseline-ruleset-plan/variables/PLATFORM_APP_ID"] | Should -Be '104'
        $cloud.variables["$prefix/enterprise-baseline-ruleset-plan-drift/variables/PLATFORM_APP_ID"] | Should -Be '104'
        $cloud.variables["$prefix/enterprise-baseline-apply/variables/PLATFORM_APP_ID"] | Should -Be '103'
        $securityReview = $cloud.environments["$prefix/enterprise-baseline-apply"].protection_rules |
            Where-Object { $_.type -eq 'required_reviewers' }
        $securityReview.reviewers[0].reviewer.id | Should -Be 31
        @($cloud.secrets.Keys).Count | Should -Be 6
        $federation = @($cloud.resources.Values | Where-Object { $_.Contains('properties') -and $_.properties.Contains('subject') })
        @($federation | Where-Object { $_.properties.subject -like '*enterprise-baseline*' }).Count | Should -Be 5
    }

    It 'does not publish keys or initial main when an App is owned by a workload organization' {
        $cloud.appOwner = @{ login = 'demo-platform'; type = 'Organization' }
        $arguments.ResourcesOnly = $false

        { & $bootstrap @arguments } | Should -Throw '*not owned by the declared enterprise*'
        $cloud.secrets.Count | Should -Be 0
        $cloud.commit | Should -BeNullOrEmpty
        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeFalse
    }

    It 'rejects a write-capable authorization key without narrowing its token permissions' {
        $cloud.appPermissions.members = 'write'
        $arguments.ResourcesOnly = $false

        { & $bootstrap @arguments } | Should -Throw '*Actual GitHub App permissions differ*'
        $cloud.secrets.Count | Should -Be 0
        $cloud.commit | Should -BeNullOrEmpty
    }

    It 'keeps the prepared repository empty with Actions disabled until credentials are verified' {
        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeFalse
        $cloud.commit | Should -BeNullOrEmpty
        $cloud.secrets.Count | Should -Be 0
        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeFalse
    }

    It 'resumes an interrupted secret upload without replacing the seeded release' {
        $arguments.ResourcesOnly = $false
        $cloud.failPath = '/repos/demo-platform/instance/environments/pr-authorization/secrets/PLATFORM_APP_PRIVATE_KEY'

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'
        $initialCommit = ConvertTo-Json -InputObject $cloud.commit -Compress
        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        (ConvertTo-Json -InputObject $cloud.commit -Compress) | Should -Be $initialCommit
        $cloud.secrets.Count | Should -Be 1
    }

    It 'stops before key upload when GHE.com ignores required security-team reviews' {
        $arguments.ResourcesOnly = $false
        $cloud.rejectSecurityReview = $true

        { & $bootstrap @arguments } | Should -Throw '*did not enforce*security-team*'
        $cloud.secrets.Count | Should -Be 0
        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeFalse
    }

    It 'creates protected main even when the organization initializes repositories on master' {
        $cloud.defaultBranch = 'master'
        $arguments.ResourcesOnly = $false

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        $cloud.resources['/repos/demo-platform/instance'].default_branch | Should -Be 'main'
        $cloud.resources['/repos/demo-platform/instance/git/ref/heads/main'].object.sha | Should -Be 'commit-sha'
        $cloud.writes.Clear()
        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
    }

    It 'accepts the Azure script result object without requiring a separate serialized file' {
        $arguments.AzureBootstrap = [pscustomobject] $azure

        (& $bootstrap @arguments).Repository | Should -Be 'demo-platform/instance'
    }
}
