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
        $sourceInventory = Join-Path $PSScriptRoot "bootstrap-$([guid]::NewGuid()).json"
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
            teamRepositoryResponses = @{}
            oidcSettings = @{ use_default = $true; use_immutable_subject = $false; sub_claim_prefix = 'repo:demo-platform/instance' }
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
        $cloudTransport = {
            param([uri] $Uri, [string] $Body, [string] $Method = 'GET', [hashtable] $Headers)
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
            elseif ($path -eq '/user') { $reply = @{ login = 'owner_example' } }
            elseif ($path -eq '/app' -or $path -eq '/app/installations') {
                $segment = $Headers.Authorization.Split(' ')[1].Split('.')[1].Replace('-', '+').Replace('_', '/')
                $segment = $segment.PadRight($segment.Length + (4 - $segment.Length % 4) % 4, '=')
                $appId = [string] ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json -AsHashtable).iss
                $appRecord = $cloud.apps[$appId]
                if ($path -eq '/app') {
                    $reply = @{ id = [int] $appId; slug = $appRecord.slug; owner = $cloud.appOwner; permissions = $appRecord.permissions }
                }
                else {
                    $reply = @(@{ id = [int] $appRecord.installationId; account = @{ login = 'demo-platform' }; target_type = 'Organization'
                        suspended_at = $null; permissions = $appRecord.permissions; repository_selection = $appRecord.selection })
                }
            }
            elseif ($path -like '*/actions/workflows/bootstrap-acceptance.yml/dispatches') {
                $runId = if ($cloud.ContainsKey('nextRun')) { $cloud.nextRun } else { 80 }
                $cloud.nextRun = $runId + 10
                $cloud.resources['/repos/demo-platform/instance/actions/workflows/bootstrap-acceptance.yml/runs'] = @{
                    workflow_runs = @(@{ id = $runId; display_title = "Bootstrap acceptance $($data.inputs.evidence_id)" })
                }
                $cloud.resources["/repos/demo-platform/instance/actions/runs/$runId"] = @{
                    id = $runId; display_title = "Bootstrap acceptance $($data.inputs.evidence_id)"
                    head_sha = 'commit-sha'; head_branch = 'main'; run_attempt = 1
                    status = 'completed'; conclusion = 'success'; event = 'workflow_dispatch'
                }
                if ($cloud.loseDispatchResponse) {
                    $cloud.loseDispatchResponse = $false
                    $cloud.dispatchRecovery = $true
                    return [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Dispatch accepted, response interrupted."}' }
                }
            }
            elseif ($path -like '*/actions/workflows/bootstrap-acceptance.yml/runs' -and $Uri.Query -like '*event=schedule*') {
                $reply = @{ workflow_runs = @($cloud.scheduledRuns) }
            }
            elseif ($path -eq '/orgs/demo-platform/repos' -and $Method -eq 'POST') {
                if ($cloud['loseRepositoryCreateResponse']) {
                    $cloud.repositoryCreateInventory = Get-Content -LiteralPath $cloud.inventoryPath -Raw | ConvertFrom-Json -AsHashtable
                }
                $cloud.resources['/repos/demo-platform/instance'] = @{
                    id = 20; name = 'instance'; full_name = 'demo-platform/instance'
                    owner = @{ id = 10; login = 'demo-platform'; type = 'Organization' }
                    private = $true; default_branch = $cloud.defaultBranch; description = $data.description
                }
                $cloud.resources['/repos/demo-platform/instance/actions/permissions'] = @{ enabled = $true }
                $reply = $cloud.resources['/repos/demo-platform/instance']
                if ($data.auto_init) {
                    $cloud.resources["/repos/demo-platform/instance/git/ref/heads/$($cloud.defaultBranch)"] = @{ object = @{ sha = 'seed-sha' } }
                }
                if ($cloud['loseRepositoryCreateResponse']) {
                    $cloud.loseRepositoryCreateResponse = $false
                    return [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Repository created, response interrupted."}' }
                }
            }
            elseif ($path -eq '/repos/demo-platform/instance/actions/oidc/customization/sub' -and $Method -eq 'GET') {
                $reply = $cloud.oidcSettings
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
                foreach ($file in $cloud.tree | Where-Object path -Match '^\.github/workflows/[^/]+\.ya?ml$') {
                    $workflowPath = "/repos/demo-platform/instance/actions/workflows/$($file.path.Split('/')[-1])"
                    if (-not $cloud.resources.ContainsKey($workflowPath)) {
                        $cloud.resources[$workflowPath] = @{ state = 'active' }
                    }
                }
                $reply = @{ ref = $data.ref }
            }
            elseif ($path -like '*/git/refs/heads/main' -and $Method -eq 'PATCH') {
                $cloud.resources['/repos/demo-platform/instance/git/ref/heads/main'] = @{ object = @{ sha = $data.sha } }
                foreach ($file in $cloud.tree | Where-Object path -Match '^\.github/workflows/[^/]+\.ya?ml$') {
                    $workflowPath = "/repos/demo-platform/instance/actions/workflows/$($file.path.Split('/')[-1])"
                    if (-not $cloud.resources.ContainsKey($workflowPath)) {
                        $cloud.resources[$workflowPath] = @{ state = 'active' }
                    }
                }
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
            elseif ($path -like '*/actions/workflows/*/disable' -and $Method -eq 'PUT') {
                if (-not $cloud.commit) { throw 'The workflow cannot exist before repository contents are published.' }
                if (-not $cloud.ContainsKey('unconfirmedDisable') -or $path -cne $cloud.unconfirmedDisable) {
                    $cloud.resources[$path.Substring(0, $path.Length - '/disable'.Length)].state = 'disabled_manually'
                }
            }
            elseif ($path -like '*/actions/workflows' -and $Method -eq 'GET') {
                $reply = @{ workflows = @($cloud.resources.Keys | Where-Object { $_ -like "$path/*" -and $_.Split('/').Count -eq 7 } |
                    ForEach-Object { @{} + $cloud.resources[$_] + @{ path = ".github/workflows/$($_.Split('/')[-1])" } }) }
                if ($cloud.ContainsKey('unregisteredWorkflow')) {
                    $reply.workflows = @($reply.workflows | Where-Object { $_.path -cne $cloud.unregisteredWorkflow })
                }
            }
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
                if ($cloud.teamRepositoryResponses.ContainsKey($path)) {
                    return [pscustomobject] $cloud.teamRepositoryResponses[$path]
                }
                elseif (-not $cloud.resources.ContainsKey($path)) { $status = 404 }
                elseif ($Headers.Accept -cne 'application/vnd.github.v3.repository+json') {
                    return [pscustomobject]@{ StatusCode = 204; Content = '' }
                }
                else { $reply = @{ permissions = @{ push = ($cloud.resources[$path].permission -eq 'push') } } }
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
            [pscustomobject]@{ StatusCode = $status; Content = (ConvertTo-Json -InputObject $reply -Depth 100 -Compress)
                Headers = @{ 'X-OAuth-Scopes' = 'admin:enterprise,admin:org,repo,workflow' } }
        }
        Mock Invoke-WebRequest $cloudTransport
        $appTransport = {
            param([string] $Uri, [string] $Method = 'GET', [hashtable] $Headers)
            if ($Uri -like '*/installation/token' -and $Method -eq 'DELETE') { return }
            if ($Uri -like '*/installation/repositories`?*') { return @{ repositories = @() } }
            if ($Uri -like '*/orgs/demo-platform/teams`?*') { return ,@(@{ id = 30; slug = 'platform' }) }
            if ($Uri -like '*/orgs/demo-platform/actions/permissions') { return @{ enabled_repositories = 'all' } }
            if ($Uri -like '*/orgs/demo-platform/code-security/configurations*') { return ,@() }
            if ($Uri -like '*/orgs/demo-platform/rulesets`?*') {
                return ,@(@{ id = 7; source_type = 'Organization'; source = 'demo-platform' })
            }
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
                $selection = $cloud.apps[$appId]['selection']
                if (-not $selection) { $selection = 'all' }
            }
            if ($Uri -like '*/app') { return @{ id = [int] $appId; owner = $cloud.appOwner; permissions = $permissions } }
            if ($Uri -like '*/app/installations`?*') {
                return ,@(@{ id = $installationId; account = @{ login = 'demo-platform' }; target_type = 'Organization'
                    suspended_at = $null; permissions = $permissions; repository_selection = $selection })
            }
            if ($Uri -like '*/access_tokens') { return @{ token = 'installation-test'; permissions = $permissions } }
            throw "Unexpected App request: $Method $Uri"
        }
        Mock Invoke-RestMethod $appTransport
    }

    AfterEach {
        foreach ($name in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTokens[$name]) }
        if (Test-Path -LiteralPath $sourceInventory) { Remove-Item -LiteralPath $sourceInventory }
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

    It 'rejects missing GitHub resources before sending a mutation in no-change mode' -Tag 'NoChanges' {
        @{
            version = 1; repository = 'demo-platform/instance'; enterprise = 'example'; releaseVersion = '1.0.0'
            initializationPending = $false; apps = @{}; resources = @()
        } | ConvertTo-Json | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $arguments.NoChanges = $true

        { & $bootstrap @arguments } | Should -Throw '*NoChanges*POST*'
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects <Drift> before mutating the existing instance in no-change mode' -Tag 'NoChanges' -ForEach @(
        @{ Drift = 'environment'; Method = 'PUT' }
        @{ Drift = 'variable'; Method = 'PATCH' }
        @{ Drift = 'federation'; Method = 'PUT' }
    ) {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        switch ($Drift) {
            environment { $cloud.environments['/repos/demo-platform/instance/environments/approve-apply'].can_admins_bypass = $true }
            variable { $cloud.variables['/repos/demo-platform/instance/environments/application-plan/variables/AZURE_CLIENT_ID'] = 'wrong-client' }
            federation {
                $fid = @($cloud.resources.Keys | Where-Object { $_ -like '*/federatedIdentityCredentials/*' })[0]
                $cloud.resources.Remove($fid)
            }
        }
        $before = (Get-FileHash $inventory).Hash
        $cloud.writes.Clear()
        $arguments.NoChanges = $true

        { & $bootstrap @arguments } | Should -Throw "*NoChanges*$Method*"

        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'keeps the recorded inventory unchanged on a successful no-change repeat' -Tag 'NoChanges' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $before = (Get-FileHash $inventory).Hash
        $cloud.writes.Clear()
        $arguments.NoChanges = $true

        $result = & $bootstrap @arguments

        $result.HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'validates the current protected release without rewriting historical inventory' -Tag 'NoChanges', 'HistoricalInventory' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.9.0'
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[string]]::new()
        $arguments.NoChanges = $true
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation.Kind)
            return $true
        }.GetNewClosure()

        $result = & $bootstrap @arguments

        $result.ReleaseVersion | Should -BeExactly '1.0.0'
        $result.HasChanges | Should -BeFalse
        $result.CredentialsConfigured | Should -BeTrue
        @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 1
        Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter {
            $Method -ceq 'GET' -and $Uri -like '*/contents/.platform-bootstrap.json?ref=commit-sha'
        }
        Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter {
            $Method -ceq 'GET' -and $Uri -like '*/contents/instance.yaml?ref=commit-sha'
        }
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects missing main before issuing any validation token with historical inventory' -Tag 'NoChanges', 'HistoricalInventory' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.9.0'
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $cloud.resources.Remove('/repos/demo-platform/instance/git/ref/heads/main')
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[string]]::new()
        $arguments.NoChanges = $true
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation.Kind)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*NoChanges*existing main*'

        @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects absent inventory even when protected main matches the running release' -Tag 'NoChanges', 'HistoricalInventory' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        Remove-Item -LiteralPath $inventory
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[string]]::new()
        $arguments.NoChanges = $true
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation.Kind)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*NoChanges*existing initialized bootstrap inventory*'

        $operations.Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        Test-Path -LiteralPath $inventory | Should -BeFalse
    }

    It 'rejects <State> inventory before issuing any validation token in no-change mode' -Tag 'NoChanges', 'HistoricalInventory' -ForEach @(
        @{ State = 'pending'; Pending = $true }
        @{ State = 'unconfirmed'; Pending = $null }
    ) {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.9.0'
        $record.initializationPending = $Pending
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[string]]::new()
        $arguments.NoChanges = $true
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation.Kind)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*NoChanges*initialized inventory*'

        @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects unprotected main before issuing any validation token with historical inventory' -Tag 'NoChanges', 'HistoricalInventory' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.9.0'
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $cloud.resources['/repos/demo-platform/instance/rulesets/60'].enforcement = 'disabled'
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[string]]::new()
        $arguments.NoChanges = $true
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation.Kind)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*NoChanges*PUT*rulesets*'

        @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects main moving during verification before issuing any validation token' -Tag 'NoChanges', 'HistoricalInventory' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.9.0'
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[string]]::new()
        $arguments.NoChanges = $true
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation.Kind)
            return $true
        }.GetNewClosure()
        Mock Invoke-WebRequest {
            $cloud.resources['/repos/demo-platform/instance/git/ref/heads/main'] = @{ object = @{ sha = 'changed-commit' } }
            $blob = $cloud.tree | Where-Object { $_.path -ceq 'instance.yaml' }
            [pscustomobject]@{ StatusCode = 200; Content = (@{
                content = [Convert]::ToBase64String($cloud.blobs[$blob.sha])
            } | ConvertTo-Json -Compress) }
        } -ParameterFilter { $Method -ceq 'GET' -and $Uri -like '*/contents/instance.yaml?*' }

        { & $bootstrap @arguments } | Should -Throw '*main changed during*'

        @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects <Drift> before tokens or writes with historical inventory' -Tag 'NoChanges', 'HistoricalInventory' -ForEach @(
        @{ Drift = 'missing marker'; ExpectedError = '*Existing main has no bootstrap marker*' }
        @{ Drift = 'marker version'; ExpectedError = '*bootstrap marker differs*' }
        @{ Drift = 'marker instance'; ExpectedError = '*bootstrap marker differs*' }
        @{ Drift = 'marker file hash'; ExpectedError = '*bootstrap marker differs*' }
        @{ Drift = 'extra marker file'; ExpectedError = '*bootstrap marker differs*' }
        @{ Drift = 'missing configuration'; ExpectedError = '*GET*instance.yaml*HTTP 404*' }
        @{ Drift = 'configuration'; ExpectedError = '*configuration differs from protected main*' }
        @{ Drift = 'missing protection'; ExpectedError = '*NoChanges*POST*rulesets*' }
        @{ Drift = 'main bypass'; ExpectedError = '*NoChanges*PUT*rulesets*' }
        @{ Drift = 'security reviewers'; ExpectedError = '*NoChanges*PUT*rulesets*' }
        @{ Drift = 'main-only policy'; ExpectedError = '*NoChanges*PUT*rulesets*' }
    ) {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.9.0'
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $remoteMarker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        switch ($Drift) {
            'missing marker' { $cloud.tree = @($cloud.tree | Where-Object { $_.path -cne '.platform-bootstrap.json' }) }
            'marker version' { $remoteMarker.releaseVersion = '0.9.0' }
            'marker instance' { $remoteMarker.instance = 'another-instance' }
            'marker file hash' { $remoteMarker.files['tools/Invoke-GitHubBootstrap.ps1'] = 'wrong-hash' }
            'extra marker file' { $remoteMarker.files['extra.ps1'] = 'unapproved-hash' }
            'missing configuration' { $cloud.tree = @($cloud.tree | Where-Object { $_.path -cne 'instance.yaml' }) }
            'configuration' {
                $configBlob = $cloud.tree | Where-Object { $_.path -ceq 'instance.yaml' }
                $remoteConfig = ConvertFrom-Yaml ([Text.Encoding]::UTF8.GetString($cloud.blobs[$configBlob.sha]))
                $remoteConfig.instance.name = 'another-instance'
                $cloud.blobs[$configBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Yaml $remoteConfig))
            }
            'missing protection' { $cloud.resources.Remove('/repos/demo-platform/instance/rulesets/60') }
            'main bypass' {
                $cloud.resources['/repos/demo-platform/instance/rulesets/60'].bypass_actors = @(@{ actor_type = 'OrganizationAdmin'; bypass_mode = 'always' })
            }
            'security reviewers' {
                ($cloud.resources['/repos/demo-platform/instance/rulesets/60'].rules |
                    Where-Object { $_.type -ceq 'pull_request' }).parameters.required_reviewers = @()
            }
            'main-only policy' {
                $cloud.resources['/repos/demo-platform/instance/rulesets/60'].conditions.ref_name.include = @('~ALL')
            }
        }
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes(($remoteMarker | ConvertTo-Json -Depth 100))
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[string]]::new()
        $arguments.NoChanges = $true
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation.Kind)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw $ExpectedError

        @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'supervises credential validation and verifies revocation during the actual historical-inventory repeat' -Tag 'NoChanges', 'HistoricalInventory' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.9.0'
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $cloud.writes.Clear()
        $events = [Collections.Generic.List[string]]::new()
        $operations = [Collections.Generic.List[string]]::new()
        $arguments.NoChanges = $true
        $arguments.VerifyTokenRevocation = $true
        $arguments.TokenLifecycle = {
            param($LifecycleEvent)
            $events.Add($LifecycleEvent.Event)
            return $true
        }.GetNewClosure()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation.Kind)
            return $Operation.Kind -cne 'Reconcile'
        }.GetNewClosure()
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 204 } } -ParameterFilter {
            $Method -eq 'DELETE' -and $Uri -like '*/installation/token'
        }
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 401 } } -ParameterFilter {
            $Method -eq 'GET' -and $Uri -like '*/installation/repositories*'
        }

        $result = & $bootstrap @arguments

        $result.HasChanges | Should -BeFalse
        $result.CredentialsConfigured | Should -BeTrue
        @($events) | Should -Be @('Issued', 'Revoking', 'Revoked')
        @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 1
        @($operations | Where-Object { $_ -ceq 'TokenRevoke' }).Count | Should -Be 1
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'leaves protective Actions containment to the controller after no-change workflow isolation fails' -Tag 'NoChanges' {
        @{ kind = 'github-bootstrap-acceptance' } | ConvertTo-Json | Set-Content (Join-Path $release 'bootstrap-acceptance.json')
        $arguments.ResourcesOnly = $false
        $arguments.AcceptanceOnly = $true
        Copy-Item -LiteralPath (Join-Path $tools 'acceptance/github/bootstrap-acceptance.yml') `
            -Destination (Join-Path $release 'templates/instance/.github/workflows/bootstrap-acceptance.yml')
        $null = & $bootstrap @arguments
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/vendor.yml'].state = 'active'
        $cloud.writes.Clear()
        $arguments.NoChanges = $true

        try { $null = & $bootstrap @arguments; throw 'Expected no-change rejection.' }
        catch {
            $_.Exception.Message | Should -Match '^NoChanges refuses PUT'
            $_.Exception.Message | Should -Not -Match 'Repository Actions isolation also failed'
        }
        $cloud.writes.Count | Should -Be 0
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
    It 'binds immutable OIDC subjects to the exact repository IDs and each phase without widening trust' {
        $cloud.oidcSettings = @{
            use_default = $true; use_immutable_subject = $true; sub_claim_prefix = 'repo:demo-platform@10/instance@20'
        }
        & $bootstrap @arguments | Out-Null
        $planPath = $azure.Modules[0].Plan.ResourceId
        $applyPath = $azure.Modules[0].Apply.ResourceId
        $plan = @($cloud.resources.Keys | Where-Object { $_.StartsWith("$planPath/federatedIdentityCredentials/") } |
            ForEach-Object { $cloud.resources[$_].properties.subject })
        $apply = @($cloud.resources.Keys | Where-Object { $_.StartsWith("$applyPath/federatedIdentityCredentials/") } |
            ForEach-Object { $cloud.resources[$_].properties.subject })
        $plan | Should -HaveCount 2
        $plan | Should -Contain 'repo:demo-platform@10/instance@20:environment:application-plan'
        $plan | Should -Contain 'repo:demo-platform@10/instance@20:environment:application-plan-drift'
        $apply | Should -HaveCount 1
        $apply[0] | Should -BeExactly 'repo:demo-platform@10/instance@20:environment:application-apply'
        @($plan + $apply | Where-Object { $_ -like '*approve-*' -or $_ -like '*teardown*' -or $_ -like '*foundation*' }) | Should -HaveCount 0
        $cloud.writes.Clear()
        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes | Should -HaveCount 0
    }
    It 'rejects unproven OIDC mode or repository identity before federation writes (<Invalid>)' -TestCases @(
        @{ Invalid = 'MissingMode' }, @{ Invalid = 'StringMode' }, @{ Invalid = 'CustomTemplate' },
        @{ Invalid = 'PrefixIds' }, @{ Invalid = 'MissingPrefix' }, @{ Invalid = 'MissingOwnerId' },
        @{ Invalid = 'MissingOwner' }, @{ Invalid = 'StringOwnerId' }, @{ Invalid = 'DifferentOwner' }, @{ Invalid = 'ZeroRepositoryId' }
    ) {
        param($Invalid)
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        switch ($Invalid) {
            MissingMode { $cloud.oidcSettings.Remove('use_immutable_subject') }
            StringMode { $cloud.oidcSettings.use_immutable_subject = 'true' }
            CustomTemplate { $cloud.oidcSettings.use_default = $false }
            PrefixIds { $cloud.oidcSettings.sub_claim_prefix = 'repo:demo-platform@10/instance@999' }
            MissingPrefix { $cloud.oidcSettings.Remove('sub_claim_prefix') }
            MissingOwnerId { $cloud.resources['/repos/demo-platform/instance'].owner.Remove('id') }
            MissingOwner { $cloud.resources['/repos/demo-platform/instance'].Remove('owner') }
            StringOwnerId { $cloud.resources['/repos/demo-platform/instance'].owner.id = '10' }
            DifferentOwner { $cloud.resources['/repos/demo-platform/instance'].owner.login = 'other-platform' }
            ZeroRepositoryId { $cloud.resources['/repos/demo-platform/instance'].id = 0 }
        }
        { & $bootstrap @arguments } | Should -Throw '*OIDC*'
        @($cloud.writes | Where-Object { $_.path -like '*/federatedIdentityCredentials*' }) | Should -HaveCount 0
        @($cloud.writes | Where-Object { $_.path -like '*/actions/oidc/*' }) | Should -HaveCount 0
    }

    It 'refuses to silently migrate existing legacy federation when the repository switches to immutable subjects' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $cloud.oidcSettings = @{
            use_default = $true; use_immutable_subject = $true; sub_claim_prefix = 'repo:demo-platform@10/instance@20'
        }
        { & $bootstrap @arguments } | Should -Throw '*unexpected federated credential*approved access change*'
        @($cloud.writes | Where-Object { $_.path -like '*/federatedIdentityCredentials*' }) | Should -HaveCount 0
    }

    It 'reads existing team push permissions without writes or changing other endpoint headers' -Tag 'TeamPermissions' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()

        $result = & $bootstrap @arguments

        $result.HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter {
            $Uri.Host -eq 'api.example.ghe.com' -and
            -not ($Method -eq 'GET' -and $Uri.AbsolutePath -like '*/teams/*/repos/*') -and
            $Headers.Accept -cne 'application/vnd.github+json'
        }
    }

    It 'rejects an unproven team permission response (<Label>) without a permission write' -Tag 'TeamPermissions' -TestCases @(
        @{ Label = '204 without body'; Code = 204; Content = '' }
        @{ Label = '204 with a detail'; Code = 204; Content = '{"permissions":{"push":true}}' }
        @{ Label = '201 with a detail'; Code = 201; Content = '{"permissions":{"push":true}}' }
        @{ Label = '200 without body'; Code = 200; Content = '' }
        @{ Label = 'null detail'; Code = 200; Content = 'null' }
        @{ Label = 'array detail'; Code = 200; Content = '[{"permissions":{"push":true}}]' }
        @{ Label = 'missing permissions'; Code = 200; Content = '{}' }
        @{ Label = 'null permissions'; Code = 200; Content = '{"permissions":null}' }
        @{ Label = 'array permissions'; Code = 200; Content = '{"permissions":[{"push":true}]}' }
        @{ Label = 'missing push'; Code = 200; Content = '{"permissions":{"pull":true}}' }
        @{ Label = 'null push'; Code = 200; Content = '{"permissions":{"push":null}}' }
        @{ Label = 'string push'; Code = 200; Content = '{"permissions":{"push":"true"}}' }
        @{ Label = 'numeric push'; Code = 200; Content = '{"permissions":{"push":1}}' }
        @{ Label = 'array push'; Code = 200; Content = '{"permissions":{"push":[true]}}' }
    ) {
        param($Code, $Content)
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $cloud.teamRepositoryResponses['/orgs/demo-platform/teams/platform/repos/demo-platform/instance'] = @{
            StatusCode = $Code; Content = $Content
        }

        { & $bootstrap @arguments } | Should -Throw '*team repository permissions*'

        $cloud.writes.Count | Should -Be 0
    }

    It 'reports invalid JSON in a team permission detail without a permission write' -Tag 'TeamPermissions' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $cloud.teamRepositoryResponses['/orgs/demo-platform/teams/platform/repos/demo-platform/instance'] = @{
            StatusCode = 200; Content = '{"permissions":'
        }

        { & $bootstrap @arguments } | Should -Throw '*JSON*'

        $cloud.writes.Count | Should -Be 0
    }

    It 'repairs only genuinely insufficient team access (<Access>) and then remains write-free' -Tag 'TeamPermissions' -TestCases @(
        @{ Access = 'pull' }
        @{ Access = 'missing' }
    ) {
        param($Access)
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $accessPath = '/orgs/demo-platform/teams/platform/repos/demo-platform/instance'
        if ($Access -eq 'missing') { $cloud.resources.Remove($accessPath) }
        else { $cloud.resources[$accessPath].permission = $Access }

        $result = & $bootstrap @arguments

        $result.HasChanges | Should -BeTrue
        $cloud.writes.Count | Should -Be 1
        $cloud.writes[0].path | Should -Be $accessPath
        $cloud.writes[0].body.permission | Should -Be 'push'
        $cloud.writes.Clear()
        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
    }

    It 'reports a failed team permission update without retrying or claiming success' -Tag 'TeamPermissions' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $accessPath = '/orgs/demo-platform/teams/platform/repos/demo-platform/instance'
        $cloud.resources[$accessPath].permission = 'pull'
        $cloud.failPath = $accessPath

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'

        $cloud.resources[$accessPath].permission | Should -Be 'pull'
        $cloud.writes.Count | Should -Be 0
    }

    It 'does not claim push access when a successful permission update is not confirmed' -Tag 'TeamPermissions' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $accessPath = '/orgs/demo-platform/teams/platform/repos/demo-platform/instance'
        $cloud.teamRepositoryResponses[$accessPath] = @{
            StatusCode = 200; Content = '{"permissions":{"push":false}}'
        }

        { & $bootstrap @arguments } | Should -Throw '*push access*after*update*'

        @($cloud.writes | Where-Object { $_.path -eq $accessPath }).Count | Should -Be 1
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

    It 'preserves original key dates and existing history across successive rotations and an unchanged repeat' -Tag 'KeyRotationHistory' {
        $arguments.ResourcesOnly = $false
        & $bootstrap @arguments | Out-Null
        $keyManifest = Get-Content -LiteralPath $keysPath -Raw | ConvertFrom-Json -AsHashtable
        $previousHistory = @()
        foreach ($rotation in 1..2) {
            $before = (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).apps.authorization
            $replacement = [Security.Cryptography.RSA]::Create(2048)
            try { $replacement.ExportRSAPrivateKeyPem() | Set-Content -LiteralPath $keyPath }
            finally { $replacement.Dispose() }
            $keyManifest.authorization.createdAt = [DateTimeOffset]::UtcNow.ToString('o')
            $keyManifest.authorization.rotateBy = [DateTimeOffset]::UtcNow.AddDays(90 - $rotation).ToString('o')
            $keyManifest | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $keysPath

            (& $bootstrap @arguments).CredentialsConfigured | Should -BeTrue

            $after = (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).apps.authorization
            $after.fingerprint | Should -Not -Be $before.fingerprint
            $after.previousKeys.Count | Should -Be $rotation
            $retired = $after.previousKeys[-1]
            $retired.appId | Should -Be $before.appId
            $retired.fingerprint | Should -Be $before.fingerprint
            $retired.createdAt | Should -Be $before.createdAt
            $retired.rotateBy | Should -Be $before.rotateBy
            $retired.revocationRequired | Should -BeTrue
            if ($rotation -eq 2) {
                ($after.previousKeys[0] | ConvertTo-Json -Compress) | Should -Be $previousHistory
            }
            $previousHistory = $after.previousKeys[0] | ConvertTo-Json -Compress
        }
        $beforeRepeat = $after | ConvertTo-Json -Depth 100 -Compress
        $cloud.writes.Clear()

        (& $bootstrap @arguments).HasChanges | Should -BeFalse

        $afterRepeat = (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).apps.authorization
        ($afterRepeat | ConvertTo-Json -Depth 100 -Compress) | Should -BeExactly $beforeRepeat
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

    It 'isolates all three enterprise-baseline App identities including both nightly plans (<Immutable>)' -TestCases @(
        @{ Immutable = $false }, @{ Immutable = $true }
    ) {
        param($Immutable)
        $subjectPrefix = if ($Immutable) { 'repo:demo-platform@10/instance@20' } else { 'repo:demo-platform/instance' }
        $cloud.oidcSettings = @{ use_default = $true; use_immutable_subject = $Immutable; sub_claim_prefix = $subjectPrefix }
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
        $identity = $azure.Modules | Where-Object { $_.Name -eq 'enterprise-baseline' }
        $planSubjects = @($cloud.resources.Keys | Where-Object { $_.StartsWith("$($identity.Plan.ResourceId)/federatedIdentityCredentials/") } |
            ForEach-Object { $cloud.resources[$_].properties.subject })
        $applySubjects = @($cloud.resources.Keys | Where-Object { $_.StartsWith("$($identity.Apply.ResourceId)/federatedIdentityCredentials/") } |
            ForEach-Object { $cloud.resources[$_].properties.subject })
        $planSubjects | Should -HaveCount 4
        foreach ($environment in @('enterprise-baseline-plan', 'enterprise-baseline-plan-drift',
            'enterprise-baseline-ruleset-plan', 'enterprise-baseline-ruleset-plan-drift')) {
            $planSubjects | Should -Contain "${subjectPrefix}:environment:$environment"
        }
        $applySubjects | Should -HaveCount 1
        $applySubjects[0] | Should -BeExactly "${subjectPrefix}:environment:enterprise-baseline-apply"
        @($federation | Where-Object { $_.properties.subject -match 'pr-authorization|approve-|teardown' }) | Should -HaveCount 0
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

    It 'rejects inventory inside the running source checkout even when the release is elsewhere' {
        $arguments.InventoryPath = $sourceInventory

        { & $bootstrap @arguments } | Should -Throw '*outside*source*'
        $cloud.writes.Count | Should -Be 0
        Test-Path -LiteralPath $sourceInventory | Should -BeFalse
    }

    It 'rejects changing the release version of an existing preparation before any cloud write' -Tag 'HistoricalInventory' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $arguments.ReleaseVersion = '2.0.0'
        $before = (Get-FileHash $inventory).Hash
        $arguments.RequestPolicy = { throw 'Provisioning must reject historical inventory before any API request.' }

        { & $bootstrap @arguments } | Should -Throw '*inventory*release*'
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
        (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).releaseVersion | Should -Be '1.0.0'
    }

    It 'records confirmed resource identities rather than mutation and upload endpoints' {
        $arguments.ResourcesOnly = $false
        & $bootstrap @arguments | Out-Null
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable

        $record.resources | Should -Contain '/orgs/demo-platform'
        $record.resources | Should -Contain '/repos/demo-platform/instance'
        $record.resources | Should -Contain '/orgs/demo-platform/teams/platform'
        $record.resources | Should -Contain '/repos/demo-platform/instance/environments/application-plan'
        $record.resources | Should -Contain '/repos/demo-platform/instance/rulesets/60'
        @($record.resources | Where-Object { $_ -eq '/graphql' -or $_ -like '*/git/*' -or $_.Contains('?') }).Count | Should -Be 0
    }

    It 'does not record a failed GraphQL mutation as a created organization' {
        Mock Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 200; Content = '{"errors":[{"message":"Organization creation denied."}]}' }
        } -ParameterFilter { $Uri.AbsolutePath -eq '/graphql' -and $Body -like '*mutation*' }

        { & $bootstrap @arguments } | Should -Throw '*GraphQL failed*'
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.resources.Count | Should -Be 0
    }

    It 'retains manually declared Apps even when verification fails without another resource write' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $instance.githubApps.authorization.appId = '999'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $arguments.ResourcesOnly = $false
        $cloud.appOwner = @{ login = 'demo-platform'; type = 'Organization' }

        { & $bootstrap @arguments } | Should -Throw '*not owned by the declared enterprise*'
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.declaredApps.authorization.appId | Should -Be '999'
        $record.declaredApps.authorization.previousAppIds | Should -Contain '101'
        $record.declaredApps.authorization.removalRequired | Should -BeTrue
        $cloud.writes.Count | Should -Be 0
    }

    It 'persists initialization intent before repository creation and resumes after its response is lost' -Tag 'InitializationRecovery' {
        $arguments.ResourcesOnly = $false
        $cloud.inventoryPath = $inventory
        $cloud.loseRepositoryCreateResponse = $true

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'

        $cloud.repositoryCreateInventory.initializationPending | Should -BeTrue
        $pending = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $pending.initializationPending | Should -BeTrue
        $pending['seedCommit'] | Should -BeNullOrEmpty
        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeTrue
        $cloud.writes.Clear()

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        @($cloud.writes | Where-Object { $_.path -ceq '/orgs/demo-platform/repos' }).Count | Should -Be 0
        $cloud.commit.parents | Should -Be @('seed-sha')
        @($cloud.writes)[0].path | Should -Be '/repos/demo-platform/instance/actions/permissions'
        @($cloud.writes)[0].body.enabled | Should -BeFalse
        $completed = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $completed.seedCommit | Should -Be 'seed-sha'
        $completed.initializationPending | Should -BeFalse
        $cloud.writes.Clear()
        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
    }

    It 'disables Actions on retry when repository creation succeeded but disabling was interrupted' {
        $cloud.failPath = '/repos/demo-platform/instance/actions/permissions'

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'
        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeTrue
        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeFalse
        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeFalse
        $cloud.commit | Should -BeNullOrEmpty
    }

    It 'does not restore bootstrap memberships after initialized teams have been synchronized' {
        $arguments.ResourcesOnly = $false
        & $bootstrap @arguments | Out-Null
        $cloud.resources.Remove('/orgs/demo-platform/teams/platform/memberships/owner_example')
        $cloud.resources.Remove('/orgs/demo-platform/teams/security/memberships/owner_example')
        $cloud.writes.Clear()

        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
        $cloud.resources.ContainsKey('/orgs/demo-platform/teams/platform/memberships/owner_example') | Should -BeFalse
        $cloud.resources.ContainsKey('/orgs/demo-platform/teams/security/memberships/owner_example') | Should -BeFalse
    }

    It 'activates only acceptance and disables every other workflow before enabling Actions' {
        @{ kind = 'github-bootstrap-acceptance' } | ConvertTo-Json | Set-Content (Join-Path $release 'bootstrap-acceptance.json')
        Copy-Item (Join-Path $tools 'acceptance/github/bootstrap-acceptance.yml') `
            -Destination (Join-Path $release 'templates/instance/.github/workflows/bootstrap-acceptance.yml')
        'name: Future' | Set-Content (Join-Path $release 'templates/instance/.github/workflows/future.yml')
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/custom.yml'] = @{ state = 'active' }
        $arguments.ResourcesOnly = $false
        $arguments.AcceptanceOnly = $true

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/bootstrap-acceptance.yml'].state | Should -Be 'active'
        $paths = @($cloud.writes.path)
        $enabled = @($cloud.writes | Where-Object { $_.path -like '*/actions/permissions' -and $_.body.enabled })[0]
        foreach ($name in @('deploy.yml', 'vendor.yml', 'future.yml', 'custom.yml')) {
            $path = "/repos/demo-platform/instance/actions/workflows/$name"
            $cloud.resources[$path].state | Should -Be 'disabled_manually'
            if ($name -cne 'custom.yml') { $cloud.tree.path | Should -Contain ".github/workflows/$name" }
            $disabled = [Array]::IndexOf($paths, "$path/disable")
            $disabled | Should -BeGreaterOrEqual 0
            [Array]::IndexOf(@($cloud.writes), $enabled) | Should -BeGreaterThan $disabled
        }
        @($cloud.writes | Where-Object method -EQ 'DELETE').Count | Should -Be 0
    }

    It 'leaves deployment, vendoring and future workflows active in normal mode' {
        'name: Future' | Set-Content (Join-Path $release 'templates/instance/.github/workflows/future.yml')
        $arguments.ResourcesOnly = $false

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        foreach ($name in @('deploy.yml', 'vendor.yml', 'future.yml')) {
            $cloud.resources["/repos/demo-platform/instance/actions/workflows/$name"].state | Should -Be 'active'
            $cloud.tree.path | Should -Contain ".github/workflows/$name"
        }
        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeTrue
        @($cloud.writes | Where-Object path -Like '*/actions/workflows/*/disable').Count | Should -Be 0
    }

    It 'isolates an initialized acceptance repository on failure without changing a compliant rerun' {
        @{ kind = 'github-bootstrap-acceptance' } | ConvertTo-Json | Set-Content (Join-Path $release 'bootstrap-acceptance.json')
        Copy-Item (Join-Path $tools 'acceptance/github/bootstrap-acceptance.yml') `
            -Destination (Join-Path $release 'templates/instance/.github/workflows/bootstrap-acceptance.yml')
        $arguments.ResourcesOnly = $false
        $arguments.AcceptanceOnly = $true
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()

        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeTrue
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/vendor.yml'].state = 'active'
        $cloud.failPath = '/repos/demo-platform/instance/actions/workflows/vendor.yml/disable'

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'

        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeFalse
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/vendor.yml'].state | Should -Be 'active'
        @($cloud.writes | Where-Object { $_.path -like '*/actions/permissions' -and $_.body.enabled }).Count | Should -Be 0
    }

    It 'keeps Actions disabled when another acceptance-candidate workflow cannot be isolated' -TestCases @(
        @{ Failure = 'disable' }
        @{ Failure = 'registration' }
        @{ Failure = 'unconfirmed' }
    ) {
        param($Failure)
        @{ kind = 'github-bootstrap-acceptance' } | ConvertTo-Json | Set-Content (Join-Path $release 'bootstrap-acceptance.json')
        Copy-Item (Join-Path $tools 'acceptance/github/bootstrap-acceptance.yml') `
            -Destination (Join-Path $release 'templates/instance/.github/workflows/bootstrap-acceptance.yml')
        $arguments.ResourcesOnly = $false
        $arguments.AcceptanceOnly = $true
        if ($Failure -ceq 'disable') {
            $cloud.failPath = '/repos/demo-platform/instance/actions/workflows/vendor.yml/disable'
            $errorMessage = '*HTTP 503*'
        }
        elseif ($Failure -ceq 'unconfirmed') {
            $cloud.unconfirmedDisable = '/repos/demo-platform/instance/actions/workflows/vendor.yml/disable'
            $errorMessage = '*was not disabled*'
        }
        else {
            $cloud.unregisteredWorkflow = '.github/workflows/vendor.yml'
            $errorMessage = '*not uniquely registered*'
        }

        { & $bootstrap @arguments } | Should -Throw $errorMessage

        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeFalse
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/vendor.yml'].state | Should -Be 'active'
        @($cloud.writes | Where-Object { $_.path -like '*/actions/permissions' -and $_.body.enabled }).Count | Should -Be 0
    }

    It 'reports both registration and containment errors without retrying failed containment' {
        @{ kind = 'github-bootstrap-acceptance' } | ConvertTo-Json | Set-Content (Join-Path $release 'bootstrap-acceptance.json')
        Copy-Item (Join-Path $tools 'acceptance/github/bootstrap-acceptance.yml') `
            -Destination (Join-Path $release 'templates/instance/.github/workflows/bootstrap-acceptance.yml')
        $arguments.ResourcesOnly = $false
        $arguments.AcceptanceOnly = $true
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/vendor.yml'].state = 'active'
        $cloud.unregisteredWorkflow = '.github/workflows/vendor.yml'
        $cloud.failPath = '/repos/demo-platform/instance/actions/permissions'

        { & $bootstrap @arguments } | Should -Throw '*not uniquely registered*Repository Actions isolation also failed*HTTP 503*'

        $cloud.resources['/repos/demo-platform/instance/actions/permissions'].enabled | Should -BeTrue
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/vendor.yml'].state | Should -Be 'active'
        $cloud.writes.Count | Should -Be 0
    }

    It 'drives the public acceptance wizard through publication and real-run evidence without accepting missing nightly or rotation checks' {
        $sourceRoot = Split-Path $tools -Parent
        Copy-Item (Join-Path $tools 'acceptance') -Destination (Join-Path $release 'tools') -Recurse
        foreach ($name in @('bootstrap-probe', 'enterprise-baseline')) {
            $module = @{ Name = $name }
            foreach ($phase in @('plan', 'apply')) {
                $module[$phase] = @{ ResourceId = "/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-demo-bootstrap/providers/Microsoft.ManagedIdentity/userAssignedIdentities/id-demo-$name-$phase"
                    ClientId = [guid]::NewGuid().ToString() }
                $cloud.resources[$module[$phase].ResourceId] = @{ properties = @{ clientId = $module[$phase].ClientId }
                    tags = @{ platformInstance = 'demo'; platformComponent = 'bootstrap'; platformModule = $name; platformPhase = $phase } }
            }
            $azure.Modules += $module
        }
        $azureResult = Join-Path $casePath 'azure-result.json'
        ConvertTo-Json (@{} + $azure + @{ HasChanges = $false }) -Depth 30 | Set-Content $azureResult
        # Substitute the Azure provisioning command; the GitHub bootstrap and wizard run unchanged.
        Set-Content (Join-Path $release 'tools/Invoke-Bootstrap.ps1') @"
param([string] `$InstancePath, [string] `$ModulesPath, [switch] `$AllowUnboundApps)
Get-Content '$($azureResult.Replace("'", "''"))' -Raw | ConvertFrom-Json -AsHashtable
"@
        $registration = @{}
        $keyFolder = Join-Path $casePath 'github-acceptance/keys'
        $null = New-Item -ItemType Directory -Path $keyFolder -Force
        $index = 101
        foreach ($alias in @('authorization', 'reader', 'writer', 'rulesets')) {
            $permission = if ($alias -eq 'authorization') { @{ members = 'read' } }
            else { @{ organization_administration = $(if ($alias -eq 'reader') { 'read' } else { 'write' }) } }
            $cloud.apps[[string] $index] = @{ installationId = [string] ($index + 100); permissions = $permission
                slug = "demo-bootstrap-$alias"; selection = 'selected' }
            $registration[$alias] = @{ "$($alias)AppId" = [string] $index }
            $key = [Security.Cryptography.RSA]::Create(2048)
            $key.ExportRSAPrivateKeyPem() | Set-Content (Join-Path $keyFolder "probe-$alias.pem")
            $key.Dispose()
            $index++
        }
        @{ acceptance = @{ apps = $registration }; confirmations = @{}; probe = @{} } |
            ConvertTo-Json -Depth 20 | Set-Content (Join-Path $casePath 'github-acceptance/setup-state.json')
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/deploy.yml'] = @{ state = 'active' }
        $cloud.resources['/repos/demo-platform/instance/actions/runs/80'] = @{
            id = 80; head_sha = 'commit-sha'; run_attempt = 1; status = 'completed'; conclusion = 'success'; event = 'workflow_dispatch'
        }
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/bootstrap-acceptance.yml/runs'] = @{ workflow_runs = @() }
        $cloud.scheduledRuns = @()
        $cloud.loseDispatchResponse = $true
        $cloud.dispatchRecovery = $false
        $cloud.retryUsed = $false
        $cloud.failDownload = $false
        Import-Module (Join-Path $sourceRoot 'tools/InstanceSetup.psm1') -Force
        Mock Invoke-WebRequest -ModuleName InstanceSetup $cloudTransport
        Mock Invoke-RestMethod -ModuleName InstanceSetup $appTransport
        Mock az -ModuleName InstanceSetup {
            $global:LASTEXITCODE = 0
            '{"tenant":"11111111-1111-1111-1111-111111111111","accessToken":"azure-test"}'
        }
        Mock Write-Host -ModuleName InstanceSetup {}
        Mock Read-Host -ModuleName InstanceSetup {
            if ($Prompt -like 'Actual creation*') { return [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o') }
            if ($Prompt -like 'What next*') {
                if ($cloud.dispatchRecovery -and -not $cloud.retryUsed) { $cloud.retryUsed = $true; return 'r' }
                return 's'
            }
            if ($Prompt -like 'Local evidence*') { return 'https://example.ghe.com/demo-platform/instance/pull/9 observed the specified check' }
            return 'y'
        }
        $ghTransport = {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'secret') { return 'encrypted-key' }
            if ($args[0] -eq 'run') {
                if ($cloud.failDownload) { $global:LASTEXITCODE = 1; return }
                $target = $args[[Array]::IndexOf($args, '--dir') + 1]
                $runId = [string] $args[2]
                $manifest = Get-Content (Join-Path $casePath 'github-acceptance/keys.json') -Raw | ConvertFrom-Json -AsHashtable
                foreach ($phase in @('plan', 'rulesetPlan', 'wrongSubject', 'apply')) {
                    $folder = Join-Path $target "bootstrap-acceptance-$phase"
                    $null = New-Item -ItemType Directory -Path $folder -Force
                    $checks = @{ organizationApisRead = $true; phaseIdentityVerified = $true; otherModuleStateDenied = $true
                        rulesetBypassRead = $true; wrongSubjectRejected = $true }
                    $alias = switch ($phase) { plan { 'reader' }; apply { 'writer' }; rulesetPlan { 'rulesets' }; default { 'authorization' } }
                    @{ version = 1; phase = $phase; passed = $true; checks = $checks; revision = 'commit-sha'; runId = $runId
                        runAttempt = '1'; keyFingerprint = $manifest[$alias].fingerprint
                        authorizationFingerprint = $manifest.authorization.fingerprint } |
                        ConvertTo-Json -Depth 10 | Set-Content (Join-Path $folder 'result.json')
                }
                return
            }
            'gho_test'
        }
        Mock gh $ghTransport
        Mock gh -ModuleName InstanceSetup $ghTransport

        $result = & (Join-Path $sourceRoot 'tools/Start-InstanceSetup.ps1') -WorkPath $casePath -GitHubAcceptance `
            -ReleasePath $release -ReleaseVersion '0.0.0-bootstrap.11' -PassThru

        if (($result.Stages | Where-Object Id -eq 'acceptance-workflow').Status -ne 'Ok') {
            Write-Information ($result.Stages | Format-Table Id, Status, Detail -Wrap | Out-String -Width 200) -InformationAction Continue
        }
        ($result.Stages | Where-Object Id -eq 'acceptance-workflow').Status | Should -Be 'Ok'
        ($result.Stages | Where-Object Id -eq 'acceptance-repeat').Status | Should -Be 'Ok'
        ($result.Stages | Where-Object Id -eq 'acceptance-nightly').Status | Should -Be 'Missing'
        ($result.Stages | Where-Object Id -eq 'acceptance-witnesses').Status | Should -Not -Be 'Ok'
        $result.AcceptancePassed | Should -BeFalse
        $acceptanceInstance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $casePath 'github-acceptance/instance.yaml') -Raw)
        foreach ($alias in @('authorization', 'reader', 'writer', 'rulesets')) {
            $acceptanceInstance.githubApps[$alias].resources.repositories.Count | Should -Be 0
        }
        (Get-Content $result.SummaryPath -Raw) | Should -Not -Match 'example.ghe.com|11111111|installation-test|demo-platform'
        $cloud.resources['/repos/demo-platform/instance/actions/workflows/deploy.yml'].state | Should -Be 'disabled_manually'

        $resumed = & (Join-Path $sourceRoot 'tools/Start-InstanceSetup.ps1') -WorkPath $casePath -GitHubAcceptance `
            -ReleasePath $release -ReleaseVersion '0.0.0-bootstrap.11' -Reconfirm -PassThru
        ($resumed.Stages | Where-Object Id -eq 'acceptance-workflow').Status | Should -Be 'Ok'
        @($cloud.writes | Where-Object path -like '*/dispatches').Count | Should -Be 1

        $replacement = [Security.Cryptography.RSA]::Create(2048)
        $replacement.ExportRSAPrivateKeyPem() | Set-Content (Join-Path $keyFolder 'probe-reader.pem')
        $replacement.Dispose()
        $cloud.scheduledRuns = @(@{ id = 85; head_sha = 'commit-sha'; head_branch = 'main'; run_attempt = 1
            status = 'completed'; conclusion = 'success'; event = 'schedule'; created_at = [DateTimeOffset]::UtcNow.ToString('o') })
        $cloud.resources['/repos/demo-platform/instance/actions/runs/85/attempts/1/jobs'] = @{ jobs = @(
            @{ name = 'authorize'; conclusion = 'success' }, @{ name = 'probe-plan'; conclusion = 'success' }
            @{ name = 'probe-rulesetPlan'; conclusion = 'success' }, @{ name = 'wrong_subject'; conclusion = 'success' }
            @{ name = 'approve_apply'; conclusion = 'skipped' }, @{ name = 'apply-probe'; conclusion = 'skipped' }
        ) }
        $completed = & (Join-Path $sourceRoot 'tools/Start-InstanceSetup.ps1') -WorkPath $casePath -GitHubAcceptance `
            -ReleasePath $release -ReleaseVersion '0.0.0-bootstrap.11' -PassThru
        if (-not $completed.AcceptancePassed) {
            Write-Information ($completed.Stages | Format-Table Id, Status, Detail -Wrap | Out-String -Width 200) -InformationAction Continue
        }
        $completed.AcceptancePassed | Should -BeTrue
        @($cloud.writes | Where-Object path -like '*/dispatches').Count | Should -Be 2
        $record = Get-Content (Join-Path $casePath 'github-acceptance/bootstrap-resources.json') -Raw | ConvertFrom-Json -AsHashtable
        $record.apps.reader.previousKeys[0].revocationRequired | Should -BeFalse
        $record.apps.reader.previousKeys[0].revokedAt | Should -Not -BeNullOrEmpty

        $proofPath = Join-Path $casePath 'github-acceptance/evidence/90-1/bootstrap-acceptance-plan/result.json'
        $retainedProof = Get-Content $proofPath -Raw
        $cloud.failDownload = $true
        $unavailable = & (Join-Path $sourceRoot 'tools/Start-InstanceSetup.ps1') -WorkPath $casePath -GitHubAcceptance `
            -ReleasePath $release -ReleaseVersion '0.0.0-bootstrap.11' -PassThru
        ($unavailable.Stages | Where-Object Id -eq 'acceptance-workflow').Status | Should -Be 'Error'
        $unavailable.AcceptancePassed | Should -BeFalse
        Test-Path $proofPath | Should -BeTrue
        (Get-Content $proofPath -Raw) | Should -Be $retainedProof
    }
}
