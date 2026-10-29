BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $scriptRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline/scripts'
    Import-Module (Join-Path $scriptRoot 'ActionsPolicy.psm1') -Force

    $apiUrl = 'https://api.example.ghe.com'
    $token = 'test-installation-token'
    $organization = 'demo-a1b2c3-workloads'
    $target = @{ ApiUrl = $apiUrl; Organization = $organization }
    $managedPolicy = @{
        enabled_repositories = 'all'; allowed_actions = 'local_only'
        sha_pinning_required = $true
        default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false
    }
    $defaultPolicy = @{
        enabled_repositories = 'all'; allowed_actions = 'all'
        sha_pinning_required = $false
        default_workflow_permissions = 'read'; can_approve_pull_request_reviews = $false
    }

    function Initialize-ActionsPolicyStub {
        <# A new organization with the GitHub defaults; the enterprise default of the workflow permissions is write. #>
        @{
            Actions = Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization -Set @{ allowed_actions = 'all'; sha_pinning_required = $false }
            Workflow = Get-GitHubApiFixture -Name actions/get-github-actions-default-workflow-permissions-organization -Set @{
                default_workflow_permissions = 'write'; can_approve_pull_request_reviews = $true
            }
            Requests = [Collections.Generic.List[object]]::new()
            # Operation name => scriptblock returning @{ Status; Body } instead of the stub response.
            Override = @{}
        }
    }

    function Get-StubWrite {
        , @($stub.Requests | Where-Object { $_.Method -cne 'GET' })
    }

    function Invoke-ActionsPolicyStub {
        param([string] $Method, [string] $PathAndQuery, [hashtable] $Headers, [AllowNull()][string] $Body)

        $Headers['Authorization'] | Should -BeExactly "Bearer $token"
        $Headers['X-GitHub-Api-Version'] | Should -BeExactly '2026-03-10'
        $operation = switch -Regex ("$Method $PathAndQuery") {
            "^GET /orgs/$organization/actions/permissions$" { 'getActions' }
            "^PUT /orgs/$organization/actions/permissions$" { 'setActions' }
            "^GET /orgs/$organization/actions/permissions/workflow$" { 'getWorkflow' }
            "^PUT /orgs/$organization/actions/permissions/workflow$" { 'setWorkflow' }
            default { throw "Unexpected request $Method $PathAndQuery." }
        }
        $parsed = if ($Body) { $Body | ConvertFrom-Json -AsHashtable } else { $null }
        $stub.Requests.Add(@{ Method = $Method; Operation = $operation; Body = $parsed })
        if ($stub.Override.Contains($operation)) { return & $stub.Override[$operation] }
        switch ($operation) {
            'getActions' { @{ Status = 200; Body = ConvertTo-Json -InputObject $stub.Actions -Compress } }
            'getWorkflow' { @{ Status = 200; Body = ConvertTo-Json -InputObject $stub.Workflow -Compress } }
            'setActions' {
                # The documented request: enabled_repositories is required; allowed_actions and sha_pinning_required are optional.
                $parsed['enabled_repositories'] | Should -BeIn @('all', 'none', 'selected')
                foreach ($key in $parsed.Keys) { $stub.Actions[$key] = $parsed[$key] }
                @{ Status = 204; Body = '' }
            }
            'setWorkflow' {
                foreach ($key in $parsed.Keys) { $stub.Workflow[$key] = $parsed[$key] }
                @{ Status = 204; Body = '' }
            }
        }
    }
}

