BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    Import-Module (Join-Path $PSScriptRoot 'MicrosoftApiFixture.psm1') -Force
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $ownerCheck = Join-Path $toolsPath 'Test-TeardownEnterpriseOwner.ps1'
    $modulesPath = Join-Path (Split-Path $toolsPath -Parent) 'modules'
    $tenantId = '11111111-1111-1111-1111-111111111111'
    $spId = '33333333-3333-3333-3333-333333333333'
    $ownerRoleId = '44444444-4444-4444-4444-444444444444'
    $otherRoleId = '55555555-5555-5555-5555-555555555555'
    $leadId = '66666666-6666-6666-6666-666666666666'
    $ownerId = '77777777-7777-7777-7777-777777777777'
    $graph = 'https://graph.microsoft.com/v1.0'

    function Get-TestResponse {
        param([int] $StatusCode = 200, $Data = @{})
        [pscustomobject]@{ StatusCode = $StatusCode; Content = (ConvertTo-Json -InputObject $Data -Depth 100 -Compress) }
    }

    function New-TestAssignment {
        param(
            [string] $PrincipalId = $ownerId,
            [string] $PrincipalType = 'User',
            [string] $AppRoleId = $ownerRoleId,
            [string] $ResourceId = $spId
        )
        (Get-MicrosoftApiFixture -Name graph/serviceprincipal-list-approleassignedto -Set @{
            'value.0.principalId' = $PrincipalId
            'value.0.principalType' = $PrincipalType
            'value.0.appRoleId' = $AppRoleId
            'value.0.resourceId' = $ResourceId
        })['value'][0]
    }
}

