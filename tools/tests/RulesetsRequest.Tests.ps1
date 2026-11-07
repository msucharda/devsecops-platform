BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'RulesetsStub.psm1') -Force
}

Describe 'Organization ruleset request contract before a stub write' {
    BeforeEach {
        $state = Initialize-RulesetsStub -Origin 'https://api.example.test'
        $request = Get-GitHubApiFixture -Name repos/get-org-ruleset.baseline
        foreach ($responseField in @('id', 'source', 'source_type')) { $request.Remove($responseField) }
        $headers = @{ Authorization = 'Bearer stub-token'; 'X-GitHub-Api-Version' = '2026-03-10' }
    }

    It 'rejects an undocumented nested CodeQL security threshold before recording a POST' {
        # Intentionally invalid: change only one value in a schema-derived valid request.
        $request.rules[0].parameters.code_scanning_tools[0].security_alerts_threshold = 'high'

        $reply = Invoke-RulesetsStubRequest -State $state -Method POST -Path '/orgs/demo/rulesets' `
            -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)

        $reply.Status | Should -Be 422
        $reply.Body | Should -Match 'security_alerts_threshold'
        $state.Writes.Count | Should -Be 0
        $state.Items.Count | Should -Be 0
        $state.NextId | Should -Be 100
    }

    It 'accepts all four documented baseline rule variants on <Method>' -ForEach @(
        @{ Method = 'POST'; Status = 201; Path = '/orgs/demo/rulesets' }
        @{ Method = 'PUT'; Status = 200; Path = '/orgs/demo/rulesets/21' }
    ) {
        if ($Method -ceq 'PUT') { $state.Items.Add((Get-GitHubApiFixture -Name repos/get-org-ruleset.baseline)) }
        $reply = Invoke-RulesetsStubRequest -State $state -Method $Method -Path $Path `
            -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)

        $reply.Status | Should -Be $Status -Because $reply.Body
        $state.Writes.Count | Should -Be 1
        (ConvertFrom-Json -InputObject $reply.Body).rules.type | Should -Be @('code_scanning', 'deletion', 'non_fast_forward', 'pull_request')
    }

    It 'rejects <Case> before a POST or PUT changes stored state' -ForEach @(
        @{ Case = 'non-string tool'; Change = { $request.rules[0].parameters.code_scanning_tools[0].tool = 1 }; ExpectedError = 'tool' }
        @{ Case = 'missing tool'; Change = { $request.rules[0].parameters.code_scanning_tools[0].Remove('tool') }; ExpectedError = 'tool' }
        @{ Case = 'missing alerts threshold'; Change = { $request.rules[0].parameters.code_scanning_tools[0].Remove('alerts_threshold') }; ExpectedError = 'alerts_threshold' }
        @{ Case = 'non-string alerts threshold'; Change = { $request.rules[0].parameters.code_scanning_tools[0].alerts_threshold = $false }; ExpectedError = 'alerts_threshold' }
        @{ Case = 'unknown alerts threshold'; Change = { $request.rules[0].parameters.code_scanning_tools[0].alerts_threshold = 'warning' }; ExpectedError = 'alerts_threshold' }
        @{ Case = 'differently cased security threshold'; Change = { $request.rules[0].parameters.code_scanning_tools[0].security_alerts_threshold = 'HIGH_OR_HIGHER' }; ExpectedError = 'security_alerts_threshold' }
        @{ Case = 'missing security threshold'; Change = { $request.rules[0].parameters.code_scanning_tools[0].Remove('security_alerts_threshold') }; ExpectedError = 'security_alerts_threshold' }
        @{ Case = 'non-string security threshold'; Change = { $request.rules[0].parameters.code_scanning_tools[0].security_alerts_threshold = 1 }; ExpectedError = 'security_alerts_threshold' }
        @{ Case = 'non-object tool'; Change = { $request.rules[0].parameters.code_scanning_tools[0] = 'CodeQL' }; ExpectedError = 'code_scanning_tools[0]' }
        @{ Case = 'object tool list'; Change = { $request.rules[0].parameters.code_scanning_tools = @{} }; ExpectedError = 'code_scanning_tools' }
        @{ Case = 'missing tool list'; Change = { $request.rules[0].parameters.Remove('code_scanning_tools') }; ExpectedError = 'code_scanning_tools' }
        @{ Case = 'parameterless code scanning variant'; Change = { $request.rules[0].Remove('parameters') }; ExpectedError = 'parameters' }
        @{ Case = 'parameterless pull request variant'; Change = { $request.rules[3].Remove('parameters') }; ExpectedError = 'parameters' }
        @{ Case = 'non-object code scanning parameters'; Change = { $request.rules[0].parameters = @() }; ExpectedError = 'parameters' }
        @{ Case = 'non-object pull request parameters'; Change = { $request.rules[3].parameters = 'required' }; ExpectedError = 'parameters' }
        @{ Case = 'missing approval count'; Change = { $request.rules[3].parameters.Remove('required_approving_review_count') }; ExpectedError = 'required_approving_review_count' }
        @{ Case = 'string approval count'; Change = { $request.rules[3].parameters.required_approving_review_count = '1' }; ExpectedError = 'required_approving_review_count' }
        @{ Case = 'approval count below zero'; Change = { $request.rules[3].parameters.required_approving_review_count = -1 }; ExpectedError = 'required_approving_review_count' }
        @{ Case = 'approval count above ten'; Change = { $request.rules[3].parameters.required_approving_review_count = 11 }; ExpectedError = 'required_approving_review_count' }
        @{ Case = 'non-boolean stale review dismissal'; Change = { $request.rules[3].parameters.dismiss_stale_reviews_on_push = 'true' }; ExpectedError = 'dismiss_stale_reviews_on_push' }
        @{ Case = 'missing stale review dismissal'; Change = { $request.rules[3].parameters.Remove('dismiss_stale_reviews_on_push') }; ExpectedError = 'dismiss_stale_reviews_on_push' }
        @{ Case = 'missing code owner requirement'; Change = { $request.rules[3].parameters.Remove('require_code_owner_review') }; ExpectedError = 'require_code_owner_review' }
        @{ Case = 'non-boolean code owner requirement'; Change = { $request.rules[3].parameters.require_code_owner_review = 'true' }; ExpectedError = 'require_code_owner_review' }
        @{ Case = 'non-boolean last push approval'; Change = { $request.rules[3].parameters.require_last_push_approval = 0 }; ExpectedError = 'require_last_push_approval' }
        @{ Case = 'missing last push approval'; Change = { $request.rules[3].parameters.Remove('require_last_push_approval') }; ExpectedError = 'require_last_push_approval' }
        @{ Case = 'missing thread resolution requirement'; Change = { $request.rules[3].parameters.Remove('required_review_thread_resolution') }; ExpectedError = 'required_review_thread_resolution' }
        @{ Case = 'non-boolean thread resolution requirement'; Change = { $request.rules[3].parameters.required_review_thread_resolution = 1 }; ExpectedError = 'required_review_thread_resolution' }
        @{ Case = 'non-boolean observed extension'; Change = { $request.rules[3].parameters.require_extra_approval_for_unattributed_changes = 'true' }; ExpectedError = 'require_extra_approval_for_unattributed_changes' }
        @{ Case = 'invalid merge method'; Change = { $request.rules[3].parameters.allowed_merge_methods[0] = 'fast-forward' }; ExpectedError = 'allowed_merge_methods' }
        @{ Case = 'no allowed merge method'; Change = { $request.rules[3].parameters.allowed_merge_methods = @() }; ExpectedError = 'allowed_merge_methods' }
        @{ Case = 'non-array merge methods'; Change = { $request.rules[3].parameters.allowed_merge_methods = 'merge' }; ExpectedError = 'allowed_merge_methods' }
        @{ Case = 'non-array required reviewers'; Change = { $request.rules[3].parameters['required_reviewers'] = @{} }; ExpectedError = 'required_reviewers' }
        @{ Case = 'unsupported nonempty required reviewers'; Change = { $request.rules[3].parameters['required_reviewers'] = @(@{}) }; ExpectedError = 'Unsupported' }
        @{ Case = 'non-array ref include'; Change = { $request.conditions.ref_name.include = '~DEFAULT_BRANCH' }; ExpectedError = 'ref_name.include' }
        @{ Case = 'non-string ref exclude'; Change = { $request.conditions.ref_name.exclude = @(1) }; ExpectedError = 'ref_name.exclude' }
        @{ Case = 'non-array repository include'; Change = { $request.conditions.repository_name.include = '~ALL' }; ExpectedError = 'repository_name.include' }
        @{ Case = 'non-string repository exclude'; Change = { $request.conditions.repository_name.exclude = @(1) }; ExpectedError = 'repository_name.exclude' }
        @{ Case = 'non-boolean protected repository'; Change = { $request.conditions.repository_name.protected = 'false' }; ExpectedError = 'repository_name.protected' }
        @{ Case = 'non-object ref condition'; Change = { $request.conditions.ref_name = @() }; ExpectedError = 'ref_name' }
        @{ Case = 'non-object repository condition'; Change = { $request.conditions.repository_name = $null }; ExpectedError = 'repository_name' }
        @{ Case = 'non-object conditions'; Change = { $request.conditions = @() }; ExpectedError = 'conditions' }
        @{ Case = 'unknown nested tool property'; Change = { $request.rules[0].parameters.code_scanning_tools[0]['extra'] = $true }; ExpectedError = 'extra' }
        @{ Case = 'differently cased required tool property'; Change = { $value = $request.rules[0].parameters.code_scanning_tools[0].tool; $request.rules[0].parameters.code_scanning_tools[0].Remove('tool'); $request.rules[0].parameters.code_scanning_tools[0]['Tool'] = $value }; ExpectedError = 'tool' }
        @{ Case = 'parameters on a parameterless rule'; Change = { $request.rules[1]['parameters'] = @{} }; ExpectedError = 'parameters' }
        @{ Case = 'unknown rule variant'; Change = { $request.rules[0].type = 'unknown' }; ExpectedError = 'type' }
        @{ Case = 'missing rule discriminator'; Change = { $request.rules[0].Remove('type') }; ExpectedError = 'type' }
        @{ Case = 'non-string rule discriminator'; Change = { $request.rules[0].type = 1 }; ExpectedError = 'type' }
        @{ Case = 'null rule'; Change = { $request.rules[0] = $null }; ExpectedError = 'type' }
        @{ Case = 'unknown condition'; Change = { $request.conditions['extra'] = @{} }; ExpectedError = 'extra' }
        @{ Case = 'repository ID condition'; Change = { $request.conditions.Remove('repository_name'); $request.conditions['repository_id'] = @{ repository_ids = @(1) } }; ExpectedError = 'repository_name' }
        @{ Case = 'repository property condition'; Change = { $request.conditions.Remove('repository_name'); $request.conditions['repository_property'] = @{} }; ExpectedError = 'repository_name' }
        @{ Case = 'non-string name'; Change = { $request.name = $false }; ExpectedError = 'name' }
        @{ Case = 'unknown target'; Change = { $request.target = 'default' }; ExpectedError = 'target' }
        @{ Case = 'non-string target'; Change = { $request.target = 1 }; ExpectedError = 'target' }
        @{ Case = 'unknown enforcement'; Change = { $request.enforcement = 'enabled' }; ExpectedError = 'enforcement' }
        @{ Case = 'non-string enforcement'; Change = { $request.enforcement = $null }; ExpectedError = 'enforcement' }
        @{ Case = 'non-array rules'; Change = { $request.rules = @{} }; ExpectedError = 'rules' }
        @{ Case = 'unknown root field'; Change = { $request['extra'] = $true }; ExpectedError = 'extra' }
        @{ Case = 'root key collection shadow'; Change = { $request['Keys'] = @('name', 'enforcement') }; ExpectedError = 'Keys' }
        @{ Case = 'condition key collection shadow'; Change = { $request.conditions['Keys'] = @('repository_name') }; ExpectedError = 'Keys' }
        @{ Case = 'ref condition key collection shadow'; Change = { $request.conditions.ref_name['Keys'] = @() }; ExpectedError = 'Keys' }
        @{ Case = 'rule key collection shadow'; Change = { $request.rules[0]['Keys'] = @('type', 'parameters') }; ExpectedError = 'Keys' }
        @{ Case = 'parameter key collection shadow'; Change = { $request.rules[0].parameters['Keys'] = @('code_scanning_tools') }; ExpectedError = 'Keys' }
        @{ Case = 'tool key collection shadow'; Change = { $request.rules[0].parameters.code_scanning_tools[0]['Keys'] = @('tool', 'alerts_threshold', 'security_alerts_threshold') }; ExpectedError = 'Keys' }
        @{ Case = 'bypass actor key collection shadow'; WithBypass = $true; Change = { $request.bypass_actors[0]['Keys'] = @('actor_type', 'actor_id', 'bypass_mode') }; ExpectedError = 'Keys' }
        @{ Case = 'differently cased optional target property'; Change = { $value = $request.target; $request.Remove('target'); $request['Target'] = $value }; ExpectedError = 'Target' }
        @{ Case = 'non-array bypass actors'; Change = { $request.bypass_actors = @{} }; ExpectedError = 'bypass_actors' }
        @{ Case = 'Team bypass actor without identity'; WithBypass = $true; Change = { $request.bypass_actors[0].Remove('actor_id') }; ExpectedError = 'actor_id' }
        @{ Case = 'Team bypass actor with null identity'; WithBypass = $true; Change = { $request.bypass_actors[0].actor_id = $null }; ExpectedError = 'actor_id' }
        @{ Case = 'missing bypass actor type'; WithBypass = $true; Change = { $request.bypass_actors[0].Remove('actor_type') }; ExpectedError = 'actor_type' }
        @{ Case = 'unknown bypass actor type'; WithBypass = $true; Change = { $request.bypass_actors[0].actor_type = 'Unknown' }; ExpectedError = 'actor_type' }
        @{ Case = 'differently cased bypass actor type'; WithBypass = $true; Change = { $request.bypass_actors[0].actor_type = 'team' }; ExpectedError = 'actor_type' }
        @{ Case = 'non-string bypass actor type'; WithBypass = $true; Change = { $request.bypass_actors[0].actor_type = $false }; ExpectedError = 'actor_type' }
        @{ Case = 'non-integer bypass identity'; WithBypass = $true; Change = { $request.bypass_actors[0].actor_id = '234' }; ExpectedError = 'actor_id' }
        @{ Case = 'unknown bypass mode'; WithBypass = $true; Change = { $request.bypass_actors[0].bypass_mode = 'sometimes' }; ExpectedError = 'bypass_mode' }
        @{ Case = 'non-string bypass mode'; WithBypass = $true; Change = { $request.bypass_actors[0].bypass_mode = $true }; ExpectedError = 'bypass_mode' }
        @{ Case = 'non-object bypass actor'; WithBypass = $true; Change = { $request.bypass_actors[0] = @() }; ExpectedError = 'bypass_actors[0]' }
        @{ Case = 'unknown bypass actor property'; WithBypass = $true; Change = { $request.bypass_actors[0]['extra'] = $true }; ExpectedError = 'extra' }
        @{ Case = 'DeployKey bypass with non-null identity'; WithBypass = $true; Change = { $request.bypass_actors[0].actor_type = 'DeployKey' }; ExpectedError = 'actor_id' }
        @{ Case = 'pull-request bypass on a tag ruleset'; WithBypass = $true; PullRequestBypass = $true; Change = { $request.target = 'tag' }; ExpectedError = 'bypass_mode' }
    ) {
        param($Case, $Change, $ExpectedError, [bool] $WithBypass = $false, [bool] $PullRequestBypass = $false)
        if ($WithBypass) { $request.bypass_actors = (Get-GitHubApiFixture -Name repos/create-org-ruleset).bypass_actors }
        if ($PullRequestBypass) { $request.bypass_actors[0].bypass_mode = 'pull_request' }
        $state.Items.Add((Get-GitHubApiFixture -Name repos/get-org-ruleset.baseline))
        $before = ConvertTo-Json -InputObject $state.Items -Depth 50
        # Each case intentionally invalidates or selects an unsupported part of one schema-derived field.
        $null = & $Change
        foreach ($method in @('POST', 'PUT', 'POST', 'PUT')) {
            $path = if ($method -ceq 'POST') { '/orgs/demo/rulesets' } else { '/orgs/demo/rulesets/21' }
            $reply = Invoke-RulesetsStubRequest -State $state -Method $method -Path $path `
                -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)

            $reply.Status | Should -Be 422 -Because "$method must reject $Case"
            $reply.Body | Should -Match ([regex]::Escape($ExpectedError))
            (ConvertTo-Json -InputObject $state.Items -Depth 50) | Should -BeExactly $before
            $state.Writes.Count | Should -Be 0
            $state.NextId | Should -Be 100
        }
    }

    It 'rejects POST missing <Field> without allocating an ID across retries' -ForEach @(
        @{ Field = 'name' }
        @{ Field = 'enforcement' }
    ) {
        # Intentionally invalid: remove only the POST-required property.
        $request.Remove($Field)
        foreach ($attempt in @(1, 2)) {
            $reply = Invoke-RulesetsStubRequest -State $state -Method POST -Path '/orgs/demo/rulesets' `
                -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)
            $reply.Status | Should -Be 422
            $reply.Body | Should -Match $Field
            $state.Items.Count | Should -Be 0
            $state.Writes.Count | Should -Be 0
            $state.NextId | Should -Be 100
        }
    }

    It 'requires a non-null identity for <ActorType> on POST and PUT' -ForEach @(
        @{ ActorType = 'Integration' }
        @{ ActorType = 'RepositoryRole' }
        @{ ActorType = 'Team' }
        @{ ActorType = 'User' }
    ) {
        $request.bypass_actors = (Get-GitHubApiFixture -Name repos/create-org-ruleset).bypass_actors
        $request.bypass_actors[0].actor_type = $ActorType
        $state.Items.Add((Get-GitHubApiFixture -Name repos/get-org-ruleset.baseline))
        $before = ConvertTo-Json -InputObject $state.Items -Depth 50
        foreach ($identity in @('missing', 'null')) {
            # Intentionally invalid: remove or null only the required identity.
            if ($identity -ceq 'missing') { $request.bypass_actors[0].Remove('actor_id') }
            else { $request.bypass_actors[0]['actor_id'] = $null }
            foreach ($method in @('POST', 'PUT')) {
                $path = if ($method -ceq 'POST') { '/orgs/demo/rulesets' } else { '/orgs/demo/rulesets/21' }
                $reply = Invoke-RulesetsStubRequest -State $state -Method $method -Path $path `
                    -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)
                $reply.Status | Should -Be 422
                $reply.Body | Should -Match 'actor_id'
                $reply.Body | Should -Match $ActorType
                (ConvertTo-Json -InputObject $state.Items -Depth 50) | Should -BeExactly $before
                $state.Writes.Count | Should -Be 0
                $state.NextId | Should -Be 100
            }
        }
    }

    It 'accepts documented bypass mode <Mode> on a branch ruleset' -ForEach @(
        @{ Mode = 'always' }
        @{ Mode = 'pull_request' }
        @{ Mode = 'exempt' }
    ) {
        $request.bypass_actors = (Get-GitHubApiFixture -Name repos/create-org-ruleset).bypass_actors
        $request.bypass_actors[0].bypass_mode = $Mode
        $reply = Invoke-RulesetsStubRequest -State $state -Method POST -Path '/orgs/demo/rulesets' `
            -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)
        $reply.Status | Should -Be 201 -Because $reply.Body
    }

    It 'accepts documented bypass actor <ActorType> without interpreting it as an empty baseline' -ForEach @(
        @{ ActorType = 'Integration'; ActorId = 234 }
        @{ ActorType = 'OrganizationAdmin'; ActorId = $null }
        @{ ActorType = 'RepositoryRole'; ActorId = 234 }
        @{ ActorType = 'Team'; ActorId = 234 }
        @{ ActorType = 'DeployKey'; ActorId = $null }
        @{ ActorType = 'EnterpriseOwner'; ActorId = $null }
        @{ ActorType = 'EnterpriseRole'; ActorId = 234 }
        @{ ActorType = 'User'; ActorId = 234 }
    ) {
        $request.bypass_actors = (Get-GitHubApiFixture -Name repos/create-org-ruleset).bypass_actors
        $request.bypass_actors[0].actor_type = $ActorType
        $request.bypass_actors[0].actor_id = $ActorId
        $reply = Invoke-RulesetsStubRequest -State $state -Method POST -Path '/orgs/demo/rulesets' `
            -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)
        $reply.Status | Should -Be 201 -Because $reply.Body
        (ConvertFrom-Json -InputObject $reply.Body).bypass_actors[0].actor_type | Should -BeExactly $ActorType
    }

    It 'rejects pull-request bypass for DeployKey before a write' {
        $request.bypass_actors = (Get-GitHubApiFixture -Name repos/create-org-ruleset).bypass_actors
        $request.bypass_actors[0].actor_type = 'DeployKey'
        $request.bypass_actors[0].actor_id = $null
        # Intentionally invalid: only the otherwise valid DeployKey bypass mode is changed.
        $request.bypass_actors[0].bypass_mode = 'pull_request'
        foreach ($method in @('POST', 'PUT')) {
            if ($method -ceq 'PUT') { $state.Items.Add((Get-GitHubApiFixture -Name repos/get-org-ruleset.baseline)) }
            $before = ConvertTo-Json -InputObject $state.Items -Depth 50
            $path = if ($method -ceq 'POST') { '/orgs/demo/rulesets' } else { '/orgs/demo/rulesets/21' }
            $reply = Invoke-RulesetsStubRequest -State $state -Method $method -Path $path `
                -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)
            $reply.Status | Should -Be 422
            $reply.Body | Should -Match 'bypass_mode'
            (ConvertTo-Json -InputObject $state.Items -Depth 50) | Should -BeExactly $before
            $state.Writes.Count | Should -Be 0
            $state.NextId | Should -Be 100
        }
    }

    It 'does not confuse a valid weaker security threshold with a malformed request' {
        $request.rules[0].parameters.code_scanning_tools[0].security_alerts_threshold = 'critical'
        $reply = Invoke-RulesetsStubRequest -State $state -Method POST -Path '/orgs/demo/rulesets' `
            -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)

        $reply.Status | Should -Be 201
        (ConvertFrom-Json -InputObject $reply.Body).rules[0].parameters.code_scanning_tools[0].security_alerts_threshold |
            Should -BeExactly 'critical'
    }

    It 'accepts a documented partial PUT without requiring POST-only properties' {
        $state.Items.Add((Get-GitHubApiFixture -Name repos/get-org-ruleset.baseline))
        $reply = Invoke-RulesetsStubRequest -State $state -Method PUT -Path '/orgs/demo/rulesets/21' `
            -Headers $headers -Body '{"enforcement":"evaluate"}'

        $reply.Status | Should -Be 200
        $state.Items[0].name | Should -BeExactly 'platform-default-branch'
        $state.Items[0].enforcement | Should -BeExactly 'evaluate'
    }

    It 'rejects a <Count>-object root array before a <Method> changes state' -ForEach @(
        @{ Method = 'POST'; Count = 0 }
        @{ Method = 'POST'; Count = 1 }
        @{ Method = 'POST'; Count = 2 }
        @{ Method = 'PUT'; Count = 0 }
        @{ Method = 'PUT'; Count = 1 }
        @{ Method = 'PUT'; Count = 2 }
    ) {
        $state.Items.Add((Get-GitHubApiFixture -Name repos/get-org-ruleset.baseline))
        $before = ConvertTo-Json -InputObject $state.Items -Depth 50
        # Intentionally invalid: wrap valid objects in an array instead of sending an object.
        $wrapped = @()
        for ($index = 0; $index -lt $Count; $index++) { $wrapped += $request }
        $body = ConvertTo-Json -InputObject $wrapped -Depth 50
        $path = if ($Method -ceq 'POST') { '/orgs/demo/rulesets' } else { '/orgs/demo/rulesets/21' }
        foreach ($attempt in @(1, 2)) {
            $reply = Invoke-RulesetsStubRequest -State $state -Method $Method -Path $path -Headers $headers -Body $body
            $reply.Status | Should -Be 422
            $reply.Body | Should -Match 'request must be object'
            (ConvertTo-Json -InputObject $state.Items -Depth 50) | Should -BeExactly $before
            $state.Writes.Count | Should -Be 0
            $state.NextId | Should -Be 100
        }
    }

    It 'preserves supported state across POST then partial PUT when omitting <Case>' -ForEach @(
        @{ Case = 'target'; Omitted = @('target') }
        @{ Case = 'bypass actors'; Omitted = @('bypass_actors') }
        @{ Case = 'conditions'; Omitted = @('conditions') }
        @{ Case = 'rules'; Omitted = @('rules') }
        @{ Case = 'all optional properties'; Omitted = @('target', 'bypass_actors', 'conditions', 'rules') }
    ) {
        foreach ($field in $Omitted) { $request.Remove($field) }
        $created = Invoke-RulesetsStubRequest -State $state -Method POST -Path '/orgs/demo/rulesets' `
            -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)
        $created.Status | Should -Be 201 -Because $created.Body
        $id = (ConvertFrom-Json -InputObject $created.Body).id
        $updated = Invoke-RulesetsStubRequest -State $state -Method PUT -Path "/orgs/demo/rulesets/$id" `
            -Headers $headers -Body '{"name":"renamed"}'
        $updated.Status | Should -Be 200 -Because $updated.Body
        $state.Items[0].name | Should -BeExactly 'renamed'
        $state.Items[0].target | Should -BeExactly 'branch'
        foreach ($field in $Omitted) {
            if ($field -cne 'target') { $state.Items[0].Contains($field) | Should -BeFalse }
            $state.Writes[0].Body.Contains($field) | Should -BeFalse
        }
        $state.Writes.Count | Should -Be 2
        $state.NextId | Should -Be 101
    }

    It 'rejects an incompatible partial PUT against retained fields: <Case>' -ForEach @(
        @{ Case = 'bypass on retained tag target'; Target = 'tag'; Enforcement = 'active'; Mode = 'always'; Body = '{"bypass_actors":[{"actor_type":"Team","actor_id":234,"bypass_mode":"pull_request"}]}'; ExpectedError = 'bypass_mode' }
        @{ Case = 'tag target with retained pull-request bypass'; Target = 'branch'; Enforcement = 'active'; Mode = 'pull_request'; Body = '{"target":"tag"}'; ExpectedError = 'bypass_mode' }
        @{ Case = 'evaluate on retained repository target'; Target = 'repository'; Enforcement = 'active'; Mode = 'always'; Body = '{"enforcement":"evaluate"}'; ExpectedError = 'enforcement' }
        @{ Case = 'repository target with retained evaluate'; Target = 'branch'; Enforcement = 'evaluate'; Mode = 'always'; Body = '{"target":"repository"}'; ExpectedError = 'enforcement' }
    ) {
        $item = Get-GitHubApiFixture -Name repos/get-org-ruleset.baseline
        $item.target = $Target
        $item.enforcement = $Enforcement
        $item.rules = @()
        $item.conditions.Remove('ref_name')
        $item.bypass_actors = (Get-GitHubApiFixture -Name repos/create-org-ruleset).bypass_actors
        $item.bypass_actors[0].bypass_mode = $Mode
        $state.Items.Add($item)
        $before = ConvertTo-Json -InputObject $state.Items -Depth 50
        foreach ($attempt in @(1, 2)) {
            # Intentionally invalid: the one submitted field conflicts with valid retained state.
            $reply = Invoke-RulesetsStubRequest -State $state -Method PUT -Path '/orgs/demo/rulesets/21' `
                -Headers $headers -Body $Body
            $reply.Status | Should -Be 422
            $reply.Body | Should -Match $ExpectedError
            (ConvertTo-Json -InputObject $state.Items -Depth 50) | Should -BeExactly $before
            $state.Writes.Count | Should -Be 0
            $state.NextId | Should -Be 100
        }
    }

    It 'rejects evaluate for a repository target before a POST' {
        $request.target = 'repository'
        $request.rules = @()
        $request.conditions.Remove('ref_name')
        # Intentionally invalid: only enforcement differs from the valid repository target request.
        $request.enforcement = 'evaluate'
        $reply = Invoke-RulesetsStubRequest -State $state -Method POST -Path '/orgs/demo/rulesets' `
            -Headers $headers -Body (ConvertTo-Json -InputObject $request -Depth 50)
        $reply.Status | Should -Be 422
        $reply.Body | Should -Match 'enforcement'
        $state.Items.Count | Should -Be 0
        $state.Writes.Count | Should -Be 0
        $state.NextId | Should -Be 100
    }
}
