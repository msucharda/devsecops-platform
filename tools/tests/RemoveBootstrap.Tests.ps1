BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'MicrosoftApiFixture.psm1') -Force
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $removeScript = Join-Path $toolsPath 'Remove-Bootstrap.ps1'
    $realModulesPath = Join-Path (Split-Path $toolsPath -Parent) 'modules'
    $tenantId = '11111111-1111-1111-1111-111111111111'
    $subscriptionId = '22222222-2222-2222-2222-222222222222'
    $workloadSubscriptionId = '23232323-2323-2323-2323-232323232323'
    $spId = '33333333-3333-3333-3333-333333333333'
    $planPrincipal = 'aaaaaaaa-0000-0000-0000-000000000001'
    $applyPrincipal = 'aaaaaaaa-0000-0000-0000-000000000002'
    $applyRoleId = 'bbbbbbbb-0000-0000-0000-000000000001'
    $planRoleId = 'bbbbbbbb-0000-0000-0000-000000000002'
    $organization = 'demo-abc123-platform'
    $repository = "$organization/instance"
    $githubApi = 'https://api.contoso.ghe.com'
    $arm = 'https://management.azure.com'
    $graph = 'https://graph.microsoft.com/v1.0'
    $resourceGroupId = "/subscriptions/$subscriptionId/resourceGroups/rg-demo-bootstrap"
    $storageAccountId = "$resourceGroupId/providers/Microsoft.Storage/storageAccounts/stdemotfstate"
    $lockId = "$storageAccountId/providers/Microsoft.Authorization/locks/lock-state"
    $managementGroupScope = '/providers/Microsoft.Management/managementGroups/mg-platform'

    function Get-TestResponse {
        param([int] $StatusCode = 200, $Data)
        $content = if ($PSBoundParameters.ContainsKey('Data')) { ConvertTo-Json -InputObject $Data -Depth 100 -Compress } else { '' }
        [pscustomobject]@{ StatusCode = $StatusCode; Content = $content }
    }

    function Get-TestNotFound {
        Get-TestResponse -StatusCode 404 -Data @{ message = 'Not Found' }
    }

    function Get-TestIdentity {
        param([string] $Phase, [string] $PrincipalId)
        $name = "id-demo-emu-identity-$Phase"
        (Get-MicrosoftApiFixture -Name arm/user-assigned-identities-list-by-resource-group -Set @{
            'value.0.id' = "$resourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities/$name"
            'value.0.name' = $name
            'value.0.properties.principalId' = $PrincipalId
            'value.0.properties.tenantId' = $tenantId
            'value.0.tags' = @{ platformInstance = 'demo'; platformComponent = 'bootstrap'; platformModule = 'emu-identity'; platformPhase = $Phase }
        })['value'][0]
    }

    function Get-TestRoleAssignment {
        param([string] $Name, [string] $PrincipalId, [string] $Scope)
        (Get-MicrosoftApiFixture -Name arm/role-assignments-list-for-scope -Set @{
            'value.0.name' = $Name
            'value.0.id' = "$Scope/providers/Microsoft.Authorization/roleAssignments/$Name"
            'value.0.properties.principalId' = $PrincipalId
            'value.0.properties.principalType' = 'ServicePrincipal'
            'value.0.properties.scope' = $Scope
        })['value'][0]
    }

    function Get-TestRoleDefinition {
        param([string] $Id, [string] $Phase)
        (Get-MicrosoftApiFixture -Name graph/rbacapplication-list-roledefinitions -Set @{
            'value.0.id' = $Id
            'value.0.displayName' = "platform-demo-emu-identity-$Phase"
            'value.0.description' = "Platform module emu-identity ($Phase) on the EMU enterprise application. Managed by bootstrap."
            'value.0.isBuiltIn' = $false
            'value.0.templateId' = $Id
        })['value'][0]
    }

    function Get-TestDirectoryAssignment {
        param([string] $Id, [string] $PrincipalId, [string] $RoleDefinitionId)
        (Get-MicrosoftApiFixture -Name graph/rbacapplication-list-roleassignments -Set @{
            'value.0.id' = $Id
            'value.0.principalId' = $PrincipalId
            'value.0.directoryScopeId' = "/$spId"
            'value.0.resourceScope' = "/$spId"
            'value.0.roleDefinitionId' = $RoleDefinitionId
        })['value'][0]
    }

    function Get-TestRunList {
        param([string] $Workflow, [string] $Status = 'completed', [AllowNull()][string] $Conclusion = 'success', [datetime] $CreatedAt, [switch] $Empty)
        if ($Empty) {
            $list = Get-GitHubApiFixture -Name actions/list-workflow-runs -Set @{ total_count = 0 }
            $list['workflow_runs'] = @()
            return $list
        }
        Get-GitHubApiFixture -Name actions/list-workflow-runs -Set @{
            'workflow_runs.0.path' = ".github/workflows/$Workflow"
            'workflow_runs.0.head_branch' = 'main'
            'workflow_runs.0.status' = $Status
            'workflow_runs.0.conclusion' = $Conclusion
            'workflow_runs.0.created_at' = $CreatedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
            'workflow_runs.0.run_started_at' = $CreatedAt.ToString('yyyy-MM-ddTHH:mm:ssZ')
            'workflow_runs.0.updated_at' = $CreatedAt.AddMinutes(5).ToString('yyyy-MM-ddTHH:mm:ssZ')
        }
    }

    function Get-TestWorld {
        $world = @{
            Repository = Get-GitHubApiFixture -Name repos/get -Set @{
                full_name = $repository; name = 'instance'; private = $true; 'owner.login' = $organization
                description = 'Platform instance demo; bootstrap-owned.'
            }
            Organization = Get-GitHubApiFixture -Name orgs/get -Set @{ login = $organization }
            ActiveRuns = @{ in_progress = 0; queued = 0; requested = 0; waiting = 0; pending = 0 }
            Runs = @{
                'teardown.yml' = Get-TestRunList -Workflow 'teardown.yml' -CreatedAt ([datetime]'2026-05-02T10:00:00Z')
                'deploy.yml' = Get-TestRunList -Workflow 'deploy.yml' -CreatedAt ([datetime]'2026-05-01T10:00:00Z')
            }
            ResourceGroup = Get-MicrosoftApiFixture -Name arm/resource-groups-get -Set @{
                id = $resourceGroupId; name = 'rg-demo-bootstrap'; tags = @{ platformInstance = 'demo'; platformComponent = 'bootstrap' }
            }
            ResourceGroupDeletePolls = 1
            ResourceGroupDeleting = $false
            RepeatRunPages = $false
            OrganizationDeleting = $false
            OrganizationDeletePolls = 0
            Lock = $true
            Identities = [System.Collections.Generic.List[object]]::new()
            RoleAssignments = [System.Collections.Generic.List[object]]::new()
            RoleDefinitions = [System.Collections.Generic.List[object]]::new()
            DirectoryAssignments = [System.Collections.Generic.List[object]]::new()
        }
        $world.Identities.Add((Get-TestIdentity -Phase plan -PrincipalId $planPrincipal))
        $world.Identities.Add((Get-TestIdentity -Phase apply -PrincipalId $applyPrincipal))
        $world.RoleAssignments.Add((Get-TestRoleAssignment -Name 'ra-sub' -PrincipalId $applyPrincipal -Scope "/subscriptions/$workloadSubscriptionId"))
        $world.RoleAssignments.Add((Get-TestRoleAssignment -Name 'ra-mg' -PrincipalId $applyPrincipal -Scope $managementGroupScope))
        $world.RoleAssignments.Add((Get-TestRoleAssignment -Name 'ra-plan' -PrincipalId $planPrincipal -Scope "/subscriptions/$subscriptionId"))
        $world.RoleAssignments.Add((Get-TestRoleAssignment -Name 'ra-state' -PrincipalId $applyPrincipal -Scope "$storageAccountId/blobServices/default/containers/emu-identity"))
        $world.RoleAssignments.Add((Get-TestRoleAssignment -Name 'ra-other' -PrincipalId 'cccccccc-0000-0000-0000-000000000001' -Scope "/subscriptions/$subscriptionId"))
        $world.RoleDefinitions.Add((Get-TestRoleDefinition -Id $applyRoleId -Phase apply))
        $world.RoleDefinitions.Add((Get-TestRoleDefinition -Id $planRoleId -Phase plan))
        $world.DirectoryAssignments.Add((Get-TestDirectoryAssignment -Id 'dra-apply' -PrincipalId $applyPrincipal -RoleDefinitionId $applyRoleId))
        $world.DirectoryAssignments.Add((Get-TestDirectoryAssignment -Id 'dra-plan' -PrincipalId $planPrincipal -RoleDefinitionId $planRoleId))
        return $world
    }

    function Invoke-TestApi {
        param([hashtable] $World, [string] $Uri, [string] $Method)

        $address = [uri] $Uri
        $path = [uri]::UnescapeDataString($address.AbsolutePath)
        $query = [uri]::UnescapeDataString($address.Query)
        if ($address.Host -ceq 'api.contoso.ghe.com') {
            if ($path -ceq "/repos/$repository") {
                if (-not $World.Repository) { return Get-TestNotFound }
                if ($Method -ceq 'DELETE') { $World.Repository = $null; return Get-TestResponse -StatusCode 204 }
                return Get-TestResponse -Data $World.Repository
            }
            if ($path -ceq "/repos/$repository/actions/runs" -and $query -match 'status=(\w+)') {
                $count = $World.ActiveRuns[$Matches[1]]
                $list = Get-GitHubApiFixture -Name actions/list-workflow-runs-for-repo -Set @{ total_count = $count }
                if ($count -eq 0) { $list['workflow_runs'] = @() }
                return Get-TestResponse -Data $list
            }
            if ($path -match "^/repos/$([regex]::Escape($repository))/actions/workflows/([a-z]+\.yml)/runs$") {
                $workflow = $Matches[1]
                if (-not $World.Runs.Contains($workflow)) { return Get-TestNotFound }
                if ($query -match '[?&]page=(\d+)' -and [int] $Matches[1] -gt 1 -and -not $World.RepeatRunPages) {
                    $list = $World.Runs[$workflow].Clone()
                    $list['workflow_runs'] = @()
                    return Get-TestResponse -Data $list
                }
                return Get-TestResponse -Data $World.Runs[$workflow]
            }
            if ($path -ceq "/orgs/$organization") {
                if (-not $World.Organization) { return Get-TestNotFound }
                if ($Method -ceq 'DELETE') { $World.OrganizationDeleting = $true; return Get-TestResponse -StatusCode 202 -Data @{} }
                if ($World.OrganizationDeleting -and $World.OrganizationDeletePolls-- -le 0) {
                    $World.Organization = $null
                    return Get-TestNotFound
                }
                return Get-TestResponse -Data $World.Organization
            }
        }
        if ($address.Host -ceq 'management.azure.com') {
            if ($path -ceq $resourceGroupId) {
                if (-not $World.ResourceGroup) { return Get-TestNotFound }
                if ($Method -ceq 'DELETE') {
                    if ($World.Lock) { return Get-TestResponse -StatusCode 409 -Data @{ error = @{ code = 'ScopeLocked' } } }
                    $World.ResourceGroupDeleting = $true
                    return Get-TestResponse -StatusCode 202
                }
                if ($World.ResourceGroupDeleting) {
                    if ($World.ResourceGroupDeletePolls-- -le 0) {
                        $World.ResourceGroup = $null
                        $World.Identities.Clear()
                        foreach ($item in @($World.RoleAssignments | Where-Object { $_.properties.scope.StartsWith($resourceGroupId) })) {
                            $null = $World.RoleAssignments.Remove($item)
                        }
                        return Get-TestNotFound
                    }
                }
                return Get-TestResponse -Data $World.ResourceGroup
            }
            if ($path -ceq "$resourceGroupId/providers/Microsoft.ManagedIdentity/userAssignedIdentities") {
                if (-not $World.ResourceGroup) { return Get-TestNotFound }
                $list = Get-MicrosoftApiFixture -Name arm/user-assigned-identities-list-by-resource-group
                $list.Remove('nextLink')
                $list['value'] = @($World.Identities)
                return Get-TestResponse -Data $list
            }
            if ($path -like '*/providers/Microsoft.Authorization/roleAssignments' -and $Method -ceq 'GET') {
                if ($query -notmatch "principalId eq '([0-9a-f-]+)'") { throw "Unfiltered role assignment list $Uri" }
                $principal = $Matches[1]
                $list = Get-MicrosoftApiFixture -Name arm/role-assignments-list-for-scope
                # The filter returns assignments at, above and below the scope; the fake returns all of the principal.
                $list['value'] = @($World.RoleAssignments | Where-Object { $_.properties.principalId -eq $principal })
                return Get-TestResponse -Data $list
            }
            if ($path -like '*/providers/Microsoft.Authorization/roleAssignments/*' -and $Method -ceq 'DELETE') {
                $item = @($World.RoleAssignments | Where-Object { $_.id -eq $path })
                if ($item.Count -eq 0) { return Get-TestResponse -StatusCode 204 }
                $null = $World.RoleAssignments.Remove($item[0])
                return Get-TestResponse -Data $item[0]
            }
            if ($path -ceq $lockId -and $Method -ceq 'DELETE') {
                if (-not $World.ResourceGroup) { return Get-TestNotFound }
                $World.Lock = $false
                return Get-TestResponse -StatusCode 200
            }
        }
        if ($address.Host -ceq 'graph.microsoft.com') {
            if ($path -ceq '/v1.0/roleManagement/directory/roleDefinitions' -and $query -match "displayName eq '([^']+)'") {
                $name = $Matches[1]
                $list = Get-MicrosoftApiFixture -Name graph/rbacapplication-list-roledefinitions
                $list['value'] = @($World.RoleDefinitions | Where-Object { $_.displayName -eq $name })
                return Get-TestResponse -Data $list
            }
            if ($path -ceq '/v1.0/roleManagement/directory/roleAssignments' -and $query -match "roleDefinitionId eq '([^']+)'") {
                $id = $Matches[1]
                $list = Get-MicrosoftApiFixture -Name graph/rbacapplication-list-roleassignments
                $list['value'] = @($World.DirectoryAssignments | Where-Object { $_.roleDefinitionId -eq $id })
                return Get-TestResponse -Data $list
            }
            if ($path -like '/v1.0/roleManagement/directory/roleAssignments/*' -and $Method -ceq 'DELETE') {
                $item = @($World.DirectoryAssignments | Where-Object { $_.id -eq $path.Split('/')[-1] })
                if ($item.Count -eq 0) { return Get-TestResponse -StatusCode 404 -Data @{ error = @{ code = 'Request_ResourceNotFound' } } }
                $null = $World.DirectoryAssignments.Remove($item[0])
                return Get-TestResponse -StatusCode 204
            }
            if ($path -like '/v1.0/roleManagement/directory/roleDefinitions/*' -and $Method -ceq 'DELETE') {
                $id = $path.Split('/')[-1]
                if (@($World.DirectoryAssignments | Where-Object { $_.roleDefinitionId -eq $id }).Count -gt 0) {
                    return Get-TestResponse -StatusCode 400 -Data @{ error = @{ code = 'Request_BadRequest'; message = 'Role is assigned.' } }
                }
                $item = @($World.RoleDefinitions | Where-Object { $_.id -eq $id })
                if ($item.Count -eq 0) { return Get-TestResponse -StatusCode 404 -Data @{ error = @{ code = 'Request_ResourceNotFound' } } }
                $null = $World.RoleDefinitions.Remove($item[0])
                return Get-TestResponse -StatusCode 204
            }
        }
        throw "Unexpected request $Method $Uri"
    }
}

