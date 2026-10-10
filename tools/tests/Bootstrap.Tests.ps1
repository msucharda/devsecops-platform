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
        }
        Mock Start-Sleep {}
        Mock gh { $global:LASTEXITCODE = 0; 'gho_test' }
        Mock az {
            $global:LASTEXITCODE = 0
            '{"tenant":"11111111-1111-1111-1111-111111111111","accessToken":"test"}'
        }
        Mock Invoke-WebRequest {
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
            if ($Uri.Host -eq 'graph.microsoft.com' -and $Uri.AbsolutePath -eq '/v1.0/servicePrincipals') {
                return Get-TestResponse -Data @{
                    value = @(@{ id = 'graph-sp'; appRoles = @(
                        @{ id = 'group-create'; value = 'Group.Create'; isEnabled = $true; allowedMemberTypes = @('Application') }
                        @{ id = 'group-read'; value = 'Group.Read.All'; isEnabled = $true; allowedMemberTypes = @('Application') }
                    ) })
                }
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
                $scope = $Uri.AbsoluteUri.Split('/providers/Microsoft.Authorization/roleAssignments')[0]
                $query = [uri]::UnescapeDataString($Uri.Query)
                $principal = if ($query -match "principalId eq '([^']+)'") { $Matches[1] } else { '' }
                $scopePath = ([uri] $scope).AbsolutePath
                return Get-TestResponse -Data @{
                    value = @($cloud.resources.Values | Where-Object {
                        $_.Contains('properties') -and $_.properties.Contains('scope') -and $_.properties.Contains('principalId') -and $_.properties.principalId -eq $principal -and
                        ($_.properties.scope -eq $scopePath -or $_.properties.scope.StartsWith("$scopePath/") -or $scopePath.StartsWith("$($_.properties.scope)/"))
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

    It 'waits for managed identity replication before granting Graph permissions' {
        $cloud.registrationDelay = 1

        $result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath

        $result.Modules.Count | Should -Be 2
        $application = @($result.Modules | Where-Object Name -EQ application)[0]
        @($cloud.graphAssignments[$application.Apply.PrincipalId].appRoleId) | Should -Be @('group-create')
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
}