Describe 'Teardown Enterprise Owner check' {
    BeforeEach {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.teams.platform = @('lead@contoso.test', 'owner@contoso.test')
        $instance.modules = @{ 'emu-identity' = @{} }
        $instance.bootstrap = @{
            tenantId = $tenantId
            managementSubscriptionId = '22222222-2222-2222-2222-222222222222'
            subscriptionIds = @('22222222-2222-2222-2222-222222222222')
            enterpriseApplicationObjectId = $spId
            githubHost = 'contoso.ghe.com'
            enterprise = 'contoso'
        }
        $instancePath = Join-Path $TestDrive 'instance.yaml'
        $write = { ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath }
        & $write

        $application = Get-MicrosoftApiFixture -Name graph/serviceprincipal-get -Set @{ id = $spId }
        $application.appRoles = @(
            (Get-MicrosoftApiFixture -Name graph/serviceprincipal-get -Set @{
                'appRoles.0.id' = $otherRoleId; 'appRoles.0.displayName' = 'User'; 'appRoles.0.allowedMemberTypes' = @('User')
            }).appRoles[0]
            (Get-MicrosoftApiFixture -Name graph/serviceprincipal-get -Set @{
                'appRoles.0.id' = $ownerRoleId; 'appRoles.0.displayName' = 'Enterprise Owner'; 'appRoles.0.allowedMemberTypes' = @('User')
                'appRoles.0.value' = 'enterprise_owner'
            }).appRoles[0]
        )
        $users = @{
            'lead@contoso.test' = Get-MicrosoftApiFixture -Name graph/user-get -Set @{ id = $leadId; userPrincipalName = 'lead@contoso.test' }
            'owner@contoso.test' = Get-MicrosoftApiFixture -Name graph/user-get -Set @{ id = $ownerId; userPrincipalName = 'Owner@Contoso.test' }
        }
        $assignmentPages = [System.Collections.Generic.List[object]]::new()
        $assignmentPages.Add((Get-MicrosoftApiFixture -Name graph/serviceprincipal-list-approleassignedto))
        $assignmentPages[0].value = @(
            New-TestAssignment -PrincipalId $leadId -AppRoleId $otherRoleId
            New-TestAssignment -PrincipalId $ownerId
        )
        $responses = @{}
        $requests = [System.Collections.Generic.List[object]]::new()
        $token = @{ tenant = $tenantId; accessToken = 'graph-token' }

        Mock Start-Sleep {}
        Mock az {
            $global:LASTEXITCODE = 0
            ConvertTo-Json $token
        }
        Mock Invoke-WebRequest {
            $requests.Add([pscustomobject]@{ Uri = [string] $Uri; Method = $Method; Headers = $Headers })
            if ($requests.Count -gt 20) { throw 'Request limit exceeded; the check must stop paging.' }
            $path = [uri]::UnescapeDataString(([uri] $Uri).AbsolutePath)
            if ($responses.ContainsKey($path)) {
                $queue = $responses[$path]
                if ($queue -is [System.Collections.Queue]) { return $queue.Dequeue() }
                return $queue
            }
            if ($path -ceq "/v1.0/servicePrincipals/$spId") { return Get-TestResponse -Data $application }
            if ($path -like '/v1.0/users/*') {
                $upn = [uri]::UnescapeDataString($path.Substring('/v1.0/users/'.Length))
                if ($users.ContainsKey($upn)) { return Get-TestResponse -Data $users[$upn] }
                return Get-TestResponse -StatusCode 404 -Data @{ error = @{ code = 'Request_ResourceNotFound'; message = 'Not found.' } }
            }
            if ($path -ceq "/v1.0/servicePrincipals/$spId/appRoleAssignedTo") {
                $page = if (([uri] $Uri).Query -match 'skiptoken=(\d+)') { [int] $Matches[1] } else { 0 }
                return Get-TestResponse -Data $assignmentPages[$page]
            }
            throw "Unexpected request $Method $Uri"
        }
    }

    Context 'passes' {
        It 'when a platform team member has a direct Enterprise Owner assignment' {
            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Not -Throw

            Should -Invoke az -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -match "--tenant $tenantId" -and ($args -join ' ') -match '--resource https://graph\.microsoft\.com/'
            }
            @($requests | Where-Object { $_.Method -cne 'GET' }) | Should -BeNullOrEmpty
            @($requests | ForEach-Object { ([uri] $_.Uri).Host } | Sort-Object -Unique) | Should -Be @('graph.microsoft.com')
            $requests[0].Headers.Authorization | Should -Be 'Bearer graph-token'
            $requests[0].Uri | Should -BeLike "$graph/servicePrincipals/$spId?*select=id,appRoles"
        }

        It 'when the assignment is on a later Graph page' {
            $next = Get-MicrosoftApiFixture -Name graph/serviceprincipal-list-approleassignedto.next-page -Set @{
                '@odata.nextLink' = "$graph/servicePrincipals/$spId/appRoleAssignedTo?`$skiptoken=1"
            }
            $next.value = @(New-TestAssignment -PrincipalId $leadId -AppRoleId $otherRoleId)
            $last = Get-MicrosoftApiFixture -Name graph/serviceprincipal-list-approleassignedto
            $last.value = @(New-TestAssignment -PrincipalId $ownerId)
            $assignmentPages[0] = $next
            $assignmentPages.Add($last)

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Not -Throw
            @($requests | Where-Object { $_.Uri -like '*appRoleAssignedTo*' }).Count | Should -Be 2
        }

        It 'when another platform team member no longer exists in Entra ID' {
            $users.Remove('lead@contoso.test')

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Not -Throw
        }

        It 'after Graph throttling' {
            $responses["/v1.0/servicePrincipals/$spId"] = [System.Collections.Queue]::new(@(
                Get-TestResponse -StatusCode 429 -Data @{ error = @{ code = 'TooManyRequests' } }
                Get-TestResponse -Data $application
            ))

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Not -Throw
        }
    }

    Context 'fails closed with the manual step' {
        It 'when <Case>' -ForEach @(
            @{ Case = 'no platform member has the assignment'; Change = { $assignmentPages[0].value = @(New-TestAssignment -PrincipalId $leadId -AppRoleId $otherRoleId) } }
            @{ Case = 'the assignment is inherited through a group'; Change = { $assignmentPages[0].value = @(New-TestAssignment -PrincipalId $ownerId -PrincipalType 'Group') } }
            @{ Case = 'the owner is not in teams.platform'; Change = { $instance.teams.platform = @('lead@contoso.test'); & $write } }
            @{ Case = 'the assignment grants another app role'; Change = { $assignmentPages[0].value = @(New-TestAssignment -PrincipalId $ownerId -AppRoleId $otherRoleId) } }
            @{ Case = 'the assignment belongs to another resource'; Change = { $assignmentPages[0].value = @(New-TestAssignment -PrincipalId $ownerId -ResourceId $otherRoleId) } }
            @{ Case = 'the application has no assignments'; Change = { $assignmentPages[0].value = @() } }
            @{ Case = 'no platform member exists in Entra ID'; Change = { $users.Clear() } }
        ) {
            . $Change

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } |
                Should -Throw '*direct Enterprise Owner*Entra ID administrator*teams.platform*'
        }
    }

    Context 'fails closed' {
        It 'when the enterprise application <Case>' -ForEach @(
            @{ Case = 'has no Enterprise Owner role'; Change = { $application.appRoles = @($application.appRoles[0]) } }
            @{ Case = 'has a disabled Enterprise Owner role'; Change = { $application.appRoles[1].isEnabled = $false } }
            @{ Case = 'has an Enterprise Owner role that users cannot hold'; Change = { $application.appRoles[1].allowedMemberTypes = @('Application') } }
            @{ Case = 'has two Enterprise Owner roles'; Change = { $application.appRoles[0].displayName = 'Enterprise Owner' } }
        ) {
            . $Change

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*one enabled Enterprise Owner app role*'
            @($requests | Where-Object { $_.Uri -like '*appRoleAssignedTo*' }) | Should -BeNullOrEmpty
        }

        It 'when Graph returns another service principal' {
            $application.id = $otherRoleId

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*enterpriseApplicationObjectId*'
        }

        It 'when Graph returns a user with another UPN' {
            $users['owner@contoso.test'].userPrincipalName = 'other@contoso.test'

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*owner@contoso.test*'
        }

        It 'when Graph returns a user without id' {
            $users['owner@contoso.test'].id = ''

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*owner@contoso.test*'
        }

        It 'when Graph denies the <Request> request' -ForEach @(
            @{ Request = 'service principal'; Path = "/v1.0/servicePrincipals/33333333-3333-3333-3333-333333333333" }
            @{ Request = 'user'; Path = '/v1.0/users/owner@contoso.test' }
            @{ Request = 'assignment'; Path = '/v1.0/servicePrincipals/33333333-3333-3333-3333-333333333333/appRoleAssignedTo' }
        ) {
            $responses[$Path] = Get-TestResponse -StatusCode 403 -Data @{ error = @{ code = 'Authorization_RequestDenied'; message = 'Insufficient privileges.' } }

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*HTTP 403*Authorization_RequestDenied*'
        }

        It 'when Graph keeps throttling' {
            $responses["/v1.0/servicePrincipals/$spId"] = Get-TestResponse -StatusCode 503

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*HTTP 503*'
        }

        It 'when Graph returns <Case>' -ForEach @(
            @{ Case = 'invalid JSON'; Response = [pscustomobject]@{ StatusCode = 200; Content = '{' } }
            @{ Case = 'a JSON array'; Response = [pscustomobject]@{ StatusCode = 200; Content = '[]' } }
            @{ Case = 'a page without value'; Response = [pscustomobject]@{ StatusCode = 200; Content = '{"@odata.context":"x"}' } }
            @{ Case = 'a non-object item'; Response = [pscustomobject]@{ StatusCode = 200; Content = '{"value":["x"]}' } }
            @{ Case = 'a redirect'; Response = [pscustomobject]@{ StatusCode = 302; Content = '' } }
        ) {
            $responses["/v1.0/servicePrincipals/$spId/appRoleAssignedTo"] = $Response

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw
        }

        It 'when the next page link <Case>' -ForEach @(
            @{ Case = 'points to another host'; Link = 'https://graph.example.test/v1.0/servicePrincipals/x/appRoleAssignedTo?$skiptoken=1' }
            @{ Case = 'uses plain HTTP'; Link = 'http://graph.microsoft.com/v1.0/servicePrincipals/x/appRoleAssignedTo?$skiptoken=1' }
            @{ Case = 'leaves Graph v1.0'; Link = 'https://graph.microsoft.com/beta/servicePrincipals/x/appRoleAssignedTo?$skiptoken=1' }
        ) {
            $next = Get-MicrosoftApiFixture -Name graph/serviceprincipal-list-approleassignedto.next-page -Set @{ '@odata.nextLink' = $Link }
            $next.value = @(New-TestAssignment -PrincipalId $leadId -AppRoleId $otherRoleId)
            $assignmentPages[0] = $next

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*Untrusted Graph address*'
            @($requests | Where-Object { ([uri] $_.Uri).Host -cne 'graph.microsoft.com' }) | Should -BeNullOrEmpty
        }

        It 'when the next page link repeats a page' {
            $next = Get-MicrosoftApiFixture -Name graph/serviceprincipal-list-approleassignedto.next-page -Set @{
                '@odata.nextLink' = "$graph/servicePrincipals/$spId/appRoleAssignedTo?`$skiptoken=1"
            }
            $next.value = @()
            $assignmentPages[0] = $next
            $assignmentPages.Add($next)

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*pagination cycle*'
        }

        It 'when the Azure login <Case>' -ForEach @(
            @{ Case = 'fails'; Change = { Mock az { $global:LASTEXITCODE = 1; 'Please run az login.' } }; Error = '*Azure authentication*' }
            @{ Case = 'belongs to another tenant'; Change = { $token.tenant = '99999999-9999-9999-9999-999999999999' }; Error = '*tenantId*' }
            @{ Case = 'returns no token'; Change = { $token.accessToken = '' }; Error = '*tenantId*' }
        ) {
            . $Change

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw $Error
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'when the instance has no bootstrap connection' {
            $instance.Remove('bootstrap')
            & $write

            { & $ownerCheck -InstancePath $instancePath -ModulesPath $modulesPath } | Should -Throw '*$.bootstrap*'
            Should -Invoke az -Times 0 -Exactly
        }
    }
}