Describe 'Bootstrap removal' {
    BeforeAll {
        $savedTokens = @{}
        foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
            $savedTokens[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
    }

    AfterAll {
        foreach ($name in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTokens[$name]) }
    }

    BeforeEach {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.teams.platform = @('lead@contoso.test')
        $instance.modules = @{ 'emu-identity' = @{} }
        $instance.bootstrap = @{
            tenantId = $tenantId
            managementSubscriptionId = $subscriptionId
            subscriptionIds = @($subscriptionId, $workloadSubscriptionId)
            enterpriseApplicationObjectId = $spId
            githubHost = 'contoso.ghe.com'
            enterprise = 'contoso'
        }
        $instancePath = Join-Path $TestDrive 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $modulesPath = Join-Path $TestDrive 'modules'
        Remove-Item -LiteralPath $modulesPath -Recurse -Force -ErrorAction SilentlyContinue
        Copy-Item -LiteralPath $realModulesPath -Destination $modulesPath -Recurse
        $manifestPath = Join-Path $modulesPath 'emu-identity/module.yaml'
        (Get-Content -LiteralPath $manifestPath -Raw).Replace(
            "  azure: []", "  azure:`n    - role: Reader`n      scope: $managementGroupScope") | Set-Content -LiteralPath $manifestPath

        $inventoryPath = Join-Path $TestDrive 'inventory/bootstrap-inventory.json'
        $inventory = [ordered]@{
            version = 1; repository = $repository; enterprise = 'contoso'; deploymentIdentifier = 'abc123'
            releaseVersion = '1.0.0'; initializationPending = $false
            resources = @("/orgs/$organization", "/repos/$repository")
            apps = @{ deploy = @{ appId = 101; fingerprint = 'x'; previousKeys = @() } }
            declaredApps = @{ deploy = @{ appId = 101; removalRequired = $true; previousAppIds = @(99) } }
        }
        $writeInventory = {
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $inventoryPath -Parent)
            ConvertTo-Json -InputObject $inventory -Depth 20 | Set-Content -LiteralPath $inventoryPath
        }
        & $writeInventory

        $world = Get-TestWorld
        $requests = [System.Collections.Generic.List[object]]::new()
        $failure = @{ At = 0; After = $false; Count = 0 }
        $token = @{ tenant = $tenantId; accessToken = 'azure-token' }

        Mock Start-Sleep {}
        $ghLogin = @{ Token = 'gho_testtoken'; Exit = 0 }
        Mock gh { $global:LASTEXITCODE = $ghLogin.Exit; $ghLogin.Token }
        Mock az { $global:LASTEXITCODE = 0; ConvertTo-Json $token }
        Mock Invoke-WebRequest {
            # The cmdlet binds -Method to the WebRequestMethod enum (Delete); compare as the upper-case HTTP verb.
            $Method = ([string] $Method).ToUpperInvariant()
            $requests.Add([pscustomobject]@{ Uri = [string] $Uri; Method = $Method; Headers = $Headers })
            if ($requests.Count -gt 200) { throw 'Request limit exceeded.' }
            if ($Method -cne 'GET') {
                $failure.Count++
                if ($failure.Count -eq $failure.At -and -not $failure.After) { throw 'Simulated interruption before the request.' }
            }
            $response = Invoke-TestApi -World $world -Uri $Uri -Method $Method
            if ($Method -cne 'GET' -and $failure.Count -eq $failure.At -and $failure.After) { throw 'Simulated interruption after the request.' }
            return $response
        }
        $run = { & $removeScript -InstancePath $instancePath -InventoryPath $inventoryPath -ModulesPath $modulesPath -ConfirmInstanceName demo -Confirm:$false }
        $readInventory = { Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -AsHashtable }
        $assertRemoved = {
            $world.Repository | Should -BeNullOrEmpty
            $world.Organization | Should -BeNullOrEmpty
            $world.ResourceGroup | Should -BeNullOrEmpty
            $world.RoleDefinitions.Count | Should -Be 0
            $world.DirectoryAssignments.Count | Should -Be 0
            @($world.RoleAssignments | ForEach-Object name) | Should -Be @('ra-other')
            (& $readInventory).removal.completed | Should -BeTrue
        }
    }

    Context 'removes' {
        It 'every bootstrap resource in order and reports manual App deletion' {
            $result = & $run

            & $assertRemoved
            $result.Completed | Should -BeTrue
            $result.ManualSteps | Should -Contain 'Delete GitHub App 101 in its owner settings on https://contoso.ghe.com; GitHub has no API that deletes an App.'
            $result.ManualSteps | Should -Contain 'Delete GitHub App 99 in its owner settings on https://contoso.ghe.com; GitHub has no API that deletes an App.'
            $deletes = @($requests | Where-Object Method -ceq 'DELETE' | ForEach-Object { ([uri] $_.Uri).AbsolutePath })
            $deletes[0] | Should -Be "/repos/$repository"
            $deletes[1] | Should -Be "/orgs/$organization"
            $deletes[-2] | Should -Be $lockId
            $deletes[-1] | Should -Be $resourceGroupId
            [array]::IndexOf($deletes, "/v1.0/roleManagement/directory/roleAssignments/dra-apply") |
                Should -BeLessThan ([array]::IndexOf($deletes, "/v1.0/roleManagement/directory/roleDefinitions/$applyRoleId"))
            $deletes | Should -Not -Contain "$storageAccountId/blobServices/default/containers/emu-identity/providers/Microsoft.Authorization/roleAssignments/ra-state"
            @($requests | Where-Object { $_.Method -cnotin @('GET', 'DELETE') }) | Should -BeNullOrEmpty
            $github = @($requests | Where-Object { ([uri] $_.Uri).Host -ceq 'api.contoso.ghe.com' })
            @($github | Where-Object { $_.Headers['X-GitHub-Api-Version'] -cne '2026-03-10' }) | Should -BeNullOrEmpty
            @($requests | Where-Object { $_.Uri -like "*$managementGroupScope/providers/Microsoft.Authorization/roleAssignments?*" }) | Should -Not -BeNullOrEmpty
            @($requests | Where-Object { $_.Uri -like "*/subscriptions/$workloadSubscriptionId/providers/Microsoft.Authorization/roleAssignments?*" }) | Should -Not -BeNullOrEmpty
        }

        It 'when the deploy workflow has no run' {
            $world.Runs['deploy.yml'] = Get-TestRunList -Workflow 'deploy.yml' -Empty

            $null = & $run

            & $assertRemoved
        }

        It 'and records the managed identities that bind Azure resources to the inventory' {
            $null = & $run

            (& $readInventory).removal.azurePrincipals | Should -Be @($planPrincipal, $applyPrincipal | Sort-Object)
        }

        It 'nothing again when the inventory records a completed removal' {
            $null = & $run
            $requests.Clear()

            $result = & $run 3>$null

            $result.Completed | Should -BeTrue
            $requests.Count | Should -Be 0
        }

        It 'only the resources recorded when the GitHub bootstrap stopped before the repository' {
            $inventory.resources = @("/orgs/$organization")
            $world.Repository = $null
            & $writeInventory

            $null = & $run

            & $assertRemoved
            @($requests | Where-Object { $_.Uri -like '*/actions/*' }) | Should -BeNullOrEmpty
        }

        It 'a legacy inventory without a deployment identifier' {
            $legacyOrganization = 'demo-platform'
            $inventory.Remove('deploymentIdentifier')
            $inventory.repository = "$legacyOrganization/instance"
            $inventory.resources = @()
            $world.Repository = $null
            $world.Organization = $null
            & $writeInventory

            $null = & $run

            (& $readInventory).removal.completed | Should -BeTrue
        }
    }

    Context 'resumes after an interruption' {
        It 'at <Label> mutating request <At>' -ForEach @(
            foreach ($at in 1..11) {
                @{ At = $at; After = $false; Label = 'before' }
                @{ At = $at; After = $true; Label = 'after' }
            }
        ) {
            $failure.At = $At
            $failure.After = $After

            { & $run } | Should -Throw '*Simulated interruption*'
            $state = (& $readInventory).removal
            $state.completed | Should -BeFalse
            @($state.steps.Values | Where-Object { $_ -ceq 'started' }).Count | Should -Be 1

            $failure.At = 0
            $null = & $run

            & $assertRemoved
            (& $readInventory).removal.steps.Values | Should -Not -Contain 'started'
        }

        It 'when the organization is still being deleted' {
            $world.OrganizationDeletePolls = 5

            { & $removeScript -InstancePath $instancePath -InventoryPath $inventoryPath -ModulesPath $modulesPath `
                -ConfirmInstanceName demo -DeletionPollCount 2 -Confirm:$false } | Should -Throw '*still being deleted*'
            (& $readInventory).removal.steps['organization'] | Should -Be 'started'
            @($requests | Where-Object { $_.Method -cne 'GET' -and ([uri] $_.Uri).Host -cne 'api.contoso.ghe.com' }) | Should -BeNullOrEmpty

            $null = & $run

            & $assertRemoved
        }

        It 'and refuses Azure resources of a replacement deployment after an interruption at <Label>' -ForEach @(
            @{ Label = 'the repository deletion'; At = 1 }
            @{ Label = 'the organization deletion'; At = 2 }
        ) {
            $failure.At = $At
            { & $run } | Should -Throw '*Simulated interruption*'
            (& $readInventory).removal.azurePrincipals | Should -Be @($planPrincipal, $applyPrincipal | Sort-Object)
            $failure.At = 0
            $world.Identities[1] = Get-TestIdentity -Phase apply -PrincipalId 'dddddddd-0000-0000-0000-000000000002'
            $requests.Clear()

            { & $run } | Should -Throw '*differ from those this inventory recorded*'
            @($requests | Where-Object { $_.Method -cne 'GET' -and ([uri] $_.Uri).Host -cne 'api.contoso.ghe.com' }) | Should -BeNullOrEmpty
        }

        It 'covers every mutating request of a full run' {
            $null = & $run
            $failure.Count | Should -Be 11
        }

        It 'when the resource group is still being deleted' {
            $world.ResourceGroupDeletePolls = 5

            { & $removeScript -InstancePath $instancePath -InventoryPath $inventoryPath -ModulesPath $modulesPath `
                -ConfirmInstanceName demo -DeletionPollCount 2 -Confirm:$false } | Should -Throw '*still being deleted*'
            (& $readInventory).removal.steps['resource-group'] | Should -Be 'started'

            $null = & $run

            & $assertRemoved
        }
    }

    Context 'binds Azure resources to the inventory' {
        BeforeEach {
            # The tenth mutating request deletes the state lock; the run stops before it.
            $failure.At = 10
            { & $run } | Should -Throw '*Simulated interruption*'
            (& $readInventory).removal.steps['state-lock'] | Should -Be 'started'
            $failure.At = 0
            $requests.Clear()
            $replacement = 'dddddddd-0000-0000-0000-000000000001'
        }

        It 'and refuses to resume when another deployment <Label>' -ForEach @(
            @{ Label = 'replaced an identity'; Change = { $world.Identities[0] = Get-TestIdentity -Phase plan -PrincipalId $replacement } }
            @{ Label = 'added an identity'; Change = { $world.Identities.Add((Get-TestIdentity -Phase plan -PrincipalId $replacement)) } }
            @{ Label = 'left one identity'; Change = { $world.Identities.RemoveAt(0) } }
            @{ Label = 'left no identity'; Change = { $world.Identities.Clear() } }
        ) {
            . $Change

            { & $run } | Should -Throw '*differ from those this inventory recorded*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
            $world.Lock | Should -BeTrue
        }


        It 'and refuses to resume the resource group deletion when another deployment replaced an identity' {
            $world.ResourceGroupDeletePolls = 5
            { & $removeScript -InstancePath $instancePath -InventoryPath $inventoryPath -ModulesPath $modulesPath `
                -ConfirmInstanceName demo -DeletionPollCount 1 -Confirm:$false } | Should -Throw '*still being deleted*'
            $world.ResourceGroupDeleting = $false
            $world.Identities[0] = Get-TestIdentity -Phase plan -PrincipalId $replacement
            $requests.Clear()

            { & $run } | Should -Throw '*differ from those this inventory recorded*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'and resumes the resource group deletion when only recorded identities remain' {
            $world.ResourceGroupDeletePolls = 5
            { & $removeScript -InstancePath $instancePath -InventoryPath $inventoryPath -ModulesPath $modulesPath `
                -ConfirmInstanceName demo -DeletionPollCount 1 -Confirm:$false } | Should -Throw '*still being deleted*'
            $world.Identities.RemoveAt(0)

            $null = & $run

            & $assertRemoved
        }


        It 'and refuses an inventory that recorded no identities before Azure steps finished' {
            $stored = & $readInventory
            $stored.removal.Remove('azurePrincipals')
            ConvertTo-Json -InputObject $stored -Depth 20 | Set-Content -LiteralPath $inventoryPath

            { & $run } | Should -Throw '*does not record the managed identities*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'and refuses an inventory with an invalid identity record <Label>' -ForEach @(
            @{ Label = 'in upper case'; Value = @('AAAAAAAA-0000-0000-0000-000000000001') }
            @{ Label = 'that is not a list'; Value = 'aaaaaaaa-0000-0000-0000-000000000001' }
            @{ Label = 'that is not an id'; Value = @('x') }
        ) {
            $stored = & $readInventory
            $stored.removal.azurePrincipals = $Value
            ConvertTo-Json -InputObject $stored -Depth 20 | Set-Content -LiteralPath $inventoryPath

            { & $run } | Should -Throw '*invalid removal record*'
            $requests.Count | Should -Be 0
        }
    }

    Context 'refuses before any change' {
        It 'when <Label>' -ForEach @(
            @{ Label = 'the confirmation differs in case'; Confirm = 'Demo'; Expected = "*-ConfirmInstanceName 'demo'*" }
            @{ Label = 'the confirmation is another instance'; Confirm = 'other'; Expected = "*-ConfirmInstanceName 'demo'*" }
        ) {
            { & $removeScript -InstancePath $instancePath -InventoryPath $inventoryPath -ModulesPath $modulesPath -ConfirmInstanceName $Confirm -Confirm:$false } |
                Should -Throw $Expected
            $requests.Count | Should -Be 0
        }

        It 'when the inventory <Label>' -ForEach @(
            @{ Label = 'names another repository'; Field = 'repository'; Value = 'demo-abc123-platform/other'; Expected = '*belongs to another instance*' }
            @{ Label = 'names the repository in another case'; Field = 'repository'; Value = 'Demo-abc123-platform/instance'; Expected = '*belongs to another instance*' }
            @{ Label = 'names another enterprise'; Field = 'enterprise'; Value = 'fabrikam'; Expected = '*belongs to another instance*' }
            @{ Label = 'has an invalid deployment identifier'; Field = 'deploymentIdentifier'; Value = 'ABC'; Expected = '*invalid deployment identifier*' }
            @{ Label = 'has an invalid removal record'; Field = 'removal'; Value = @{ steps = @{ repository = 'skipped' }; completed = $false }; Expected = "*invalid removal step 'repository'*" }
            @{ Label = 'has a removal record without completion flag'; Field = 'removal'; Value = @{ steps = @{} }; Expected = '*invalid removal record*' }
            @{ Label = 'has a non-string resource'; Field = 'resources'; Value = @(@{ path = '/orgs/x' }); Expected = '*invalid resources list*' }
        ) {
            $inventory[$Field] = $Value
            & $writeInventory

            { & $run } | Should -Throw $Expected
            $requests.Count | Should -Be 0
        }

        It 'when the inventory is missing' {
            Remove-Item -LiteralPath $inventoryPath

            { & $run } | Should -Throw '*does not exist*'
        }

        It 'when the inventory is inside the source checkout' {
            $insidePath = Join-Path (Split-Path $toolsPath -Parent) 'inventory.json'

            { & $removeScript -InstancePath $instancePath -InventoryPath $insidePath -ModulesPath $modulesPath -ConfirmInstanceName demo -Confirm:$false } |
                Should -Throw '*outside the source checkout*'
        }

        It 'when <Variable> is set' -ForEach @(
            @{ Variable = 'GH_TOKEN' }, @{ Variable = 'GITHUB_TOKEN' }, @{ Variable = 'GH_ENTERPRISE_TOKEN' }, @{ Variable = 'GITHUB_ENTERPRISE_TOKEN' }
        ) {
            [Environment]::SetEnvironmentVariable($Variable, 'ghp_secret')
            try { { & $run } | Should -Throw "*refuses $Variable*" }
            finally { [Environment]::SetEnvironmentVariable($Variable, $null) }
            $requests.Count | Should -Be 0
        }

        It 'when gh returns <Label>' -ForEach @(
            @{ Label = 'a PAT'; GhToken = 'ghp_classic'; Exit = 0 }
            @{ Label = 'an empty token'; GhToken = ''; Exit = 0 }
            @{ Label = 'an error'; GhToken = 'gho_x'; Exit = 1 }
        ) {
            $ghLogin.Token = $GhToken
            $ghLogin.Exit = $Exit

            { & $run } | Should -Throw '*PATs are not supported*'
            $requests.Count | Should -Be 0
        }

        It 'when the Azure token <Label>' -ForEach @(
            @{ Label = 'belongs to another tenant'; AzureToken = @{ tenant = '99999999-9999-9999-9999-999999999999'; accessToken = 'x' }; Expected = '*does not belong*' }
            @{ Label = 'is empty'; AzureToken = @{ tenant = '11111111-1111-1111-1111-111111111111'; accessToken = '' }; Expected = '*does not belong*' }
            @{ Label = 'is missing'; AzureToken = @{ tenant = '11111111-1111-1111-1111-111111111111' }; Expected = '*does not belong*' }
        ) {
            $token.Clear()
            foreach ($key in $AzureToken.Keys) { $token[$key] = $AzureToken[$key] }

            { & $run } | Should -Throw $Expected
            $requests.Count | Should -Be 0
        }

        It 'when the Azure CLI login fails' {
            Mock az { $global:LASTEXITCODE = 1; 'ERROR: Please run az login' }

            { & $run } | Should -Throw '*Azure authentication failed*'
            $requests.Count | Should -Be 0
        }

        It 'when -WhatIf is used' {
            & $removeScript -InstancePath $instancePath -InventoryPath $inventoryPath -ModulesPath $modulesPath -ConfirmInstanceName demo -WhatIf

            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
            (& $readInventory).Contains('removal') | Should -BeFalse
        }
    }

    Context 'refuses to delete the repository' {
        It 'when <Label>' -ForEach @(
            @{ Label = 'the repository is public'; Field = 'private'; Value = $false; Expected = '*not the private bootstrap-owned*' }
            @{ Label = 'private is a string'; Field = 'private'; Value = 'true'; Expected = '*not the private bootstrap-owned*' }
            @{ Label = 'the marker is missing'; Field = 'description'; Value = $null; Expected = '*not the private bootstrap-owned*' }
            @{ Label = 'the marker names another instance'; Field = 'description'; Value = 'Platform instance other; bootstrap-owned.'; Expected = '*not the private bootstrap-owned*' }
            @{ Label = 'the marker differs in case'; Field = 'description'; Value = 'platform instance demo; bootstrap-owned.'; Expected = '*not the private bootstrap-owned*' }
            @{ Label = 'the full name differs'; Field = 'full_name'; Value = 'demo-abc123-platform/other'; Expected = '*not the private bootstrap-owned*' }
            @{ Label = 'the owner differs'; Field = 'owner.login'; Value = 'demo-xyz789-platform'; Expected = '*not the private bootstrap-owned*' }
        ) {
            $fields = @{
                full_name = $repository; private = $true; 'owner.login' = $organization
                description = 'Platform instance demo; bootstrap-owned.'
            }
            $fields[$Field] = $Value
            $world.Repository = Get-GitHubApiFixture -Name repos/get -Set $fields

            { & $run } | Should -Throw $Expected
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the owner object is missing' {
            # Intentionally invalid response: the documented schema requires owner.
            $world.Repository.Remove('owner')

            { & $run } | Should -Throw '*not the private bootstrap-owned*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when a run with status <Status> is not finished' -ForEach @(
            @{ Status = 'in_progress' }, @{ Status = 'queued' }, @{ Status = 'requested' }, @{ Status = 'waiting' }, @{ Status = 'pending' }
        ) {
            $world.ActiveRuns[$Status] = 1

            { & $run } | Should -Throw "*status '$Status' are not finished*"
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the latest teardown run <Label>' -ForEach @(
            @{ Label = 'failed'; Status = 'completed'; Conclusion = 'failure' }
            @{ Label = 'was cancelled'; Status = 'completed'; Conclusion = 'cancelled' }
            @{ Label = 'is not completed'; Status = 'in_progress'; Conclusion = $null }
            @{ Label = 'has a conclusion in another case'; Status = 'completed'; Conclusion = 'Success' }
        ) {
            $world.Runs['teardown.yml'] = Get-TestRunList -Workflow 'teardown.yml' -Status $Status -Conclusion $Conclusion -CreatedAt ([datetime]'2026-05-02T10:00:00Z')

            { & $run } | Should -Throw '*did not succeed*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the teardown run <Label>' -ForEach @(
            @{ Label = 'is on another branch'; Field = 'workflow_runs.0.head_branch'; Value = 'feature'; Expected = '*did not succeed*' }
            @{ Label = 'is from another workflow file'; Field = 'workflow_runs.0.path'; Value = '.github/workflows/deploy.yml'; Expected = '*invalid run of teardown.yml*' }
        ) {
            $world.Runs['teardown.yml'] = Get-TestRunList -Workflow 'teardown.yml' -CreatedAt ([datetime]'2026-05-02T10:00:00Z')
            $world.Runs['teardown.yml'].workflow_runs[0][$Field.Split('.')[-1]] = $Value

            { & $run } | Should -Throw $Expected
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when no teardown run exists' {
            $world.Runs['teardown.yml'] = Get-TestRunList -Workflow 'teardown.yml' -Empty

            { & $run } | Should -Throw '*did not succeed*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the teardown workflow does not exist' {
            $world.Runs.Remove('teardown.yml')

            { & $run } | Should -Throw '*HTTP 404*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when a deploy run started <Label> the teardown' -ForEach @(
            @{ Label = 'after'; CreatedAt = [datetime]'2026-05-03T10:00:00Z' }
            @{ Label = 'together with'; CreatedAt = [datetime]'2026-05-02T10:00:00Z' }
        ) {
            $world.Runs['deploy.yml'] = Get-TestRunList -Workflow 'deploy.yml' -CreatedAt $CreatedAt

            { & $run } | Should -Throw '*deploy workflow run changed after*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when an older deploy run was rerun after the teardown started' {
            $rerun = Get-TestRunList -Workflow 'deploy.yml' -CreatedAt ([datetime]'2026-04-01T10:00:00Z')
            $rerun['workflow_runs'][0]['run_attempt'] = 2
            $rerun['workflow_runs'][0]['run_started_at'] = '2026-05-03T10:00:00Z'
            $rerun['workflow_runs'][0]['updated_at'] = '2026-05-03T10:05:00Z'
            $list = $world.Runs['deploy.yml']
            $list['workflow_runs'] = @($list['workflow_runs'][0], $rerun['workflow_runs'][0])
            $list['total_count'] = 2

            { & $run } | Should -Throw '*deploy workflow run changed after*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
            @($requests | Where-Object Uri -like '*deploy.yml/runs?per_page=100&page=1') | Should -HaveCount 1
        }

        It 'when <Label>' -ForEach @(
            @{ Label = 'the teardown run has no attempt start time'; Workflow = 'teardown.yml'; Field = 'run_started_at'; Value = $null; Expected = '*start time of the latest teardown attempt*' }
            @{ Label = 'a deploy run has no update time'; Workflow = 'deploy.yml'; Field = 'updated_at'; Value = $null; Expected = '*invalid run of deploy.yml*' }
        ) {
            # Intentionally invalid response: the field is removed to test the fail-closed check.
            $world.Runs[$Workflow]['workflow_runs'][0][$Field] = $Value

            { & $run } | Should -Throw $Expected
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the deploy run list is incomplete' {
            $world.Runs['deploy.yml']['total_count'] = 2

            { & $run } | Should -Throw '*incomplete run list*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the deploy workflow has more than 1000 runs' {
            $world.Runs['deploy.yml']['total_count'] = 5000
            $world.RepeatRunPages = $true

            { & $run } | Should -Throw '*more than 1000 runs*'
            @($requests | Where-Object Uri -like '*deploy.yml/runs*') | Should -HaveCount 10
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the deploy workflow does not exist' {
            $world.Runs.Remove('deploy.yml')

            { & $run } | Should -Throw '*HTTP 404*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the run count is missing' {
            # Intentionally invalid response: the documented schema requires total_count.
            $world.Runs['teardown.yml'].Remove('total_count')

            { & $run } | Should -Throw '*run count*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when the repository is missing but its removal never started' {
            $world.Repository = $null

            { & $run } | Should -Throw "*Repository '$repository' is missing*"
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }

        It 'when GitHub answers <Status>' -ForEach @(@{ Status = 403 }, @{ Status = 500 }) {
            $world.Repository = $null
            Mock Invoke-WebRequest {
                $requests.Add([pscustomobject]@{ Uri = [string] $Uri; Method = ([string] $Method).ToUpperInvariant() })
                Get-TestResponse -StatusCode $Status -Data @{ message = 'Denied' }
            }

            { & $run } | Should -Throw "*HTTP $Status*"
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
        }
    }

    Context 'refuses to delete the organization' {
        It 'when GitHub returns another login' {
            $world.Organization = Get-GitHubApiFixture -Name orgs/get -Set @{ login = 'Demo-abc123-platform' }

            { & $run } | Should -Throw '*refusing to delete it*'
            @($requests | Where-Object { $_.Method -cne 'GET' -and $_.Uri -like '*/orgs/*' }) | Should -BeNullOrEmpty
        }

        It 'when GitHub returns another login while the organization is being deleted' {
            $world.OrganizationDeletePolls = 5
            Mock Invoke-WebRequest {
                $Method = ([string] $Method).ToUpperInvariant()
                $requests.Add([pscustomobject]@{ Uri = [string] $Uri; Method = $Method })
                $response = Invoke-TestApi -World $world -Uri $Uri -Method $Method
                if ($world.OrganizationDeleting -and $Method -ceq 'GET' -and $Uri -like '*/orgs/*') {
                    return Get-TestResponse -Data (Get-GitHubApiFixture -Name orgs/get -Set @{ login = 'Demo-abc123-platform' })
                }
                return $response
            }

            { & $run } | Should -Throw '*during its deletion*'
            (& $readInventory).removal.steps['organization'] | Should -Be 'started'
        }

        It 'when the organization is missing but its removal never started' {
            $world.Organization = $null

            { & $run } | Should -Throw "*Organization '$organization' is missing*"
        }
    }

    Context 'refuses to remove Azure access' {
        It 'when the resource group <Label>' -ForEach @(
            @{ Label = 'has no instance tag'; Tags = @{ platformComponent = 'bootstrap' } }
            @{ Label = 'has another instance tag'; Tags = @{ platformInstance = 'other'; platformComponent = 'bootstrap' } }
            @{ Label = 'has a tag in another case'; Tags = @{ platformInstance = 'Demo'; platformComponent = 'bootstrap' } }
            @{ Label = 'has another component tag'; Tags = @{ platformInstance = 'demo'; platformComponent = 'workload' } }
            @{ Label = 'has no tags'; Tags = $null }
        ) {
            $world.ResourceGroup.tags = $Tags

            { & $run } | Should -Throw '*bootstrap ownership tags*'
            @($requests | Where-Object { $_.Method -cne 'GET' -and ([uri] $_.Uri).Host -cne 'api.contoso.ghe.com' }) | Should -BeNullOrEmpty
        }

        It 'when the resource group has another id' {
            $world.ResourceGroup.id = "/subscriptions/$workloadSubscriptionId/resourceGroups/rg-demo-bootstrap"

            { & $run } | Should -Throw '*bootstrap ownership tags*'
        }

        It 'when an identity <Label>' -ForEach @(
            @{ Label = 'has another instance tag'; Field = 'tags.platformInstance'; Value = 'other'; Expected = '*ownership tags*' }
            @{ Label = 'has another component tag'; Field = 'tags.platformComponent'; Value = 'workload'; Expected = '*ownership tags*' }
            @{ Label = 'has an unknown phase tag'; Field = 'tags.platformPhase'; Value = 'Apply'; Expected = '*ownership tags*' }
            @{ Label = 'has no module tag'; Field = 'tags.platformModule'; Value = $null; Expected = '*ownership tags*' }
            @{ Label = 'has a name that does not match its tags'; Field = 'name'; Value = 'id-demo-other-plan'; Expected = '*ownership tags*' }
            @{ Label = 'belongs to another tenant'; Field = 'properties.tenantId'; Value = '99999999-9999-9999-9999-999999999999'; Expected = '*no usable principal*' }
            @{ Label = 'has no principal'; Field = 'properties.principalId'; Value = $null; Expected = '*no usable principal*' }
        ) {
            $identity = $world.Identities[0]
            $segments = $Field.Split('.')
            if ($segments.Count -eq 1) { $identity[$Field] = $Value } else { $identity[$segments[0]][$segments[1]] = $Value }

            { & $run } | Should -Throw $Expected
            @($requests | Where-Object { $_.Method -cne 'GET' -and ([uri] $_.Uri).Host -cne 'api.contoso.ghe.com' }) | Should -BeNullOrEmpty
        }

        It 'when Azure returns an assignment of another principal' {
            Mock Invoke-WebRequest {
                $Method = ([string] $Method).ToUpperInvariant()
                $requests.Add([pscustomobject]@{ Uri = [string] $Uri; Method = $Method })
                if ($Uri -like '*/providers/Microsoft.Authorization/roleAssignments`?*') {
                    $list = Get-MicrosoftApiFixture -Name arm/role-assignments-list-for-scope
                    return Get-TestResponse -Data $list
                }
                Invoke-TestApi -World $world -Uri $Uri -Method $Method
            }

            { & $run } | Should -Throw '*does not belong to principal*'
            @($requests | Where-Object { $_.Method -cne 'GET' -and $_.Uri -like '*roleAssignments*' }) | Should -BeNullOrEmpty
        }

        It 'when the resource group is missing before the role assignments were removed' {
            $world.ResourceGroup = $null

            { & $run } | Should -Throw '*Remove orphaned role assignments manually*'
        }
    }

    Context 'refuses to delete an Entra directory role' {
        It 'when the role <Label>' -ForEach @(
            @{ Label = 'is built-in'; Field = 'isBuiltIn'; Value = $true; Expected = '*not a bootstrap-owned custom role*' }
            @{ Label = 'has no built-in flag'; Field = 'isBuiltIn'; Value = $null; Expected = '*not a bootstrap-owned custom role*' }
            @{ Label = 'has another description'; Field = 'description'; Value = 'Created by hand.'; Expected = '*not a bootstrap-owned custom role*' }
            @{ Label = 'has a name in another case'; Field = 'displayName'; Value = 'Platform-demo-emu-identity-apply'; Expected = '*not a bootstrap-owned custom role*' }
            @{ Label = 'has an unsafe id'; Field = 'id'; Value = '../roleAssignments'; Expected = '*not a bootstrap-owned custom role*' }
        ) {
            $world.RoleDefinitions[0][$Field] = $Value
            if ($Field -ceq 'displayName') {
                Mock Invoke-WebRequest {
                    $Method = ([string] $Method).ToUpperInvariant()
                $requests.Add([pscustomobject]@{ Uri = [string] $Uri; Method = $Method })
                    if ($Uri -like '*roleDefinitions`?*' -and [uri]::UnescapeDataString($Uri) -like '*-apply''*') {
                        $list = Get-MicrosoftApiFixture -Name graph/rbacapplication-list-roledefinitions
                        $list['value'] = @($world.RoleDefinitions[0])
                        return Get-TestResponse -Data $list
                    }
                    Invoke-TestApi -World $world -Uri $Uri -Method $Method
                }
            }

            { & $run } | Should -Throw $Expected
            @($requests | Where-Object { $_.Method -cne 'GET' -and ([uri] $_.Uri).Host -ceq 'graph.microsoft.com' }) | Should -BeNullOrEmpty
        }

        It 'when the role name is ambiguous' {
            $world.RoleDefinitions.Add((Get-TestRoleDefinition -Id 'bbbbbbbb-0000-0000-0000-000000000003' -Phase apply))

            { & $run } | Should -Throw '*ambiguous*'
            @($requests | Where-Object { $_.Method -cne 'GET' -and ([uri] $_.Uri).Host -ceq 'graph.microsoft.com' }) | Should -BeNullOrEmpty
        }

        It 'when Graph returns an assignment of another role' {
            Mock Invoke-WebRequest {
                $Method = ([string] $Method).ToUpperInvariant()
                $requests.Add([pscustomobject]@{ Uri = [string] $Uri; Method = $Method })
                if ($Method -ceq 'GET' -and $Uri -like '*directory/roleAssignments`?*') {
                    $list = Get-MicrosoftApiFixture -Name graph/rbacapplication-list-roleassignments -Set @{ 'value.0.roleDefinitionId' = 'ffffffff-0000-0000-0000-000000000001' }
                    return Get-TestResponse -Data $list
                }
                Invoke-TestApi -World $world -Uri $Uri -Method $Method
            }

            { & $run } | Should -Throw '*does not belong to Entra directory role*'
            @($requests | Where-Object { $_.Method -cne 'GET' -and ([uri] $_.Uri).Host -ceq 'graph.microsoft.com' }) | Should -BeNullOrEmpty
        }
    }

    Context 'request policy' {
        It 'receives every request and stops the run when it refuses a deletion' {
            $seen = [System.Collections.Generic.List[object]]::new()
            $policy = { param($request) $seen.Add($request); $request.Method -ceq 'GET' }

            { & $removeScript -InstancePath $instancePath -InventoryPath $inventoryPath -ModulesPath $modulesPath `
                -ConfirmInstanceName demo -RequestPolicy $policy -Confirm:$false } | Should -Throw '*did not authorize DELETE*'
            @($requests | Where-Object Method -cne 'GET') | Should -BeNullOrEmpty
            @($seen | Where-Object Method -ceq 'DELETE')[0].Kind | Should -Be 'Reconcile'
        }
    }
}
