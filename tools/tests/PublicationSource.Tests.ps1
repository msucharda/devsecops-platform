BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../PublicationSource.psm1') -Force
}

Describe 'Published platform source evidence' {
    BeforeEach {
        $check = Get-GitHubApiFixture -Name checks/create.completed
        $commit = $check.head_sha
        $check.name = 'GHE accepted source'
        $check.status = 'completed'
        $check.conclusion = 'success'
        $check.external_id = "platform-source-publication/v1:$('a' * 64)"
        $check.output.summary = @{
            schemaVersion = 1; kind = 'platform-source-publication'; phase = 'published'
            ref = 'refs/heads/source-publication/v1'; commit = $commit; receiptSha256 = 'a' * 64
        } | ConvertTo-Json -Compress
        $branchRules = Get-GitHubApiFixture -Name repos/get-branch-rules.merge-gate-required-check -Set @{
            '1.parameters.required_status_checks.0.context' = 'GHE accepted source'
            '1.parameters.required_status_checks.0.integration_id' = 1
            '1.parameters.strict_required_status_checks_policy' = $true
            '1.ruleset_id' = 42; '1.ruleset_source' = 'upstream/platform'
        }
        # Both union members and their parameters come from pinned primary API fixtures.
        $ruleset = Get-GitHubApiFixture -Name repos/get-repo-ruleset.no-bypass -Set @{
            source = 'upstream/platform'
            'conditions.ref_name.include' = @('refs/heads/source-publication/v1')
            'conditions.ref_name.exclude' = @()
            rules = @(@{
                type = 'required_status_checks'
                parameters = ($branchRules[1].parameters | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable)
            })
        }
        $checks = Get-GitHubApiFixture -Name checks/list-for-ref -Set @{ total_count = 1; check_runs = @($check) }
        $reference = Get-GitHubApiFixture -Name git/get-ref -Set @{
            ref = 'refs/heads/source-publication/v1'; 'object.sha' = $commit
        }
        $comparison = Get-GitHubApiFixture -Name repos/compare-commits -Set @{
            status = 'identical'; 'merge_base_commit.sha' = $commit
        }
        $documents = @{
            'rules/branches/source-publication%2Fv1' = $branchRules
            'rulesets/42' = $ruleset
            "commits/$commit/check-runs?filter=all&per_page=100&page=1" = $checks
            'git/ref/heads/source-publication/v1' = $reference
            "compare/$commit...${commit}?per_page=1" = $comparison
        }
        $reads = [Collections.Generic.List[string]]::new()
        $read = {
            param($Route)
            $reads.Add($Route)
            if (-not $documents.ContainsKey($Route)) { throw "Unexpected publication API route: $Route" }
            return ,$documents[$Route]
        }.GetNewClosure()
    }

    It 'combines independent active binding and ancestry with publisher-attested no-bypass' {
        $evidence = Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read
        $evidence.CheckId | Should -Be 4
        $evidence.ReceiptSha256 | Should -BeExactly ('a' * 64)
        $evidence.ProtectionEvidence | Should -BeExactly 'active-exact-ref-app-binding'
        $evidence.NoBypassEvidence | Should -BeExactly 'publisher-attested'
    }

    It 'accepts hidden bypass visibility without claiming an independently current audit' {
        $null = $ruleset.Remove('bypass_actors')
        $evidence = Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read
        $evidence.NoBypassEvidence | Should -BeExactly 'publisher-attested'
    }

    It 'accepts a legacy release commit behind the independently read publication tip' {
        $reference.object.sha = 'b' * 40
        $comparison.status = 'behind'
        $documents["compare/$('b' * 40)...${commit}?per_page=1"] = $comparison
        $evidence = Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read
        $evidence.Commit | Should -BeExactly $commit
    }

    It 'accepts the documented unrelated bypass actor <Type> without confusing actor namespaces' -ForEach @(
        @{ Type = 'Integration'; Id = 2 }
        @{ Type = 'OrganizationAdmin'; Id = $null }
        @{ Type = 'RepositoryRole'; Id = 1 }
        @{ Type = 'Team'; Id = 1 }
        @{ Type = 'DeployKey'; Id = $null }
        @{ Type = 'EnterpriseOwner'; Id = $null }
        @{ Type = 'EnterpriseRole'; Id = 1 }
        @{ Type = 'User'; Id = 1 }
    ) {
        $example = Get-GitHubApiFixture -Name repos/get-repo-ruleset.bypass-visible -Set @{
            'bypass_actors.0.actor_type' = $Type; 'bypass_actors.0.actor_id' = $Id
        }
        $ruleset.bypass_actors = @($example.bypass_actors[0])
        $evidence = Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read
        $evidence.NoBypassEvidence | Should -BeExactly 'publisher-attested'
    }

    It 'rejects <Case> at the actual evidence boundary' -ForEach @(
        # Each row changes one field of a documented valid response into deliberately invalid input.
        @{ Case = 'non-array branch rules'; Resource = 'branch'; Field = ''; Value = @{}; Error = '*binding rules*' }
        @{ Case = 'non-object branch rule'; Resource = 'branch'; Field = '0'; Value = 'bad'; Error = '*rule shape*' }
        @{ Case = 'non-string rule type'; Resource = 'branch'; Field = '1.type'; Value = @('required_status_checks'); Error = '*rule shape*' }
        @{ Case = 'case-folded check rule type'; Resource = 'branch'; Field = '1.type'; Value = 'Required_status_checks'; Error = '*binding type or context*' }
        @{ Case = 'non-object check parameters'; Resource = 'branch'; Field = '1.parameters'; Value = @(); Error = '*binding required checks*' }
        @{ Case = 'non-array required checks'; Resource = 'branch'; Field = '1.parameters.required_status_checks'; Value = @{}; Error = '*binding required checks*' }
        @{ Case = 'non-object required check'; Resource = 'branch'; Field = '1.parameters.required_status_checks.0'; Value = 'bad'; Error = '*check shape*' }
        @{ Case = 'non-string required context'; Resource = 'branch'; Field = '1.parameters.required_status_checks.0.context'; Value = @('GHE accepted source'); Error = '*check shape*' }
        @{ Case = 'a missing required context'; Resource = 'branch'; Field = '1.parameters.required_status_checks.0.context'; Value = 'different'; Error = '*Missing or ambiguous*binding*' }
        @{ Case = 'case-folded required context'; Resource = 'branch'; Field = '1.parameters.required_status_checks.0.context'; Value = 'ghe accepted source'; Error = '*binding type or context*' }
        @{ Case = 'a string integration ID'; Resource = 'branch'; Field = '1.parameters.required_status_checks.0.integration_id'; Value = '1'; Error = '*not bound*' }
        @{ Case = 'an unbound required check'; Resource = 'branch'; Field = '1.parameters.required_status_checks.0.integration_id'; Value = $null; Error = '*not bound*' }
        @{ Case = 'a different required App'; Resource = 'branch'; Field = '1.parameters.required_status_checks.0.integration_id'; Value = 2; Error = '*not bound*' }
        @{ Case = 'non-boolean strictness'; Resource = 'branch'; Field = '1.parameters.strict_required_status_checks_policy'; Value = 'true'; Error = '*enforce strict checks*' }
        @{ Case = 'disabled strictness'; Resource = 'branch'; Field = '1.parameters.strict_required_status_checks_policy'; Value = $false; Error = '*enforce strict checks*' }
        @{ Case = 'non-boolean creation policy'; Resource = 'branch'; Field = '1.parameters.do_not_enforce_on_create'; Value = 'false'; Error = '*enforce strict checks*' }
        @{ Case = 'a false-like numeric creation policy'; Resource = 'branch'; Field = '1.parameters.do_not_enforce_on_create'; Value = 0; Error = '*enforce strict checks*' }
        @{ Case = 'unenforced creation'; Resource = 'branch'; Field = '1.parameters.do_not_enforce_on_create'; Value = $true; Error = '*enforce strict checks*' }
        @{ Case = 'a string binding ruleset ID'; Resource = 'branch'; Field = '1.ruleset_id'; Value = '42'; Error = '*ruleset source*' }
        @{ Case = 'a zero binding ruleset ID'; Resource = 'branch'; Field = '1.ruleset_id'; Value = 0; Error = '*ruleset source*' }
        @{ Case = 'non-string binding source type'; Resource = 'branch'; Field = '1.ruleset_source_type'; Value = @('Repository'); Error = '*ruleset source*' }
        @{ Case = 'a case-folded binding source type'; Resource = 'branch'; Field = '1.ruleset_source_type'; Value = 'repository'; Error = '*ruleset source*' }
        @{ Case = 'non-string binding repository'; Resource = 'branch'; Field = '1.ruleset_source'; Value = @('upstream/platform'); Error = '*ruleset source*' }
        @{ Case = 'a different binding repository'; Resource = 'branch'; Field = '1.ruleset_source'; Value = 'other/platform'; Error = '*ruleset source*' }
        @{ Case = 'non-object ruleset detail'; Resource = 'detail'; Field = ''; Value = @(); Error = '*ruleset identity*' }
        @{ Case = 'a string detail ID'; Resource = 'detail'; Field = 'id'; Value = '42'; Error = '*ruleset identity*' }
        @{ Case = 'a different detail ID'; Resource = 'detail'; Field = 'id'; Value = 43; Error = '*ruleset identity*' }
        @{ Case = 'non-string ruleset target'; Resource = 'detail'; Field = 'target'; Value = @('branch'); Error = '*ruleset identity*' }
        @{ Case = 'a tag ruleset target'; Resource = 'detail'; Field = 'target'; Value = 'tag'; Error = '*ruleset identity*' }
        @{ Case = 'case-folded ruleset target'; Resource = 'detail'; Field = 'target'; Value = 'Branch'; Error = '*ruleset identity*' }
        @{ Case = 'non-string enforcement'; Resource = 'detail'; Field = 'enforcement'; Value = @('active'); Error = '*ruleset identity*' }
        @{ Case = 'evaluate-only enforcement'; Resource = 'detail'; Field = 'enforcement'; Value = 'evaluate'; Error = '*ruleset identity*' }
        @{ Case = 'case-folded enforcement'; Resource = 'detail'; Field = 'enforcement'; Value = 'Active'; Error = '*ruleset identity*' }
        @{ Case = 'non-string detail source type'; Resource = 'detail'; Field = 'source_type'; Value = @('Repository'); Error = '*ruleset identity*' }
        @{ Case = 'case-folded detail source type'; Resource = 'detail'; Field = 'source_type'; Value = 'repository'; Error = '*ruleset identity*' }
        @{ Case = 'non-string detail repository'; Resource = 'detail'; Field = 'source'; Value = @('upstream/platform'); Error = '*ruleset identity*' }
        @{ Case = 'a different detail repository'; Resource = 'detail'; Field = 'source'; Value = 'other/platform'; Error = '*ruleset identity*' }
        @{ Case = 'non-object conditions'; Resource = 'detail'; Field = 'conditions'; Value = @(); Error = '*exact-ref selector*' }
        @{ Case = 'non-object ref selector'; Resource = 'detail'; Field = 'conditions.ref_name'; Value = @(); Error = '*exact-ref selector*' }
        @{ Case = 'a scalar include selector'; Resource = 'detail'; Field = 'conditions.ref_name.include'; Value = 'refs/heads/source-publication/v1'; Error = '*only the exact*' }
        @{ Case = 'an empty include selector'; Resource = 'detail'; Field = 'conditions.ref_name.include'; Value = @(); Error = '*only the exact*' }
        @{ Case = 'non-string included ref'; Resource = 'detail'; Field = 'conditions.ref_name.include.0'; Value = @('refs/heads/source-publication/v1'); Error = '*only the exact*' }
        @{ Case = 'a wildcard publication selector'; Resource = 'detail'; Field = 'conditions.ref_name.include.0'; Value = 'refs/heads/source-publication/*'; Error = '*only the exact*' }
        @{ Case = 'a case-folded publication selector'; Resource = 'detail'; Field = 'conditions.ref_name.include.0'; Value = 'refs/heads/Source-publication/v1'; Error = '*only the exact*' }
        @{ Case = 'a non-array exclude selector'; Resource = 'detail'; Field = 'conditions.ref_name.exclude'; Value = @{}; Error = '*only the exact*' }
        @{ Case = 'a nonempty exclude selector'; Resource = 'detail'; Field = 'conditions.ref_name.exclude'; Value = @('refs/heads/source-publication/v1'); Error = '*only the exact*' }
        @{ Case = 'a changed detail App pin'; Resource = 'detail'; Field = 'rules.0.parameters.required_status_checks.0.integration_id'; Value = 2; Error = '*not bound*' }
        @{ Case = 'a malformed visible bypass list'; Resource = 'detail'; Field = 'bypass_actors'; Value = $null; Error = '*Malformed visible*bypass list*' }
        @{ Case = 'a non-object bypass actor'; Resource = 'detail'; Field = 'bypass_actors'; Value = @('bad'); Error = '*bypass actor type*' }
        @{ Case = 'an unknown bypass actor'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'Unknown' }); Error = '*bypass actor type*' }
        @{ Case = 'case-folded bypass actor type'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'integration'; actor_id = 2 }); Error = '*bypass actor type*' }
        @{ Case = 'non-string bypass actor type'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = @('Integration'); actor_id = 2 }); Error = '*bypass actor type*' }
        @{ Case = 'a string bypass actor ID'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'Integration'; actor_id = '2' }); Error = '*bypass actor ID*' }
        @{ Case = 'a null required actor ID'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'Integration'; actor_id = $null }); Error = '*bypass actor ID*' }
        @{ Case = 'a zero required actor ID'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'Integration'; actor_id = 0 }); Error = '*bypass actor ID*' }
        @{ Case = 'a malformed bypass mode'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'Team'; actor_id = 2; bypass_mode = 'unknown' }); Error = '*bypass mode*' }
        @{ Case = 'a case-folded bypass mode'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'Team'; actor_id = 2; bypass_mode = 'Always' }); Error = '*bypass mode*' }
        @{ Case = 'a non-string bypass mode'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'Team'; actor_id = 2; bypass_mode = @('always') }); Error = '*bypass mode*' }
        @{ Case = 'a known publisher bypass'; Resource = 'detail'; Field = 'bypass_actors'; Value = @(@{ actor_type = 'Integration'; actor_id = 1; bypass_mode = 'always' }); Error = '*known*bypass*' }
        @{ Case = 'a non-object check page'; Resource = 'checks'; Field = ''; Value = @(); Error = '*pagination response*' }
        @{ Case = 'a string total count'; Resource = 'checks'; Field = 'total_count'; Value = '1'; Error = '*pagination response*' }
        @{ Case = 'a negative total count'; Resource = 'checks'; Field = 'total_count'; Value = -1; Error = '*pagination response*' }
        @{ Case = 'a non-array check page'; Resource = 'checks'; Field = 'check_runs'; Value = @{}; Error = '*pagination response*' }
        @{ Case = 'excess check inventory'; Resource = 'checks'; Field = 'total_count'; Value = 0; Error = '*exceeds its declared inventory*' }
        @{ Case = 'a missing publication check'; Resource = 'checks'; Field = 'check_runs.0.name'; Value = 'different'; Error = '*Missing or ambiguous*witness*' }
        @{ Case = 'a wrong witness App'; Resource = 'checks'; Field = 'check_runs.0.app.id'; Value = 2; Error = '*Missing or ambiguous*witness*' }
        @{ Case = 'a non-object ref'; Resource = 'ref'; Field = ''; Value = @(); Error = '*source reference*' }
        @{ Case = 'a non-string ref name'; Resource = 'ref'; Field = 'ref'; Value = @('refs/heads/source-publication/v1'); Error = '*source reference*' }
        @{ Case = 'a wrong ref name'; Resource = 'ref'; Field = 'ref'; Value = 'refs/heads/main'; Error = '*source reference*' }
        @{ Case = 'a case-folded ref name'; Resource = 'ref'; Field = 'ref'; Value = 'refs/heads/Source-publication/v1'; Error = '*source reference*' }
        @{ Case = 'a non-object ref object'; Resource = 'ref'; Field = 'object'; Value = @(); Error = '*source reference*' }
        @{ Case = 'a non-string ref type'; Resource = 'ref'; Field = 'object.type'; Value = @('commit'); Error = '*source reference*' }
        @{ Case = 'a tag instead of commit ref'; Resource = 'ref'; Field = 'object.type'; Value = 'tag'; Error = '*source reference*' }
        @{ Case = 'a case-folded ref type'; Resource = 'ref'; Field = 'object.type'; Value = 'Commit'; Error = '*source reference*' }
        @{ Case = 'a non-string tip SHA'; Resource = 'ref'; Field = 'object.sha'; Value = @('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); Error = '*source reference*' }
        @{ Case = 'an invalid tip SHA'; Resource = 'ref'; Field = 'object.sha'; Value = 'invalid'; Error = '*source reference*' }
        @{ Case = 'an uppercase tip SHA'; Resource = 'ref'; Field = 'object.sha'; Value = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; Error = '*source reference*' }
        @{ Case = 'a non-object comparison'; Resource = 'comparison'; Field = ''; Value = @(); Error = '*not independently verified*' }
        @{ Case = 'a non-string comparison status'; Resource = 'comparison'; Field = 'status'; Value = @('identical'); Error = '*not independently verified*' }
        @{ Case = 'a diverged commit'; Resource = 'comparison'; Field = 'status'; Value = 'diverged'; Error = '*not independently verified*' }
        @{ Case = 'a case-folded comparison status'; Resource = 'comparison'; Field = 'status'; Value = 'Identical'; Error = '*not independently verified*' }
        @{ Case = 'a non-object merge base'; Resource = 'comparison'; Field = 'merge_base_commit'; Value = @(); Error = '*not independently verified*' }
        @{ Case = 'a non-string merge-base SHA'; Resource = 'comparison'; Field = 'merge_base_commit.sha'; Value = @('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); Error = '*not independently verified*' }
        @{ Case = 'a wrong merge-base SHA'; Resource = 'comparison'; Field = 'merge_base_commit.sha'; Value = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; Error = '*not independently verified*' }
        @{ Case = 'a case-folded merge-base SHA'; Resource = 'comparison'; Field = 'merge_base_commit.sha'; Value = 'replaced-by-case-folded-fixture-commit'; Error = '*not independently verified*' }
    ) {
        if ($Case -in @('a non-string tip SHA', 'a non-string merge-base SHA')) { $Value = @($commit) }
        if ($Case -eq 'a case-folded merge-base SHA') { $Value = $commit.ToUpperInvariant() }
        $route = @{
            branch = 'rules/branches/source-publication%2Fv1'; detail = 'rulesets/42'
            checks = "commits/$commit/check-runs?filter=all&per_page=100&page=1"
            ref = 'git/ref/heads/source-publication/v1'; comparison = "compare/$commit...${commit}?per_page=1"
        }[$Resource]
        if (-not $Field) { $documents[$route] = $Value }
        else {
            $segments = $Field.Split('.')
            $parent = $documents[$route]
            for ($i = 0; $i -lt $segments.Count - 1; $i++) {
                $key = if ($parent -is [Collections.IList]) { [int] $segments[$i] } else { $segments[$i] }
                $parent = $parent[$key]
            }
            $key = if ($parent -is [Collections.IList]) { [int] $segments[-1] } else { $segments[-1] }
            $parent[$key] = $Value
        }
        $negativeRead = $read
        if ($Resource -eq 'ref' -and $Field -ne 'ref') {
            # A separate, valid second response cannot mask a missing first-response guard.
            $validAfter = Get-GitHubApiFixture -Name git/get-ref -Set @{
                ref = 'refs/heads/source-publication/v1'; 'object.sha' = $commit
            }
            $state = @{ RefReads = 0 }
            $original = $read
            $negativeRead = {
                param($Route)
                if ($Route -ceq 'git/ref/heads/source-publication/v1') {
                    $state.RefReads++
                    if ($state.RefReads -eq 2) { return ,$validAfter }
                }
                return ,(& $original $Route)
            }.GetNewClosure()
        }
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $negativeRead } |
            Should -Throw $Error
    }

    It 'rejects admitted success at the consumer seam' {
        $payload = $check.output.summary | ConvertFrom-Json -AsHashtable
        $payload.phase = 'admitted'
        $check.output.summary = $payload | ConvertTo-Json -Compress
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read } |
            Should -Throw '*not published*'
    }

    It 'rejects ambiguous same-context checks instead of selecting the latest' {
        $duplicate = $check | ConvertTo-Json -Depth 30 | ConvertFrom-Json -AsHashtable
        $duplicate.id = 5
        $checks.check_runs = @($check, $duplicate)
        $checks.total_count = 2
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read } |
            Should -Throw '*ambiguous publication witness*'
    }

    It 'rejects duplicate active bindings rather than picking a ruleset by order' {
        $branchRules[1].parameters.required_status_checks += @($branchRules[1].parameters.required_status_checks[0])
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read } |
            Should -Throw '*ambiguous active publication App binding*'
    }

    It 'rejects a nonpositive publisher pin' {
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 0 -Read $read } |
            Should -Throw '*Invalid active publication binding rules*'
    }

    It 'rejects a malformed expected commit before API reads' {
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit 'not-a-commit' -PublisherAppId 1 -Read $read } |
            Should -Throw '*Invalid published source commit*'
        $reads.Count | Should -Be 0
    }

    It 'rejects case-folded expected commit identity before API reads' {
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit.ToUpperInvariant() -PublisherAppId 1 -Read $read } |
            Should -Throw '*Invalid published source commit*'
        $reads.Count | Should -Be 0
    }

    It 'rejects a known publisher bypass in mode <Mode>' -ForEach @(
        @{ Mode = 'always' }; @{ Mode = 'pull_request' }; @{ Mode = 'exempt' }
    ) {
        $example = Get-GitHubApiFixture -Name repos/get-repo-ruleset.bypass-visible -Set @{
            'bypass_actors.0.actor_type' = 'Integration'; 'bypass_actors.0.actor_id' = 1; 'bypass_actors.0.bypass_mode' = $Mode
        }
        $ruleset.bypass_actors = @($example.bypass_actors[0])
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read } |
            Should -Throw '*known publication ruleset bypass*'
    }

    It 'supports all documented unrelated bypass modes including <Mode>' -ForEach @(
        @{ Mode = 'always' }; @{ Mode = 'pull_request' }; @{ Mode = 'exempt' }
    ) {
        $example = Get-GitHubApiFixture -Name repos/get-repo-ruleset.bypass-visible -Set @{
            'bypass_actors.0.actor_type' = 'Team'; 'bypass_actors.0.actor_id' = 2; 'bypass_actors.0.bypass_mode' = $Mode
        }
        $ruleset.bypass_actors = @($example.bypass_actors[0])
        $evidence = Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read
        $evidence.NoBypassEvidence | Should -BeExactly 'publisher-attested'
    }

    It 'honors the documented omitted bypass_mode default for an unrelated actor' {
        $example = Get-GitHubApiFixture -Name repos/get-repo-ruleset.bypass-visible -Set @{
            'bypass_actors.0.actor_type' = 'Team'; 'bypass_actors.0.actor_id' = 2
        }
        $actor = $example.bypass_actors[0]
        $null = $actor.Remove('bypass_mode')
        $ruleset.bypass_actors = @($actor)
        $evidence = Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read
        $evidence.NoBypassEvidence | Should -BeExactly 'publisher-attested'
    }

    It 'rejects a changed or malformed second ref read: <Case>' -ForEach @(
        @{ Case = 'root array' }; @{ Case = 'ref array' }; @{ Case = 'different ref' }; @{ Case = 'case-folded ref' }
        @{ Case = 'object array' }; @{ Case = 'type array' }; @{ Case = 'different type' }
        @{ Case = 'sha array' }; @{ Case = 'different sha' }; @{ Case = 'case-folded sha' }
    ) {
        # Deliberately invalid second response, isolated from the primary first-response fixture.
        $after = $reference | ConvertTo-Json -Depth 20 | ConvertFrom-Json -AsHashtable
        switch ($Case) {
            'root array' { $after = @($after) }
            'ref array' { $after.ref = @($after.ref) }
            'different ref' { $after.ref = 'refs/heads/main' }
            'case-folded ref' { $after.ref = 'refs/heads/Source-publication/v1' }
            'object array' { $after.object = @($after.object) }
            'type array' { $after.object.type = @('commit') }
            'different type' { $after.object.type = 'Commit' }
            'sha array' { $after.object.sha = @($commit) }
            'different sha' { $after.object.sha = 'b' * 40 }
            'case-folded sha' { $after.object.sha = $commit.ToUpperInvariant() }
        }
        $state = @{ RefReads = 0 }
        $original = $read
        $secondRead = {
            param($Route)
            if ($Route -ceq 'git/ref/heads/source-publication/v1') {
                $state.RefReads++
                if ($state.RefReads -eq 2) { return ,$after }
            }
            return ,(& $original $Route)
        }.GetNewClosure()
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $secondRead } |
            Should -Throw '*reference changed during verification*'
    }

    It 'reads every check page with filter all and rejects no historical ambiguity by omission' {
        $page1 = [Collections.Generic.List[object]]::new()
        $page1.Add($check)
        foreach ($id in 1001..1099) {
            $page1.Add((Get-GitHubApiFixture -Name checks/create.completed -Set @{ id = $id; name = 'Other CI' }))
        }
        $checks.total_count = 101
        $checks.check_runs = @($page1)
        $documents["commits/$commit/check-runs?filter=all&per_page=100&page=2"] =
            Get-GitHubApiFixture -Name checks/list-for-ref -Set @{
                total_count = 101; check_runs = @((Get-GitHubApiFixture -Name checks/create.completed -Set @{ id = 2000; name = 'Other CI' }))
            }
        $evidence = Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read
        $evidence.CheckId | Should -Be 4
        $reads | Should -Contain "commits/$commit/check-runs?filter=all&per_page=100&page=2"
    }

    It 'rejects changed totals between check pages' {
        $checks.total_count = 2
        $documents["commits/$commit/check-runs?filter=all&per_page=100&page=2"] =
            Get-GitHubApiFixture -Name checks/list-for-ref -Set @{ total_count = 3; check_runs = @($check) }
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read } |
            Should -Throw '*inventory changed during pagination*'
    }

    It 'rejects an empty page before the declared inventory is complete' {
        $checks.check_runs = @()
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read } |
            Should -Throw '*Incomplete publication check pagination*'
    }

    It 'rejects duplicate check IDs across different pages' {
        $checks.total_count = 2
        $documents["commits/$commit/check-runs?filter=all&per_page=100&page=2"] =
            Get-GitHubApiFixture -Name checks/list-for-ref -Set @{ total_count = 2; check_runs = @($check) }
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read } |
            Should -Throw '*duplicate ID in publication check list*'
    }

    It 'rejects a page exceeding the declared per-page limit' {
        # Deliberately invalid response size; each member still has the documented check-run shape.
        $checks.check_runs = @(@($check) * 101)
        $checks.total_count = 101
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $read } |
            Should -Throw '*Invalid publication check pagination response*'
    }

    It 'stops after the explicit 100-page bound without accepting a partial inventory' {
        $original = $read
        $boundedRead = {
            param($Route)
            if ($Route -match '/check-runs\?filter=all&per_page=100&page=(\d+)$') {
                $page = [int] $Matches[1]
                $item = if ($page -eq 1) { $check } else {
                    Get-GitHubApiFixture -Name checks/create.completed -Set @{ id = (1000 + $page); name = 'Other CI' }
                }
                return Get-GitHubApiFixture -Name checks/list-for-ref -Set @{ total_count = 101; check_runs = @($item) }
            }
            return ,(& $original $Route)
        }.GetNewClosure()
        { Assert-PlatformPublishedSource -Repository upstream/platform -Commit $commit -PublisherAppId 1 -Read $boundedRead } |
            Should -Throw '*exceeds 100 pages*'
    }
}