Describe 'Actions policy' {
    BeforeEach {
        $env:REST_API_BEARER = $token
        $stub = Initialize-ActionsPolicyStub
        Mock -ModuleName ActionsPolicy Invoke-WebRequest {
            $uri = [Uri] $Uri
            $reply = Invoke-ActionsPolicyStub -Method ([string] $Method).ToUpperInvariant() -PathAndQuery $uri.PathAndQuery -Headers $Headers -Body $PesterBoundParameters['Body']
            [pscustomobject]@{ StatusCode = $reply.Status; Content = $reply.Body; Headers = @{} }
        }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    Context 'Set-ActionsPolicy' {
        It 'writes the managed policy including required SHA pinning to a new organization' {
            Set-ActionsPolicy @target -Policy $managedPolicy

            $stub.Actions['enabled_repositories'] | Should -BeExactly 'all'
            $stub.Actions['allowed_actions'] | Should -BeExactly 'local_only'
            $stub.Actions['sha_pinning_required'] | Should -BeExactly $true
            $stub.Workflow['default_workflow_permissions'] | Should -BeExactly 'read'
            $stub.Workflow['can_approve_pull_request_reviews'] | Should -BeExactly $false
            $writes = Get-StubWrite
            $writes.Operation | Should -Be @('setActions', 'setWorkflow')
            @($writes[0].Body.Keys) | Sort-Object | Should -Be @('allowed_actions', 'enabled_repositories', 'sha_pinning_required')
            $writes[0].Body['sha_pinning_required'] | Should -BeOfType [bool]
            $writes[1].Body['can_approve_pull_request_reviews'] | Should -BeOfType [bool]
        }

        It 'restores the GitHub defaults' {
            Set-ActionsPolicy @target -Policy $managedPolicy

            Set-ActionsPolicy @target -Policy $defaultPolicy

            $stub.Actions['allowed_actions'] | Should -BeExactly 'all'
            $stub.Actions['sha_pinning_required'] | Should -BeExactly $false
            $stub.Workflow['default_workflow_permissions'] | Should -BeExactly 'read'
            $stub.Workflow['can_approve_pull_request_reviews'] | Should -BeExactly $false
        }

        It 'resets a legacy policy stored before SHA pinning was managed' {
            Set-ActionsPolicy @target -Policy $managedPolicy
            $legacy = @{} + $defaultPolicy
            $legacy.Remove('sha_pinning_required')

            Set-ActionsPolicy @target -Policy $legacy -Reset

            $stub.Actions['sha_pinning_required'] | Should -BeExactly $false
            $stub.Actions['allowed_actions'] | Should -BeExactly 'all'
            $legacy.Contains('sha_pinning_required') | Should -BeFalse
        }

        It 'rejects a missing SHA field outside legacy reset' {
            $legacy = @{} + $defaultPolicy
            $legacy.Remove('sha_pinning_required')

            { Set-ActionsPolicy @target -Policy $legacy } | Should -Throw '*missing or undocumented value*'
            $stub.Requests | Should -BeNullOrEmpty
        }

        It 'writes nothing when the organization already has the policy' {
            Set-ActionsPolicy @target -Policy $managedPolicy
            $stub.Requests.Clear()

            Set-ActionsPolicy @target -Policy $managedPolicy

            Get-StubWrite | Should -BeNullOrEmpty
        }

        It 'accepts the string boolean <Pinning> of the external data source query' -ForEach @(
            @{ Pinning = 'true'; Expected = $true }
            @{ Pinning = 'false'; Expected = $false }
        ) {
            $policy = @{} + $managedPolicy
            $policy['can_approve_pull_request_reviews'] = 'false'
            $policy['sha_pinning_required'] = $Pinning

            Set-ActionsPolicy @target -Policy $policy

            $stub.Workflow['can_approve_pull_request_reviews'] | Should -BeExactly $false
            $stub.Actions['sha_pinning_required'] | Should -BeExactly $Expected
        }

        It 'rejects a managed policy with <Case> before any request' -ForEach @(
            @{ Case = 'an undocumented allowed_actions'; Field = 'allowed_actions'; Value = 'enterprise' }
            @{ Case = 'an upper-case allowed_actions'; Field = 'allowed_actions'; Value = 'LOCAL_ONLY' }
            @{ Case = 'an undocumented enabled_repositories'; Field = 'enabled_repositories'; Value = 'some' }
            @{ Case = 'an undocumented token permission'; Field = 'default_workflow_permissions'; Value = 'admin' }
            @{ Case = 'a non-boolean approval'; Field = 'can_approve_pull_request_reviews'; Value = 'False' }
            @{ Case = 'a missing approval'; Field = 'can_approve_pull_request_reviews'; Value = $null }
            @{ Case = 'a missing allowed_actions'; Field = 'allowed_actions'; Value = $null }
            @{ Case = 'a missing SHA pinning'; Field = 'sha_pinning_required'; Value = $null }
            @{ Case = 'an upper-case SHA pinning'; Field = 'sha_pinning_required'; Value = 'True' }
            @{ Case = 'an empty SHA pinning'; Field = 'sha_pinning_required'; Value = '' }
            @{ Case = 'a numeric SHA pinning'; Field = 'sha_pinning_required'; Value = 1 }
        ) {
            $policy = @{} + $managedPolicy
            $policy[$Field] = $Value

            { Set-ActionsPolicy @target -Policy $policy } | Should -Throw '*missing or undocumented value*'
            $stub.Requests | Should -BeNullOrEmpty
        }

        It 'reports an enterprise policy that blocks the organization setting (HTTP 409)' {
            $stub.Override['setWorkflow'] = { @{ Status = 409; Body = '{"message":"Conflict"}' } }

            { Set-ActionsPolicy @target -Policy $managedPolicy } | Should -Throw '*HTTP 409*enterprise policy prevents*'
        }

        It 'fails when GitHub accepts a write but keeps another value' {
            $stub.Override['setActions'] = { @{ Status = 204; Body = '' } }

            { Set-ActionsPolicy @target -Policy $managedPolicy } | Should -Throw '*allowed actions policy of demo-a1b2c3-workloads is not local_only*'
        }

        It 'repairs SHA pinning alone without changing the other policy fields' {
            Set-ActionsPolicy @target -Policy $managedPolicy
            $stub.Actions['sha_pinning_required'] = $false
            $stub.Requests.Clear()

            Set-ActionsPolicy @target -Policy $managedPolicy

            $writes = Get-StubWrite
            $writes.Count | Should -Be 1
            $writes[0].Operation | Should -BeExactly 'setActions'
            $writes[0].Body['enabled_repositories'] | Should -BeExactly 'all'
            $writes[0].Body['allowed_actions'] | Should -BeExactly 'local_only'
            $writes[0].Body['sha_pinning_required'] | Should -BeExactly $true
        }

        It 'fails readback when GitHub accepts but ignores required SHA pinning' {
            Set-ActionsPolicy @target -Policy $managedPolicy
            $stub.Actions['sha_pinning_required'] = $false
            $stub.Override['setActions'] = { @{ Status = 204; Body = '' } }

            { Set-ActionsPolicy @target -Policy $managedPolicy } | Should -Throw '*Required SHA pinning*not true*'
        }

        It 'fails on HTTP <Status> of <Operation>' -ForEach @(
            @{ Operation = 'getActions'; Status = 403 }
            @{ Operation = 'getWorkflow'; Status = 404 }
            @{ Operation = 'setActions'; Status = 422 }
        ) {
            $stub.Override[$Operation] = { @{ Status = $Status; Body = '{"message":"Error"}' } }.GetNewClosure()

            { Set-ActionsPolicy @target -Policy $managedPolicy } | Should -Throw "*HTTP $Status*"
        }

        It 'rejects an organization login that could change the request path' {
            { Set-ActionsPolicy -ApiUrl $apiUrl -Organization 'demo/../enterprises/example' -Policy $managedPolicy } | Should -Throw '*not a GitHub organization login*'
            $stub.Requests | Should -BeNullOrEmpty
        }

        It 'rejects an API URL that is not an HTTPS origin' {
            { Set-ActionsPolicy -ApiUrl 'http://api.example.ghe.com' -Organization $organization -Policy $managedPolicy } | Should -Throw '*HTTPS origin*'
        }

        It 'fails without the installation token' {
            Remove-Item Env:\REST_API_BEARER

            { Set-ActionsPolicy @target -Policy $managedPolicy } | Should -Throw '*REST_API_BEARER*'
        }
    }

    Context 'Get-ActionsPolicyStateViolation' {
        BeforeEach {
            $compliant = @{
                actions_permissions = Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization -Set @{ allowed_actions = 'local_only' }
                workflow_permissions = Get-GitHubApiFixture -Name actions/get-github-actions-default-workflow-permissions-organization -Set @{ can_approve_pull_request_reviews = $false }
            }
            $policy = ConvertTo-ActionsPolicy -Policy $managedPolicy
        }

        It 'accepts boolean SHA pinning <Pinning> when it matches the managed policy' -ForEach @(
            @{ Pinning = $true }
            @{ Pinning = $false }
        ) {
            $compliant.actions_permissions['sha_pinning_required'] = $Pinning
            $policy['sha_pinning_required'] = $Pinning

            @(Get-ActionsPolicyStateViolation -State $compliant -Policy $policy -Organization $organization) | Should -BeNullOrEmpty
        }

        It 'reports exactly the condition <Case>' -ForEach @(
            @{ Case = 'actions disabled'; Section = 'actions_permissions'; Field = 'enabled_repositories'; Value = 'none'; Message = '*not enabled for all repositories*' }
            @{ Case = 'selected repositories'; Section = 'actions_permissions'; Field = 'enabled_repositories'; Value = 'selected'; Message = '*not enabled for all repositories*' }
            @{ Case = 'upper-case enabled_repositories'; Section = 'actions_permissions'; Field = 'enabled_repositories'; Value = 'ALL'; Message = '*not enabled for all repositories*' }
            @{ Case = 'boolean enabled_repositories'; Section = 'actions_permissions'; Field = 'enabled_repositories'; Value = $true; Message = '*not enabled for all repositories*' }
            @{ Case = 'missing enabled_repositories'; Section = 'actions_permissions'; Field = 'enabled_repositories'; Remove = $true; Message = '*not enabled for all repositories*' }
            @{ Case = 'all actions'; Section = 'actions_permissions'; Field = 'allowed_actions'; Value = 'all'; Message = '*allowed actions policy*not local_only*' }
            @{ Case = 'selected actions'; Section = 'actions_permissions'; Field = 'allowed_actions'; Value = 'selected'; Message = '*allowed actions policy*not local_only*' }
            @{ Case = 'upper-case allowed_actions'; Section = 'actions_permissions'; Field = 'allowed_actions'; Value = 'LOCAL_ONLY'; Message = '*allowed actions policy*not local_only*' }
            @{ Case = 'boolean allowed_actions'; Section = 'actions_permissions'; Field = 'allowed_actions'; Value = $true; Message = '*allowed actions policy*not local_only*' }
            @{ Case = 'missing allowed_actions'; Section = 'actions_permissions'; Field = 'allowed_actions'; Remove = $true; Message = '*allowed actions policy*not local_only*' }
            @{ Case = 'disabled SHA pinning'; Section = 'actions_permissions'; Field = 'sha_pinning_required'; Value = $false; Message = '*Required SHA pinning*not true*' }
            @{ Case = 'string SHA pinning'; Section = 'actions_permissions'; Field = 'sha_pinning_required'; Value = 'true'; Message = '*Required SHA pinning*not true*' }
            @{ Case = 'null SHA pinning'; Section = 'actions_permissions'; Field = 'sha_pinning_required'; Value = $null; Message = '*Required SHA pinning*not true*' }
            @{ Case = 'missing SHA pinning'; Section = 'actions_permissions'; Field = 'sha_pinning_required'; Remove = $true; Message = '*Required SHA pinning*not true*' }
            @{ Case = 'empty SHA pinning'; Section = 'actions_permissions'; Field = 'sha_pinning_required'; Value = ''; Message = '*Required SHA pinning*not true*' }
            @{ Case = 'numeric SHA pinning'; Section = 'actions_permissions'; Field = 'sha_pinning_required'; Value = 1; Message = '*Required SHA pinning*not true*' }
            @{ Case = 'write token'; Section = 'workflow_permissions'; Field = 'default_workflow_permissions'; Value = 'write'; Message = '*GITHUB_TOKEN permissions*not read*' }
            @{ Case = 'upper-case token permission'; Section = 'workflow_permissions'; Field = 'default_workflow_permissions'; Value = 'READ'; Message = '*GITHUB_TOKEN permissions*not read*' }
            @{ Case = 'boolean token permission'; Section = 'workflow_permissions'; Field = 'default_workflow_permissions'; Value = $true; Message = '*GITHUB_TOKEN permissions*not read*' }
            @{ Case = 'missing token permission'; Section = 'workflow_permissions'; Field = 'default_workflow_permissions'; Remove = $true; Message = '*GITHUB_TOKEN permissions*not read*' }
            @{ Case = 'pull request approval'; Section = 'workflow_permissions'; Field = 'can_approve_pull_request_reviews'; Value = $true; Message = '*create and approve pull requests is not false*' }
            @{ Case = 'string approval'; Section = 'workflow_permissions'; Field = 'can_approve_pull_request_reviews'; Value = 'false'; Message = '*create and approve pull requests is not false*' }
            @{ Case = 'null approval'; Section = 'workflow_permissions'; Field = 'can_approve_pull_request_reviews'; Value = $null; Message = '*create and approve pull requests is not false*' }
            @{ Case = 'missing approval'; Section = 'workflow_permissions'; Field = 'can_approve_pull_request_reviews'; Remove = $true; Message = '*create and approve pull requests is not false*' }
        ) {
            if ($_.Contains('Remove')) { $compliant[$Section].Remove($Field) } else { $compliant[$Section][$Field] = $Value }

            $violations = @(Get-ActionsPolicyStateViolation -State $compliant -Policy $policy -Organization $organization)

            $violations.Count | Should -Be 1 -Because ($violations -join ' ')
            $violations[0] | Should -BeLike $Message
        }

        It 'reports every condition of a missing <Section>' -ForEach @(
            @{ Section = 'actions_permissions'; Messages = @('*not enabled for all repositories*', '*allowed actions policy*', '*Required SHA pinning*') }
            @{ Section = 'workflow_permissions'; Messages = @('*GITHUB_TOKEN permissions*', '*create and approve pull requests*') }
        ) {
            $compliant.Remove($Section)

            $violations = @(Get-ActionsPolicyStateViolation -State $compliant -Policy $policy -Organization $organization)

            $violations.Count | Should -Be $Messages.Count
            for ($i = 0; $i -lt $Messages.Count; $i++) { $violations[$i] | Should -BeLike $Messages[$i] }
        }
    }

    Context 'Get-ActionsPolicyStateResult' {
        It 'returns the state and no violation after the policy is set' {
            Set-ActionsPolicy @target -Policy $managedPolicy
            $query = @{} + $managedPolicy
            $query['can_approve_pull_request_reviews'] = 'false'

            $result = Get-ActionsPolicyStateResult @target -Policy $query | ConvertFrom-Json -AsHashtable

            $result['violations'] | Should -BeExactly '[]'
            ($result['state'] | ConvertFrom-Json -AsHashtable)['actions_permissions']['allowed_actions'] | Should -BeExactly 'local_only'
        }

        It 'lists the violations of a new organization' {
            $query = @{} + $managedPolicy
            $query['can_approve_pull_request_reviews'] = 'false'

            $result = Get-ActionsPolicyStateResult @target -Policy $query | ConvertFrom-Json -AsHashtable

            $violations = ConvertFrom-Json -InputObject $result['violations'] -NoEnumerate
            $violations.Count | Should -Be 4
            $violations | ForEach-Object { $_ | Should -BeOfType [string] }
            Get-StubWrite | Should -BeNullOrEmpty
        }

        It 'fails instead of returning a state when GitHub returns <Case>' -ForEach @(
            @{ Case = 'an empty body'; Body = ''; Message = '*empty successful GET*' }
            @{ Case = 'a JSON array'; Body = '[]'; Message = '*no JSON object*' }
        ) {
            $stub.Override['getWorkflow'] = { @{ Status = 200; Body = $Body } }.GetNewClosure()

            { Get-ActionsPolicyStateResult @target -Policy $managedPolicy } | Should -Throw $Message
        }
    }
}
