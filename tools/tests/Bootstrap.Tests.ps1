BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $bootstrap = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-Bootstrap.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
    $example = Join-Path $PSScriptRoot 'fixtures/instance.yaml'

    function Get-TestResponse {
        param([int] $StatusCode = 200, $Data = @{})
        [pscustomobject]@{ StatusCode = $StatusCode; Content = (ConvertTo-Json -InputObject $Data -Depth 100 -Compress) }
    }
}

Describe 'Local Azure bootstrap' {
    BeforeEach {
        $tokenEnvironment = @{}
        foreach ($environmentName in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
            $tokenEnvironment[$environmentName] = [Environment]::GetEnvironmentVariable($environmentName)
            [Environment]::SetEnvironmentVariable($environmentName, $null)
        }
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath $example -Raw)
        $instance.modules = @{ application = @{} }
        $instance.bootstrap = @{
            tenantId = '11111111-1111-1111-1111-111111111111'
            managementSubscriptionId = '22222222-2222-2222-2222-222222222222'
            subscriptionIds = @('22222222-2222-2222-2222-222222222222')
            enterpriseApplicationObjectId = '33333333-3333-3333-3333-333333333333'
            githubHost = 'example.ghe.com'
            enterprise = 'example'
        }
        $modulesPath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Copy-Item -LiteralPath $fixtures -Destination $modulesPath -Recurse
        $applicationPath = Join-Path $modulesPath 'application/module.yaml'
        $application = ConvertFrom-Yaml (Get-Content -LiteralPath $applicationPath -Raw)
        $application.permissions.azure[0].scope = '/subscriptions/22222222-2222-2222-2222-222222222222'
        ConvertTo-Yaml $application | Set-Content -LiteralPath $applicationPath
        $instancePath = Join-Path $TestDrive 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $cloud = @{
            resources = @{}
            writes = [System.Collections.Generic.List[object]]::new()
            directOwner = $true
            graphAssignments = @{}
            registrationDelay = 0
            failurePattern = ''
            oidc = 'oidc'
            scimActive = $true
            licensed = $true
            subscriptionTenant = '11111111-1111-1111-1111-111111111111'
            subscriptionState = 'Enabled'
            githubOwner = $true
            omitDisabledStorageFeatures = $false
            disableStoragePublicNetwork = $false
            roleDefinitions = @{}
            transientResponses = [System.Collections.Generic.Queue[object]]::new()
            managementGroupAncestors = @{
                '22222222-2222-2222-2222-222222222222' = @('11111111-1111-1111-1111-111111111111', 'platform')
            }
            ancestryStatusCode = 200
            paginateAncestors = $false
            hideRoleAssignments = $false
            roleAssignmentFailureScope = ''
            directoryRoleDefinitions = [System.Collections.Generic.List[object]]::new()
            directoryRoleAssignments = [System.Collections.Generic.List[object]]::new()
        }
        Mock Start-Sleep {}
        Mock gh { $global:LASTEXITCODE = 0; 'gho_test' }
        Mock az {
            $global:LASTEXITCODE = 0
            '{"tenant":"11111111-1111-1111-1111-111111111111","accessToken":"test"}'
        }
        Mock Invoke-WebRequest {
            if ($cloud.transientResponses.Count -gt 0) {
                return $cloud.transientResponses.Dequeue()
            }
            if ($cloud.failurePattern -and $Method -eq 'PUT' -and $Uri.AbsoluteUri -like $cloud.failurePattern) {
                return Get-TestResponse -StatusCode 403 -Data @{ error = @{ code = 'AuthorizationFailed'; message = 'Injected interruption.' } }
            }
            if ($Uri -like '*/me') {
                return Get-TestResponse -Data @{ id = 'user-id'; userPrincipalName = 'platform@example.test' }
            }
            if ($Uri -like '*/servicePrincipals/33333333-3333-3333-3333-333333333333') {
                return Get-TestResponse -Data @{
                    preferredSingleSignOnMode = $cloud.oidc
                    appRoles = @(@{ id = 'owner-role'; displayName = 'Enterprise Owner'; isEnabled = $true; allowedMemberTypes = @('User') })
                }
            }
            if ($Uri -like '*/appRoleAssignedTo*') {
                $principal = if ($cloud.directOwner) { 'user-id' } else { 'group-id' }
                $type = if ($cloud.directOwner) { 'User' } else { 'Group' }
                return Get-TestResponse -Data @{
                    value = @(@{ principalId = $principal; principalType = $type; appRoleId = 'owner-role' })
                }
            }
            if ($Uri -like '*/synchronization/jobs') {
                return Get-TestResponse -Data @{ value = @(@{
                    schedule = @{ state = 'Active' }
                    status = @{ code = if ($cloud.scimActive) { 'Active' } else { 'Quarantine' } }
                }) }
            }
            if ($Uri -like '*/subscribedSkus') {
                return Get-TestResponse -Data @{
                    value = @(@{ capabilityStatus = 'Enabled'; prepaidUnits = @{ enabled = [int] $cloud.licensed }; servicePlans = @(
                        @{ servicePlanName = 'AAD_PREMIUM'; provisioningStatus = 'Success' }
                    ) })
                }
            }
            if ($Uri -like '*/graphql') {
                return Get-TestResponse -Data @{
                    data = @{
                        viewer = @{ login = 'owner_example' }
                        enterprise = @{
                            viewerIsAdmin = $cloud.githubOwner
                            ownerInfo = @{
                                admins = @{ nodes = @(@{ login = 'owner_example' }); pageInfo = @{ hasNextPage = $false; endCursor = $null } }
                            }
                        }
                    }
                }
            }
            if ($Uri -match '^https://management.azure.com/subscriptions/[^/?]+\?') {
                return Get-TestResponse -Data @{ tenantId = $cloud.subscriptionTenant; state = $cloud.subscriptionState }
            }
            if ($Uri.AbsolutePath -eq '/providers/Microsoft.Management/getEntities') {
                if ($Method -ne 'POST') { throw 'Management-group entity discovery requires POST, including continuation pages.' }
                if ($cloud.ancestryStatusCode -ne 200) {
                    return Get-TestResponse -StatusCode $cloud.ancestryStatusCode -Data @{
                        error = @{ code = 'AuthorizationFailed'; message = 'Cannot read subscription ancestors.' }
                    }
                }
                $query = [uri]::UnescapeDataString($Uri.Query)
                if ($query -notmatch "name eq '([^']+)'") { throw "Invalid entity filter: $Uri" }
                $subscriptionId = $Matches[1]
                if ($cloud.paginateAncestors -and $query -notlike '*$skiptoken=next*') {
                    return Get-TestResponse -Data @{
                        value = @()
                        nextLink = "$($Uri.AbsoluteUri)&`$skiptoken=next"
                    }
                }
                $ancestors = @('11111111-1111-1111-1111-111111111111')
                if ($cloud.managementGroupAncestors.ContainsKey($subscriptionId)) {
                    $ancestors = $cloud.managementGroupAncestors[$subscriptionId]
                }
                return Get-TestResponse -Data @{
                    value = @(@{
                        id = "/subscriptions/$subscriptionId"
                        name = $subscriptionId
                        type = '/subscriptions'
                        properties = @{ tenantId = $cloud.subscriptionTenant; parentNameChain = $ancestors }
                    })
                }
            }
            if ($Uri.Host -eq 'graph.microsoft.com' -and $Uri.AbsolutePath -eq '/v1.0/servicePrincipals') {
                return Get-TestResponse -Data @{
                    value = @(@{ id = 'graph-sp'; appRoles = @(
                        @{ id = 'group-create'; value = 'Group.Create'; isEnabled = $true; allowedMemberTypes = @('Application') }
                        @{ id = 'group-read'; value = 'Group.Read.All'; isEnabled = $true; allowedMemberTypes = @('Application') }
                        @{ id = 'user-read'; value = 'User.Read.All'; isEnabled = $true; allowedMemberTypes = @('Application') }
                    ) })
                }
            }
            if ($Uri.Host -eq 'graph.microsoft.com' -and $Uri.AbsolutePath -match '^/v1\.0/roleManagement/directory/roleDefinitions(/([^/]+))?$') {
                $definitionId = $Matches[2]
                if ($Method -eq 'GET') {
                    $query = [uri]::UnescapeDataString($Uri.Query)
                    if ($query -notmatch "displayName eq '([^']+)'") { throw "Invalid directory role lookup: $Uri" }
                    $displayName = $Matches[1]
                    return Get-TestResponse -Data @{ value = @($cloud.directoryRoleDefinitions | Where-Object { $_.displayName -eq $displayName }) }
                }
                $data = ConvertFrom-Json -InputObject $Body -AsHashtable
                if ($Method -eq 'POST') {
                    $data.id = [guid]::NewGuid().ToString()
                    $data.isBuiltIn = $false
                    $cloud.directoryRoleDefinitions.Add($data)
                }
                elseif ($Method -eq 'PATCH') {
                    $definition = @($cloud.directoryRoleDefinitions | Where-Object { $_.id -eq $definitionId })[0]
                    foreach ($key in $data.Keys) { $definition[$key] = $data[$key] }
                }
                $cloud.writes.Add(@{ uri = $Uri.AbsoluteUri; method = $Method; data = $data })
                return Get-TestResponse -StatusCode ($(if ($Method -eq 'POST') { 201 } else { 204 })) -Data $data
            }
            if ($Uri.Host -eq 'graph.microsoft.com' -and $Uri.AbsolutePath -eq '/v1.0/roleManagement/directory/roleAssignments') {
                if ($Method -eq 'GET') {
                    $query = [uri]::UnescapeDataString($Uri.Query)
                    if ($query -notmatch "principalId eq '([^']+)'") { throw "Invalid directory role assignment lookup: $Uri" }
                    $principal = $Matches[1]
                    return Get-TestResponse -Data @{ value = @($cloud.directoryRoleAssignments | Where-Object { $_.principalId -eq $principal }) }
                }
                $data = ConvertFrom-Json -InputObject $Body -AsHashtable
                $data.id = [guid]::NewGuid().ToString()
                $cloud.directoryRoleAssignments.Add($data)
                $cloud.writes.Add(@{ uri = $Uri.AbsoluteUri; method = $Method; data = $data })
                return Get-TestResponse -StatusCode 201 -Data $data
            }
            if ($Uri -match '/servicePrincipals/([^/]+)/appRoleAssignments$') {
                $principal = $Matches[1]
                if ($Method -eq 'GET') {
                    if ($cloud.registrationDelay -gt 0) {
                        $cloud.registrationDelay--
                        return Get-TestResponse -StatusCode 404 -Data @{ error = @{ code = 'Request_ResourceNotFound'; message = 'Principal not yet replicated.' } }
                    }
                    $assignments = if ($cloud.graphAssignments.ContainsKey($principal)) { $cloud.graphAssignments[$principal] } else { @() }
                    return Get-TestResponse -Data @{ value = @($assignments) }
                }
                if ($Method -eq 'POST') {
                    $data = ConvertFrom-Json -InputObject $Body -AsHashtable
                    $cloud.graphAssignments[$principal] = if ($cloud.graphAssignments.ContainsKey($principal)) {
                        @($cloud.graphAssignments[$principal]) + @($data)
                    }
                    else { @($data) }
                    $cloud.writes.Add(@{ uri = $Uri.AbsoluteUri; data = $data })
                    return Get-TestResponse -Data $data
                }
            }
            if ($Uri.AbsolutePath -like '*/roleDefinitions') {
                $query = [uri]::UnescapeDataString($Uri.Query)
                if ($query -notmatch "roleName eq '([^']+)'") { throw "Invalid role lookup: $Uri" }
                $roleName = $Matches[1]
                if ($cloud.roleDefinitions.ContainsKey($roleName)) {
                    return Get-TestResponse -Data @{ value = @($cloud.roleDefinitions[$roleName]) }
                }
                $roleId = switch ($roleName) {
                    'Reader' { 'acdd72a7-3385-48ef-bd42-f606fba81ae7' }
                    'Contributor' { 'b24988ac-6180-42a0-ab88-20f7382dd24c' }
                    default { throw "Unknown role '$roleName'." }
                }
                $actions = if ($roleName -eq 'Reader') { @('*/read') } else { @('*') }
                return Get-TestResponse -Data @{
                    value = @(@{
                        id = "/subscriptions/22222222-2222-2222-2222-222222222222/providers/Microsoft.Authorization/roleDefinitions/$roleId"
                        properties = @{ roleName = $roleName; permissions = @(@{ actions = $actions; dataActions = @() }) }
                    })
                }
            }
            if ($Uri.AbsolutePath -like '*/roleAssignments') {
                if ($cloud.hideRoleAssignments) { return Get-TestResponse -Data @{ value = @() } }
                $scope = $Uri.AbsoluteUri.Split('/providers/Microsoft.Authorization/roleAssignments')[0]
                $query = [uri]::UnescapeDataString($Uri.Query)
                $principal = if ($query -match "principalId eq '([^']+)'") { $Matches[1] } else { '' }
                $scopePath = ([uri] $scope).AbsolutePath
                if ($scopePath -eq $cloud.roleAssignmentFailureScope) {
                    return Get-TestResponse -StatusCode 403 -Data @{
                        error = @{ code = 'AuthorizationFailed'; message = 'Cannot audit management-group role assignments.' }
                    }
                }
                return Get-TestResponse -Data @{
                    value = @($cloud.resources.Values | Where-Object {
                        $_.Contains('properties') -and $_.properties.Contains('scope') -and $_.properties.Contains('principalId') -and $_.properties.principalId -eq $principal -and
                        ($_.properties.scope -eq $scopePath -or $_.properties.scope.StartsWith("$scopePath/"))
                    })
                }
            }
            if ($Uri -like 'https://management.azure.com/*') {
                $key = $Uri.AbsoluteUri.Split('?')[0]
                if ($Method -eq 'GET') {
                    if ($cloud.resources.ContainsKey($key)) {
                        $data = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $cloud.resources[$key] -Depth 100) -AsHashtable
                        if ($cloud.omitDisabledStorageFeatures -and $key -match '/storageAccounts/[^/]+$') {
                            foreach ($property in @('allowBlobPublicAccess', 'isHnsEnabled', 'isNfsV3Enabled', 'isSftpEnabled', 'isLocalUserEnabled')) {
                                if ($data.properties[$property] -eq $false) { $data.properties.Remove($property) }
                            }
                        }
                        return Get-TestResponse -Data $data
                    }
                    return Get-TestResponse -StatusCode 404
                }
                if ($Method -eq 'PUT') {
                    $data = ConvertFrom-Json -InputObject $Body -AsHashtable
                    $data.id = ([uri] $key).AbsolutePath
                    if ($key -match '/storageAccounts/[^/]+$') {
                        $data.properties.provisioningState = 'Succeeded'
                        if ($cloud.disableStoragePublicNetwork) { $data.properties.publicNetworkAccess = 'Disabled' }
                    }
                    if ($key -match '/userAssignedIdentities/[^/]+$') {
                        $data.properties = @{
                            principalId = [guid]::NewGuid().ToString()
                            clientId = [guid]::NewGuid().ToString()
                            tenantId = '11111111-1111-1111-1111-111111111111'
                        }
                    }
                    if ($key -match '/providers/Microsoft.Authorization/roleAssignments/') {
                        $data.properties.scope = $data.id.Split('/providers/Microsoft.Authorization/roleAssignments/')[0]
                    }
                    $cloud.resources[$key] = $data
                    $cloud.writes.Add(@{ uri = $key; data = $data })
                    return Get-TestResponse -Data $data
                }
            }
            throw "Unexpected request: $Method $Uri"
        }
    }

    AfterEach {
        foreach ($environmentName in $tokenEnvironment.Keys) {
            [Environment]::SetEnvironmentVariable($environmentName, $tokenEnvironment[$environmentName])
        }
    }

    It 'rejects an unconfirmed enterprise control before accessing either cloud' {
        $instance.manualPrerequisites.privateInternalForksDisabled = $false
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        Mock Invoke-RestMethod { throw 'Cloud must not be contacted.' }

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*$.manualPrerequisites.privateInternalForksDisabled*'
    }

    It 'rejects a group-inherited Enterprise Owner role before provisioning' {
        $cloud.directOwner = $false

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*direct*Enterprise Owner*'
    }

    It 'creates an Entra-only state backend protected against accidental deletion' {
        $instance.modules = @{}
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $result.StorageAccountName | Should -Be 'stdemotfstate'
        $account = @($cloud.writes | Where-Object { $_.uri -match '/storageAccounts/[^/]+$' })[0].data
        $account.properties.allowSharedKeyAccess | Should -BeFalse
        $account.properties.allowBlobPublicAccess | Should -BeFalse
        $account.properties.publicNetworkAccess | Should -Be 'Enabled'
        $account.properties.defaultToOAuthAuthentication | Should -BeTrue
        $account.properties.minimumTlsVersion | Should -Be 'TLS1_2'
        $service = @($cloud.writes | Where-Object { $_.uri -like '*/blobServices/default' })[0].data
        $service.properties.isVersioningEnabled | Should -BeTrue
        $service.properties.deleteRetentionPolicy.enabled | Should -BeTrue
        $service.properties.deleteRetentionPolicy.days | Should -Be 30
        $service.properties.containerDeleteRetentionPolicy.enabled | Should -BeTrue
        $service.properties.containerDeleteRetentionPolicy.days | Should -Be 30
        @($cloud.writes | Where-Object { $_.uri -like '*/locks/*' })[0].data.properties.level | Should -Be 'CanNotDelete'
        $result.HasChanges | Should -BeTrue
    }

    It 'repairs disabled public network access and then performs no further writes' {
        $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $account = @($cloud.resources.Values | Where-Object { $_.id -match '/storageAccounts/[^/]+$' })[0]
        $account.properties.publicNetworkAccess = 'Disabled'
        $cloud.writes.Clear()

        $repair = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $repair.HasChanges | Should -BeTrue
        @($cloud.writes).Count | Should -Be 1
        $cloud.writes[0].data.properties.publicNetworkAccess | Should -Be 'Enabled'
        $cloud.writes[0].data.properties.allowSharedKeyAccess | Should -BeFalse
        $cloud.writes[0].data.properties.allowBlobPublicAccess | Should -BeFalse
        $cloud.writes.Clear()
        (& $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath).HasChanges | Should -BeFalse
        @($cloud.writes).Count | Should -Be 0
    }

    It 'rejects Azure drift before sending a write in no-change mode' -Tag 'NoChanges' {
        $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $account = @($cloud.resources.Values | Where-Object { $_.id -match '/storageAccounts/[^/]+$' })[0]
        $account.properties.publicNetworkAccess = 'Disabled'
        $cloud.writes.Clear()

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath -NoChanges } |
            Should -Throw '*NoChanges*PUT*'
        $cloud.writes.Count | Should -Be 0
        $account.properties.publicNetworkAccess | Should -Be 'Disabled'
    }

    It 'executes the real unchanged Azure bootstrap with only allowlisted read operations' -Tag 'NoChanges' {
        $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $cloud.writes.Clear()
        $operations = [Collections.Generic.List[object]]::new()
        $policy = { param($Operation) $operations.Add($Operation); return $Operation.Kind -ceq 'Read' }.GetNewClosure()

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath -NoChanges -RequestPolicy $policy

        $result.HasChanges | Should -BeFalse
        $result.StorageAccountName | Should -Be 'stdemotfstate'
        $cloud.writes.Count | Should -Be 0
        @($operations | Where-Object Method -EQ 'POST').Count | Should -BeGreaterThan 0
        @($operations | Where-Object Kind -NE 'Read').Count | Should -Be 0
    }

    It 'does not retry a rejected Azure read in no-change mode' -Tag 'NoChanges' {
        $cloud.transientResponses.Enqueue((Get-TestResponse -StatusCode 503))

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath -NoChanges } | Should -Throw '*HTTP 503*'

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        $cloud.writes.Count | Should -Be 0
    }

    It 'fails explicitly when the provisioned backend still blocks public network access' {
        $cloud.disableStoragePublicNetwork = $true

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*publicNetworkAccess*Enabled*Azure Policy*'
    }

    It 'isolates module state and separates manifest permissions for plan and apply' {
        $manifestPath = Join-Path $modulesPath 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.azure = @(
            @{ role = 'Reader'; scope = '/subscriptions/22222222-2222-2222-2222-222222222222'; phase = 'plan' }
            @{ role = 'Contributor'; scope = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-workload' }
        )
        $manifest.permissions.microsoftGraph = @('Group.Create', @{ permission = 'Group.Read.All'; phase = 'plan' })
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        @($result.Modules.Name) | Should -Be @('application', 'foundation')
        $foundation = @($result.Modules | Where-Object Name -EQ foundation)[0]
        $foundation.Plan.PrincipalId | Should -Not -Be $foundation.Apply.PrincipalId
        $foundation.Plan.ResourceId | Should -BeLike '*/id-demo-foundation-plan'
        $foundation.Apply.ResourceId | Should -BeLike '*/id-demo-foundation-apply'
        $containers = @($cloud.writes | Where-Object { $_.uri -match '/containers/[^/]+$' })
        @($containers.data.id | ForEach-Object { ($_ -split '/')[-1] }) | Should -Be @('application', 'foundation')
        $stateAssignments = @($cloud.writes | Where-Object { $_.uri -match '/containers/[^/]+/providers/Microsoft.Authorization/roleAssignments/' })
        $stateAssignments.Count | Should -Be 4
        foreach ($assignment in $stateAssignments) {
            $module = @($result.Modules | Where-Object {
                $assignment.data.properties.principalId -in @($_.Plan.PrincipalId, $_.Apply.PrincipalId)
            })[0]
            $assignment.uri | Should -BeLike "*/containers/$($module.Name)/providers/*"
            $assignment.data.properties.roleDefinitionId | Should -BeLike '*/ba92f5b4-2d11-453d-a403-e96b0029c9fe'
        }
        $planGrants = @($cloud.writes | Where-Object { $_.data.Contains('principalId') -and $_.data.principalId -eq $foundation.Plan.PrincipalId })
        @($planGrants.data.appRoleId) | Should -Be @('group-read')
        $applyGrants = @($cloud.writes | Where-Object { $_.data.Contains('principalId') -and $_.data.principalId -eq $foundation.Apply.PrincipalId })
        @($applyGrants.data.appRoleId) | Should -Be @('group-create')
        $planAzure = @($cloud.writes | Where-Object {
            $_.data.Contains('properties') -and $_.data.properties.Contains('roleDefinitionId') -and
            $_.data.properties.principalId -eq $foundation.Plan.PrincipalId
        })
        @($planAzure.data.properties.roleDefinitionId | ForEach-Object { ($_ -split '/')[-1] }) |
            Should -Be @('ba92f5b4-2d11-453d-a403-e96b0029c9fe', 'acdd72a7-3385-48ef-bd42-f606fba81ae7')
        $applyAzure = @($cloud.writes | Where-Object {
            $_.data.Contains('properties') -and $_.data.properties.Contains('roleDefinitionId') -and
            $_.data.properties.principalId -eq $foundation.Apply.PrincipalId
        })
        @($applyAzure.data.properties.roleDefinitionId | ForEach-Object { ($_ -split '/')[-1] }) |
            Should -Be @('ba92f5b4-2d11-453d-a403-e96b0029c9fe', 'b24988ac-6180-42a0-ab88-20f7382dd24c')
    }

    It 'performs no cloud changes on a repeated run and keeps all identity identifiers' {
        $configurationBefore = [IO.File]::ReadAllText($instancePath)
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $writesBefore = $cloud.writes.Count

        $second = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $second.HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be $writesBefore
        (ConvertTo-Json -InputObject $second.Modules -Depth 10) | Should -BeExactly (ConvertTo-Json -InputObject $first.Modules -Depth 10)
        [IO.File]::ReadAllText($instancePath) | Should -BeExactly $configurationBefore
    }

    Context 'Entra directory roles scoped to the enterprise application' {
        BeforeEach {
            $foundationPath = Join-Path $modulesPath 'foundation/module.yaml'
            $foundation = ConvertFrom-Yaml (Get-Content -LiteralPath $foundationPath -Raw)
            $foundation.permissions.entraDirectoryRoles = @(
                @{ phase = 'apply'; scope = 'enterpriseApplication'; actions = @(
                    'microsoft.directory/servicePrincipals/appRoleAssignedTo/update'
                    'microsoft.directory/servicePrincipals/appRoleAssignedTo/read'
                    'microsoft.directory/servicePrincipals/standard/read'
                ) }
                @{ phase = 'plan'; scope = 'enterpriseApplication'; actions = @(
                    'microsoft.directory/servicePrincipals/appRoleAssignedTo/read'
                    'microsoft.directory/servicePrincipals/standard/read'
                ) }
            )
            ConvertTo-Yaml $foundation | Set-Content -LiteralPath $foundationPath
            $instance.modules = @{ foundation = @{} }
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        }

        It 'creates a custom role per phase and assigns it only at the enterprise application scope' {
            $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

            $result.HasChanges | Should -BeTrue
            $definitions = @($cloud.directoryRoleDefinitions | Sort-Object displayName)
            @($definitions.displayName) | Should -Be @('platform-demo-foundation-apply', 'platform-demo-foundation-plan')
            foreach ($definition in $definitions) {
                $definition.isEnabled | Should -BeTrue
                @($definition.rolePermissions).Count | Should -Be 1
            }
            @($definitions[0].rolePermissions[0].allowedResourceActions | Sort-Object) | Should -Be @(
                'microsoft.directory/servicePrincipals/appRoleAssignedTo/read'
                'microsoft.directory/servicePrincipals/appRoleAssignedTo/update'
                'microsoft.directory/servicePrincipals/standard/read'
            )
            @($definitions[1].rolePermissions[0].allowedResourceActions | Sort-Object) | Should -Be @(
                'microsoft.directory/servicePrincipals/appRoleAssignedTo/read'
                'microsoft.directory/servicePrincipals/standard/read'
            )
            $module = $result.Modules[0]
            foreach ($phase in @('Plan', 'Apply')) {
                $definition = @($definitions | Where-Object displayName -EQ "platform-demo-foundation-$($phase.ToLowerInvariant())")[0]
                $assignments = @($cloud.directoryRoleAssignments | Where-Object principalId -EQ $module.$phase.PrincipalId)
                $assignments.Count | Should -Be 1
                $assignments[0].roleDefinitionId | Should -Be $definition.id
                $assignments[0].directoryScopeId | Should -Be '/33333333-3333-3333-3333-333333333333'
            }
        }

        It 'performs no directory changes on a repeated run' {
            $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
            $writesBefore = $cloud.writes.Count

            $second = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

            $second.HasChanges | Should -BeFalse
            $cloud.writes.Count | Should -Be $writesBefore
            $cloud.directoryRoleDefinitions.Count | Should -Be 2
            $cloud.directoryRoleAssignments.Count | Should -Be 2
        }

        It 'restores drifted role actions without recreating the role' {
            $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
            $plan = @($cloud.directoryRoleDefinitions | Where-Object displayName -EQ 'platform-demo-foundation-plan')[0]
            $plan.rolePermissions = @(@{ allowedResourceActions = @('microsoft.directory/servicePrincipals/appRoleAssignedTo/update') })
            $cloud.writes.Clear()

            $repair = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

            $repair.HasChanges | Should -BeTrue
            @($cloud.writes).Count | Should -Be 1
            $cloud.writes[0].method | Should -Be 'PATCH'
            $cloud.writes[0].uri | Should -BeLike "*/roleDefinitions/$($plan.id)"
            @($plan.rolePermissions[0].allowedResourceActions | Sort-Object) | Should -Be @(
                'microsoft.directory/servicePrincipals/appRoleAssignedTo/read'
                'microsoft.directory/servicePrincipals/standard/read'
            )
        }

        It 'rejects a write action in the plan role before any change' {
            $foundation.permissions.entraDirectoryRoles[1].actions = @('microsoft.directory/servicePrincipals/appRoleAssignedTo/update')
            ConvertTo-Yaml $foundation | Set-Content -LiteralPath $foundationPath

            { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
                Should -Throw "*plan Entra directory role*not read-only*"
            $cloud.writes.Count | Should -Be 0
        }

        It 'refuses to adopt a built-in role with the platform role name' {
            $cloud.directoryRoleDefinitions.Add(@{
                id = 'built-in'; displayName = 'platform-demo-foundation-plan'; isBuiltIn = $true; isEnabled = $true
                rolePermissions = @(@{ allowedResourceActions = @('microsoft.directory/servicePrincipals/standard/read') })
            })

            { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
                Should -Throw "*platform-demo-foundation-plan*built-in*"
            $cloud.writes.Count | Should -Be 0
        }

        It 'rejects an unexpected directory role of a module identity' {
            $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
            $cloud.directoryRoleAssignments.Add(@{
                id = 'unexpected'; principalId = $first.Modules[0].Plan.PrincipalId
                roleDefinitionId = '62e90394-69f5-4237-9190-012177145e10'; directoryScopeId = '/'
            })
            $writesBefore = $cloud.writes.Count

            { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
                Should -Throw "*foundation/plan*unexpected Entra directory role*"
            $cloud.writes.Count | Should -Be $writesBefore
        }

        It 'refuses a missing directory role in no-change mode before sending a write' -Tag 'NoChanges' {
            $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
            $cloud.directoryRoleAssignments.Clear()
            $cloud.writes.Clear()

            { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath -NoChanges } |
                Should -Throw '*NoChanges*POST*roleAssignments*'
            $cloud.writes.Count | Should -Be 0
        }
    }

    It 'provisions the released emu-identity manifest with read-only plan access and no tenant-wide assignment write' {
        $source = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/emu-identity/module.yaml'
        $null = New-Item -ItemType Directory -Path (Join-Path $modulesPath 'emu-identity')
        Copy-Item -LiteralPath $source -Destination (Join-Path $modulesPath 'emu-identity/module.yaml')
        $instance.modules = @{ 'emu-identity' = @{} }
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $module = $result.Modules[0]
        $module.Name | Should -Be 'emu-identity'
        $planGrants = @($cloud.writes | Where-Object { $_.data.Contains('principalId') -and $_.data.principalId -eq $module.Plan.PrincipalId -and $_.data.Contains('appRoleId') })
        @($planGrants.data.appRoleId | Sort-Object) | Should -Be @('group-read', 'user-read')
        $applyGrants = @($cloud.writes | Where-Object { $_.data.Contains('principalId') -and $_.data.principalId -eq $module.Apply.PrincipalId -and $_.data.Contains('appRoleId') })
        @($applyGrants.data.appRoleId | Sort-Object) | Should -Be @('group-create', 'user-read')
        $definitions = @($cloud.directoryRoleDefinitions | Sort-Object displayName)
        @($definitions.displayName) | Should -Be @('platform-demo-emu-identity-apply', 'platform-demo-emu-identity-plan')
        @($definitions[1].rolePermissions[0].allowedResourceActions | Where-Object { $_ -notlike '*/read' }) | Should -BeNullOrEmpty
        @($definitions[0].rolePermissions[0].allowedResourceActions | Where-Object { $_ -notlike '*/read' }) |
            Should -Be @('microsoft.directory/servicePrincipals/appRoleAssignedTo/update')
        @($cloud.directoryRoleAssignments.directoryScopeId | Sort-Object -Unique) | Should -Be @('/33333333-3333-3333-3333-333333333333')
        @($cloud.writes | Where-Object { $_.uri -like '*/providers/Microsoft.Authorization/roleAssignments/*' -and $_.uri -notlike '*/containers/*' }) |
            Should -BeNullOrEmpty
    }

    It 'rejects a conditional <Phase> state grant before changing existing bootstrap resources' -ForEach @(
        @{ Phase = 'Plan' }
        @{ Phase = 'Apply' }
    ) {
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $application = @($first.Modules | Where-Object Name -EQ application)[0]
        $assignment = @($cloud.resources.Values | Where-Object {
            $_.Contains('properties') -and $_.properties.Contains('roleDefinitionId') -and
            $_.properties.principalId -eq $application.$Phase.PrincipalId
        })[0]
        $assignment.properties.condition = "(@Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals 'denied.tfstate')"
        $assignment.properties.conditionVersion = '2.0'
        $account = @($cloud.resources.Values | Where-Object { $_.id -match '/storageAccounts/[^/]+$' })[0]
        $account.properties.allowSharedKeyAccess = $true
        $writesBefore = $cloud.writes.Count

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*conditional Azure role assignment*'
        $cloud.writes.Count | Should -Be $writesBefore
    }

    It 'reuses an unconditional equivalent state grant with a different ID and <Case> condition' -ForEach @(
        @{ Case = 'null'; Condition = $null }
        @{ Case = 'empty'; Condition = '' }
    ) {
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $application = @($first.Modules | Where-Object Name -EQ application)[0]
        $assignment = @($cloud.resources.Values | Where-Object {
            $_.Contains('properties') -and $_.properties.Contains('roleDefinitionId') -and
            $_.properties.principalId -eq $application.Plan.PrincipalId
        })[0]
        $oldId = $assignment.id
        $assignment.id = "$($assignment.properties.scope)/providers/Microsoft.Authorization/roleAssignments/equivalent"
        $assignment.properties.condition = $Condition
        $cloud.resources.Remove("https://management.azure.com$oldId")
        $cloud.resources["https://management.azure.com$($assignment.id)"] = $assignment
        $writesBefore = $cloud.writes.Count

        $second = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $second.HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be $writesBefore
        $second.Modules.Plan.PrincipalId | Should -Be $first.Modules.Plan.PrincipalId
    }

    It 'rejects a conditional state grant even alongside an unconditional match' {
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $application = @($first.Modules | Where-Object Name -EQ application)[0]
        $assignment = @($cloud.resources.Values | Where-Object {
            $_.Contains('properties') -and $_.properties.Contains('roleDefinitionId') -and
            $_.properties.principalId -eq $application.Plan.PrincipalId
        })[0]
        $duplicate = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $assignment -Depth 10) -AsHashtable
        $duplicate.id = "$($assignment.properties.scope)/providers/Microsoft.Authorization/roleAssignments/conditional"
        $duplicate.properties.condition = "(@Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals 'denied.tfstate')"
        $duplicate.properties.conditionVersion = '2.0'
        $cloud.resources["https://management.azure.com$($duplicate.id)"] = $duplicate
        $writesBefore = $cloud.writes.Count

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*conditional Azure role assignment*'
        $cloud.writes.Count | Should -Be $writesBefore
    }

    It 'rejects a conditional assignment returned by resource GET but omitted from list results' {
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $application = @($first.Modules | Where-Object Name -EQ application)[0]
        $assignment = @($cloud.resources.Values | Where-Object {
            $_.Contains('properties') -and $_.properties.Contains('roleDefinitionId') -and
            $_.properties.principalId -eq $application.Plan.PrincipalId
        })[0]
        $assignment.properties.condition = "(@Resource[Microsoft.Storage/storageAccounts/blobServices/containers/blobs:path] StringEquals 'denied.tfstate')"
        $assignment.properties.conditionVersion = '2.0'
        $cloud.hideRoleAssignments = $true
        $writesBefore = $cloud.writes.Count

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*conditional Azure role assignment*'
        $cloud.writes.Count | Should -Be $writesBefore
    }

    It 'waits for managed identity replication before granting Graph permissions' {
        $cloud.registrationDelay = 1

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $result.Modules.Count | Should -Be 2
        $application = @($result.Modules | Where-Object Name -EQ application)[0]
        @($cloud.graphAssignments[$application.Apply.PrincipalId].appRoleId) | Should -Be @('group-create')
    }

    It 'retries HTTP <StatusCode> with a non-JSON response before completing bootstrap' -ForEach @(
        @{ StatusCode = 429; Content = 'Too many requests.' }
        @{ StatusCode = 503; Content = '<html><body>Service unavailable.</body></html>' }
    ) {
        $cloud.transientResponses.Enqueue([pscustomobject]@{ StatusCode = $StatusCode; Content = $Content })

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $result.Modules.Count | Should -Be 2
        $result.HasChanges | Should -BeTrue
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'stops after twelve HTTP <StatusCode> attempts and reports the last response' -ForEach @(
        @{ StatusCode = 429 }
        @{ StatusCode = 503 }
    ) {
        for ($attempt = 0; $attempt -lt 12; $attempt++) {
            $cloud.transientResponses.Enqueue([pscustomobject]@{ StatusCode = $StatusCode; Content = 'Persistent transient failure.' })
        }

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw "*HTTP $StatusCode*Persistent transient failure*"

        Should -Invoke Invoke-WebRequest -Times 12 -Exactly
        Should -Invoke Start-Sleep -Times 11 -Exactly -ParameterFilter { $Seconds -eq 5 }
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects <Case> without retrying a nontransient HTTP response' -ForEach @(
        @{ Case = 'HTML success'; StatusCode = 200; Content = '<html>Not a JSON response.</html>'; Error = '*invalid JSON*HTTP 200*' }
        @{ Case = 'an array success'; StatusCode = 200; Content = '[]'; Error = '*did not return a JSON object*HTTP 200*' }
        @{ Case = 'an HTML client error'; StatusCode = 400; Content = '<html>Bad request.</html>'; Error = '*invalid JSON*HTTP 400*' }
    ) {
        $cloud.transientResponses.Enqueue([pscustomobject]@{ StatusCode = $StatusCode; Content = $Content })

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw $Error

        Should -Invoke Start-Sleep -Times 0 -Exactly
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects an existing identity with state access outside its own container' {
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $application = @($first.Modules | Where-Object Name -EQ application)[0]
        $scope = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-demo-bootstrap/providers/Microsoft.Storage/storageAccounts/stdemotfstate'
        $assignmentId = "$scope/providers/Microsoft.Authorization/roleAssignments/extra"
        $cloud.resources["https://management.azure.com$assignmentId"] = @{
            id = $assignmentId
            properties = @{
                scope = $scope
                principalId = $application.Plan.PrincipalId
                roleDefinitionId = '/subscriptions/22222222-2222-2222-2222-222222222222/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe'
            }
        }

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*unexpected Azure role*'
    }

    It 'rejects an inherited <Phase> role at <Group> before changing existing bootstrap resources' -ForEach @(
        @{ Phase = 'Plan'; Group = 'platform' }
        @{ Phase = 'Apply'; Group = 'platform' }
        @{ Phase = 'Plan'; Group = '11111111-1111-1111-1111-111111111111' }
        @{ Phase = 'Apply'; Group = '11111111-1111-1111-1111-111111111111' }
    ) {
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $application = @($first.Modules | Where-Object Name -EQ application)[0]
        $scope = "/providers/Microsoft.Management/managementGroups/$Group"
        $assignmentId = "$scope/providers/Microsoft.Authorization/roleAssignments/extra"
        $cloud.resources["https://management.azure.com$assignmentId"] = @{
            id = $assignmentId
            properties = @{
                scope = $scope
                principalId = $application.$Phase.PrincipalId
                roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/ba92f5b4-2d11-453d-a403-e96b0029c9fe'
            }
        }
        $account = @($cloud.resources.Values | Where-Object { $_.id -match '/storageAccounts/[^/]+$' })[0]
        $account.properties.allowSharedKeyAccess = $true
        $writesBefore = $cloud.writes.Count

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*unexpected Azure role*'
        $cloud.writes.Count | Should -Be $writesBefore
    }

    It 'audits ancestors of every configured subscription, not only the backend subscription' {
        $subscriptionId = '55555555-5555-5555-5555-555555555555'
        $instance.bootstrap.subscriptionIds += $subscriptionId
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $cloud.managementGroupAncestors[$subscriptionId] = @('11111111-1111-1111-1111-111111111111', 'workloads')
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $application = @($first.Modules | Where-Object Name -EQ application)[0]
        $scope = '/providers/Microsoft.Management/managementGroups/workloads'
        $assignmentId = "$scope/providers/Microsoft.Authorization/roleAssignments/extra"
        $cloud.resources["https://management.azure.com$assignmentId"] = @{
            id = $assignmentId
            properties = @{
                scope = $scope
                principalId = $application.Apply.PrincipalId
                roleDefinitionId = '/providers/Microsoft.Authorization/roleDefinitions/b24988ac-6180-42a0-ab88-20f7382dd24c'
            }
        }
        $writesBefore = $cloud.writes.Count

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*unexpected Azure role*workloads*'
        $cloud.writes.Count | Should -Be $writesBefore
    }

    It 'discovers subscription ancestors across POST continuation pages and deduplicates shared audit scopes' {
        $instance.bootstrap.subscriptionIds += '55555555-5555-5555-5555-555555555555'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $cloud.paginateAncestors = $true

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $result.Modules.Count | Should -Be 2
        Should -Invoke Invoke-WebRequest -Times 4 -Exactly -ParameterFilter {
            $Uri.AbsolutePath -eq '/providers/Microsoft.Management/getEntities' -and $Method -eq 'POST'
        }
        Should -Invoke Invoke-WebRequest -Times 5 -Exactly -ParameterFilter {
            $Uri.AbsolutePath -eq '/providers/Microsoft.Management/managementGroups/11111111-1111-1111-1111-111111111111/providers/Microsoft.Authorization/roleAssignments'
        }
    }

    It 'rejects an incomplete ancestor chain <Case> before any mutation' -ForEach @(
        @{ Case = 'missing'; Chain = $null }
        @{ Case = 'empty'; Chain = @() }
        @{ Case = 'without tenant root'; Chain = @('platform') }
        @{ Case = 'with a malformed name'; Chain = @('11111111-1111-1111-1111-111111111111', '../platform') }
        @{ Case = 'with a cycle'; Chain = @('11111111-1111-1111-1111-111111111111', 'platform', 'platform') }
    ) {
        $cloud.managementGroupAncestors['22222222-2222-2222-2222-222222222222'] = $Chain

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*management-group ancestor chain*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'does not continue when subscription ancestry cannot be read' {
        $cloud.ancestryStatusCode = 403

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*HTTP 403*Cannot read subscription ancestors*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'requires role-assignment read access at tenant root before creating bootstrap resources' {
        $cloud.roleAssignmentFailureScope = '/providers/Microsoft.Management/managementGroups/11111111-1111-1111-1111-111111111111'

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*HTTP 403*Cannot audit management-group role assignments*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects Graph write permissions on a plan identity before any mutation' {
        $manifestPath = Join-Path $modulesPath 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.microsoftGraph = @(@{ permission = 'Directory.ReadWrite.All'; phase = 'plan' })
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*plan*not read-only*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'finishes an interrupted run without replacing previously created identities' {
        $cloud.failurePattern = '*/userAssignedIdentities/id-demo-foundation-apply?*'
        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*HTTP 403*Injected interruption*'
        $writesBefore = $cloud.writes.Count
        $completedIdentities = @($cloud.writes | Where-Object { $_.uri -like '*/userAssignedIdentities/*' })
        $completedIdentities.Count | Should -Be 3
        $cloud.failurePattern = ''

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $result.HasChanges | Should -BeTrue
        $result.Modules.Count | Should -Be 2
        $newIdentities = @($cloud.writes.GetRange($writesBefore, $cloud.writes.Count - $writesBefore) |
            Where-Object { $_.uri -like '*/userAssignedIdentities/*' })
        $newIdentities.Count | Should -Be 1
        $newIdentities[0].uri | Should -BeLike '*/id-demo-foundation-apply'
        foreach ($created in $completedIdentities) {
            $cloud.resources[$created.uri].properties.principalId | Should -Be $created.data.properties.principalId
        }
        (& $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath).HasChanges | Should -BeFalse
    }

    It 'requires the manual confirmation <Name> before either cloud is contacted' -ForEach @(
        @{ Name = 'tenant' }
        @{ Name = 'enterpriseOidc' }
        @{ Name = 'enterpriseScim' }
        @{ Name = 'enterpriseOwner' }
        @{ Name = 'subscriptions' }
        @{ Name = 'licenses' }
        @{ Name = 'privateInternalForksDisabled' }
        @{ Name = 'emuUserNamespacesRestricted' }
        @{ Name = 'fineGrainedPatApprovalRequired' }
        @{ Name = 'patMaxLifetime90Days' }
        @{ Name = 'githubAppAvailabilityVerified' }
    ) {
        $instance.manualPrerequisites.Remove($Name)
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        Mock gh { throw 'GitHub must not be contacted.' }
        Mock az { throw 'Azure must not be contacted.' }
        Mock Invoke-WebRequest { throw 'APIs must not be contacted.' }

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw "*$.manualPrerequisites.$Name*"
    }

    It 'blocks missing live prerequisite <Case> before the first change' -ForEach @(
        @{ Case = 'OIDC'; Field = 'oidc'; Value = 'saml'; Error = '*OIDC enterprise application*' }
        @{ Case = 'SCIM'; Field = 'scimActive'; Value = $false; Error = '*active SCIM*' }
        @{ Case = 'Entra P1'; Field = 'licensed'; Value = $false; Error = '*Entra ID P1*' }
        @{ Case = 'subscription tenant'; Field = 'subscriptionTenant'; Value = 'another-tenant'; Error = '*Subscription*tenantId*' }
        @{ Case = 'subscription state'; Field = 'subscriptionState'; Value = 'Disabled'; Error = '*Subscription*enabled*' }
        @{ Case = 'GitHub owner'; Field = 'githubOwner'; Value = $false; Error = '*OAuth user*owner*' }
    ) {
        $cloud[$Field] = $Value

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw $Error
        $cloud.writes.Count | Should -Be 0
    }

    It 'refuses personal access tokens instead of accepting a stored OAuth login' -ForEach @(
        @{ Token = 'ghp_classic' }
        @{ Token = 'github_pat_finegrained' }
    ) {
        Mock gh { $global:LASTEXITCODE = 0; $Token }

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*OAuth token*PATs are not supported*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'refuses credential environment override <Variable>' -ForEach @(
        @{ Variable = 'GH_TOKEN' }
        @{ Variable = 'GITHUB_TOKEN' }
        @{ Variable = 'GH_ENTERPRISE_TOKEN' }
        @{ Variable = 'GITHUB_ENTERPRISE_TOKEN' }
    ) {
        [Environment]::SetEnvironmentVariable($Variable, 'test-override')

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw "*refuses $Variable*"
    }

    It 'rejects unsafe Azure role <Case> before the first change' -ForEach @(
        @{ Case = 'writer for plan'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-workload'; Phase = 'plan'; Error = '*plan role*not read-only*' }
        @{ Case = 'writer above backend'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222'; Phase = 'apply'; Error = '*could change the state backend*' }
        @{ Case = 'access to other state'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-demo-bootstrap/providers/Microsoft.Storage/storageAccounts/stdemotfstate/blobServices/default/containers/application'; Phase = 'apply'; Error = '*state access*own container*' }
    ) {
        $manifestPath = Join-Path $modulesPath 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.azure = @(@{ role = 'Contributor'; scope = $Scope; phase = $Phase })
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw $Error
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects an unknown Graph permission before creating Azure resources' {
        $manifestPath = Join-Path $modulesPath 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.microsoftGraph = @('NotAReal.Permission')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*application permission*missing or disabled*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'rejects <Phase> blob-read grants covering other module state at <Scope>' -ForEach @(
        @{ Phase = 'plan'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222'; DataAction = 'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read' }
        @{ Phase = 'apply'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222'; DataAction = 'Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read' }
        @{ Phase = 'plan'; Scope = '/providers/Microsoft.Management/managementGroups/platform'; DataAction = 'Microsoft.Storage/*/read' }
        @{ Phase = 'apply'; Scope = '/providers/Microsoft.Management/managementGroups/platform'; DataAction = 'Microsoft.Storage/*/read' }
    ) {
        $manifestPath = Join-Path $modulesPath 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.azure = @(@{ role = 'State Reader'; scope = $Scope; phase = $Phase })
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $cloud.roleDefinitions['State Reader'] = @{
            id = "$Scope/providers/Microsoft.Authorization/roleDefinitions/44444444-4444-4444-4444-444444444444"
            properties = @{
                roleName = 'State Reader'
                permissions = @(@{ actions = @('*/read'); dataActions = @($DataAction); notDataActions = @() })
            }
        }

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*could read another module*state*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'allows <Phase> read-only data access <Case> without exposing other module state' -ForEach @(
        @{ Phase = 'plan'; Case = 'outside bootstrap'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-data'; DataAction = 'Microsoft.Storage/*/read'; NotDataActions = @() }
        @{ Phase = 'apply'; Case = 'outside bootstrap'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222/resourceGroups/rg-data'; DataAction = 'Microsoft.Storage/*/read'; NotDataActions = @() }
        @{ Phase = 'plan'; Case = 'with excluded blob read'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222'; DataAction = 'Microsoft.Storage/*/read'; NotDataActions = @('Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read') }
        @{ Phase = 'apply'; Case = 'with excluded blob read'; Scope = '/subscriptions/22222222-2222-2222-2222-222222222222'; DataAction = 'Microsoft.Storage/*/read'; NotDataActions = @('Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read') }
        @{ Phase = 'plan'; Case = 'for unrelated data'; Scope = '/providers/Microsoft.Management/managementGroups/platform'; DataAction = 'Microsoft.KeyVault/vaults/secrets/read'; NotDataActions = @() }
        @{ Phase = 'apply'; Case = 'for unrelated data'; Scope = '/providers/Microsoft.Management/managementGroups/platform'; DataAction = 'Microsoft.KeyVault/vaults/secrets/read'; NotDataActions = @() }
    ) {
        $manifestPath = Join-Path $modulesPath 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.azure = @(@{ role = 'Data Reader'; scope = $Scope; phase = $Phase })
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $cloud.roleDefinitions['Data Reader'] = @{
            id = "$Scope/providers/Microsoft.Authorization/roleDefinitions/44444444-4444-4444-4444-444444444444"
            properties = @{
                roleName = 'Data Reader'
                permissions = @(@{ actions = @('*/read'); dataActions = @($DataAction); notDataActions = $NotDataActions })
            }
        }

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $result.Modules.Count | Should -Be 2
        $foundation = @($result.Modules | Where-Object Name -EQ foundation)[0]
        $principalId = if ($Phase -eq 'plan') { $foundation.Plan.PrincipalId } else { $foundation.Apply.PrincipalId }
        $grants = @($cloud.writes | Where-Object {
            $_.data.Contains('properties') -and $_.data.properties.Contains('principalId') -and
            $_.data.properties.Contains('roleDefinitionId') -and
            $_.data.properties.principalId -eq $principalId -and
            $_.data.properties.roleDefinitionId -like '*/44444444-4444-4444-4444-444444444444'
        })
        $grants.Count | Should -Be 1
        $grants[0].data.properties.scope | Should -Be $Scope
    }

    It 'does not let an excluded permission set cancel blob read allowed by another set' {
        $manifestPath = Join-Path $modulesPath 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $scope = '/subscriptions/22222222-2222-2222-2222-222222222222'
        $manifest.permissions.azure = @(@{ role = 'Data Reader'; scope = $scope; phase = 'plan' })
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $cloud.roleDefinitions['Data Reader'] = @{
            id = "$scope/providers/Microsoft.Authorization/roleDefinitions/44444444-4444-4444-4444-444444444444"
            properties = @{
                roleName = 'Data Reader'
                permissions = @(
                    @{ actions = @('*/read'); dataActions = @('Microsoft.Storage/*/read'); notDataActions = @('Microsoft.Storage/*') }
                    @{ actions = @(); dataActions = @('Microsoft.Storage/storageAccounts/blobServices/containers/blobs/read'); notDataActions = @() }
                )
            }
        }

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } |
            Should -Throw '*could read another module*state*'
        $cloud.writes.Count | Should -Be 0
    }

    It 'refuses to adopt a foreign storage account with a matching name' {
        $instance.modules = @{}
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $account = @($cloud.resources.Values | Where-Object { $_.id -match '/storageAccounts/[^/]+$' })[0]
        $account.tags.platformInstance = 'foreign'

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*ownership tags*refusing to adopt*'
    }

    It 'rejects bootstrap identifiers that do not satisfy the instance schema' {
        $instance.bootstrap.tenantId = 'not-a-tenant-id'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

        { & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*$.bootstrap.tenantId*'
    }

    It 'uses the required manual OIDC confirmation explicitly when Graph returns a null launch mode' {
        $cloud.oidc = $null
        $warnings = @()

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath -WarningVariable warnings 3>$null

        $result.Modules.Count | Should -Be 2
        $result.OidcModeVerified | Should -BeFalse
        ($warnings -join ' ') | Should -BeLike '*manual*enterpriseOidc*not automatically verified*'
    }

    It 'does not rewrite storage when the API omits disabled feature flags' {
        $cloud.omitDisabledStorageFeatures = $true
        $first = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $writesBefore = $cloud.writes.Count

        $second = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $second.HasChanges | Should -BeFalse
        $cloud.writes.Count | Should -Be $writesBefore
        $second.StorageAccountName | Should -Be $first.StorageAccountName
    }

    It 'does not normalize an explicitly enabled unsafe storage property <Property> to false' -ForEach @(
        @{ Property = 'isSftpEnabled' }
        @{ Property = 'isLocalUserEnabled' }
        @{ Property = 'allowSharedKeyAccess' }
    ) {
        $cloud.omitDisabledStorageFeatures = $true
        $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
        $account = @($cloud.resources.Values | Where-Object { $_.id -match '/storageAccounts/[^/]+$' })[0]
        $account.properties[$Property] = $true

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $result.HasChanges | Should -BeTrue
        $current = @($cloud.resources.Values | Where-Object { $_.id -match '/storageAccounts/[^/]+$' })[0]
        $current.properties[$Property] | Should -BeFalse
    }

    Context 'Preflight' {
        BeforeEach {
            $preflight = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-BootstrapPrerequisites.ps1'
            $cloud.providers = @{ 'Microsoft.Storage' = 'Registered'; 'Microsoft.ManagedIdentity' = 'Registered' }
            $cloud.permissions = @{}
            $cloud.nameAvailable = $true
            $cloud.nameChecks = [System.Collections.Generic.List[string]]::new()
            Mock Invoke-WebRequest -ParameterFilter { $Uri.AbsolutePath -match '^/subscriptions/[^/]+/providers/Microsoft\.[A-Za-z]+$' } {
                $namespace = $Uri.AbsolutePath.Split('/')[-1]
                Get-TestResponse -Data @{ namespace = $namespace; registrationState = $cloud.providers[$namespace] }
            }
            Mock Invoke-WebRequest -ParameterFilter { $Uri.AbsolutePath -like '*/providers/Microsoft.Authorization/permissions' } {
                $scope = $Uri.AbsolutePath.Split('/providers/Microsoft.Authorization/permissions')[0]
                $sets = if ($cloud.permissions.ContainsKey($scope)) { $cloud.permissions[$scope] } else { @(@{ actions = @('*'); notActions = @() }) }
                Get-TestResponse -Data @{ value = @($sets) }
            }
            Mock Invoke-WebRequest -ParameterFilter { $Uri.AbsolutePath -like '*/providers/Microsoft.Storage/checkNameAvailability' } {
                if ($Method -ne 'POST') { throw 'Storage name availability requires POST.' }
                $cloud.nameChecks.Add((ConvertFrom-Json -InputObject $Body -AsHashtable).name)
                Get-TestResponse -Data @{ nameAvailable = $cloud.nameAvailable; reason = if ($cloud.nameAvailable) { $null } else { 'AlreadyExists' } }
            }
        }

        BeforeAll {
            function Get-TestRow {
                param([object[]] $Rows, [string] $Check)
                @($Rows | Where-Object Check -EQ $Check)[0]
            }
        }

        It 'reports every check without changing either cloud' {
            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            $rows.Count | Should -Be 28
            @($rows | Where-Object Status -EQ 'Pass').Count | Should -Be 17
            @($rows | Where-Object Status -NotIn @('Pass', 'Confirmed')) | Should -BeNullOrEmpty
            $rows.Check | Should -Contain 'State backend names'
            $rows.Check | Should -Contain 'Role assignment rights at module scopes'
            $rows.Check | Should -Contain 'Existing module identities'
            $rows.Check | Should -Contain '$.manualPrerequisites.enterpriseOidc'
            (Get-TestRow -Rows $rows -Check 'Bootstrap user permissions in the management subscription').Detail |
                Should -BeLike '*ABAC conditions and deny assignments are not evaluated*'
            $cloud.nameChecks.Count | Should -Be 1
            $cloud.nameChecks[0] | Should -Be 'stdemotfstate'
            $cloud.writes.Count | Should -Be 0
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Method -eq 'PUT' }
        }

        It 'collects independent failures and skips dependent checks' {
            Mock gh { $global:LASTEXITCODE = 1; 'not logged in' }
            $cloud.directOwner = $false
            $cloud.licensed = $false

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            (Get-TestRow -Rows $rows -Check 'gh OAuth login').Status | Should -Be 'Fail'
            (Get-TestRow -Rows $rows -Check 'Enterprise owner in GitHub').Status | Should -Be 'Skip'
            (Get-TestRow -Rows $rows -Check 'Direct Enterprise Owner assignment').Detail | Should -BeLike '*direct*Enterprise Owner*'
            (Get-TestRow -Rows $rows -Check 'Entra ID P1 or P2 license').Status | Should -Be 'Fail'
            (Get-TestRow -Rows $rows -Check 'SCIM provisioning job').Status | Should -Be 'Pass'
            (Get-TestRow -Rows $rows -Check 'State backend names').Status | Should -Be 'Pass'
            $cloud.writes.Count | Should -Be 0
        }

        It 'skips every Azure and Entra ID check when Azure login fails' {
            Mock az { $global:LASTEXITCODE = 1; 'Please run az login.' }

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            (Get-TestRow -Rows $rows -Check 'Azure CLI login').Detail | Should -BeLike '*az login*'
            @($rows | Where-Object { $_.Area -in @('Azure', 'Entra ID', 'Modules') -and $_.Check -ne 'Azure CLI login' -and $_.Status -ne 'Skip' }) |
                Should -BeNullOrEmpty
            (Get-TestRow -Rows $rows -Check 'Enterprise owner in GitHub').Status | Should -Be 'Pass'
        }

        It 'marks the OIDC check manual when Graph returns a null launch mode' {
            $cloud.oidc = $null

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath 3>&1)

            @($rows | Where-Object { $_ -is [System.Management.Automation.WarningRecord] }) | Should -BeNullOrEmpty
            $row = Get-TestRow -Rows $rows -Check 'EMU OIDC enterprise application'
            $row.Status | Should -Be 'Manual'
            $row.Detail | Should -BeLike '*enterpriseOidc*not automatically verified*'
            (Get-TestRow -Rows $rows -Check 'Direct Enterprise Owner assignment').Status | Should -Be 'Pass'
        }

        It 'lists unconfirmed manual prerequisites and still checks both clouds' {
            $instance.manualPrerequisites.privateInternalForksDisabled = $false
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            (Get-TestRow -Rows $rows -Check '$.manualPrerequisites.privateInternalForksDisabled').Status | Should -Be 'Manual'
            (Get-TestRow -Rows $rows -Check '$.manualPrerequisites.enterpriseOidc').Status | Should -Be 'Confirmed'
            (Get-TestRow -Rows $rows -Check 'Enterprise owner in GitHub').Status | Should -Be 'Pass'
            (Get-TestRow -Rows $rows -Check 'Subscriptions in the bootstrap tenant').Status | Should -Be 'Pass'
        }

        It 'fails an unregistered resource provider and skips the state backend check' {
            $cloud.providers['Microsoft.ManagedIdentity'] = 'NotRegistered'

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            $row = Get-TestRow -Rows $rows -Check 'Resource providers in the management subscription'
            $row.Status | Should -Be 'Fail'
            $row.Detail | Should -BeLike '*Microsoft.ManagedIdentity (NotRegistered)*'
            (Get-TestRow -Rows $rows -Check 'State backend names').Status | Should -Be 'Skip'
        }

        It 'fails a Contributor that cannot write role assignments or locks' {
            $cloud.permissions['/subscriptions/22222222-2222-2222-2222-222222222222'] = @(@{
                actions = @('*')
                notActions = @('Microsoft.Authorization/*/Delete', 'Microsoft.Authorization/*/Write', 'Microsoft.Authorization/elevateAccess/Action')
            })

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            $row = Get-TestRow -Rows $rows -Check 'Bootstrap user permissions in the management subscription'
            $row.Status | Should -Be 'Fail'
            $row.Detail | Should -BeLike '*Microsoft.Authorization/locks/write*Microsoft.Authorization/roleAssignments/write*Owner*'
            $row.Detail | Should -Not -BeLike '*roleAssignments/read*'
            (Get-TestRow -Rows $rows -Check 'Role assignment rights at module scopes').Status | Should -Be 'Fail'
        }

        It 'marks a management-group module scope for manual verification' {
            $manifestPath = Join-Path $modulesPath 'application/module.yaml'
            $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
            $manifest.permissions.azure = @(@{ role = 'Reader'; scope = '/providers/Microsoft.Management/managementGroups/workloads'; phase = 'plan' })
            ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            $row = Get-TestRow -Rows $rows -Check 'Role assignment rights at module scopes'
            $row.Status | Should -Be 'Manual'
            $row.Detail | Should -BeLike '*managementGroups/workloads*manually*'
        }

        It 'fails a storage account name that another owner holds' {
            $cloud.nameAvailable = $false

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            $row = Get-TestRow -Rows $rows -Check 'State backend names'
            $row.Status | Should -Be 'Fail'
            $row.Detail | Should -BeLike "*'stdemotfstate'*AlreadyExists*another `$.instance.name*"
        }

        It 'accepts the state backend of the same instance and rejects foreign ownership tags' {
            $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
            $writes = $cloud.writes.Count

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            @($rows | Where-Object Status -NotIn @('Pass', 'Confirmed')) | Should -BeNullOrEmpty
            $cloud.nameChecks.Count | Should -Be 0
            $account = @($cloud.resources.Values | Where-Object { $_.id -match '/storageAccounts/[^/]+$' })[0]
            $account.tags.platformInstance = 'foreign'

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            (Get-TestRow -Rows $rows -Check 'State backend names').Detail | Should -BeLike '*ownership tags*refuse to adopt*'
            $cloud.writes.Count | Should -Be $writes
        }

        It 'reports an invalid module identity grant without stopping' {
            $null = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath
            $identity = @($cloud.resources.Values | Where-Object { $_.id -like '*/userAssignedIdentities/id-demo-application-plan' })[0]
            $cloud.graphAssignments[$identity.properties.principalId] = @(@{ resourceId = 'graph-sp'; appRoleId = 'unexpected-role' })

            $rows = @(& $preflight -InstancePath $instancePath -ModulesPath $modulesPath)

            $row = Get-TestRow -Rows $rows -Check 'Existing module identities'
            $row.Status | Should -Be 'Fail'
            $row.Detail | Should -BeLike '*unexpected application permission*'
            (Get-TestRow -Rows $rows -Check '$.manualPrerequisites.enterpriseOidc').Status | Should -Be 'Confirmed'
        }
    }
}