Describe 'Platform release source policy' {
    BeforeEach {
        $source = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $source
    }

    It 'keeps a release without a declaration on the legacy main authority' {
        $policy = Get-PlatformReleaseSourcePolicy -SourcePath $source
        $policy.Line | Should -BeExactly 'main'
        $policy.Ref | Should -BeExactly 'refs/heads/main'
        $policy.PublisherAppId | Should -BeNullOrEmpty
    }

    It 'maps an authenticated version-one declaration to the fixed publication ref and App' {
        '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":7}' |
            Set-Content -LiteralPath (Join-Path $source 'release-source-policy.json')
        $policy = Get-PlatformReleaseSourcePolicy -SourcePath $source
        $policy.Line | Should -BeExactly 'ghe-publication'
        $policy.Ref | Should -BeExactly 'refs/heads/source-publication/v1'
        $policy.PublisherAppId | Should -Be 7
    }

    It 'accepts the explicit legacy declaration without a publisher pin' {
        '{"schemaVersion":1,"line":"main"}' |
            Set-Content -LiteralPath (Join-Path $source 'release-source-policy.json')
        $policy = Get-PlatformReleaseSourcePolicy -SourcePath $source
        $policy.Ref | Should -BeExactly 'refs/heads/main'
        $policy.PublisherAppId | Should -BeNullOrEmpty
    }

    It 'rejects <Case> rather than falling back to main' -ForEach @(
        @{ Case = 'malformed JSON'; Json = '{'; Error = '*declaration JSON*' }
        @{ Case = 'an array'; Json = '[{"schemaVersion":1,"line":"main"}]'; Error = '*must be an object*' }
        @{ Case = 'null'; Json = 'null'; Error = '*must be an object*' }
        @{ Case = 'a missing version'; Json = '{"line":"main"}'; Error = '*Missing*fields*' }
        @{ Case = 'a missing line'; Json = '{"schemaVersion":1}'; Error = '*Missing*fields*' }
        @{ Case = 'an unknown field'; Json = '{"schemaVersion":1,"line":"main","ref":"other"}'; Error = '*Invalid*fields*' }
        @{ Case = 'a case-folded field'; Json = '{"schemaVersion":1,"Line":"main"}'; Error = '*Invalid*fields*' }
        @{ Case = 'a repeated field'; Json = '{"schemaVersion":1,"line":"main","line":"main"}'; Error = '*Invalid*fields*' }
        @{ Case = 'a string version'; Json = '{"schemaVersion":"1","line":"main"}'; Error = '*schemaVersion*' }
        @{ Case = 'a decimal version'; Json = '{"schemaVersion":1.0,"line":"main"}'; Error = '*schemaVersion*' }
        @{ Case = 'an unknown version'; Json = '{"schemaVersion":2,"line":"main"}'; Error = '*schemaVersion*' }
        @{ Case = 'a non-string line'; Json = '{"schemaVersion":1,"line":1}'; Error = '*line type*' }
        @{ Case = 'a null line'; Json = '{"schemaVersion":1,"line":null}'; Error = '*line type*' }
        @{ Case = 'an unknown line'; Json = '{"schemaVersion":1,"line":"release-input"}'; Error = '*declaration line.*' }
        @{ Case = 'case-folded main'; Json = '{"schemaVersion":1,"line":"Main"}'; Error = '*declaration line.*' }
        @{ Case = 'case-folded publication'; Json = '{"schemaVersion":1,"line":"GHE-publication","publisherAppId":7}'; Error = '*declaration line.*' }
        @{ Case = 'an App pin on main'; Json = '{"schemaVersion":1,"line":"main","publisherAppId":7}'; Error = '*main*cannot pin*' }
        @{ Case = 'a missing App pin'; Json = '{"schemaVersion":1,"line":"ghe-publication"}'; Error = '*Missing*publisherAppId*' }
        @{ Case = 'a string App pin'; Json = '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":"7"}'; Error = '*Invalid*publisherAppId*' }
        @{ Case = 'a decimal App pin'; Json = '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":7.0}'; Error = '*Invalid*publisherAppId*' }
        @{ Case = 'an overflowing App pin'; Json = '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":9223372036854775808}'; Error = '*Invalid*publisherAppId*' }
        @{ Case = 'a zero App pin'; Json = '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":0}'; Error = '*Invalid*publisherAppId*' }
        @{ Case = 'a negative App pin'; Json = '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":-7}'; Error = '*Invalid*publisherAppId*' }
    ) {
        $Json | Set-Content -LiteralPath (Join-Path $source 'release-source-policy.json')
        { Get-PlatformReleaseSourcePolicy -SourcePath $source } | Should -Throw $Error
    }

    It 'rejects a file instead of the release directory' {
        $file = Join-Path $source 'not-a-directory'
        '' | Set-Content -LiteralPath $file
        { Get-PlatformReleaseSourcePolicy -SourcePath $file } | Should -Throw '*source must be a directory*'
    }

    It 'rejects a directory instead of the declaration file' {
        $null = New-Item -ItemType Directory -Path (Join-Path $source 'release-source-policy.json')
        { Get-PlatformReleaseSourcePolicy -SourcePath $source } | Should -Throw '*regular, exactly named file*'
    }

    It 'rejects a case-folded declaration on every filesystem' {
        '{}' | Set-Content -LiteralPath (Join-Path $source 'Release-source-policy.json')
        { Get-PlatformReleaseSourcePolicy -SourcePath $source } | Should -Throw '*regular, exactly named file*'
    }

    It 'rejects an ambiguous directory enumeration' {
        # Deliberately invalid filesystem response; Windows cannot create case-only duplicate names.
        Mock Get-ChildItem -ModuleName PublicationSource { @(
            [pscustomobject]@{ Name = 'release-source-policy.json' }
            [pscustomobject]@{ Name = 'Release-source-policy.json' }
        ) }
        { Get-PlatformReleaseSourcePolicy -SourcePath $source } | Should -Throw '*Ambiguous*declaration*'
    }

    It 'rejects a declaration reparse point without following it' {
        # Deliberately unsafe filesystem entry; no privileged symlink creation is needed.
        Mock Get-ChildItem -ModuleName PublicationSource {
            [pscustomobject]@{
                Name = 'release-source-policy.json'; PSIsContainer = $false
                Attributes = [IO.FileAttributes]::ReparsePoint
            }
        }
        { Get-PlatformReleaseSourcePolicy -SourcePath $source } | Should -Throw '*regular, exactly named file*'
    }
}
