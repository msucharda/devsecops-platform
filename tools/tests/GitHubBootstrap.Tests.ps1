BeforeDiscovery {
    $upgradeVersionCases = @(
        @{ From = '0.1.0-rc.5'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.6'; To = '0.1.0-rc.8' }
        @{ From = '0.1.0-rc.9'; To = '0.1.0-rc.10' }
        @{ From = '0.1.0-rc.10'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.12'; To = '0.1.0' }
        @{ From = '0.1.0-rc.2147483648'; To = '0.1.0-rc.2147483649' }
    )
    $unsupportedUpgradeVersionCases = @(
        @{ From = '0.1.0-rc.5'; To = '0.1.0-rc.5' }
        @{ From = '0.1.0-rc.4'; To = '0.1.0-rc.10' }
        @{ From = '0.1.0-rc.10'; To = '0.1.0-rc.9' }
        @{ From = '0.1.0-rc.10'; To = '0.1.0-rc.10' }
        @{ From = '0.1.0-RC.5'; To = '0.1.0-rc.10' }
        @{ From = '0.1.0-rc.5'; To = '0.1.0-RC.10' }
        @{ From = '0.1.0'; To = '0.1.0' }
        @{ From = '0.1.0'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.5'; To = '0.1.0-rc.4' }
        @{ From = '0.1.1-rc.5'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.5'; To = '0.1.1-rc.12' }
        @{ From = '0.2.0-rc.5'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.5'; To = '0.2.0-rc.12' }
        @{ From = '10.1.0-rc.5'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.5'; To = '10.1.0-rc.12' }
        @{ From = '0.1.0-beta.5'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.5'; To = '0.1.0-beta.12' }
        @{ From = '0.1.0-rc.05'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.5'; To = '0.1.0-rc.012' }
        @{ From = '0.1.0-rc.0'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.5'; To = '0.1.0-rc.0' }
        @{ From = "0.1.0-rc.5`n"; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.5'; To = "0.1.0-rc.12`n" }
        @{ From = '0.1.0-rc.2147483649'; To = '0.1.0-rc.2147483648' }
    )
    $upgradeProtectionCases = @(
        @{ ProtectionCase = 'disabled' }
        @{ ProtectionCase = 'missing' }
        @{ ProtectionCase = 'duplicate' }
        @{ ProtectionCase = 'non-object list entry' }
        @{ ProtectionCase = 'missing ruleset ID' }
        @{ ProtectionCase = 'string ruleset ID' }
        @{ ProtectionCase = 'zero ruleset ID' }
        @{ ProtectionCase = 'non-object detail' }
        @{ ProtectionCase = 'different detail ID' }
        @{ ProtectionCase = 'array detail ID' }
        @{ ProtectionCase = 'wrong source type' }
        @{ ProtectionCase = 'wrong source' }
        @{ ProtectionCase = 'source casing' }
        @{ ProtectionCase = 'missing conditions' }
        @{ ProtectionCase = 'extra conditions' }
        @{ ProtectionCase = 'bypass actor' }
        @{ ProtectionCase = 'wrong target' }
        @{ ProtectionCase = 'wrong branch' }
        @{ ProtectionCase = 'excluded main' }
        @{ ProtectionCase = 'missing deletion rule' }
        @{ ProtectionCase = 'missing force-push rule' }
        @{ ProtectionCase = 'missing pull-request rule' }
        @{ ProtectionCase = 'missing approval' }
        @{ ProtectionCase = 'stale approval' }
        @{ ProtectionCase = 'missing code-owner approval' }
        @{ ProtectionCase = 'missing last-push approval' }
        @{ ProtectionCase = 'unresolved threads' }
        @{ ProtectionCase = 'wrong review team' }
        @{ ProtectionCase = 'missing required reviewer' }
        @{ ProtectionCase = 'wrong reviewer pattern' }
    )
    $upgradeTeamCases = @(
        @{ TeamCase = 'missing' }
        @{ TeamCase = 'missing ID' }
        @{ TeamCase = 'string ID' }
        @{ TeamCase = 'zero ID' }
        @{ TeamCase = 'wrong slug' }
        @{ TeamCase = 'slug casing' }
        @{ TeamCase = 'enterprise type' }
        @{ TeamCase = 'missing organization' }
        @{ TeamCase = 'wrong organization' }
        @{ TeamCase = 'wrong ownership' }
    )
    $upgradeInventoryCases = @(
        @{ State = 'absent inventory' }
        @{ State = 'pending initialization'; Pending = $true }
        @{ State = 'missing initialization' }
        @{ State = 'null initialization'; Pending = $null }
        @{ State = 'string initialization'; Pending = 'false' }
        @{ State = 'numeric initialization'; Pending = 0 }
    )
    foreach ($case in $upgradeProtectionCases) {
        $case.ExpectedError = switch ($case.ProtectionCase) {
            { $_ -in @('missing ruleset ID', 'string ruleset ID', 'zero ruleset ID') } {
                '*main protection: a valid ruleset ID*'
            }
            { $_ -in @('missing', 'duplicate', 'non-object list entry') } {
                '*main protection: exactly one bootstrap main ruleset*'
            }
            default { '*main protection with enforced security-team PR reviews and no bypass*' }
        }
    }
}

BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $tools = Split-Path $PSScriptRoot -Parent
    $bootstrap = Join-Path $tools 'Invoke-GitHubBootstrap.ps1'
    $upgradeMainSha = 'aa218f56b14c9653891f9e74264a383fa43fefbd'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()

    function Initialize-TestInventoryUpgrade {
        param($Arguments, $Cloud, $Inventory, $Bootstrap, $From = '0.1.0-rc.5', $To = '0.1.0-rc.10')

        $Arguments.ResourcesOnly = $false
        $Cloud.commitShaOverride = $upgradeMainSha
        $null = & $Bootstrap @Arguments
        $record = Get-Content -LiteralPath $Inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = $From
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $Inventory
        $Arguments.ReleaseVersion = $To
        $Arguments.UpgradeInventory = $true
        $Cloud.requiredContentRef = $upgradeMainSha
        $markerBlob = $Cloud.tree | Where-Object path -CEQ '.platform-bootstrap.json'
        $marker = [Text.Encoding]::UTF8.GetString($Cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $marker.releaseVersion = $Arguments.ReleaseVersion
        $Cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        $Cloud.writes.Clear()
    }

    function Initialize-TestVendoringAppSet {
        param($Instance, $Cloud, $KeysPath, $CasePath)

        $keys = Get-Content -LiteralPath $KeysPath -Raw | ConvertFrom-Json -AsHashtable
        foreach ($entry in @(
            @{ alias = 'action-import'; id = '160'; installation = '260'; org = 'demo-a1b2c3-actions'; repo = 'actions-checkout'; permissions = @{ contents = 'write'; pull_requests = 'write' } }
            @{ alias = 'release-import'; id = '161'; installation = '261'; org = 'demo-a1b2c3-platform'; repo = 'instance'; permissions = @{ contents = 'write'; pull_requests = 'write' } }
            @{ alias = 'source-import'; id = '162'; installation = '262'; org = 'demo-a1b2c3-platform'; repo = 'private-source'; permissions = @{ contents = 'read'; attestations = 'read' } }
        )) {
            $Instance.githubApps[$entry.alias] = @{
                appId = $entry.id; installationId = $entry.installation; enterprise = 'example'
                permissions = $entry.permissions
                resources = @{ organizations = @($entry.org); repositories = @{ $entry.org = @($entry.repo) } }
            }
            $Cloud.apps[$entry.id] = @{
                installationId = $entry.installation; permissions = @{} + $entry.permissions + @{ metadata = 'read' }
                selection = 'selected'; slug = $entry.alias.ToLowerInvariant(); repositories = @($entry.repo); organization = $entry.org
            }
            $path = Join-Path $CasePath "$($entry.alias).pem"
            $key = [Security.Cryptography.RSA]::Create(2048)
            try { $key.ExportRSAPrivateKeyPem() | Set-Content -LiteralPath $path }
            finally { $key.Dispose() }
            $keys[$entry.alias] = @{} + $keys.authorization
            $keys[$entry.alias].privateKeyPath = $path
        }
        ConvertTo-Json -InputObject $keys -Depth 10 | Set-Content -LiteralPath $KeysPath
    }

    function Initialize-TestUpgradeProtectionCase {
        param($Cloud, [string] $ProtectionCase)

        $rule = Get-GitHubApiFixture -Name repos/get-repo-ruleset.bootstrap-main
        $list = Get-GitHubApiFixture -Name repos/get-repo-rulesets -Set @{
            '0.id' = 60; '0.name' = 'platform-instance-main'; '0.source' = 'demo-a1b2c3-platform/instance'
        }
        $Cloud.rulesetListOverride = $list
        $Cloud.rulesetDetailOverride = $rule
        $review = $rule.rules[2].parameters
        # Each case changes one field of a contract fixture; malformed types are deliberate.
        switch ($ProtectionCase) {
            valid { }
            disabled { $rule.enforcement = 'disabled' }
            missing { $Cloud.rulesetListOverride = @() }
            duplicate { $Cloud.rulesetListOverride = @($list[0], $list[0]) }
            'non-object list entry' { $Cloud.rulesetListOverride = @('invalid ruleset') }
            'missing ruleset ID' { $list[0].Remove('id') }
            'string ruleset ID' { $list[0].id = '60' }
            'zero ruleset ID' { $list[0].id = 0 }
            'non-object detail' { $Cloud.rulesetDetailOverride = @('invalid ruleset') }
            'different detail ID' { $rule.id = 61 }
            'array detail ID' { $rule.id = @(60) }
            'wrong source type' { $rule.source_type = 'Organization' }
            'wrong source' { $rule.source = 'other/instance' }
            'source casing' { $rule.source = 'Demo-a1b2c3-platform/instance' }
            'missing conditions' { $rule.Remove('conditions') }
            'extra conditions' { $rule.conditions.repository_name = @{ include = @('other'); exclude = @() } }
            'bypass actor' { $rule.bypass_actors = @(@{ actor_id = 31; actor_type = 'Team'; bypass_mode = 'always' }) }
            'wrong target' { $rule.target = 'tag' }
            'wrong branch' { $rule.conditions.ref_name.include = @('refs/heads/other') }
            'excluded main' { $rule.conditions.ref_name.exclude = @('refs/heads/main') }
            'missing deletion rule' { $rule.rules = @($rule.rules | Where-Object type -CNE deletion) }
            'missing force-push rule' { $rule.rules = @($rule.rules | Where-Object type -CNE non_fast_forward) }
            'missing pull-request rule' { $rule.rules = @($rule.rules | Where-Object type -CNE pull_request) }
            'missing approval' { $review.required_approving_review_count = 0 }
            'stale approval' { $review.dismiss_stale_reviews_on_push = $false }
            'missing code-owner approval' { $review.require_code_owner_review = $false }
            'missing last-push approval' { $review.require_last_push_approval = $false }
            'unresolved threads' { $review.required_review_thread_resolution = $false }
            'wrong review team' { $review.required_reviewers[0].reviewer.id = 32 }
            'missing required reviewer' { $review.required_reviewers = @() }
            'wrong reviewer pattern' { $review.required_reviewers[0].file_patterns[0] = 'other.yaml' }
            default { throw "Unknown protection case '$ProtectionCase'." }
        }
    }

    function Initialize-TestUpgradeTeamCase {
        param($Cloud, [string] $TeamCase)

        $path = '/orgs/demo-a1b2c3-platform/teams/security'
        $team = $Cloud.resources[$path]
        # Deliberately invalid/mismatched fields must not prove the existing security team.
        switch ($TeamCase) {
            missing { $Cloud.resources.Remove($path) }
            'missing ID' { $team.Remove('id') }
            'string ID' { $team.id = '31' }
            'zero ID' { $team.id = 0 }
            'wrong slug' { $team.slug = 'other' }
            'slug casing' { $team.slug = 'Security' }
            'enterprise type' { $team.type = 'enterprise' }
            'missing organization' { $team.Remove('organization') }
            'wrong organization' { $team.organization.login = 'other' }
            'wrong ownership' { $team.description = 'other' }
            default { throw "Unknown team case '$TeamCase'." }
        }
    }
}

Describe 'GitHub bootstrap public interface' {
    BeforeEach {
        $savedGlobalPSDefaultParameterValues = $global:PSDefaultParameterValues
        $PSDefaultParameterValues = @{} + $PSDefaultParameterValues
        $PSDefaultParameterValues['New-PlatformGitHubToken.ps1:IssuanceStatePath'] = Join-Path $TestDrive "issuance-$([guid]::NewGuid())/pending.json"
        $global:PSDefaultParameterValues = $PSDefaultParameterValues
        $setupModule = $null
        $savedSetupPSDefaultParameterValues = $null
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
        Copy-Item (Join-Path $tools 'vendor') -Destination $releaseTools.FullName -Recurse
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
            permissions = @{ members = 'read' }; resources = @{ organizations = @('demo-a1b2c3-platform'); repositories = @{} }
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
            commitShaOverride = $null; requiredContentRef = $null
            referenceShaOverrideEnabled = $false; referenceShaOverride = $null
            referenceTypeOverrideEnabled = $false; referenceTypeOverride = $null
            referenceInvalidCase = ''; contentVariant = ''; contentVariantPath = ''
            protectedCommitMutation = ''; protectedTreeMutation = ''
            contentEncodingOverrideEnabled = $false; contentEncodingOverride = $null
            contentValueOverrideEnabled = $false; contentValueOverride = $null
            contentTypeOverrideEnabled = $false; contentTypeOverride = $null
            appOwner = @{ login = 'example'; type = 'enterprise' }
            appPermissions = @{ members = 'read'; metadata = 'read' }
            apps = @{}
            teamRepositoryResponses = @{}
            oidcSettings = @{ use_default = $true; use_immutable_subject = $false; sub_claim_prefix = 'repo:demo-a1b2c3-platform/instance' }
            defaultBranch = 'main'; failPath = ''; rejectSecurityReview = $false
            takenOrganizations = @()
        }
        $deploymentIdentifiers = [Collections.Generic.Queue[string]]::new()
        Mock Get-RandomPlatformDeploymentIdentifier {
            if ($deploymentIdentifiers.Count) { $deploymentIdentifiers.Dequeue() } else { 'a1b2c3' }
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
            if ($path -eq '/installation/token' -and $Method -eq 'DELETE') {
                return [pscustomobject]@{ StatusCode = 204; Content = '' }
            }
            if ($Method -ne 'GET' -and ($path -ne '/graphql' -or $data.query -like 'mutation*')) {
                $cloud.writes.Add(@{ method = $Method; path = $path; body = $data })
            }
            if ($path -eq '/graphql') {
                if ($data.query -like '*createEnterpriseOrganization*') {
                    $login = $data.variables.input.login
                    if ($login -cin $cloud.takenOrganizations) {
                        $reply = @{ errors = @(@{ message = "The name '$login' is already taken." }) }
                    }
                    else {
                        $cloud.resources["/orgs/$login"] = @{ login = $login; id = 10 }
                        $cloud.takenOrganizations += $login
                        $reply = @{ data = @{ createEnterpriseOrganization = @{ organization = @{ login = $login } } } }
                    }
                }
                else {
                    $reply = @{ data = @{ viewer = @{ login = 'owner_example' }; enterprise = @{
                        id = 'enterprise-node'; viewerIsAdmin = $true
                        organizations = @{ nodes = @($cloud.resources.Keys | Where-Object { $_ -cmatch '^/orgs/[^/]+$' } |
                            ForEach-Object { @{ login = $_.Substring(6) } }); pageInfo = @{ hasNextPage = $false } }
                    } } }
                }
            }
            elseif ($path -eq '/user') { $reply = Get-GitHubApiFixture -Name users/get-authenticated-user.private-user -Set @{ login = 'owner_example' } }
            elseif ($path -eq '/app' -or $path -eq '/app/installations') {
                $segment = $Headers.Authorization.Split(' ')[1].Split('.')[1].Replace('-', '+').Replace('_', '/')
                $segment = $segment.PadRight($segment.Length + (4 - $segment.Length % 4) % 4, '=')
                $appId = [string] ([Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($segment)) | ConvertFrom-Json -AsHashtable).iss
                $appRecord = $cloud.apps[$appId]
                if ($path -eq '/app') {
                    $reply = Get-GitHubApiFixture -Name apps/get-app.owner-simple-user -Set @{
                        id = [int] $appId; slug = $appRecord.slug; 'owner.login' = $cloud.appOwner.login; 'owner.type' = $cloud.appOwner.type
                        permissions = $appRecord.permissions
                    }
                }
                else {
                    $reply = Get-GitHubApiFixture -Name apps/list-installations -Set @{
                        '0.id' = [int] $appRecord.installationId; '0.account.login' = 'demo-a1b2c3-platform'; '0.account.type' = 'Organization'
                        '0.target_type' = 'Organization'; '0.suspended_at' = $null; '0.permissions' = $appRecord.permissions
                        '0.repository_selection' = $appRecord.selection
                    }
                }
            }
            elseif ($path -like '*/actions/workflows/bootstrap-acceptance.yml/dispatches') {
                $runId = if ($cloud.ContainsKey('nextRun')) { $cloud.nextRun } else { 80 }
                $cloud.nextRun = $runId + 10
                $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/bootstrap-acceptance.yml/runs'] = @{
                    workflow_runs = @(@{ id = $runId; display_title = "Bootstrap acceptance $($data.inputs.evidence_id)" })
                }
                $cloud.resources["/repos/demo-a1b2c3-platform/instance/actions/runs/$runId"] = @{
                    id = $runId; display_title = "Bootstrap acceptance $($data.inputs.evidence_id)"
                    head_sha = $upgradeMainSha; head_branch = 'main'; run_attempt = 1
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
            elseif ($path -eq '/orgs/demo-a1b2c3-platform/repos' -and $Method -eq 'POST') {
                if ($cloud['loseRepositoryCreateResponse']) {
                    $cloud.repositoryCreateInventory = Get-Content -LiteralPath $cloud.inventoryPath -Raw | ConvertFrom-Json -AsHashtable
                }
                $cloud.resources['/repos/demo-a1b2c3-platform/instance'] = @{
                    id = 20; name = 'instance'; full_name = 'demo-a1b2c3-platform/instance'
                    owner = @{ id = 10; login = 'demo-a1b2c3-platform'; type = 'Organization' }
                    private = $true; default_branch = $cloud.defaultBranch; description = $data.description
                }
                $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'] = @{ enabled = $true }
                $reply = $cloud.resources['/repos/demo-a1b2c3-platform/instance']
                if ($data.auto_init) {
                    $cloud.resources["/repos/demo-a1b2c3-platform/instance/git/ref/heads/$($cloud.defaultBranch)"] = @{ object = @{ sha = 'seed-sha' } }
                }
                if ($cloud['loseRepositoryCreateResponse']) {
                    $cloud.loseRepositoryCreateResponse = $false
                    return [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Repository created, response interrupted."}' }
                }
            }
            elseif ($path -eq '/repos/demo-a1b2c3-platform/instance/actions/oidc/customization/sub' -and $Method -eq 'GET') {
                $reply = $cloud.oidcSettings
            }
            elseif ($path -eq '/orgs/demo-a1b2c3-platform/teams' -and $Method -eq 'POST') {
                $status = 201
                $reply = Get-GitHubApiFixture -Name teams/get-by-name -Set @{
                    id = $(if ($data.name -eq 'platform') { 30 } else { 31 })
                    name = $data.name; slug = $data.name; description = $data.description
                    'organization.login' = 'demo-a1b2c3-platform'
                }
                $cloud.resources["/orgs/demo-a1b2c3-platform/teams/$($data.name)"] = $reply
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
                $status = 201
                $reply = Get-GitHubApiFixture -Name git/create-commit -Set @{
                    sha = $(if ($cloud.commitShaOverride) { $cloud.commitShaOverride } else { $upgradeMainSha })
                }
            }
            elseif ($path -like '*/git/commits/*' -and $Method -eq 'GET') {
                $reply = Get-GitHubApiFixture -Name git/get-commit -Set @{ sha = $path.Split('/')[-1] }
                # Deliberately invalid response shapes exercise the fail-closed commit binding.
                switch ($cloud.protectedCommitMutation) {
                    'non-object' { $reply = @('invalid commit') }
                    'wrong SHA' { $reply.sha = 'bb218f56b14c9653891f9e74264a383fa43fefbd' }
                    'SHA casing' { $reply.sha = $reply.sha.ToUpperInvariant() }
                    'missing tree' { $reply.Remove('tree') }
                    'wrong tree shape' { $reply.tree = @('invalid tree') }
                    'numeric tree SHA' { $reply.tree.sha = [Numerics.BigInteger]::Parse('1234567890123456789012345678901234567890') }
                    'missing tree SHA' { $reply.tree.Remove('sha') }
                    'invalid tree SHA' { $reply.tree.sha = 'main' }
                    'tree SHA newline' { $reply.tree.sha += "`n" }
                }
            }
            elseif ($path -like '*/git/trees/*' -and $Method -eq 'GET') {
                $entry = (Get-GitHubApiFixture -Name git/get-tree).tree[0]
                $entries = @(foreach ($item in $cloud.tree | Where-Object { -not $_.path.Contains('/') }) {
                    $copy = @{} + $entry
                    foreach ($key in @('path', 'mode', 'type', 'sha')) { $copy[$key] = $item[$key] }
                    $copy
                })
                $reply = Get-GitHubApiFixture -Name git/get-tree -Set @{ tree = $entries; sha = $path.Split('/')[-1] }
                # Deliberately invalid or incomplete trees must not prove the protected file paths.
                switch ($cloud.protectedTreeMutation) {
                    'non-object' { $reply = @('invalid tree') }
                    'wrong SHA' { $reply.sha = 'bb218f56b14c9653891f9e74264a383fa43fefbd' }
                    'SHA casing' { $reply.sha = $reply.sha.ToUpperInvariant() }
                    'missing truncated' { $reply.Remove('truncated') }
                    'string truncated' { $reply.truncated = 'false' }
                    'truncated' { $reply.truncated = $true }
                    'missing entries' { $reply.Remove('tree') }
                    'wrong entries shape' { $reply.tree = @{ path = 'instance.yaml' } }
                    'non-object entry' { $reply.tree = @($reply.tree | Where-Object path -CNE 'instance.yaml') + @('instance.yaml') }
                }
            }
            elseif ($path -like '*/git/refs' -and $Method -eq 'POST') {
                $cloud.resources['/repos/demo-a1b2c3-platform/instance/git/ref/heads/main'] = @{ object = @{ sha = $data.sha } }
                foreach ($file in $cloud.tree | Where-Object path -Match '^\.github/workflows/[^/]+\.ya?ml$') {
                    $workflowPath = "/repos/demo-a1b2c3-platform/instance/actions/workflows/$($file.path.Split('/')[-1])"
                    if (-not $cloud.resources.ContainsKey($workflowPath)) {
                        $cloud.resources[$workflowPath] = @{ state = 'active' }
                    }
                }
                $reply = @{ ref = $data.ref }
            }
            elseif ($path -like '*/git/refs/heads/main' -and $Method -eq 'PATCH') {
                $cloud.resources['/repos/demo-a1b2c3-platform/instance/git/ref/heads/main'] = @{ object = @{ sha = $data.sha } }
                foreach ($file in $cloud.tree | Where-Object path -Match '^\.github/workflows/[^/]+\.ya?ml$') {
                    $workflowPath = "/repos/demo-a1b2c3-platform/instance/actions/workflows/$($file.path.Split('/')[-1])"
                    if (-not $cloud.resources.ContainsKey($workflowPath)) {
                        $cloud.resources[$workflowPath] = @{ state = 'active' }
                    }
                }
                $reply = @{ ref = 'refs/heads/main' }
            }
            elseif ($path -like '*/git/ref/heads/main' -and $Method -eq 'GET') {
                if (-not $cloud.resources.ContainsKey($path)) { $status = 404 }
                else {
                    $sha = $cloud.resources[$path].object.sha
                    $type = 'commit'
                    if ($cloud.referenceShaOverrideEnabled) { $sha = $cloud.referenceShaOverride }
                    if ($cloud.referenceTypeOverrideEnabled) { $type = $cloud.referenceTypeOverride }
                    $reply = Get-GitHubApiFixture -Name 'git/get-ref' -Set @{
                        ref = 'refs/heads/main'; 'object.sha' = $sha; 'object.type' = $type
                    }
                    switch ($cloud.referenceInvalidCase) {
                        'non-object' { $reply = @('invalid reference response') }
                        'missing object' { $reply.Remove('object') }
                        'missing SHA' { $reply.object.Remove('sha') }
                    }
                }
            }
            elseif ($path -like '*/environments/*' -and $path -notlike '*/variables*' -and $path -notlike '*/secrets*' -and $path -notlike '*/deployment-branch-policies*') {
                if ($Method -eq 'PUT') {
                    $documented = Get-GitHubApiFixture -Name repos/create-or-update-environment
                    $reviewers = @($data.reviewers | ForEach-Object {
                        $reviewer = @{} + $documented.protection_rules[1].reviewers[0].reviewer
                        $reviewer.id = $_.id
                        @{ type = $_.type; reviewer = $reviewer }
                    })
                    $rules = @()
                    if ($reviewers.Count) {
                        $rule = @{} + $documented.protection_rules[1]
                        $rule.reviewers = $reviewers
                        $rule.prevent_self_review = $data.prevent_self_review
                        $rules += $rule
                    }
                    $rules += $documented.protection_rules[2]
                    $reply = Get-GitHubApiFixture -Name repos/create-or-update-environment -Set @{
                        protection_rules = $rules; deployment_branch_policy = $data.deployment_branch_policy
                    }
                    if ($path -like '*/environments/vendoring-*' -and $cloud.ContainsKey('environmentBypassVariant')) {
                        switch ($cloud.environmentBypassVariant) {
                            missing { $reply.Remove('can_admins_bypass') }
                            enabled { $reply.can_admins_bypass = $true }
                            null { $reply.can_admins_bypass = $null }
                            string { $reply.can_admins_bypass = 'false' }
                            number { $reply.can_admins_bypass = 0 }
                        }
                    }
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
                $reply = @($cloud.resources.Keys | Where-Object { $_ -like "$path/*" } | ForEach-Object {
                    $rule = $cloud.resources[$_]
                    (Get-GitHubApiFixture -Name repos/get-repo-rulesets -Set @{
                        '0.id' = $rule.id; '0.name' = $rule.name
                        '0.source' = $rule.source; '0.enforcement' = $rule.enforcement
                    })[0]
                })
                if ($cloud.ContainsKey('rulesetListOverride')) { $reply = $cloud.rulesetListOverride }
            }
            elseif ($path -like '*/rulesets/*' -and $Method -eq 'GET' -and $cloud.ContainsKey('rulesetDetailOverride')) {
                $reply = $cloud.rulesetDetailOverride
            }
            elseif ($path -like '*/rulesets' -and $Method -eq 'POST') {
                $status = 201
                if ($cloud.rejectSecurityReview) {
                    ($data.rules | Where-Object { $_.type -eq 'pull_request' }).parameters.required_reviewers = @()
                }
                $reply = Get-GitHubApiFixture -Name repos/get-repo-ruleset.bootstrap-main
                foreach ($name in $data.Keys) { $reply[$name] = $data[$name] }
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
                $contentRef = [System.Web.HttpUtility]::ParseQueryString($Uri.Query).Get('ref')
                $mainPath = '/repos/demo-a1b2c3-platform/instance/git/ref/heads/main'
                $mainSha = if ($cloud.resources.ContainsKey($mainPath)) { $cloud.resources[$mainPath].object.sha } else { '' }
                $blob = $cloud.tree | Where-Object { $_.path -eq $relative }
                if ($cloud.requiredContentRef -and $contentRef -cne $cloud.requiredContentRef) { $status = 404 }
                elseif ($contentRef -and $contentRef -cnotin @('main', $mainSha)) { $status = 404 }
                elseif ($cloud.contentVariant -and $relative -ceq $cloud.contentVariantPath) {
                    $reply = Get-GitHubApiFixture -Name "repos/get-content.$($cloud.contentVariant)"
                }
                elseif ($blob) {
                    $bytes = $cloud.blobs[$blob.sha]
                    $fixture = @{
                        type = 'file'; encoding = 'base64'; size = $bytes.Length
                        name = $relative.Split('/')[-1]; path = $relative
                        content = [Convert]::ToBase64String($bytes); sha = $blob.sha
                    }
                    if ($cloud.contentEncodingOverrideEnabled) { $fixture.encoding = $cloud.contentEncodingOverride }
                    if ($cloud.contentValueOverrideEnabled) { $fixture.content = $cloud.contentValueOverride }
                    if ($cloud.contentTypeOverrideEnabled) { $fixture.type = $cloud.contentTypeOverride }
                    $reply = Get-GitHubApiFixture -Name 'repos/get-content.file' -Set $fixture
                }
                else { $status = 404 }
            }
            else { $status = 404 }
            $response = [pscustomobject]@{ StatusCode = $status; Content = (ConvertTo-Json -InputObject $reply -Depth 100 -Compress)
                Headers = @{ 'X-OAuth-Scopes' = 'admin:enterprise,admin:org,repo,workflow' } }
            return $response
        }
        Mock Invoke-WebRequest $cloudTransport
        $appTransport = {
            param([string] $Uri, [string] $Method = 'GET', [hashtable] $Headers)
            if ($Uri -like '*/installation/token' -and $Method -eq 'DELETE') { return }
            if ($Uri -like '*/installation/repositories`?*') {
                $tokenAppId = $Headers.Authorization -replace '^Bearer installation-test-', ''
                $names = if ($cloud.apps.ContainsKey($tokenAppId) -and $cloud.apps[$tokenAppId]['repositories']) { @($cloud.apps[$tokenAppId]['repositories']) } else { @() }
                $repositories = @(foreach ($name in $names) {
                    $repository = (Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation).repositories[0]
                    $repository.name = $name
                    $repository
                })
                return Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{ total_count = $repositories.Count; repositories = $repositories }
            }
            if ($Uri -like '*/orgs/demo-a1b2c3-platform/teams`?*') { return Get-GitHubApiFixture -Name teams/list-teams -Set @{ '0.id' = 30; '0.slug' = 'platform' } }
            if ($Uri -like '*/orgs/demo-a1b2c3-platform/actions/permissions') {
                return Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization -Set @{ enabled_repositories = 'all' }
            }
            if ($Uri -like '*/orgs/demo-a1b2c3-platform/code-security/configurations*') { return ,@() }
            if ($Uri -like '*/orgs/demo-a1b2c3-platform/rulesets`?*') {
                return Get-GitHubApiFixture -Name repos/get-org-rulesets -Set @{ '0.id' = 7; '0.source_type' = 'Organization'; '0.source' = 'demo-a1b2c3-platform' }
            }
            if ($Uri -like '*/orgs/demo-a1b2c3-platform/rulesets/7') {
                return Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{
                    id = 7; source = 'demo-a1b2c3-platform'; bypass_actors = @(@{ actor_type = 'Team'; actor_id = 123; bypass_mode = 'pull_request' })
                }
            }
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
            if ($Uri -like '*/app') {
                if ($cloud.ContainsKey('enterpriseOwnerVariant') -and $cloud.enterpriseOwnerVariant) {
                    return Get-GitHubApiFixture -Name apps/get-app.owner-enterprise -Set @{
                        id = [int] $appId; 'owner.slug' = $cloud.appOwner.login; permissions = $permissions
                    }
                }
                return Get-GitHubApiFixture -Name apps/get-app.owner-simple-user -Set @{
                    id = [int] $appId; 'owner.login' = $cloud.appOwner.login; 'owner.type' = $cloud.appOwner.type; permissions = $permissions
                }
            }
            if ($Uri -like '*/app/installations`?*') {
                $appOrganization = if ($cloud.apps.ContainsKey($appId) -and $cloud.apps[$appId]['organization']) {
                    $cloud.apps[$appId]['organization']
                } else { 'demo-a1b2c3-platform' }
                $installationPermissions = if ($cloud.apps.ContainsKey($appId) -and $cloud.apps[$appId].ContainsKey('installationPermissions')) {
                    $cloud.apps[$appId].installationPermissions
                } else { $permissions }
                return Get-GitHubApiFixture -Name apps/list-installations -Set @{
                    '0.id' = $installationId; '0.account.login' = $appOrganization; '0.account.type' = 'Organization'
                    '0.target_type' = 'Organization'; '0.suspended_at' = $null; '0.permissions' = $installationPermissions; '0.repository_selection' = $selection
                }
            }
            if ($Uri -like '*/access_tokens') {
                if ($cloud.ContainsKey('expectedIssuanceStatePath')) {
                    [IO.File]::Exists($cloud.expectedIssuanceStatePath) | Should -BeTrue
                }
                return Get-GitHubApiFixture -Name apps/create-installation-access-token -Set @{ token = "installation-test-$appId"; permissions = $permissions }
            }
            throw "Unexpected App request: $Method $Uri"
        }
        Mock Invoke-RestMethod $appTransport
    }

    AfterEach {
        if ($setupModule) { $setupModule.SessionState.PSVariable.Set('PSDefaultParameterValues', $savedSetupPSDefaultParameterValues) }
        $global:PSDefaultParameterValues = $savedGlobalPSDefaultParameterValues
        foreach ($name in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTokens[$name]) }
        if (Test-Path -LiteralPath $sourceInventory) { Remove-Item -LiteralPath $sourceInventory }
    }

    It 'prepares main-only vendoring environments with isolated approvals and no cloud credentials' -Tag 'Vendoring', 'EnvironmentProtection' {
        $null = & $bootstrap @arguments

        foreach ($name in @('vendoring-source', 'vendoring-action-import', 'vendoring-release-import')) {
            $path = "/repos/demo-a1b2c3-platform/instance/environments/$name"
            $cloud.environments.ContainsKey($path) | Should -BeTrue
            $cloud.environments[$path].can_admins_bypass | Should -BeFalse
            @($cloud.writes | Where-Object { $_.path -ceq $path -and $_.method -eq 'PUT' })[0].body.can_admins_bypass |
                Should -BeFalse
            $cloud.branchRules["$path/deployment-branch-policies"].name | Should -Be @('main')
            $cloud.branchRules["$path/deployment-branch-policies"].type | Should -Be @('branch')
            $reviewers = @($cloud.environments[$path].protection_rules | Where-Object type -EQ required_reviewers)
            if ($name -eq 'vendoring-source') { $reviewers.Count | Should -Be 0 }
            else { $reviewers[0].reviewers[0].reviewer.id | Should -Be 30 }
            @($cloud.variables.Keys | Where-Object { $_ -like "$path/*" }).Count | Should -Be 0
            @($cloud.secrets.Keys | Where-Object { $_ -like "$path/*" }).Count | Should -Be 0
        }
        @($cloud.resources.Values | Where-Object { $_.ContainsKey('properties') -and
            $_.properties.ContainsKey('subject') -and $_.properties.subject -like '*environment:vendoring-*' }).Count | Should -Be 0
    }

    It 'fails closed when GHE.com returns <Variant> admin bypass confirmation' -Tag 'Vendoring', 'EnvironmentProtection' -ForEach @(
        @{ Variant = 'missing' }
        @{ Variant = 'enabled' }
        @{ Variant = 'null' }
        @{ Variant = 'string' }
        @{ Variant = 'number' }
    ) {
        # Missing is the documented OpenAPI shape; the other variants intentionally violate the observed boolean contract.
        $cloud.environmentBypassVariant = $Variant
        { & $bootstrap @arguments } | Should -Throw '*did not enforce environment*vendoring*protection*'
        $cloud.secrets.Count | Should -Be 0
    }

    It 'creates the instance repository with the exact release and both organization teams' -Tag 'SupplyChain' {
        foreach ($relative in @('tools/.dependencies/interrupted', 'templates/instance/tools/.dependencies/interrupted')) {
            $cache = Join-Path $release $relative
            $null = New-Item -ItemType Directory -Path $cache -Force
            Set-Content (Join-Path $cache 'unverified.nupkg') 'not an approved release dependency'
        }
        $arguments.ResourcesOnly = $false
        $result = & $bootstrap @arguments

        $result.Repository | Should -Be 'demo-a1b2c3-platform/instance'
        $result.CredentialsConfigured | Should -BeTrue
        $cloud.resources['/orgs/demo-a1b2c3-platform/teams/platform/memberships/owner_example'].state | Should -Be 'active'
        $cloud.resources['/orgs/demo-a1b2c3-platform/teams/security/memberships/owner_example'].state | Should -Be 'active'
        $cloud.tree.path | Should -Contain 'platform/schemas/instance.schema.json'
        @($cloud.tree.path | Where-Object { $_ -match '[\\/]\.dependencies[\\/]' }).Count | Should -Be 0
        $markerBlob = $cloud.tree | Where-Object { $_.path -eq '.platform-bootstrap.json' }
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        @($marker.files.Keys | Where-Object { $_ -match '[\\/]\.dependencies[\\/]' }).Count | Should -Be 0
        $codeowners = $cloud.tree | Where-Object { $_.path -eq '.github/CODEOWNERS' }
        [Text.Encoding]::UTF8.GetString($cloud.blobs[$codeowners.sha]) | Should -Be "* @demo-a1b2c3-platform/platform`n"
        $rules = $cloud.resources['/repos/demo-a1b2c3-platform/instance/rulesets/60']
        $rules.enforcement | Should -Be 'active'
        $rules.bypass_actors.Count | Should -Be 0
        $cloud.commit.parents | Should -Be @('seed-sha')
        ($rules.rules | Where-Object { $_.type -eq 'pull_request' }).parameters.required_reviewers[0].reviewer.id | Should -Be 31
        Test-Path -LiteralPath $inventory | Should -BeTrue
    }

    It 'records a deployment identifier at first organization creation and reuses it on repeat' -Tag 'DeploymentIdentifier' {
        $first = & $bootstrap @arguments
        $deploymentIdentifiers.Enqueue('zzzzzz')

        $second = & $bootstrap @arguments

        $first.Organization | Should -BeExactly 'demo-a1b2c3-platform'
        $second.Organization | Should -BeExactly 'demo-a1b2c3-platform'
        $second.Repository | Should -BeExactly 'demo-a1b2c3-platform/instance'
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.deploymentIdentifier | Should -BeExactly 'a1b2c3'
        $record.repository | Should -BeExactly 'demo-a1b2c3-platform/instance'
        @($cloud.writes | Where-Object { $_.path -ceq '/graphql' -and $_.body.query -like '*createEnterpriseOrganization*' }).Count | Should -Be 1
        Should -Invoke Get-RandomPlatformDeploymentIdentifier -Times 1 -Exactly
    }

    It 'reuses the recorded deployment identifier when organization creation did not complete' -Tag 'DeploymentIdentifier' {
        $cloud.takenOrganizations = @('demo-a1b2c3-platform')
        { & $bootstrap @arguments } | Should -Throw '*already taken*'
        (Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable).deploymentIdentifier | Should -BeExactly 'a1b2c3'
        $cloud.takenOrganizations = @()
        $deploymentIdentifiers.Enqueue('zzzzzz')

        $result = & $bootstrap @arguments

        $result.Organization | Should -BeExactly 'demo-a1b2c3-platform'
        Should -Invoke Get-RandomPlatformDeploymentIdentifier -Times 1 -Exactly
    }

    It 'refuses to recreate a deleted organization under its recorded deployment identifier' -Tag 'DeploymentIdentifier' {
        $null = & $bootstrap @arguments
        $cloud.resources.Remove('/orgs/demo-a1b2c3-platform')
        $cloud.writes.Clear()

        { & $bootstrap @arguments } | Should -Throw '*demo-a1b2c3-platform*no longer exists*new inventory*'
        @($cloud.writes | Where-Object { $_.path -ceq '/graphql' -and $_.body.query -like '*createEnterpriseOrganization*' }).Count | Should -Be 0
    }

    It 'uses a new deployment identifier for a new deployment after the platform organization was deleted' -Tag 'DeploymentIdentifier' {
        $null = & $bootstrap @arguments
        foreach ($path in @($cloud.resources.Keys | Where-Object { $_ -like '*/demo-a1b2c3-platform*' })) { $cloud.resources.Remove($path) }
        Remove-Item -LiteralPath $inventory
        $deploymentIdentifiers.Enqueue('d4e5f6')
        $cloud.failPath = '/orgs/demo-d4e5f6-platform/repos'

        { & $bootstrap @arguments } | Should -Throw '*Injected interruption*'

        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.deploymentIdentifier | Should -BeExactly 'd4e5f6'
        $record.repository | Should -BeExactly 'demo-d4e5f6-platform/instance'
        $record.resources | Should -Contain '/orgs/demo-d4e5f6-platform'
        $created = @($cloud.writes | Where-Object { $_.path -ceq '/graphql' -and $_.body.query -like '*createEnterpriseOrganization*' })
        $created.body.variables.input.login | Should -Be @('demo-a1b2c3-platform', 'demo-d4e5f6-platform')
    }

    It 'keeps the organization name of an inventory recorded before deployment identifiers' -Tag 'DeploymentIdentifier' {
        @{
            version = 1; repository = 'demo-platform/instance'; enterprise = 'example'; releaseVersion = '1.0.0'
            apps = @{}; resources = @()
        } | ConvertTo-Json | Set-Content $inventory
        $cloud.failPath = '/orgs/demo-platform/repos'

        { & $bootstrap @arguments } | Should -Throw '*Injected interruption*'

        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.repository | Should -BeExactly 'demo-platform/instance'
        $record.resources | Should -Contain '/orgs/demo-platform'
        $record.Contains('deploymentIdentifier') | Should -BeFalse
        @($cloud.writes | Where-Object { $_.path -ceq '/graphql' -and $_.body.query -like '*createEnterpriseOrganization*' }).body.variables.input.login |
            Should -BeExactly 'demo-platform'
        Should -Invoke Get-RandomPlatformDeploymentIdentifier -Times 0 -Exactly
    }

    It 'rejects an inventory whose <Case> does not match its organization' -Tag 'DeploymentIdentifier' -TestCases @(
        @{ Case = 'deployment identifier'; Record = @{ repository = 'demo-a1b2c3-platform/instance'; deploymentIdentifier = 'zzzzzz' } }
        @{ Case = 'legacy repository'; Record = @{ repository = 'other-platform/instance' } }
        @{ Case = 'identifier format'; Record = @{ repository = 'demo-A1B2C3-platform/instance'; deploymentIdentifier = 'A1B2C3' } }
    ) {
        (@{ version = 1; enterprise = 'example'; releaseVersion = '1.0.0'; apps = @{}; resources = @() } + $Record) |
            ConvertTo-Json | Set-Content $inventory

        { & $bootstrap @arguments } | Should -Throw '*inventory*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects missing GitHub resources before sending a mutation in no-change mode' -Tag 'NoChanges' {
        @{
            version = 1; repository = 'demo-a1b2c3-platform/instance'; deploymentIdentifier = 'a1b2c3'; enterprise = 'example'; releaseVersion = '1.0.0'
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
            environment { $cloud.environments['/repos/demo-a1b2c3-platform/instance/environments/approve-apply'].can_admins_bypass = $true }
            variable { $cloud.variables['/repos/demo-a1b2c3-platform/instance/environments/application-plan/variables/AZURE_CLIENT_ID'] = 'wrong-client' }
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

    It 'accepts byte-identical protected configuration with unordered <Scope> under <Culture> (NoChanges=<ReadOnly>)' -Tag 'ConfigurationComparison' -ForEach @(
        @{ Scope = 'organizations'; Culture = 'cs-CZ'; ReadOnly = $true }
        @{ Scope = 'organizations'; Culture = ''; ReadOnly = $true }
        @{ Scope = 'organizations'; Culture = 'cs-CZ'; ReadOnly = $false }
        @{ Scope = 'organizations'; Culture = ''; ReadOnly = $false }
        @{ Scope = 'repositories'; Culture = 'cs-CZ'; ReadOnly = $true }
        @{ Scope = 'repositories'; Culture = ''; ReadOnly = $true }
        @{ Scope = 'repositories'; Culture = 'cs-CZ'; ReadOnly = $false }
        @{ Scope = 'repositories'; Culture = ''; ReadOnly = $false }
    ) {
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
            $arguments.ResourcesOnly = $false
            $null = & $bootstrap @arguments
            $arguments.ResourcesOnly = $true
            $instance.githubApps['organization-reader'] = @{
                appId = '102'; installationId = '202'; enterprise = 'example'; permissions = @{ members = 'read' }
                resources = @{
                    organizations = @('demo-a1b2c3-platform', 'demo-a1b2c3-actions', 'demo-a1b2c3-workloads')
                    repositories = @{}
                }
            }
            if ($Scope -eq 'repositories') {
                $instance.githubApps['organization-reader'].resources.organizations = @('demo-a1b2c3-actions')
                $instance.githubApps['organization-reader'].resources.repositories = @{
                    'demo-a1b2c3-actions' = @('actions-upload-artifact', 'actions-checkout',
                        'actions-download-artifact', 'actions-create-github-app-token')
                }
            }
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            $configBlob = $cloud.tree | Where-Object { $_.path -ceq 'instance.yaml' }
            $cloud.blobs[$configBlob.sha] = [IO.File]::ReadAllBytes($instancePath)
            [Convert]::ToBase64String($cloud.blobs[$configBlob.sha]) |
                Should -BeExactly ([Convert]::ToBase64String([IO.File]::ReadAllBytes($instancePath)))
            $before = (Get-FileHash $inventory).Hash
            $cloud.writes.Clear()
            $arguments.NoChanges = $ReadOnly

            $result = & $bootstrap @arguments

            $result.HasChanges | Should -BeFalse
            $cloud.writes.Count | Should -Be 0
            if ($ReadOnly) { (Get-FileHash $inventory).Hash | Should -BeExactly $before }
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
    }

    It 'rejects a protected configuration <Difference> under cs-CZ before tokens or writes' -Tag 'ConfigurationComparison' -ForEach @(
        @{ Difference = 'changed scalar' }
        @{ Difference = 'extra organization' }
        @{ Difference = 'changed permission' }
        @{ Difference = 'changed repository' }
        @{ Difference = 'extra repository' }
        @{ Difference = 'changed case' }
        @{ Difference = 'changed ordered list' }
    ) {
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('cs-CZ')
            $arguments.ResourcesOnly = $false
            $null = & $bootstrap @arguments
            $arguments.ResourcesOnly = $true
            $instance.githubApps.authorization.resources.repositories = @{
                'demo-a1b2c3-platform' = @('actions-checkout', 'actions-download-artifact')
            }
            $instance.teams.platform = @('platform@example.test', 'other@example.test')
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            $remoteConfig = ConvertFrom-Yaml (Get-Content -LiteralPath $instancePath -Raw)
            switch ($Difference) {
                'changed scalar' { $remoteConfig.instance.name = 'other' }
                'extra organization' { $remoteConfig.githubApps.authorization.resources.organizations += 'demo-other' }
                'changed permission' { $remoteConfig.githubApps.authorization.permissions.members = 'write' }
                'changed repository' { $remoteConfig.githubApps.authorization.resources.repositories['demo-a1b2c3-platform'][0] = 'actions-upload-artifact' }
                'extra repository' { $remoteConfig.githubApps.authorization.resources.repositories['demo-a1b2c3-platform'] += 'actions-upload-artifact' }
                'changed case' { $remoteConfig.teams.platform[0] = 'Platform@example.test' }
                'changed ordered list' { $remoteConfig.teams.platform = @('other@example.test', 'platform@example.test') }
            }
            $configBlob = $cloud.tree | Where-Object { $_.path -ceq 'instance.yaml' }
            $cloud.blobs[$configBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Yaml $remoteConfig))
            $before = (Get-FileHash $inventory).Hash
            $cloud.writes.Clear()
            $arguments.NoChanges = $true
            $operations = [Collections.Generic.List[string]]::new()
            $arguments.RequestPolicy = {
                param($Operation)
                $operations.Add($Operation.Kind)
                return $true
            }.GetNewClosure()

            { & $bootstrap @arguments } | Should -Throw '*configuration differs from protected main*'

            @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 0
            $cloud.writes.Count | Should -Be 0
            (Get-FileHash $inventory).Hash | Should -BeExactly $before
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
    }

    It 'upgrades initialized historical inventory only after protected main proves the current release' -Tag 'HistoricalInventory', 'BootstrapUpgrade', 'ReleaseVersionUpgrade' {
        $From = '0.1.0-rc.5'
        $To = '0.1.0-rc.12'
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        $arguments.ResourcesOnly = $false
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('cs-CZ')
            $cloud.commitShaOverride = $upgradeMainSha
            Set-Content -LiteralPath (Join-Path (Join-Path $release 'tools') 'charlie.txt') -Value 'ordinal order'
            Set-Content -LiteralPath (Join-Path (Join-Path $release 'tools') 'hotel.txt') -Value 'ordinal order'
            $null = & $bootstrap @arguments
            $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
            $record.releaseVersion = $From
            $record.apps.authorization.previousKeys = @(@{
                appId = '99'; fingerprint = 'previous-fingerprint'; createdAt = '2026-01-01T00:00:00Z'
                rotateBy = '2026-03-31T00:00:00Z'; revocationRequired = $false
            })
            $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
            $deploymentIdentifier = $record.deploymentIdentifier
            $resources = ConvertTo-PlatformCanonicalJson $record.resources
            $apps = ConvertTo-PlatformCanonicalJson $record.apps

            $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
            $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
            $arguments.ReleaseVersion = $To
            $arguments.UpgradeInventory = $true
            $cloud.requiredContentRef = $upgradeMainSha
            $marker.releaseVersion = $arguments.ReleaseVersion
            $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
            $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled = $false
            $cloud.writes.Clear()
            $operations = [Collections.Generic.List[object]]::new()
            $arguments.RequestPolicy = {
                param($Operation)
                $operations.Add($Operation)
                return $true
            }.GetNewClosure()

            $result = & $bootstrap @arguments

            $result.ReleaseVersion | Should -BeExactly $To
            $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
            $record.releaseVersion | Should -BeExactly $To
            $record.deploymentIdentifier | Should -BeExactly $deploymentIdentifier
            (ConvertTo-PlatformCanonicalJson $record.resources) | Should -BeExactly $resources
            (ConvertTo-PlatformCanonicalJson $record.apps) | Should -BeExactly $apps
            $record.apps.authorization.previousKeys[0].revocationRequired | Should -BeFalse
            $result.HasChanges | Should -BeTrue
            $paths = @($cloud.tree | ForEach-Object path)
            $charlieIndex = [Array]::IndexOf($paths, 'platform/tools/charlie.txt')
            $hotelIndex = [Array]::IndexOf($paths, 'platform/tools/hotel.txt')
            $charlieIndex | Should -BeGreaterThan -1
            $hotelIndex | Should -BeGreaterThan $charlieIndex
            $markerRequest = $operations | Where-Object Uri -Like "*/contents/.platform-bootstrap.json?ref=$upgradeMainSha" | Select-Object -First 1
            $configurationRequest = $operations | Where-Object Uri -Like "*/contents/instance.yaml?ref=$upgradeMainSha" | Select-Object -First 1
            $firstReconcileRequest = $operations | Where-Object Kind -CEQ 'Reconcile' | Select-Object -First 1
            $markerReadIndex = $operations.IndexOf($markerRequest)
            $configurationReadIndex = $operations.IndexOf($configurationRequest)
            $firstReconcileIndex = $operations.IndexOf($firstReconcileRequest)
            $markerReadIndex | Should -BeGreaterThan -1
            $configurationReadIndex | Should -BeGreaterThan -1
            $firstReconcileIndex | Should -BeGreaterThan $markerReadIndex
            $firstReconcileIndex | Should -BeGreaterThan $configurationReadIndex
            $cloud.writes.Count | Should -BeGreaterThan 0
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
    }

    It 'upgrades supported release transition <From> to <To>' -Tag 'BootstrapUpgrade', 'ReleaseVersionUpgrade' -ForEach $upgradeVersionCases {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap -From $From -To $To
        $expected = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $expected.releaseVersion = $To

        $result = & $bootstrap @arguments

        $result.ReleaseVersion | Should -BeExactly $To
        $actual = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        (ConvertTo-PlatformCanonicalJson $actual) | Should -BeExactly (ConvertTo-PlatformCanonicalJson $expected)
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects unsupported inventory upgrade pair <From> to <To> before any GitHub request' -Tag 'BootstrapUpgrade', 'ReleaseVersionUpgrade' -ForEach $unsupportedUpgradeVersionCases {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = $From
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = Get-FileHash -LiteralPath $inventory
        $cloud.writes.Clear()
        $arguments.ReleaseVersion = $To
        $arguments.UpgradeInventory = $true
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo('cs-CZ')
            { & $bootstrap @arguments } | Should -Throw '*Unsupported bootstrap inventory upgrade*'
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }

        $operations.Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before.Hash
    }

    It 'refuses a no-change inventory upgrade before any GitHub request' -Tag 'BootstrapUpgrade' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.1.0-rc.5'
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $arguments.UpgradeInventory = $true
        $arguments.NoChanges = $true
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*cannot be combined with -NoChanges*'

        $operations.Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects an invalid main reference <ReferenceCase> before reading protected files' -Tag 'BootstrapUpgrade', 'TypedResponse' -ForEach @(
        @{ ReferenceCase = 'non-object'; Mutation = 'non-object' }
        @{ ReferenceCase = 'missing object'; Mutation = 'missing object' }
        @{ ReferenceCase = 'wrong object type'; Mutation = 'wrong object type' }
        @{ ReferenceCase = 'object type casing'; Mutation = 'object type casing' }
        @{ ReferenceCase = 'array object type'; Mutation = 'array object type' }
        @{ ReferenceCase = 'missing SHA'; Mutation = 'missing SHA' }
        @{ ReferenceCase = 'invalid SHA'; Mutation = 'invalid SHA' }
        @{ ReferenceCase = 'numeric SHA'; Mutation = 'numeric SHA' }
        @{ ReferenceCase = 'SHA newline'; Mutation = 'SHA newline' }
    ) {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.1.0-rc.5'
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $cloud.writes.Clear()
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $arguments.UpgradeInventory = $true
        $cloud.requiredContentRef = $upgradeMainSha
        # Deliberately invalid reference fields isolate validation of the documented commit reference.
        switch ($Mutation) {
            'non-object' { $cloud.referenceInvalidCase = 'non-object' }
            'missing object' { $cloud.referenceInvalidCase = 'missing object' }
            'wrong object type' {
                $cloud.referenceTypeOverrideEnabled = $true
                $cloud.referenceTypeOverride = 'tree'
            }
            'object type casing' {
                $cloud.referenceTypeOverrideEnabled = $true
                $cloud.referenceTypeOverride = 'Commit'
            }
            'array object type' {
                $cloud.referenceTypeOverrideEnabled = $true
                $cloud.referenceTypeOverride = @('commit')
            }
            'missing SHA' { $cloud.referenceInvalidCase = 'missing SHA' }
            'invalid SHA' {
                $cloud.referenceShaOverrideEnabled = $true
                $cloud.referenceShaOverride = 'main'
            }
            'numeric SHA' {
                $cloud.referenceShaOverrideEnabled = $true
                $cloud.referenceShaOverride = [Numerics.BigInteger]::Parse('1234567890123456789012345678901234567890')
            }
            'SHA newline' {
                $cloud.referenceShaOverrideEnabled = $true
                $cloud.referenceShaOverride = "$upgradeMainSha`n"
            }
        }
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*valid SHA*'

        @($operations | Where-Object Uri -Like '*/contents/*').Count | Should -Be 0
        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects a dereferenced symlink at <ProtectedPath> before reconciliation (NoChanges=<ReadOnly>)' -Tag 'BootstrapUpgrade', 'ProtectedTree' -ForEach @(
        @{ ProtectedPath = 'instance.yaml'; ReadOnly = $false }
        @{ ProtectedPath = '.platform-bootstrap.json'; ReadOnly = $false }
        @{ ProtectedPath = 'instance.yaml'; ReadOnly = $true }
        @{ ProtectedPath = '.platform-bootstrap.json'; ReadOnly = $true }
    ) {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.1.0-rc.5'
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $arguments.UpgradeInventory = -not $ReadOnly
        $arguments.NoChanges = $ReadOnly
        $markerBlob = $cloud.tree | Where-Object path -CEQ '.platform-bootstrap.json'
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $marker.releaseVersion = $arguments.ReleaseVersion
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        # Contents API dereferences a symlink to a regular file; only the Git tree exposes its mode.
        ($cloud.tree | Where-Object path -CEQ $ProtectedPath).mode = '120000'
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*regular file*'

        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'accepts regular protected files with mode <FileMode>' -Tag 'BootstrapUpgrade', 'ProtectedTree' -ForEach @(
        @{ FileMode = '100644' }
        @{ FileMode = '100755' }
    ) {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        foreach ($entry in $cloud.tree | Where-Object { $_.path -cin @('instance.yaml', '.platform-bootstrap.json') }) {
            $entry.mode = $FileMode
        }

        $result = & $bootstrap @arguments

        $result.ReleaseVersion | Should -BeExactly '0.1.0-rc.10'
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects pinned commit <CommitCase> before reconciliation' -Tag 'BootstrapUpgrade', 'ProtectedTree' -ForEach @(
        @{ CommitCase = 'non-object' }
        @{ CommitCase = 'wrong SHA' }
        @{ CommitCase = 'SHA casing' }
        @{ CommitCase = 'missing tree' }
        @{ CommitCase = 'wrong tree shape' }
        @{ CommitCase = 'numeric tree SHA' }
        @{ CommitCase = 'missing tree SHA' }
        @{ CommitCase = 'invalid tree SHA' }
        @{ CommitCase = 'tree SHA newline' }
    ) {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $cloud.protectedCommitMutation = $CommitCase
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*pinned commit and a valid tree SHA*'

        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects pinned tree <TreeCase> before reconciliation' -Tag 'BootstrapUpgrade', 'ProtectedTree' -ForEach @(
        @{ TreeCase = 'non-object'; ExpectedError = '*complete pinned Git tree*' }
        @{ TreeCase = 'wrong SHA'; ExpectedError = '*complete pinned Git tree*' }
        @{ TreeCase = 'SHA casing'; ExpectedError = '*complete pinned Git tree*' }
        @{ TreeCase = 'missing truncated'; ExpectedError = '*complete pinned Git tree*' }
        @{ TreeCase = 'string truncated'; ExpectedError = '*complete pinned Git tree*' }
        @{ TreeCase = 'truncated'; ExpectedError = '*complete pinned Git tree*' }
        @{ TreeCase = 'missing entries'; ExpectedError = '*complete pinned Git tree*' }
        @{ TreeCase = 'wrong entries shape'; ExpectedError = '*complete pinned Git tree*' }
        @{ TreeCase = 'non-object entry'; ExpectedError = '*exactly one regular file*' }
    ) {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $cloud.protectedTreeMutation = $TreeCase
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw $ExpectedError

        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects protected tree entry <EntryCase> at <ProtectedPath> before reconciliation' -Tag 'BootstrapUpgrade', 'ProtectedTree' -ForEach @(
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'missing' }
        @{ ProtectedPath = '.platform-bootstrap.json'; EntryCase = 'missing' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'duplicate' }
        @{ ProtectedPath = '.platform-bootstrap.json'; EntryCase = 'duplicate' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'path casing' }
        @{ ProtectedPath = '.platform-bootstrap.json'; EntryCase = 'path casing' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'submodule' }
        @{ ProtectedPath = '.platform-bootstrap.json'; EntryCase = 'submodule' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'directory' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'missing mode' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'unknown mode' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'wrong type' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'type casing' }
        @{ ProtectedPath = 'instance.yaml'; EntryCase = 'array type' }
    ) {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $entry = $cloud.tree | Where-Object path -CEQ $ProtectedPath
        # Deliberately invalid modes, types and duplicate paths isolate each protected-entry condition.
        switch ($EntryCase) {
            'missing' { $cloud.tree = @($cloud.tree | Where-Object path -CNE $ProtectedPath) }
            'duplicate' { $cloud.tree += @(@{} + $entry) }
            'path casing' { $entry.path = $entry.path.ToUpperInvariant() }
            'submodule' { $entry.mode = '160000' }
            'directory' { $entry.mode = '040000' }
            'missing mode' { $entry.Remove('mode') }
            'unknown mode' { $entry.mode = '100664' }
            'wrong type' { $entry.type = 'tree' }
            'type casing' { $entry.type = 'Blob' }
            'array type' { $entry.type = @('blob') }
        }
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*regular file*'

        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects protected content variant <ContentVariant> before reconciliation' -Tag 'BootstrapUpgrade' -ForEach @(
        @{ ContentVariant = 'directory' }
        @{ ContentVariant = 'symlink' }
        @{ ContentVariant = 'submodule' }
    ) {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.1.0-rc.5'
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $cloud.writes.Clear()
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $arguments.UpgradeInventory = $true
        $cloud.requiredContentRef = $upgradeMainSha
        $cloud.contentVariant = $ContentVariant
        $cloud.contentVariantPath = 'instance.yaml'
        $marker.releaseVersion = $arguments.ReleaseVersion
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*base64-encoded file*'

        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects protected content <ContentCase> before reconciliation' -Tag 'BootstrapUpgrade', 'TypedResponse' -ForEach @(
        @{ ContentCase = 'with a wrong encoding'; Mutation = 'encoding'; ExpectedError = '*base64-encoded file*' }
        @{ ContentCase = 'with encoding casing'; Mutation = 'encoding casing'; ExpectedError = '*base64-encoded file*' }
        @{ ContentCase = 'with an array encoding'; Mutation = 'array encoding'; ExpectedError = '*base64-encoded file*' }
        @{ ContentCase = 'with a wrong type'; Mutation = 'type'; ExpectedError = '*base64-encoded file*' }
        @{ ContentCase = 'with type casing'; Mutation = 'type casing'; ExpectedError = '*base64-encoded file*' }
        @{ ContentCase = 'with an array type'; Mutation = 'array type'; ExpectedError = '*base64-encoded file*' }
        @{ ContentCase = 'with missing content'; Mutation = 'missing'; ExpectedError = '*base64-encoded file*' }
        @{ ContentCase = 'with numeric content'; Mutation = 'numeric'; ExpectedError = '*base64-encoded file*' }
        @{ ContentCase = 'with invalid base64'; Mutation = 'invalid'; ExpectedError = '*invalid base64*' }
    ) {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.1.0-rc.5'
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $arguments.UpgradeInventory = $true
        $cloud.requiredContentRef = $upgradeMainSha
        # Deliberately invalid scalar types and casing leave the other documented file fields intact.
        switch ($Mutation) {
            'encoding' { $cloud.contentEncodingOverrideEnabled = $true; $cloud.contentEncodingOverride = 'utf-8' }
            'encoding casing' { $cloud.contentEncodingOverrideEnabled = $true; $cloud.contentEncodingOverride = 'Base64' }
            'array encoding' { $cloud.contentEncodingOverrideEnabled = $true; $cloud.contentEncodingOverride = @('base64') }
            'type' { $cloud.contentTypeOverrideEnabled = $true; $cloud.contentTypeOverride = 'directory' }
            'type casing' { $cloud.contentTypeOverrideEnabled = $true; $cloud.contentTypeOverride = 'File' }
            'array type' { $cloud.contentTypeOverrideEnabled = $true; $cloud.contentTypeOverride = @('file') }
            'missing' { $cloud.contentValueOverrideEnabled = $true; $cloud.contentValueOverride = $null }
            'numeric' { $cloud.contentValueOverrideEnabled = $true; $cloud.contentValueOverride = 1234 }
            'invalid' { $cloud.contentValueOverrideEnabled = $true; $cloud.contentValueOverride = 'not-base64' }
        }
        $cloud.contentVariantPath = 'instance.yaml'
        $marker.releaseVersion = $arguments.ReleaseVersion
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw $ExpectedError

        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects upgrade protection <ProtectionCase> before saving inventory or reconciling' -Tag 'BootstrapUpgrade', 'UpgradeProtection' -ForEach $upgradeProtectionCases {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        Initialize-TestUpgradeProtectionCase -Cloud $cloud -ProtectionCase $ProtectionCase
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw $ExpectedError

        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects an ignorable character in the required reviewer scope' -Tag 'BootstrapUpgrade', 'UpgradePolicyOrdinal' {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $rule = Get-GitHubApiFixture -Name repos/get-repo-ruleset.bootstrap-main
        $rule.rules[2].parameters.required_reviewers[0].file_patterns[0] = "instance$([char]0x00ad).yaml"
        $cloud.rulesetDetailOverride = $rule
        $before = (Get-FileHash -LiteralPath $inventory).Hash

        { & $bootstrap @arguments } | Should -Throw '*upgrade requires the existing main protection*'

        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects upgrade security team <TeamCase> before saving inventory or reconciling' -Tag 'BootstrapUpgrade', 'UpgradeProtection' -ForEach $upgradeTeamCases {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        Initialize-TestUpgradeTeamCase -Cloud $cloud -TeamCase $TeamCase
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        { & $bootstrap @arguments } | Should -Throw '*upgrade requires the existing bootstrap-owned security team*'
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'accepts existing main protection (ResourcesOnly=<OnlyResources>, Parent=<Parent>)' -Tag 'BootstrapUpgrade', 'UpgradeProtection' -ForEach @(
        @{ OnlyResources = $false; Parent = 'null' }
        @{ OnlyResources = $true; Parent = 'team' }
    ) {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/rulesets/60'] =
            Get-GitHubApiFixture -Name repos/get-repo-ruleset.bootstrap-main
        if ($Parent -ceq 'team') {
            $cloud.resources['/orgs/demo-a1b2c3-platform/teams/security'].parent =
                Get-GitHubApiFixture -Name teams/get-by-name
        }
        $arguments.ResourcesOnly = $OnlyResources

        $null = & $bootstrap @arguments

        (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).releaseVersion | Should -BeExactly '0.1.0-rc.10'
    }

    It 'accepts the marker generated by the documented approved-release command' -Tag 'BootstrapUpgrade', 'UpgradeMarkerDocumentation' {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $documentation = Get-Content -LiteralPath (Join-Path (Split-Path $tools -Parent) 'docs/bootstrap.md') -Raw
        $example = [regex]::Match($documentation,
            '(?s)```powershell\r?\n(# Generate the marker from the original approved release,.*?)(?:\r?\n)```')
        $example.Success | Should -BeTrue
        $releaseVersion = $arguments.ReleaseVersion
        $cfg = $instancePath
        $instanceCheckout = Join-Path $casePath 'instance-checkout'
        $null = New-Item -ItemType Directory -Path $instanceCheckout

        & ([scriptblock]::Create($example.Groups[1].Value))
        $markerBlob = $cloud.tree | Where-Object path -CEQ '.platform-bootstrap.json'
        $cloud.blobs[$markerBlob.sha] = [IO.File]::ReadAllBytes((Join-Path $instanceCheckout '.platform-bootstrap.json'))
        $null = & $bootstrap @arguments

        (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).releaseVersion | Should -BeExactly '0.1.0-rc.10'
    }

    It 'rejects upgrade inventory state <State> before any API request' -Tag 'BootstrapUpgrade', 'UpgradeInventoryState' -ForEach $upgradeInventoryCases {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $expected = '*Only an initialized bootstrap inventory*'
        if ($State -ceq 'absent inventory') {
            Remove-Item -LiteralPath $inventory
            $expected = '*UpgradeInventory requires an existing initialized bootstrap inventory*'
        }
        else {
            if ($State -ceq 'missing initialization') { $record.Remove('initializationPending') }
            else { $record.initializationPending = $Pending }
            $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
            $before = (Get-FileHash -LiteralPath $inventory).Hash
        }
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw $expected

        $operations.Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        if ($State -ceq 'absent inventory') { Test-Path -LiteralPath $inventory | Should -BeFalse }
        else { (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before }
    }

    It 'stops before an Azure write when protected main moves after preflight' -Tag 'BootstrapUpgrade', 'MainMovement' {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.1.0-rc.5'
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $arguments.UpgradeInventory = $true
        $cloud.requiredContentRef = $upgradeMainSha
        $marker.releaseVersion = $arguments.ReleaseVersion
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        $credential = @($cloud.resources.Keys | Where-Object { $_ -like '*/federatedIdentityCredentials/*' })[0]
        $cloud.resources.Remove($credential)
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            if ($Operation.Kind -ceq 'Read' -and
                $Operation.Uri -like 'https://management.azure.com/*/federatedIdentityCredentials?*') {
                $cloud.resources['/repos/demo-a1b2c3-platform/instance/git/ref/heads/main'].object.sha = 'bb218f56b14c9653891f9e74264a383fa43fefbd'
            }
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*Protected main changed during bootstrap upgrade*'

        @($operations | Where-Object { $_.Uri -like 'https://management.azure.com/*' -and $_.Kind -ceq 'Reconcile' }).Count | Should -Be 0
        (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).releaseVersion | Should -BeExactly '0.1.0-rc.5'
    }

    It 'rejects case-only movement of protected main before reconciliation' -Tag 'BootstrapUpgrade', 'MainMovement' {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $movement = @{ ReferenceReads = 0; Sha = $upgradeMainSha.ToUpperInvariant() }
        $arguments.RequestPolicy = {
            param($Operation)
            if ($Operation.Uri -like '*/git/ref/heads/main') {
                $movement.ReferenceReads++
                if ($movement.ReferenceReads -eq 2) {
                    $cloud.resources['/repos/demo-a1b2c3-platform/instance/git/ref/heads/main'].object.sha = $movement.Sha
                }
            }
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*Protected main changed during bootstrap upgrade*'

        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'keeps the previous inventory version when protected main moves during provisioning' -Tag 'BootstrapUpgrade', 'MainMovement' {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.1.0-rc.5'
        Set-Content -LiteralPath $inventory -Value ((ConvertTo-PlatformCanonicalJson $record) + "`n") -NoNewline
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $arguments.UpgradeInventory = $true
        $cloud.requiredContentRef = $upgradeMainSha
        $marker.releaseVersion = $arguments.ReleaseVersion
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled = $false
        $movement = @{ ReferenceReads = 0 }
        $cloud.writes.Clear()
        $arguments.RequestPolicy = {
            param($Operation)
            if ($Operation.Uri -like '*/git/ref/heads/main') {
                $movement.ReferenceReads++
            }
            if ($movement.ReferenceReads -eq 4) {
                $cloud.resources['/repos/demo-a1b2c3-platform/instance/git/ref/heads/main'].object.sha = 'bb218f56b14c9653891f9e74264a383fa43fefbd'
            }
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*Protected main changed during bootstrap upgrade*'
        $movement.ReferenceReads | Should -Be 4
        $cloud.writes.Count | Should -Be 0
        (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).releaseVersion | Should -BeExactly '0.1.0-rc.5'
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects <Drift> before any reconciliation request during an inventory upgrade' -Tag 'BootstrapUpgrade' -ForEach @(
        @{ Drift = 'release marker'; ExpectedError = '*approved release*' }
        @{ Drift = 'protected configuration'; ExpectedError = '*configuration differs from protected main*' }
        @{ Drift = 'invalid inventory version'; ExpectedError = '*Unsupported bootstrap inventory upgrade*' }
    ) {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = if ($Drift -ceq 'invalid inventory version') { 'invalid' } else { '0.1.0-rc.5' }
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = Get-FileHash -LiteralPath $inventory
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $cloud.requiredContentRef = $upgradeMainSha
        $marker.releaseVersion = if ($Drift -ceq 'release marker') { '0.1.0-rc.8' } else { $arguments.ReleaseVersion }
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        if ($Drift -ceq 'protected configuration') {
            $configurationBlob = $cloud.tree | Where-Object { $_.path -ceq 'instance.yaml' }
            $configuration = ConvertFrom-Yaml ([Text.Encoding]::UTF8.GetString($cloud.blobs[$configurationBlob.sha]))
            $configuration.instance.name = 'other'
            $cloud.blobs[$configurationBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Yaml $configuration))
        }
        $arguments.UpgradeInventory = $true
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw $ExpectedError

        @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before.Hash
    }

    It 'rejects ignorable marker character <CodePoint> (NoChanges=<ReadOnly>, Culture=<Culture>)' -Tag 'BootstrapUpgrade', 'OrdinalBootstrap' -ForEach @(
        foreach ($culture in @('en-US', 'cs-CZ')) {
            foreach ($codePoint in @(0x00ad, 0x200b)) {
                foreach ($readOnly in @($false, $true)) {
                    @{ Culture = $culture; CodePoint = $codePoint; ReadOnly = $readOnly }
                }
            }
        }
    ) {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $arguments.UpgradeInventory = -not $ReadOnly
        $arguments.NoChanges = $ReadOnly
        $markerBlob = $cloud.tree | Where-Object path -CEQ '.platform-bootstrap.json'
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $marker.releaseVersion = '0.1.0-' + [char] $CodePoint + 'rc.10'
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)

            { & $bootstrap @arguments } | Should -Throw '*marker*release*'

            @($operations | Where-Object Kind -CEQ 'Reconcile').Count | Should -Be 0
            $cloud.writes.Count | Should -Be 0
            (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
    }

    It 'rejects ignorable inventory version character <CodePoint> before any GitHub request under <Culture>' -Tag 'BootstrapUpgrade', 'OrdinalBootstrap' -ForEach @(
        @{ CodePoint = 0x00ad; Culture = 'en-US' }
        @{ CodePoint = 0x200b; Culture = 'en-US' }
        @{ CodePoint = 0x00ad; Culture = 'cs-CZ' }
        @{ CodePoint = 0x200b; Culture = 'cs-CZ' }
    ) {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '1.0.' + [char] $CodePoint + '0'
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $arguments.NoChanges = $true
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)

            { & $bootstrap @arguments } | Should -Throw '*Unsupported bootstrap inventory upgrade*'

            $operations.Count | Should -Be 0
            $cloud.writes.Count | Should -Be 0
            (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
    }

    It 'rejects inventory identity <Field> with an ignorable character before any GitHub request' -Tag 'BootstrapUpgrade', 'OrdinalBootstrap' -ForEach @(
        @{ Field = 'repository'; CodePoint = 0x00ad }
        @{ Field = 'enterprise'; CodePoint = 0x200b }
    ) {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record[$Field] += [char] $CodePoint
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        { & $bootstrap @arguments } | Should -Throw '*inventory belongs to another instance*'

        $operations.Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'keeps the previous inventory version until an authorized upgrade provisions successfully' -Tag 'BootstrapUpgrade' {
        $arguments.ResourcesOnly = $false
        $cloud.commitShaOverride = $upgradeMainSha
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = '0.1.0-rc.5'
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $arguments.ReleaseVersion = '0.1.0-rc.10'
        $cloud.requiredContentRef = $upgradeMainSha
        $marker.releaseVersion = $arguments.ReleaseVersion
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled = $false
        $cloud.failPath = '/repos/demo-a1b2c3-platform/instance/actions/permissions'
        $arguments.UpgradeInventory = $true

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'

        (Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable).releaseVersion | Should -BeExactly '0.1.0-rc.5'

        $result = & $bootstrap @arguments

        $result.ReleaseVersion | Should -BeExactly '0.1.0-rc.10'
        (Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable).releaseVersion | Should -BeExactly '0.1.0-rc.10'
    }

    It 'persists changed App declarations before an upgrade write interrupted at <Failure>' -Tag 'BootstrapUpgrade', 'AppDeclarationRecovery' -ForEach @(
        @{ Failure = 'BeforeApply' }
        @{ Failure = 'LoseResponse' }
    ) {
        Initialize-TestInventoryUpgrade -Arguments $arguments -Cloud $cloud -Inventory $inventory -Bootstrap $bootstrap
        $instance.githubApps.authorization.appId = '102'
        $instance.githubApps.authorization.installationId = '202'
        $cloud.apps['102'] = @{
            installationId = '202'; permissions = @{ members = 'read'; metadata = 'read' }
            selection = 'selected'; slug = 'authorization-replacement'
        }
        $replacementKey = [Security.Cryptography.RSA]::Create(2048)
        try { $replacementKey.ExportRSAPrivateKeyPem() | Set-Content -LiteralPath $keyPath }
        finally { $replacementKey.Dispose() }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $configurationBlob = $cloud.tree | Where-Object path -CEQ 'instance.yaml'
        $cloud.blobs[$configurationBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Yaml $instance))
        $credential = @($cloud.resources.Keys | Where-Object { $_ -like '*/federatedIdentityCredentials/*' })[0]
        $cloud.resources.Remove($credential)
        $failureState = @{ Triggered = $false; Inventory = $null; Path = $inventory; RequestPath = $credential }
        Mock Invoke-WebRequest {
            param([uri] $Uri, [string] $Body, [string] $Method = 'GET', [hashtable] $Headers)
            $call = @{ Uri = $Uri; Body = $Body; Method = $Method; Headers = $Headers }
            if (-not $failureState.Triggered -and $Method -eq 'PUT' -and
                $Uri.AbsolutePath -ceq $failureState.RequestPath) {
                $failureState.Triggered = $true
                $failureState.Inventory = Get-Content -LiteralPath $failureState.Path -Raw | ConvertFrom-Json -AsHashtable
                if ($Failure -ceq 'LoseResponse') { $null = & $cloudTransport @call }
                return [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption."}' }
            }
            & $cloudTransport @call
        }

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'

        $failureState.Triggered | Should -BeTrue
        $failureState.Inventory.declaredApps.authorization.appId | Should -BeExactly '102'
        $failureState.Inventory.declaredApps.authorization.previousAppIds | Should -Contain '101'
        $failureState.Inventory.declaredApps.authorization.removalRequired | Should -BeTrue
        $failureState.Inventory.releaseVersion | Should -BeExactly '0.1.0-rc.5'
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.declaredApps.authorization.appId | Should -BeExactly '102'
        $record.releaseVersion | Should -BeExactly '0.1.0-rc.5'

        $result = & $bootstrap @arguments

        $result.ReleaseVersion | Should -BeExactly '0.1.0-rc.10'
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.declaredApps.authorization.previousAppIds | Should -Contain '101'
        $record.apps.authorization.appId | Should -BeExactly '102'
    }

    It 'validates matching inventory without rewriting its version' -Tag 'NoChanges' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
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
            $Method -ceq 'GET' -and $Uri -like "*/contents/.platform-bootstrap.json?ref=$upgradeMainSha"
        }
        Should -Invoke Invoke-WebRequest -Exactly -Times 1 -ParameterFilter {
            $Method -ceq 'GET' -and $Uri -like "*/contents/instance.yaml?ref=$upgradeMainSha"
        }
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'allows supported inventory upgrades during read-only verification from <From> to <To>' -Tag 'NoChanges', 'BootstrapUpgrade', 'ReadOnlyUpgrade' -ForEach @(
        @{ From = '0.1.0-rc.5'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.10'; To = '0.1.0-rc.12' }
        @{ From = '0.1.0-rc.12'; To = '0.1.0' }
    ) {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.releaseVersion = $From
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        $arguments.ReleaseVersion = $To
        $marker.releaseVersion = $arguments.ReleaseVersion
        $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $cloud.writes.Clear()
        $arguments.NoChanges = $true

        $result = & $bootstrap @arguments

        $result.ReleaseVersion | Should -BeExactly $To
        $result.HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects <VersionState> inventory before any GitHub request in no-change mode' -Tag 'NoChanges' -ForEach @(
        @{ VersionState = 'missing'; Mutation = 'missing' }
        @{ VersionState = 'null'; Mutation = 'null' }
        @{ VersionState = 'empty'; Mutation = 'empty' }
        @{ VersionState = 'unsupported'; Mutation = 'unsupported' }
    ) {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        switch ($Mutation) {
            'missing' { $record.Remove('releaseVersion') }
            'null' { $record.releaseVersion = $null }
            'empty' { $record.releaseVersion = '' }
            'unsupported' { $record.releaseVersion = '0.1.0-rc.4' }
        }
        $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $arguments.NoChanges = $true
        $arguments.RequestPolicy = {
            param($Operation)
            $operations.Add($Operation)
            return $true
        }.GetNewClosure()

        if ($VersionState -ceq 'unsupported') {
            { & $bootstrap @arguments } | Should -Throw '*Unsupported bootstrap inventory upgrade*'
        }
        else {
            { & $bootstrap @arguments } | Should -Throw '*inventory release version*'
        }

        $operations.Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects missing main before issuing any validation token with matching inventory' -Tag 'NoChanges' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $cloud.resources.Remove('/repos/demo-a1b2c3-platform/instance/git/ref/heads/main')
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

    It 'rejects absent inventory even when protected main matches the running release' -Tag 'NoChanges' {
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

    It 'rejects <State> inventory before issuing any validation token in no-change mode' -Tag 'NoChanges' -ForEach @(
        @{ State = 'pending'; Pending = $true }
        @{ State = 'unconfirmed'; Pending = $null }
    ) {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
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

    It 'rejects unprotected main before issuing any validation token with matching inventory' -Tag 'NoChanges' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/rulesets/60'].enforcement = 'disabled'
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

    It 'rejects main moving during verification before issuing any validation token' -Tag 'NoChanges' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
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
            $cloud.resources['/repos/demo-a1b2c3-platform/instance/git/ref/heads/main'] = @{ object = @{ sha = 'bb218f56b14c9653891f9e74264a383fa43fefbd' } }
            $blob = $cloud.tree | Where-Object { $_.path -ceq 'instance.yaml' }
            $bytes = $cloud.blobs[$blob.sha]
            $content = Get-GitHubApiFixture -Name 'repos/get-content.file' -Set @{
                type = 'file'; encoding = 'base64'; size = $bytes.Length
                name = 'instance.yaml'; path = 'instance.yaml'
                content = [Convert]::ToBase64String($bytes); sha = $blob.sha
            }
            [pscustomobject]@{ StatusCode = 200; Content = (ConvertTo-Json -InputObject $content -Depth 100 -Compress) }
        } -ParameterFilter { $Method -ceq 'GET' -and $Uri -like '*/contents/instance.yaml?*' }

        { & $bootstrap @arguments } | Should -Throw '*main changed during*'

        @($operations | Where-Object { $_ -ceq 'TokenIssue' }).Count | Should -Be 0
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects an invalid final NoChanges reference: <Case>' -Tag 'NoChanges', 'FinalMainReference' -ForEach @(
        @{ Case = 'empty SHA array'; ExpectedError = '*commit reference with a valid SHA*' }
        @{ Case = 'array SHA'; ExpectedError = '*commit reference with a valid SHA*' }
        @{ Case = 'unknown type'; ExpectedError = '*commit reference with a valid SHA*' }
        @{ Case = 'array type'; ExpectedError = '*commit reference with a valid SHA*' }
        @{ Case = 'ignorable SHA'; ExpectedError = '*commit reference with a valid SHA*' }
        @{ Case = 'SHA casing'; ExpectedError = '*main changed during NoChanges*' }
    ) {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $before = (Get-FileHash -LiteralPath $inventory).Hash
        $cloud.writes.Clear()
        $arguments.NoChanges = $true
        $referenceState = @{ Reads = 0 }
        Mock Invoke-WebRequest {
            $referenceState.Reads++
            $reply = Get-GitHubApiFixture -Name git/get-ref -Set @{
                ref = 'refs/heads/main'; 'object.sha' = $upgradeMainSha; 'object.type' = 'commit'
            }
            if ($referenceState.Reads -gt 1) {
                # Deliberately invalid final reference shapes must not pass NoChanges verification.
                switch ($Case) {
                    'empty SHA array' { $reply.object.sha = @() }
                    'array SHA' { $reply.object.sha = @($upgradeMainSha) }
                    'unknown type' { $reply.object.type = 'blob' }
                    'array type' { $reply.object.type = @('commit') }
                    'ignorable SHA' { $reply.object.sha = $upgradeMainSha.Insert(2, [string][char]0x200b) }
                    'SHA casing' { $reply.object.sha = $upgradeMainSha.ToUpperInvariant() }
                }
            }
            [pscustomobject]@{ StatusCode = 200; Content = (ConvertTo-Json -InputObject $reply -Depth 100 -Compress) }
        } -ParameterFilter { $Method -ceq 'GET' -and $Uri -like '*/git/ref/heads/main' }

        { & $bootstrap @arguments } | Should -Throw $ExpectedError

        $referenceState.Reads | Should -Be 2
        $cloud.writes.Count | Should -Be 0
        (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before
    }

    It 'rejects <Drift> before tokens or writes with matching inventory' -Tag 'NoChanges' -ForEach @(
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
        $record | ConvertTo-Json -Depth 100 | Set-Content $inventory
        $before = (Get-FileHash $inventory).Hash
        $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
        $remoteMarker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
        switch ($Drift) {
            'missing marker' {
                Mock Invoke-WebRequest {
                    [pscustomobject]@{ StatusCode = 404; Content = '{"message":"Not Found"}' }
                } -ParameterFilter { $Method -ceq 'GET' -and $Uri -like '*/contents/.platform-bootstrap.json?*' }
            }
            'marker version' { $remoteMarker.releaseVersion = '0.9.0' }
            'marker instance' { $remoteMarker.instance = 'another-instance' }
            'marker file hash' { $remoteMarker.files['tools/Invoke-GitHubBootstrap.ps1'] = 'wrong-hash' }
            'extra marker file' { $remoteMarker.files['extra.ps1'] = 'unapproved-hash' }
            'missing configuration' {
                Mock Invoke-WebRequest {
                    [pscustomobject]@{ StatusCode = 404; Content = '{"message":"Not Found"}' }
                } -ParameterFilter { $Method -ceq 'GET' -and $Uri -like '*/contents/instance.yaml?*' }
            }
            'configuration' {
                $configBlob = $cloud.tree | Where-Object { $_.path -ceq 'instance.yaml' }
                $remoteConfig = ConvertFrom-Yaml ([Text.Encoding]::UTF8.GetString($cloud.blobs[$configBlob.sha]))
                $remoteConfig.instance.name = 'other'
                $cloud.blobs[$configBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Yaml $remoteConfig))
            }
            'missing protection' { $cloud.resources.Remove('/repos/demo-a1b2c3-platform/instance/rulesets/60') }
            'main bypass' {
                $cloud.resources['/repos/demo-a1b2c3-platform/instance/rulesets/60'].bypass_actors = @(@{ actor_type = 'OrganizationAdmin'; bypass_mode = 'always' })
            }
            'security reviewers' {
                ($cloud.resources['/repos/demo-a1b2c3-platform/instance/rulesets/60'].rules |
                    Where-Object { $_.type -ceq 'pull_request' }).parameters.required_reviewers = @()
            }
            'main-only policy' {
                $cloud.resources['/repos/demo-a1b2c3-platform/instance/rulesets/60'].conditions.ref_name.include = @('~ALL')
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

    It 'supervises credential validation and verifies revocation during a read-only repeat' -Tag 'NoChanges' {
        $arguments.ResourcesOnly = $false
        $null = & $bootstrap @arguments
        $record = Get-Content $inventory -Raw | ConvertFrom-Json -AsHashtable
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
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml'].state = 'active'
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

        $plan = $cloud.environments['/repos/demo-a1b2c3-platform/instance/environments/application-plan']
        $drift = $cloud.environments['/repos/demo-a1b2c3-platform/instance/environments/application-plan-drift']
        @($plan.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }).Count | Should -Be 0
        @($drift.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }).Count | Should -Be 0
        $cloud.branchRules['/repos/demo-a1b2c3-platform/instance/environments/application-plan-drift/deployment-branch-policies'][0].name | Should -Be 'main'
        $federation = @($cloud.resources.Values | Where-Object { $_.Contains('properties') -and $_.properties.Contains('subject') })
        $federation.properties.subject | Should -Contain 'repo:demo-a1b2c3-platform/instance:environment:application-plan'
        $federation.properties.subject | Should -Contain 'repo:demo-a1b2c3-platform/instance:environment:application-plan-drift'
        $federation.properties.subject | Should -Contain 'repo:demo-a1b2c3-platform/instance:environment:application-apply'
        @($federation | Where-Object { $_.properties.issuer -ne 'https://token.actions.example.ghe.com' }).Count | Should -Be 0
        $teardown = $cloud.environments['/repos/demo-a1b2c3-platform/instance/environments/teardown']
        ($teardown.protection_rules | Where-Object { $_.type -eq 'required_reviewers' }).reviewers[0].reviewer.id | Should -Be 31
        $platformGate = $cloud.environments['/repos/demo-a1b2c3-platform/instance/environments/approve-teardown-platform']
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
            use_default = $true; use_immutable_subject = $true; sub_claim_prefix = 'repo:demo-a1b2c3-platform@10/instance@20'
        }
        & $bootstrap @arguments | Out-Null
        $planPath = $azure.Modules[0].Plan.ResourceId
        $applyPath = $azure.Modules[0].Apply.ResourceId
        $plan = @($cloud.resources.Keys | Where-Object { $_.StartsWith("$planPath/federatedIdentityCredentials/") } |
            ForEach-Object { $cloud.resources[$_].properties.subject })
        $apply = @($cloud.resources.Keys | Where-Object { $_.StartsWith("$applyPath/federatedIdentityCredentials/") } |
            ForEach-Object { $cloud.resources[$_].properties.subject })
        $plan | Should -HaveCount 2
        $plan | Should -Contain 'repo:demo-a1b2c3-platform@10/instance@20:environment:application-plan'
        $plan | Should -Contain 'repo:demo-a1b2c3-platform@10/instance@20:environment:application-plan-drift'
        $apply | Should -HaveCount 1
        $apply[0] | Should -BeExactly 'repo:demo-a1b2c3-platform@10/instance@20:environment:application-apply'
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
            PrefixIds { $cloud.oidcSettings.sub_claim_prefix = 'repo:demo-a1b2c3-platform@10/instance@999' }
            MissingPrefix { $cloud.oidcSettings.Remove('sub_claim_prefix') }
            MissingOwnerId { $cloud.resources['/repos/demo-a1b2c3-platform/instance'].owner.Remove('id') }
            MissingOwner { $cloud.resources['/repos/demo-a1b2c3-platform/instance'].Remove('owner') }
            StringOwnerId { $cloud.resources['/repos/demo-a1b2c3-platform/instance'].owner.id = '10' }
            DifferentOwner { $cloud.resources['/repos/demo-a1b2c3-platform/instance'].owner.login = 'other-platform' }
            ZeroRepositoryId { $cloud.resources['/repos/demo-a1b2c3-platform/instance'].id = 0 }
        }
        { & $bootstrap @arguments } | Should -Throw '*OIDC*'
        @($cloud.writes | Where-Object { $_.path -like '*/federatedIdentityCredentials*' }) | Should -HaveCount 0
        @($cloud.writes | Where-Object { $_.path -like '*/actions/oidc/*' }) | Should -HaveCount 0
    }

    It 'refuses to silently migrate existing legacy federation when the repository switches to immutable subjects' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $cloud.oidcSettings = @{
            use_default = $true; use_immutable_subject = $true; sub_claim_prefix = 'repo:demo-a1b2c3-platform@10/instance@20'
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
        $cloud.teamRepositoryResponses['/orgs/demo-a1b2c3-platform/teams/platform/repos/demo-a1b2c3-platform/instance'] = @{
            StatusCode = $Code; Content = $Content
        }

        { & $bootstrap @arguments } | Should -Throw '*team repository permissions*'

        $cloud.writes.Count | Should -Be 0
    }

    It 'reports invalid JSON in a team permission detail without a permission write' -Tag 'TeamPermissions' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $cloud.teamRepositoryResponses['/orgs/demo-a1b2c3-platform/teams/platform/repos/demo-a1b2c3-platform/instance'] = @{
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
        $accessPath = '/orgs/demo-a1b2c3-platform/teams/platform/repos/demo-a1b2c3-platform/instance'
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
        $accessPath = '/orgs/demo-a1b2c3-platform/teams/platform/repos/demo-a1b2c3-platform/instance'
        $cloud.resources[$accessPath].permission = 'pull'
        $cloud.failPath = $accessPath

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'

        $cloud.resources[$accessPath].permission | Should -Be 'pull'
        $cloud.writes.Count | Should -Be 0
    }

    It 'does not claim push access when a successful permission update is not confirmed' -Tag 'TeamPermissions' {
        & $bootstrap @arguments | Out-Null
        $cloud.writes.Clear()
        $accessPath = '/orgs/demo-a1b2c3-platform/teams/platform/repos/demo-a1b2c3-platform/instance'
        $cloud.teamRepositoryResponses[$accessPath] = @{
            StatusCode = 200; Content = '{"permissions":{"push":false}}'
        }

        { & $bootstrap @arguments } | Should -Throw '*push access*after*update*'

        @($cloud.writes | Where-Object { $_.path -eq $accessPath }).Count | Should -Be 1
    }

    It 'verifies the authorization App before uploading an encrypted key and records its rotation deadline' {
        $instance.githubApps = @{ authorization = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }; resources = @{ organizations = @('demo-a1b2c3-platform'); repositories = @{} }
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
        $cloud.secrets['/repos/demo-a1b2c3-platform/instance/environments/pr-authorization/secrets/PLATFORM_APP_PRIVATE_KEY'].encrypted_value | Should -Be 'encrypted-key'
        @($cloud.secrets.Keys).Count | Should -Be 1
        $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $record.apps.authorization.owner | Should -Be 'platform'
        $record.apps.authorization.rotateBy | Should -Not -BeNullOrEmpty
        (Get-Content -LiteralPath $inventory -Raw) | Should -Not -Match 'BEGIN.*PRIVATE KEY|installation-test|gho_test'
        $cloud.writes.Clear()
        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
    }

    Context 'vendoring App isolation' -Tag 'Vendoring' {
        BeforeEach {
            Initialize-TestVendoringAppSet -Instance $instance -Cloud $cloud -KeysPath $keysPath -CasePath $casePath
            $arguments.ResourcesOnly = $false
            $arguments.VendoringActionApp = 'action-import'
            $arguments.VendoringReleaseApp = 'release-import'
            $arguments.VendoringSourceApp = 'source-import'
            $arguments.VendoringSourceRepository = 'demo-a1b2c3-platform/private-source'
        }

        It 'verifies separate selected Apps with the <OwnerVariant> owner and uploads keys only to vendoring environments' -ForEach @(
            @{ OwnerVariant = 'Simple User'; EnterpriseOwnerVariant = $false }
            @{ OwnerVariant = 'Enterprise'; EnterpriseOwnerVariant = $true }
        ) {
            $cloud.enterpriseOwnerVariant = $EnterpriseOwnerVariant
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            $result = & $bootstrap @arguments
            $result.CredentialsConfigured | Should -BeTrue
            foreach ($entry in @(
                @{ environment = 'vendoring-action-import'; id = '160' }
                @{ environment = 'vendoring-release-import'; id = '161' }
                @{ environment = 'vendoring-source'; id = '162' }
            )) {
                $path = "/repos/demo-a1b2c3-platform/instance/environments/$($entry.environment)"
                $cloud.variables["$path/variables/PLATFORM_APP_ID"] | Should -BeExactly $entry.id
                $cloud.secrets["$path/secrets/PLATFORM_APP_PRIVATE_KEY"].encrypted_value | Should -BeExactly 'encrypted-key'
            }
            $cloud.variables['/repos/demo-a1b2c3-platform/instance/environments/vendoring-source/variables/SOURCE_REPOSITORY'] |
                Should -BeExactly 'demo-a1b2c3-platform/private-source'
            $cloud.variables['/repos/demo-a1b2c3-platform/instance/environments/vendoring-source/variables/SOURCE_API_URL'] |
                Should -BeExactly 'https://api.example.ghe.com'
            $cloud.secrets.Count | Should -Be 4
            $cloud.writes.Clear()
            (& $bootstrap @arguments).HasChanges | Should -BeFalse
            $cloud.writes.Count | Should -Be 0
        }

        It 'rejects a vendoring binding with <Case> before uploading keys' -ForEach @(
            @{ Case = 'unknown alias'; Error = '*vendoring App alias*'; Change = { $arguments.VendoringActionApp = 'missing' } }
            @{ Case = 'wrong enterprise'; Error = '*vendoring App contract*'; Change = { $instance.githubApps.'action-import'.enterprise = 'other' } }
            @{ Case = 'extra permission'; Error = '*vendoring App contract*'; Change = { $instance.githubApps.'action-import'.permissions.workflows = 'write' } }
            @{ Case = 'read-only writer'; Error = '*vendoring App contract*'; Change = { $instance.githubApps.'action-import'.permissions.contents = 'read' } }
            # Intentionally invalid permission enum; schema validation must reject it before credential setup.
            @{ Case = 'wrong permission case'; Error = '*enum*permissions.contents*'; Change = { $instance.githubApps.'action-import'.permissions.contents = 'Write' } }
            @{ Case = 'wrong organization'; Error = '*repositories outside its organizations*'; Change = { $instance.githubApps.'action-import'.resources.organizations = @('other-actions') } }
            @{ Case = 'extra organization'; Error = '*vendoring App contract*'; Change = { $instance.githubApps.'action-import'.resources.organizations += 'other-actions' } }
            @{ Case = 'all repositories'; Error = '*selected repositories*'; Change = { $instance.githubApps.'action-import'.resources.Remove('repositories') } }
            @{ Case = 'empty repository map'; Error = '*selected repositories*'; Change = { $instance.githubApps.'action-import'.resources.repositories = @{} } }
            @{ Case = 'wrong release repository'; Error = '*vendoring App contract*'; Change = { $instance.githubApps.'release-import'.resources.repositories.'demo-a1b2c3-platform' = @('other') } }
            @{ Case = 'release repository case'; Error = '*vendoring App contract*'; Change = { $instance.githubApps.'release-import'.resources.repositories.'demo-a1b2c3-platform' = @('Instance') } }
            @{ Case = 'wrong source repository'; Error = '*vendoring App contract*'; Change = { $arguments.VendoringSourceRepository = 'demo-a1b2c3-platform/other' } }
            @{ Case = 'missing source repository'; Error = '*source repository*'; Change = { $arguments.Remove('VendoringSourceRepository') } }
            @{ Case = 'source on github.com'; Error = '*source API must belong to the instance*'; Change = { $arguments.VendoringSourceApiUrl = 'https://api.github.com' } }
            @{ Case = 'source on another tenant'; Error = '*source API must belong to the instance*'; Change = { $arguments.VendoringSourceApiUrl = 'https://api.other.ghe.com' } }
            @{ Case = 'shared writer identity'; Error = '*share its identity*'; Change = { $instance.githubApps.'action-import'.appId = '161' } }
            @{ Case = 'shared authorization identity'; Error = '*share its identity*'; Change = { $instance.githubApps.'action-import'.appId = '101' } }
        ) {
            . $Change
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            { & $bootstrap @arguments } | Should -Throw $Error
            $cloud.secrets.Count | Should -Be 0
        }

        It 'warns about each unbound environment and rejects its stale <Credential>' -ForEach @(
            @{ Credential = 'key'; IsVariable = $false }
            @{ Credential = 'App ID variable'; IsVariable = $true }
        ) {
            $arguments.Remove('VendoringActionApp')
            $arguments.Remove('VendoringReleaseApp')
            $arguments.Remove('VendoringSourceApp')
            $arguments.Remove('VendoringSourceRepository')
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            $null = & $bootstrap @arguments -WarningVariable warnings -WarningAction SilentlyContinue
            foreach ($name in @('vendoring-source', 'vendoring-action-import', 'vendoring-release-import')) {
                ($warnings -join "`n") | Should -Match $name
                $path = "/repos/demo-a1b2c3-platform/instance/environments/$name"
                $store = if ($IsVariable) { $cloud.variables } else { $cloud.secrets }
                $path += $(if ($IsVariable) { '/variables/PLATFORM_APP_ID' } else { '/secrets/PLATFORM_APP_PRIVATE_KEY' })
                $store[$path] = $(if ($IsVariable) { '160' } else { @{ encrypted_value = 'stale' } })
                { & $bootstrap @arguments -WarningAction SilentlyContinue } | Should -Throw '*vendoring*without an App binding*'
                $store.Remove($path)
            }
        }

        It 'rejects inherited or cloud credentials <Case> instead of putting them in vendoring jobs' -ForEach @(
            @{ Case = 'repository key'; Path = '/repos/demo-a1b2c3-platform/instance/actions/secrets/PLATFORM_APP_PRIVATE_KEY'; Variable = $false }
            @{ Case = 'organization key'; Path = '/orgs/demo-a1b2c3-platform/actions/secrets/PLATFORM_APP_PRIVATE_KEY'; Variable = $false }
            @{ Case = 'cloud secret'; Path = '/repos/demo-a1b2c3-platform/instance/environments/vendoring-action-import/secrets/AZURE_CLIENT_SECRET'; Variable = $false }
            @{ Case = 'cloud variable'; Path = '/repos/demo-a1b2c3-platform/instance/environments/vendoring-action-import/variables/AZURE_CLIENT_ID'; Variable = $true }
            @{ Case = 'noncanonical variable'; Path = '/repos/demo-a1b2c3-platform/instance/environments/vendoring-action-import/variables/platform_app_id'; Variable = $true }
        ) {
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            if ($Variable) { $cloud.variables[$Path] = 'cloud' } else { $cloud.secrets[$Path] = @{ encrypted_value = 'inherited' } }
            { & $bootstrap @arguments } | Should -Throw
            @($cloud.writes | Where-Object { $_.path -like '*/secrets/PLATFORM_APP_PRIVATE_KEY' }).Count | Should -Be 0
        }
    }

    Context 'drift report App' -Tag 'DriftReport' {
        BeforeEach {
            $driftApp = @{ appId = '150'; installationId = '250'; enterprise = 'example'; permissions = @{ issues = 'write' }
                resources = @{ organizations = @('demo-a1b2c3-platform'); repositories = @{ 'demo-a1b2c3-platform' = @('instance') } } }
            $instance.githubApps.drift = $driftApp
            $cloud.apps['150'] = @{ installationId = '250'; permissions = @{ issues = 'write'; metadata = 'read' }
                selection = 'selected'; slug = 'platform-drift'; repositories = @('instance') }
            $driftKeyPath = Join-Path $casePath 'drift.pem'
            $driftRsa = [Security.Cryptography.RSA]::Create(2048)
            try { $driftRsa.ExportRSAPrivateKeyPem() | Set-Content -LiteralPath $driftKeyPath }
            finally { $driftRsa.Dispose() }
            $driftKeys = Get-Content -LiteralPath $keysPath -Raw | ConvertFrom-Json -AsHashtable
            $driftKeys.drift = @{} + $driftKeys.authorization
            $driftKeys.drift.privateKeyPath = $driftKeyPath
            ConvertTo-Json -InputObject $driftKeys -Depth 10 | Set-Content -LiteralPath $keysPath
            $arguments.ResourcesOnly = $false
            $arguments.DriftReportApp = 'drift'
            $driftEnvironment = '/repos/demo-a1b2c3-platform/instance/environments/drift-report'
        }

        It 'verifies the issue-writer App and binds it only to the main-only drift-report environment' {
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

            $result = & $bootstrap @arguments

            $result.CredentialsConfigured | Should -BeTrue
            $cloud.variables["$driftEnvironment/variables/PLATFORM_APP_ID"] | Should -Be '150'
            $cloud.variables["$driftEnvironment/variables/PLATFORM_APP_INSTALLATION_ID"] | Should -Be '250'
            $cloud.secrets["$driftEnvironment/secrets/PLATFORM_APP_PRIVATE_KEY"].encrypted_value | Should -Be 'encrypted-key'
            $cloud.environments[$driftEnvironment].protection_rules | Where-Object { $_.type -eq 'required_reviewers' } | Should -BeNullOrEmpty
            @($cloud.writes | Where-Object { $_.path -eq "$driftEnvironment/deployment-branch-policies" -and $_.body.name -eq 'main' }).Count | Should -Be 1
            @($cloud.secrets.Keys | Where-Object { $_ -like '*/PLATFORM_APP_PRIVATE_KEY' }).Count | Should -Be 2
            (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).apps.drift.appId | Should -Be '150'
        }

        It 'rejects a drift report App with <Case> before publishing any key' -ForEach @(
            @{ Case = 'an unknown alias'; Alias = 'missing'; Change = {} }
            @{ Case = 'read-only issues'; Alias = 'drift'; Change = { $instance.githubApps.drift.permissions = @{ issues = 'read' } } }
            @{ Case = 'an extra permission'; Alias = 'drift'; Change = { $instance.githubApps.drift.permissions.contents = 'read' } }
            @{ Case = 'another repository'; Alias = 'drift'; Change = { $instance.githubApps.drift.resources.repositories.'demo-a1b2c3-platform' = @('other') } }
            @{ Case = 'two repositories'; Alias = 'drift'; Change = { $instance.githubApps.drift.resources.repositories.'demo-a1b2c3-platform' = @('instance', 'other') } }
            @{ Case = 'organization-wide access'; Alias = 'drift'; Change = { $instance.githubApps.drift.resources.Remove('repositories') } }
            @{ Case = 'another enterprise'; Alias = 'drift'; Change = { $instance.githubApps.drift.enterprise = 'other' } }
            @{ Case = 'the authorization App identity'; Alias = 'drift'; Change = { $instance.githubApps.drift.appId = '101' } }
        ) {
            . $Change
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            $arguments.DriftReportApp = $Alias

            { & $bootstrap @arguments } | Should -Throw '*drift report App*'
            $cloud.secrets.Count | Should -Be 0
        }

        It 'warns without a drift report App and refuses a stale key in the drift-report environment' {
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            $arguments.Remove('DriftReportApp')

            $result = & $bootstrap @arguments -WarningVariable warnings -WarningAction SilentlyContinue

            $result.CredentialsConfigured | Should -BeTrue
            ($warnings -join "`n") | Should -Match 'drift report App'
            $cloud.environments.ContainsKey($driftEnvironment) | Should -BeTrue
            $cloud.secrets.ContainsKey("$driftEnvironment/secrets/PLATFORM_APP_PRIVATE_KEY") | Should -BeFalse
            $cloud.secrets["$driftEnvironment/secrets/PLATFORM_APP_PRIVATE_KEY"] = @{ encrypted_value = 'stale' }

            { & $bootstrap @arguments -WarningAction SilentlyContinue } | Should -Throw '*drift-report*App key without*drift report App*'
        }
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

    It 'isolates all three <GovernanceModule> App identities and validates reader permissions (<Immutable>, <Mode>, <MissingAt>)' -Tag 'CodeSecurityReader' -TestCases @(
        @{ GovernanceModule = 'enterprise-baseline'; Immutable = $false; Mode = 'Bootstrap'; MissingAt = '' }
        @{ GovernanceModule = 'enterprise-baseline'; Immutable = $true; Mode = 'Bootstrap'; MissingAt = '' }
        @{ GovernanceModule = 'organization-rulesets'; Immutable = $false; Mode = 'Bootstrap'; MissingAt = '' }
        @{ GovernanceModule = 'enterprise-baseline'; Immutable = $false; Mode = 'Bootstrap'; MissingAt = 'App' }
        @{ GovernanceModule = 'enterprise-baseline'; Immutable = $false; Mode = 'Bootstrap'; MissingAt = 'Installation' }
        @{ GovernanceModule = 'enterprise-baseline'; Immutable = $false; Mode = 'NoChanges'; MissingAt = 'App' }
        @{ GovernanceModule = 'enterprise-baseline'; Immutable = $false; Mode = 'NoChanges'; MissingAt = 'Installation' }
        @{ GovernanceModule = 'enterprise-baseline'; Immutable = $false; Mode = 'UpgradeInventory'; MissingAt = 'App' }
        @{ GovernanceModule = 'enterprise-baseline'; Immutable = $false; Mode = 'UpgradeInventory'; MissingAt = 'Installation' }
    ) {
        param($GovernanceModule, $Immutable, $Mode, $MissingAt)
        if ($GovernanceModule -ceq 'enterprise-baseline') {
            $manifestPath = Join-Path $release 'modules/enterprise-baseline/module.yaml'
            $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
            $production = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path (Split-Path $tools -Parent) 'modules/enterprise-baseline/module.yaml') -Raw)
            $manifest.permissions.githubApp.plan = $production.permissions.githubApp.plan
            ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
            & (Join-Path $releaseTools.FullName 'Generate-DeploymentWorkflow.ps1') -ModulesPath (Join-Path $release 'modules') `
                -OutputPath (Join-Path $release 'templates/instance/.github/workflows/deploy.yml')
        }
        if ($GovernanceModule -cne 'enterprise-baseline') {
            # Reuse the isolated governance fixture under the module name that bootstrap must protect.
            $modulesRoot = Join-Path $release 'modules'
            Rename-Item -LiteralPath (Join-Path $modulesRoot 'enterprise-baseline') -NewName $GovernanceModule
            $manifestPath = Join-Path $modulesRoot "$GovernanceModule/module.yaml"
            (Get-Content -LiteralPath $manifestPath -Raw).Replace('name: enterprise-baseline', "name: $GovernanceModule") | Set-Content -LiteralPath $manifestPath
            & (Join-Path $releaseTools.FullName 'Generate-DeploymentWorkflow.ps1') -ModulesPath $modulesRoot `
                -OutputPath (Join-Path $release 'templates/instance/.github/workflows/deploy.yml')
        }
        $subjectPrefix = if ($Immutable) { 'repo:demo-a1b2c3-platform@10/instance@20' } else { 'repo:demo-a1b2c3-platform/instance' }
        $cloud.oidcSettings = @{ use_default = $true; use_immutable_subject = $Immutable; sub_claim_prefix = $subjectPrefix }
        $instance.modules = @{ $GovernanceModule = @{ parameters = @{ target_organizations = @('demo-a1b2c3-platform') } } }
        $instance.credentials = @{ $GovernanceModule = @{
            plan = @{ environment = "$GovernanceModule-plan"; githubApp = 'reader' }
            apply = @{ environment = "$GovernanceModule-apply"; githubApp = 'writer' }
            rulesetPlan = @{ environment = "$GovernanceModule-ruleset-plan"; githubApp = 'rulesets' }
        } }
        $keyManifest = Get-Content -LiteralPath $keysPath -Raw | ConvertFrom-Json -AsHashtable
        $index = 102
        foreach ($alias in @('reader', 'writer', 'rulesets')) {
            $permissions = @{ organization_administration = $(if ($alias -eq 'reader') { 'read' } else { 'write' }) }
            if ($GovernanceModule -ceq 'enterprise-baseline' -and $alias -ceq 'reader') {
                $permissions = @{ organization_administration = 'read'; administration = 'read'; metadata = 'read' }
            }
            $app = @{ appId = [string] $index; installationId = [string] ($index + 100); enterprise = 'example'
                permissions = $permissions; resources = @{ organizations = @('demo-a1b2c3-platform') } }
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
        foreach ($name in @('service', $GovernanceModule)) {
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

        if ($Mode -cne 'Bootstrap') {
            $null = & $bootstrap @arguments
            $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
            $record.releaseVersion = '0.1.0-rc.12'
            $record | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $inventory
            $arguments.ReleaseVersion = '0.1.0-rc.13'
            $markerBlob = $cloud.tree | Where-Object { $_.path -ceq '.platform-bootstrap.json' }
            $marker = [Text.Encoding]::UTF8.GetString($cloud.blobs[$markerBlob.sha]) | ConvertFrom-Json -AsHashtable
            $marker.releaseVersion = $arguments.ReleaseVersion
            $cloud.blobs[$markerBlob.sha] = [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $marker))
            $arguments[$Mode] = $true
            $before = (Get-FileHash -LiteralPath $inventory).Hash
            $cloud.writes.Clear()
        }
        foreach ($alias in @('writer', 'rulesets')) {
            $instance.githubApps[$alias].permissions.ContainsKey('administration') | Should -BeFalse
        }
        if ($MissingAt) {
            $missingPermission = @{} + $cloud.apps['102'].permissions
            $missingPermission.Remove('administration')
            if ($MissingAt -ceq 'App') { $cloud.apps['102'].permissions = $missingPermission }
            else { $cloud.apps['102'].installationPermissions = $missingPermission }

            { & $bootstrap @arguments } |
                Should -Throw '*permissions differ*administration*read*Permissions & events*approve*'

            $expectedReaderIssues = if ($Mode -ceq 'Bootstrap') { 0 } else { 1 }
            Should -Invoke Invoke-RestMethod -Times $expectedReaderIssues -Exactly -ParameterFilter {
                $Method -ceq 'POST' -and $Uri -like '*/app/installations/202/access_tokens'
            }
            if ($Mode -ceq 'Bootstrap') { $cloud.secrets.Count | Should -Be 0 }
            else {
                if ($Mode -ceq 'NoChanges') { (Get-FileHash -LiteralPath $inventory).Hash | Should -BeExactly $before }
                else { (Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable).releaseVersion | Should -BeExactly '0.1.0-rc.12' }
                $cloud.writes.Count | Should -Be 0
            }
            return
        }
        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        $prefix = '/repos/demo-a1b2c3-platform/instance/environments'
        $cloud.variables["$prefix/$GovernanceModule-plan/variables/PLATFORM_APP_ID"] | Should -Be '102'
        $cloud.variables["$prefix/$GovernanceModule-plan-drift/variables/PLATFORM_APP_ID"] | Should -Be '102'
        $cloud.variables["$prefix/$GovernanceModule-ruleset-plan/variables/PLATFORM_APP_ID"] | Should -Be '104'
        $cloud.variables["$prefix/$GovernanceModule-ruleset-plan-drift/variables/PLATFORM_APP_ID"] | Should -Be '104'
        $cloud.variables["$prefix/$GovernanceModule-apply/variables/PLATFORM_APP_ID"] | Should -Be '103'
        $securityReview = $cloud.environments["$prefix/$GovernanceModule-apply"].protection_rules |
            Where-Object { $_.type -eq 'required_reviewers' }
        $securityReview.reviewers[0].reviewer.id | Should -Be 31
        foreach ($environment in @("$GovernanceModule-plan", "$GovernanceModule-plan-drift", "$GovernanceModule-ruleset-plan", "$GovernanceModule-ruleset-plan-drift")) {
            $cloud.environments.ContainsKey("$prefix/$environment") | Should -BeTrue
            $cloud.environments["$prefix/$environment"].protection_rules | Where-Object { $_.type -eq 'required_reviewers' } |
                Should -BeNullOrEmpty -Because "$environment runs read-only plans"
        }
        @($cloud.secrets.Keys).Count | Should -Be 6
        $federation = @($cloud.resources.Values | Where-Object { $_.Contains('properties') -and $_.properties.Contains('subject') })
        @($federation | Where-Object { $_.properties.subject -like "*$GovernanceModule*" }).Count | Should -Be 5
        $identity = $azure.Modules | Where-Object { $_.Name -eq $GovernanceModule }
        $planSubjects = @($cloud.resources.Keys | Where-Object { $_.StartsWith("$($identity.Plan.ResourceId)/federatedIdentityCredentials/") } |
            ForEach-Object { $cloud.resources[$_].properties.subject })
        $applySubjects = @($cloud.resources.Keys | Where-Object { $_.StartsWith("$($identity.Apply.ResourceId)/federatedIdentityCredentials/") } |
            ForEach-Object { $cloud.resources[$_].properties.subject })
        $planSubjects | Should -HaveCount 4
        foreach ($environment in @("$GovernanceModule-plan", "$GovernanceModule-plan-drift", "$GovernanceModule-ruleset-plan", "$GovernanceModule-ruleset-plan-drift")) {
            $planSubjects | Should -Contain "${subjectPrefix}:environment:$environment"
        }
        $applySubjects | Should -HaveCount 1
        $applySubjects[0] | Should -BeExactly "${subjectPrefix}:environment:$GovernanceModule-apply"
        @($federation | Where-Object { $_.properties.subject -match 'pr-authorization|approve-|teardown' }) | Should -HaveCount 0
    }

    It 'does not publish keys or initial main when an App is owned by a workload organization' {
        $cloud.appOwner = @{ login = 'demo-a1b2c3-platform'; type = 'Organization' }
        $arguments.ResourcesOnly = $false

        { & $bootstrap @arguments } | Should -Throw '*not owned by the declared enterprise*'
        $cloud.secrets.Count | Should -Be 0
        $cloud.commit | Should -BeNullOrEmpty
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeFalse
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
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeFalse
    }

    It 'resumes an interrupted secret upload without replacing the seeded release' {
        $arguments.ResourcesOnly = $false
        $cloud.failPath = '/repos/demo-a1b2c3-platform/instance/environments/pr-authorization/secrets/PLATFORM_APP_PRIVATE_KEY'

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
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeFalse
    }

    It 'creates protected main even when the organization initializes repositories on master' {
        $cloud.defaultBranch = 'master'
        $arguments.ResourcesOnly = $false

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        $cloud.resources['/repos/demo-a1b2c3-platform/instance'].default_branch | Should -Be 'main'
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/git/ref/heads/main'].object.sha | Should -BeExactly $upgradeMainSha
        $cloud.writes.Clear()
        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
    }

    It 'accepts the Azure script result object without requiring a separate serialized file' {
        $arguments.AzureBootstrap = [pscustomobject] $azure

        (& $bootstrap @arguments).Repository | Should -Be 'demo-a1b2c3-platform/instance'
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

        $record.resources | Should -Contain '/orgs/demo-a1b2c3-platform'
        $record.resources | Should -Contain '/repos/demo-a1b2c3-platform/instance'
        $record.resources | Should -Contain '/orgs/demo-a1b2c3-platform/teams/platform'
        $record.resources | Should -Contain '/repos/demo-a1b2c3-platform/instance/environments/application-plan'
        $record.resources | Should -Contain '/repos/demo-a1b2c3-platform/instance/rulesets/60'
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
        $cloud.appOwner = @{ login = 'demo-a1b2c3-platform'; type = 'Organization' }

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
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeTrue
        $cloud.writes.Clear()

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        @($cloud.writes | Where-Object { $_.path -ceq '/orgs/demo-a1b2c3-platform/repos' }).Count | Should -Be 0
        $cloud.commit.parents | Should -Be @('seed-sha')
        @($cloud.writes)[0].path | Should -Be '/repos/demo-a1b2c3-platform/instance/actions/permissions'
        @($cloud.writes)[0].body.enabled | Should -BeFalse
        $completed = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
        $completed.seedCommit | Should -Be 'seed-sha'
        $completed.initializationPending | Should -BeFalse
        $cloud.writes.Clear()
        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
    }

    It 'disables Actions on retry when repository creation succeeded but disabling was interrupted' {
        $cloud.failPath = '/repos/demo-a1b2c3-platform/instance/actions/permissions'

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeTrue
        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeFalse
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeFalse
        $cloud.commit | Should -BeNullOrEmpty
    }

    It 'does not restore bootstrap memberships after initialized teams have been synchronized' {
        $arguments.ResourcesOnly = $false
        & $bootstrap @arguments | Out-Null
        $cloud.resources.Remove('/orgs/demo-a1b2c3-platform/teams/platform/memberships/owner_example')
        $cloud.resources.Remove('/orgs/demo-a1b2c3-platform/teams/security/memberships/owner_example')
        $cloud.writes.Clear()

        (& $bootstrap @arguments).HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be 0
        $cloud.resources.ContainsKey('/orgs/demo-a1b2c3-platform/teams/platform/memberships/owner_example') | Should -BeFalse
        $cloud.resources.ContainsKey('/orgs/demo-a1b2c3-platform/teams/security/memberships/owner_example') | Should -BeFalse
    }

    It 'activates only acceptance and disables every other workflow before enabling Actions' {
        @{ kind = 'github-bootstrap-acceptance' } | ConvertTo-Json | Set-Content (Join-Path $release 'bootstrap-acceptance.json')
        Copy-Item (Join-Path $tools 'acceptance/github/bootstrap-acceptance.yml') `
            -Destination (Join-Path $release 'templates/instance/.github/workflows/bootstrap-acceptance.yml')
        'name: Future' | Set-Content (Join-Path $release 'templates/instance/.github/workflows/future.yml')
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/custom.yml'] = @{ state = 'active' }
        $arguments.ResourcesOnly = $false
        $arguments.AcceptanceOnly = $true

        $result = & $bootstrap @arguments

        $result.CredentialsConfigured | Should -BeTrue
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/bootstrap-acceptance.yml'].state | Should -Be 'active'
        $paths = @($cloud.writes.path)
        $enabled = @($cloud.writes | Where-Object { $_.path -like '*/actions/permissions' -and $_.body.enabled })[0]
        foreach ($name in @('deploy.yml', 'vendor.yml', 'future.yml', 'custom.yml')) {
            $path = "/repos/demo-a1b2c3-platform/instance/actions/workflows/$name"
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
            $cloud.resources["/repos/demo-a1b2c3-platform/instance/actions/workflows/$name"].state | Should -Be 'active'
            $cloud.tree.path | Should -Contain ".github/workflows/$name"
        }
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeTrue
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
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeTrue
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml'].state = 'active'
        $cloud.failPath = '/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml/disable'

        { & $bootstrap @arguments } | Should -Throw '*HTTP 503*'

        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeFalse
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml'].state | Should -Be 'active'
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
            $cloud.failPath = '/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml/disable'
            $errorMessage = '*HTTP 503*'
        }
        elseif ($Failure -ceq 'unconfirmed') {
            $cloud.unconfirmedDisable = '/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml/disable'
            $errorMessage = '*was not disabled*'
        }
        else {
            $cloud.unregisteredWorkflow = '.github/workflows/vendor.yml'
            $errorMessage = '*not uniquely registered*'
        }

        { & $bootstrap @arguments } | Should -Throw $errorMessage

        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeFalse
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml'].state | Should -Be 'active'
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
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml'].state = 'active'
        $cloud.unregisteredWorkflow = '.github/workflows/vendor.yml'
        $cloud.failPath = '/repos/demo-a1b2c3-platform/instance/actions/permissions'

        { & $bootstrap @arguments } | Should -Throw '*not uniquely registered*Repository Actions isolation also failed*HTTP 503*'

        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/permissions'].enabled | Should -BeTrue
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/vendor.yml'].state | Should -Be 'active'
        $cloud.writes.Count | Should -Be 0
    }

    It 'drives the public acceptance wizard through publication and real-run evidence without accepting missing nightly or rotation checks' -Tag StateIsolation {
        $cloud.expectedIssuanceStatePath = $PSDefaultParameterValues['New-PlatformGitHubToken.ps1:IssuanceStatePath']
        $sourceRoot = Split-Path $tools -Parent
        Copy-Item (Join-Path $tools 'acceptance') -Destination (Join-Path $release 'tools') -Recurse
        foreach ($name in @('bootstrap-probe', 'enterprise-baseline', 'organization-rulesets')) {
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
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/deploy.yml'] = @{ state = 'active' }
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/runs/80'] = @{
            id = 80; head_sha = $upgradeMainSha; run_attempt = 1; status = 'completed'; conclusion = 'success'; event = 'workflow_dispatch'
        }
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/bootstrap-acceptance.yml/runs'] = @{ workflow_runs = @() }
        $cloud.scheduledRuns = @()
        $cloud.loseDispatchResponse = $true
        $cloud.dispatchRecovery = $false
        $cloud.retryUsed = $false
        $cloud.failDownload = $false
        $setupModule = Import-Module (Join-Path $sourceRoot 'tools/InstanceSetup.psm1') -Force -PassThru
        $savedSetupPSDefaultParameterValues = $setupModule.SessionState.PSVariable.GetValue('PSDefaultParameterValues')
        $setupModule.SessionState.PSVariable.Set('PSDefaultParameterValues', @{} + $PSDefaultParameterValues)
        Mock Invoke-WebRequest -ModuleName InstanceSetup $cloudTransport
        Mock Invoke-RestMethod -ModuleName InstanceSetup $appTransport
        Mock az -ModuleName InstanceSetup {
            $global:LASTEXITCODE = 0
            '{"tenant":"11111111-1111-1111-1111-111111111111","accessToken":"azure-test"}'
        }
        Mock Write-Host -ModuleName InstanceSetup {}
        Mock Get-RandomPlatformDeploymentIdentifier -ModuleName InstanceSetup { 'a1b2c3' }
        Mock Read-Host -ModuleName InstanceSetup {
            if ($Prompt -like 'Actual creation*') { return [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o') }
            if ($Prompt -like 'What next*') {
                if ($cloud.dispatchRecovery -and -not $cloud.retryUsed) { $cloud.retryUsed = $true; return 'r' }
                return 's'
            }
            if ($Prompt -like 'Local evidence*') { return 'https://example.ghe.com/demo-a1b2c3-platform/instance/pull/9 observed the specified check' }
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
                    @{ version = 1; phase = $phase; passed = $true; checks = $checks; revision = $upgradeMainSha; runId = $runId
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
        @($acceptanceInstance.modules['organization-rulesets'].parameters.target_organizations) |
            Should -Be @('demo-a1b2c3-platform')
        $acceptanceInstance.credentials['organization-rulesets'].rulesetPlan.githubApp | Should -Be 'rulesets'
        $acceptanceInstance.credentials['organization-rulesets'].rulesetPlan.environment | Should -Be 'organization-rulesets-ruleset-plan'
        $acceptanceInstance.credentials['enterprise-baseline'].Contains('rulesetPlan') | Should -BeFalse
        foreach ($alias in @('authorization', 'reader', 'writer', 'rulesets')) {
            $acceptanceInstance.githubApps[$alias].resources.repositories.Count | Should -Be 0
        }
        (Get-Content $result.SummaryPath -Raw) | Should -Not -Match 'example.ghe.com|11111111|installation-test|demo-a1b2c3-platform'
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/workflows/deploy.yml'].state | Should -Be 'disabled_manually'

        $resumed = & (Join-Path $sourceRoot 'tools/Start-InstanceSetup.ps1') -WorkPath $casePath -GitHubAcceptance `
            -ReleasePath $release -ReleaseVersion '0.0.0-bootstrap.11' -Reconfirm -PassThru
        ($resumed.Stages | Where-Object Id -eq 'acceptance-workflow').Status | Should -Be 'Ok'
        @($cloud.writes | Where-Object path -like '*/dispatches').Count | Should -Be 1

        $replacement = [Security.Cryptography.RSA]::Create(2048)
        $replacement.ExportRSAPrivateKeyPem() | Set-Content (Join-Path $keyFolder 'probe-reader.pem')
        $replacement.Dispose()
        $cloud.scheduledRuns = @(@{ id = 85; head_sha = $upgradeMainSha; head_branch = 'main'; run_attempt = 1
            status = 'completed'; conclusion = 'success'; event = 'schedule'; created_at = [DateTimeOffset]::UtcNow.ToString('o') })
        $cloud.resources['/repos/demo-a1b2c3-platform/instance/actions/runs/85/attempts/1/jobs'] = @{ jobs = @(
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

# The interruption harness reuses the first BeforeEach, which must remain the public setup.
Describe 'GitHub bootstrap isolated upgrade guards' -Tag 'UpgradeGuardUnit' {
    BeforeAll {
        Import-Module (Join-Path $tools 'PlatformTools.psm1') -Force
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $tools 'Invoke-GitHubBootstrap.ps1'), [ref] $null, [ref] $null)
        foreach ($name in @(
            'Assert-GitHubBootstrapInventoryUpgradePair',
            'Assert-GitHubBootstrapUpgradeInventoryState', 'Assert-GitHubBootstrapUpgradeMainProtection',
            'Get-GitHubBootstrapMainRuleset', 'Test-GitHubBootstrapValue'
        )) {
            $definition = $ast.Find({
                param($node)
                $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq $name
            }, $true)
            if ($null -eq $definition) { throw "Missing bootstrap function '$name'." }
            . ([scriptblock]::Create($definition.Extent.Text))
        }
        function Invoke-GitHubBootstrapApi {
            param([string] $Path, [switch] $AllowNotFound)
            if ($Path -ceq "/orgs/$organization/teams/security") {
                if (-not $AllowNotFound -and -not $cloud.resources.ContainsKey($Path)) {
                    throw "Isolated bootstrap team not found at '$Path'."
                }
                return $cloud.resources[$Path]
            }
            if ($Path -ceq "/repos/$repository/rulesets/60") { return $cloud.rulesetDetailOverride }
            throw "Unexpected isolated bootstrap API path '$Path'."
        }
        function Get-GitHubBootstrapCollection {
            param([string] $Path)
            if ($Path -cne "/repos/$repository/rulesets?includes_parents=false") {
                throw "Unexpected isolated bootstrap collection '$Path'."
            }
            return $cloud.rulesetListOverride
        }
    }

    BeforeEach {
        $organization = 'demo-a1b2c3-platform'
        $repository = "$organization/instance"
        $ownership = 'bootstrap-test-ownership'
        $team = Get-GitHubApiFixture -Name teams/get-by-name -Set @{
            id = 31; slug = 'security'; type = 'organization'; description = $ownership
            'organization.login' = $organization
        }
        $cloud = @{ resources = @{ "/orgs/$organization/teams/security" = $team } }
        Initialize-TestUpgradeProtectionCase -Cloud $cloud -ProtectionCase valid
    }

    It 'accepts the documented main protection fixture' {
        { Assert-GitHubBootstrapUpgradeMainProtection } | Should -Not -Throw
    }

    It 'accepts isolated release transition <From> to <To>' -ForEach $upgradeVersionCases {
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            foreach ($culture in @('en-US', 'cs-CZ')) {
                [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
                { Assert-GitHubBootstrapInventoryUpgradePair -From $From -To $To } | Should -Not -Throw
            }
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
    }

    It 'rejects isolated release transition <From> to <To>' -ForEach $unsupportedUpgradeVersionCases {
        $originalCulture = [Globalization.CultureInfo]::CurrentCulture
        try {
            foreach ($culture in @('en-US', 'cs-CZ')) {
                [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($culture)
                { Assert-GitHubBootstrapInventoryUpgradePair -From $From -To $To } |
                    Should -Throw '*Unsupported bootstrap inventory upgrade*'
            }
        }
        finally { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }
    }

    It 'rejects isolated protection <ProtectionCase>' -ForEach $upgradeProtectionCases {
        Initialize-TestUpgradeProtectionCase -Cloud $cloud -ProtectionCase $ProtectionCase
        { Assert-GitHubBootstrapUpgradeMainProtection } | Should -Throw $ExpectedError
    }

    It 'rejects isolated team <TeamCase>' -ForEach $upgradeTeamCases {
        Initialize-TestUpgradeTeamCase -Cloud $cloud -TeamCase $TeamCase
        { Assert-GitHubBootstrapUpgradeMainProtection } | Should -Throw '*upgrade requires the existing bootstrap-owned security team*'
    }

    It 'accepts initialized inventory' {
        { Assert-GitHubBootstrapUpgradeInventoryState -Inventory @{ initializationPending = $false } } |
            Should -Not -Throw
    }

    It 'rejects isolated inventory <State>' -ForEach $upgradeInventoryCases {
        $record = @{ initializationPending = $false }
        $expected = '*Only an initialized bootstrap inventory*'
        if ($State -ceq 'absent inventory') {
            $record = $null
            $expected = '*UpgradeInventory requires an existing initialized bootstrap inventory*'
        }
        elseif ($State -ceq 'missing initialization') { $record.Remove('initializationPending') }
        else { $record.initializationPending = $Pending }
        { Assert-GitHubBootstrapUpgradeInventoryState -Inventory $record } | Should -Throw $expected
    }
}
