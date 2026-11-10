BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../PublicationWitness.psm1') -Force

    function New-PublicationFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory API fixture only.')]
        [CmdletBinding()]
        param([string] $Phase = 'published', [string] $Fixture = 'checks/create.completed')
        $check = Get-GitHubApiFixture -Name $Fixture
        $digest = 'a' * 64
        $summary = [ordered]@{
            schemaVersion = 1
            kind = 'platform-source-publication'
            phase = $Phase
            ref = 'refs/heads/source-publication/v1'
            commit = $check.head_sha
            receiptSha256 = $digest
        }
        Get-GitHubApiFixture -Name $Fixture -Set @{
            name = 'GHE accepted source'
            status = 'completed'
            conclusion = 'success'
            external_id = "platform-source-publication/v1:$digest"
            'output.title' = 'GHE accepted source/v1'
            'output.summary' = ($summary | ConvertTo-Json -Compress)
        }
    }

    function New-PublicationCheckList {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory API fixture only.')]
        [CmdletBinding()]
        param([object[]] $Checks)
        Get-GitHubApiFixture -Name checks/list-for-ref -Set @{
            total_count = $Checks.Count
            check_runs = $Checks
        }
    }

    function New-PublicationReconciliation {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Builds an in-memory API fixture only.')]
        [CmdletBinding()]
        param([string] $Phase = 'published')
        $check = New-PublicationFixture -Phase $Phase
        @{
            CheckRuns = (New-PublicationCheckList -Checks @($check))
            CheckId = 4
            PublisherAppId = 1
            Commit = $check.head_sha
            ReceiptSha256 = 'a' * 64
            Reference = (Get-GitHubApiFixture -Name git/get-ref -Set @{
                ref = 'refs/heads/source-publication/v1'; 'object.sha' = $check.head_sha
            })
            RuleSuite = (Get-GitHubApiFixture -Name repos/get-repo-rule-suite.pass -Set @{
                ref = 'refs/heads/source-publication/v1'; after_sha = $check.head_sha
                'rule_evaluations.0.rule_type' = 'required_status_checks'
            })
            RuleSuiteId = 21
            RulesetId = 2
            RepositoryId = 404
            ActorId = 12
            BeforeCommit = '893f768e172fb1bc9c5d6f3dd48557e45f14e01d'
        }
    }
}

Describe 'Platform publication witness' {
    It 'rejects a generic successful App check without the closed publication payload' {
        $check = Get-GitHubApiFixture -Name checks/create.completed -Set @{
            name = 'GHE accepted source'; status = 'completed'; conclusion = 'success'
        }

        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha } |
            Should -Throw '*publication witness*'
    }

    It 'accepts a published witness with the documented <Fixture> owner variant' -ForEach @(
        @{ Fixture = 'checks/create.completed' }
        @{ Fixture = 'checks/create.owner-enterprise' }
    ) {
        $check = New-PublicationFixture -Fixture $Fixture
        $witness = Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha
        $witness.phase | Should -BeExactly 'published'
        $witness.receiptSha256 | Should -BeExactly ('a' * 64)
    }

    It 'rejects admitted success at the consumer boundary' {
        $check = New-PublicationFixture -Phase admitted
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha } |
            Should -Throw '*not published*'
    }

    It 'rejects a successful witness from another App' {
        $check = New-PublicationFixture
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 999 -Commit $check.head_sha } |
            Should -Throw '*publisher App*'
    }

    It 'rejects the documented nullable App variant as a publication witness' {
        $check = New-PublicationFixture -Fixture checks/create.app-null
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $check.head_sha } |
            Should -Throw '*publisher App*'
    }

    It 'rejects the wrong check envelope field <Field>' -ForEach @(
        @{ Field = 'id'; Value = 0 }
        @{ Field = 'name'; Value = 'ghe accepted source' }
        @{ Field = 'status'; Value = 'in_progress' }
        @{ Field = 'conclusion'; Value = 'neutral' }
        @{ Field = 'head_sha'; Value = ('b' * 40) }
    ) {
        $check = New-PublicationFixture
        $commit = $check.head_sha
        $check[$Field] = $Value
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $commit } |
            Should -Throw "*$Field*"
    }

    It 'rejects a non-closed witness payload: <Case>' -ForEach @(
        @{ Case = 'missing field' }
        @{ Case = 'additional field' }
        @{ Case = 'duplicate field' }
        @{ Case = 'case-variant field' }
    ) {
        $check = New-PublicationFixture
        $payload = $check.output.summary | ConvertFrom-Json -AsHashtable -NoEnumerate
        switch ($Case) {
            'missing field' { $payload.Remove('kind') }
            'additional field' { $payload['extra'] = $true }
            'case-variant field' { $payload.Remove('kind'); $payload['Kind'] = 'platform-source-publication' }
        }
        $check.output.summary = $payload | ConvertTo-Json -Compress
        if ($Case -eq 'duplicate field') {
            $check.output.summary = $check.output.summary.Replace('"kind":', '"kind":"platform-source-publication","kind":')
        }
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha } |
            Should -Throw '*payload fields*'
    }

    It 'allows the publisher to reconcile an admitted witness explicitly' {
        $check = New-PublicationFixture -Phase admitted
        $witness = Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha -AllowAdmission
        $witness.phase | Should -BeExactly 'admitted'
    }

    It 'rejects the wrong publication payload value <Field>' -ForEach @(
        @{ Field = 'schemaVersion'; Value = 2 }
        @{ Field = 'schemaVersion'; Value = '1' }
        @{ Field = 'kind'; Value = 'Platform-source-publication' }
        @{ Field = 'phase'; Value = 'queued' }
        @{ Field = 'ref'; Value = 'refs/heads/main' }
        @{ Field = 'commit'; Value = ('b' * 40) }
        @{ Field = 'receiptSha256'; Value = ('a' * 63) }
    ) {
        $check = New-PublicationFixture
        $payload = $check.output.summary | ConvertFrom-Json -AsHashtable -NoEnumerate
        $payload[$Field] = $Value
        $check.output.summary = $payload | ConvertTo-Json -Compress
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha -AllowAdmission } |
            Should -Throw "*$Field*"
    }

    It 'rejects a check external_id that does not bind the same receipt digest and version' {
        $check = New-PublicationFixture
        $check.external_id = 'platform-source-publication/v1:' + ('b' * 64)
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha } |
            Should -Throw '*external_id*'
    }

    It 'rejects an invalid publisher App numeric identity: <Case>' -ForEach @(
        @{ Case = 'string'; Value = '1'; Pin = 1 }
        @{ Case = 'boolean'; Value = $true; Pin = 1 }
        @{ Case = 'zero'; Value = 0; Pin = 0 }
        @{ Case = 'negative'; Value = -1; Pin = -1 }
    ) {
        $check = New-PublicationFixture
        # Deliberately invalid App identity in an otherwise valid API fixture.
        $check.app.id = $Value
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $Pin -Commit $check.head_sha } |
            Should -Throw '*publisher App*'
    }

    It 'rejects an invalid expected commit even when both check and payload repeat it' {
        $check = New-PublicationFixture
        $invalid = 'f' * 39
        $check.head_sha = $invalid
        $payload = $check.output.summary | ConvertFrom-Json -AsHashtable -NoEnumerate
        $payload.commit = $invalid
        $check.output.summary = $payload | ConvertTo-Json -Compress
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $invalid } |
            Should -Throw '*expected commit*'
    }

    It 'rejects a matching summary wrapped in a non-string API value' {
        $check = New-PublicationFixture
        # Deliberately invalid API shape; a one-item array must not coerce to JSON text.
        $check.output.summary = @($check.output.summary)
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha } |
            Should -Throw '*summary JSON*'
    }

    It 'rejects a matching external_id wrapped in a non-string API value' {
        $check = New-PublicationFixture
        # Deliberately invalid API shape; collection comparison must not hide the mismatch.
        $check.external_id = @($check.external_id)
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId $check.app.id -Commit $check.head_sha } |
            Should -Throw '*external_id*'
    }

    It 'rejects a case-folded external_id even when it names the same digest' {
        $check = New-PublicationFixture
        $check.external_id = $check.external_id.ToUpperInvariant()
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $check.head_sha } |
            Should -Throw '*external_id*'
    }

    It 'rejects a non-object API witness <Field>' -ForEach @(
        @{ Field = 'check' }; @{ Field = 'output' }
    ) {
        $check = New-PublicationFixture
        $commit = $check.head_sha
        # Deliberately invalid API shape: a one-item array is not its enclosed object.
        if ($Field -eq 'check') {
            $check = @($check)
            $message = '*publisher App*'
        }
        else {
            $check.output = @($check.output)
            $message = '*summary JSON type*'
        }
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $commit } |
            Should -Throw $message
    }

    It 'rejects a missing or array-valued check field <Field>/<Case>' -ForEach @(
        foreach ($field in @('id', 'name', 'status', 'conclusion', 'head_sha', 'external_id')) {
            @{ Field = $field; Case = 'missing' }
            @{ Field = $field; Case = 'matching array' }
        }
    ) {
        $check = New-PublicationFixture
        $commit = $check.head_sha
        # Deliberately invalid API shape, changing only one field.
        if ($Case -eq 'missing') { $check.Remove($Field) }
        else { $check[$Field] = @($check[$Field]) }
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $commit } |
            Should -Throw "*$Field*"
    }

    It 'rejects case-variant check envelope <Field>' -ForEach @(
        @{ Field = 'name' }; @{ Field = 'status' }; @{ Field = 'conclusion' }; @{ Field = 'head_sha' }
    ) {
        $check = New-PublicationFixture
        $commit = $check.head_sha
        $check[$Field] = $check[$Field].ToUpperInvariant()
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $commit } |
            Should -Throw "*$Field*"
    }

    It 'rejects a non-string closed payload field <Field>/<Case>' -ForEach @(
        foreach ($field in @('kind', 'phase', 'ref', 'commit', 'receiptSha256')) {
            @{ Field = $field; Case = 'null' }
            @{ Field = $field; Case = 'matching array' }
        }
    ) {
        $check = New-PublicationFixture
        $payload = $check.output.summary | ConvertFrom-Json -AsHashtable -NoEnumerate
        if ($Case -eq 'null') { $payload[$Field] = $null }
        else { $payload[$Field] = @($payload[$Field]) }
        $check.output.summary = $payload | ConvertTo-Json -Compress
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $check.head_sha -AllowAdmission } |
            Should -Throw "*$Field type*"
    }

    It 'rejects a case-variant closed payload value <Field>' -ForEach @(
        @{ Field = 'kind' }; @{ Field = 'phase' }; @{ Field = 'ref' }; @{ Field = 'commit' }; @{ Field = 'receiptSha256' }
    ) {
        $check = New-PublicationFixture
        $payload = $check.output.summary | ConvertFrom-Json -AsHashtable -NoEnumerate
        $payload[$Field] = $payload[$Field].ToUpperInvariant()
        $check.output.summary = $payload | ConvertTo-Json -Compress
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $check.head_sha -AllowAdmission } |
            Should -Throw "*$Field*"
    }

    It 'rejects a non-object JSON summary <Summary>' -ForEach @(
        @{ Summary = '[]' }; @{ Summary = '[{}]' }; @{ Summary = 'null' }; @{ Summary = '"published"' }
    ) {
        $check = New-PublicationFixture
        $check.output.summary = $Summary
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $check.head_sha } |
            Should -Throw '*must be an object*'
    }

    It 'rejects a malformed expected commit <Case>' -ForEach @(
        @{ Case = 'uppercase'; Value = ('F' * 40) }
        @{ Case = 'trailing newline'; Value = (('f' * 40) + "`n") }
    ) {
        $check = New-PublicationFixture
        { Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $Value } |
            Should -Throw '*expected commit*'
    }

    It 'accepts native integer and long API IDs without binding an owner shape' -ForEach @(
        @{ IdType = 'int' }; @{ IdType = 'long' }
    ) {
        $check = New-PublicationFixture
        if ($IdType -eq 'int') { $check.id = [int] 4; $check.app.id = [int] 1 }
        else { $check.id = [long] 4; $check.app.id = [long] 1 }
        (Assert-PlatformPublicationWitness -Check $check -PublisherAppId 1 -Commit $check.head_sha).phase |
            Should -BeExactly 'published'
    }
}

Describe 'Publication witness reconciliation' {
    It 'rejects a non-object check-list response before interpreting its fields' {
        $parameters = New-PublicationReconciliation
        # Deliberately invalid API shape; do not unwrap a one-item response array.
        $parameters.CheckRuns = @($parameters.CheckRuns)
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*check list object*'
    }

    It 'rejects a non-array check_runs field before interpreting its count' {
        $parameters = New-PublicationReconciliation
        # Deliberately invalid API shape; a check object is not a check array.
        $parameters.CheckRuns.check_runs = $parameters.CheckRuns.check_runs[0]
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*check list check_runs array*'
    }

    It 'rejects malformed unrelated check-list entries: <Case>' -ForEach @(
        @{ Case = 'non-object' }; @{ Case = 'string ID' }; @{ Case = 'boolean ID' }
        @{ Case = 'zero ID' }; @{ Case = 'negative ID' }
    ) {
        $parameters = New-PublicationReconciliation
        $other = New-PublicationFixture
        $other.name = 'Another CI check'
        # Deliberately invalid unrelated API entry; the complete list must remain well formed.
        switch ($Case) {
            'non-object' { $other = 'not a check object' }
            'string ID' { $other.id = '5' }
            'boolean ID' { $other.id = $true }
            'zero ID' { $other.id = 0 }
            'negative ID' { $other.id = -1 }
        }
        $parameters.CheckRuns = New-PublicationCheckList -Checks @($parameters.CheckRuns.check_runs[0], $other)
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*Invalid or duplicate ID in publication check list*'
    }

    It 'rejects a non-object reference <Field>' -ForEach @(
        @{ Field = 'reference' }; @{ Field = 'object' }
    ) {
        $parameters = New-PublicationReconciliation
        # Deliberately invalid API shape; the reference and its Git object are objects, not arrays.
        if ($Field -eq 'reference') { $parameters.Reference = @($parameters.Reference) }
        else { $parameters.Reference.object = @($parameters.Reference.object) }
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*publication reference shape*'
    }

    It 'rejects an array or case-variant exact-reference field <Field>/<Case>' -ForEach @(
        foreach ($field in @('ref', 'type', 'sha')) {
            @{ Field = $field; Case = 'array' }
            @{ Field = $field; Case = 'case variant' }
        }
    ) {
        $parameters = New-PublicationReconciliation
        # Deliberately invalid API field, keeping all other reference bindings intact.
        $target = if ($Field -eq 'ref') { $parameters.Reference } else { $parameters.Reference.object }
        if ($Case -eq 'array') { $target[$Field] = @($target[$Field]) }
        else { $target[$Field] = $target[$Field].ToUpperInvariant() }
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*publication reference*'
    }

    It 'rejects a non-object rule-suite response' {
        $parameters = New-PublicationReconciliation
        # Deliberately invalid API shape; the suite is not an array of suites.
        $parameters.RuleSuite = @($parameters.RuleSuite)
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*publication rule suite shape*'
    }

    It 'rejects a non-array evaluation catalogue' {
        $parameters = New-PublicationReconciliation
        # Deliberately invalid API shape with one otherwise valid required-check evaluation.
        $parameters.RuleSuite.rule_evaluations = $parameters.RuleSuite.rule_evaluations[0]
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*rule suite evaluations*'
    }

    It 'rejects a non-object rule evaluation' {
        $parameters = New-PublicationReconciliation
        # Deliberately invalid API entry among otherwise valid evaluations.
        $parameters.RuleSuite.rule_evaluations[1] = 'not an evaluation object'
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*evaluation shape*'
    }

    It 'rejects a matching array-valued evaluation <Field>' -ForEach @(
        @{ Field = 'enforcement' }; @{ Field = 'result' }
    ) {
        $parameters = New-PublicationReconciliation
        # Deliberately invalid API field; PowerShell collection comparison must not coerce it.
        $evaluation = $parameters.RuleSuite.rule_evaluations[0]
        $evaluation[$Field] = @($evaluation[$Field])
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw "*evaluation $Field*"
    }

    It 'rejects an invalid non-active evaluation field <Field>/<Value>' -ForEach @(
        @{ Field = 'enforcement'; Value = 'EVALUATE' }
        @{ Field = 'enforcement'; Value = 'DELETED RULESET' }
        @{ Field = 'result'; Value = 'PASS' }
        @{ Field = 'result'; Value = 'bypass' }
    ) {
        $parameters = New-PublicationReconciliation
        $evaluation = $parameters.RuleSuite.rule_evaluations[2]
        $evaluation.enforcement = 'evaluate'
        # Deliberately invalid non-active evaluation, without disturbing the valid required check.
        $evaluation[$Field] = $Value
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw "*evaluation $Field*"
    }

    It 'rejects a nonpositive persisted and matching observed operation ID <Field>/<Value>' -ForEach @(
        foreach ($field in @('RuleSuiteId', 'ActorId', 'RepositoryId')) {
            @{ Field = $field; Value = 0 }
            @{ Field = $field; Value = -1 }
        }
    ) {
        $parameters = New-PublicationReconciliation
        $parameters[$Field] = $Value
        $responseField = @{ RuleSuiteId = 'id'; ActorId = 'actor_id'; RepositoryId = 'repository_id' }[$Field]
        # Deliberately invalid API identity, matching the invalid pin to isolate positivity.
        $parameters.RuleSuite[$responseField] = $Value
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw "*rule suite $responseField*"
    }

    It 'rejects an uppercase persisted before-commit even when the suite repeats it' {
        $parameters = New-PublicationReconciliation
        $parameters.BeforeCommit = $parameters.BeforeCommit.ToUpperInvariant()
        $parameters.RuleSuite.before_sha = $parameters.BeforeCommit
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*expected before commit*'
    }

    It 'rejects ambiguous same-context App checks rather than choosing the latest' {
        $check = New-PublicationFixture
        $duplicate = New-PublicationFixture
        $duplicate.id = 5
        $runs = New-PublicationCheckList -Checks @($check, $duplicate)
        {
            Resolve-PlatformPublicationWitness -CheckRuns $runs -CheckId $check.id -PublisherAppId $check.app.id `
                -Commit $check.head_sha -ReceiptSha256 ('a' * 64)
        } | Should -Throw '*ambiguous*'
    }

    It 'retains a published phase without claiming completion from incomplete readback' {
        $check = New-PublicationFixture
        $runs = New-PublicationCheckList -Checks @($check)
        $result = Resolve-PlatformPublicationWitness -CheckRuns $runs -CheckId $check.id -PublisherAppId $check.app.id `
            -Commit $check.head_sha -ReceiptSha256 ('a' * 64)
        $result.Phase | Should -BeExactly 'published'
        $result.Disposition | Should -BeExactly 'unverified'
        $result.CheckId | Should -Be 4
    }

    It 'rejects reconciliation with another pinned <Field>' -ForEach @(
        @{ Field = 'CheckId'; Value = 99; Error = 'check ID' }
        @{ Field = 'ReceiptSha256'; Value = ('b' * 64); Error = 'receipt' }
    ) {
        $check = New-PublicationFixture
        $parameters = @{
            CheckRuns = (New-PublicationCheckList -Checks @($check))
            CheckId = $check.id
            PublisherAppId = $check.app.id
            Commit = $check.head_sha
            ReceiptSha256 = 'a' * 64
        }
        $parameters[$Field] = $Value
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw "*$Error*"
    }

    It 'rejects incomplete or malformed check-list readback: <Case>' -ForEach @(
        @{ Case = 'incomplete count' }
        @{ Case = 'boolean count' }
        @{ Case = 'non-list checks' }
        @{ Case = 'duplicate IDs' }
    ) {
        $check = New-PublicationFixture
        $runs = New-PublicationCheckList -Checks @($check)
        # Deliberately incomplete or invalid list response; unrelated check IDs must also be unique.
        switch ($Case) {
            'incomplete count' { $runs.total_count = 2 }
            'boolean count' { $runs.total_count = $true }
            'non-list checks' { $runs.check_runs = $check }
            'duplicate IDs' {
                $other = New-PublicationFixture
                $other.name = 'Another CI check'
                $runs = New-PublicationCheckList -Checks @($check, $other)
            }
        }
        {
            Resolve-PlatformPublicationWitness -CheckRuns $runs -CheckId $check.id -PublisherAppId $check.app.id `
                -Commit $check.head_sha -ReceiptSha256 ('a' * 64)
        } | Should -Throw '*check list*'
    }

    It 'rejects a mismatched exact publication reference <Field>' -ForEach @(
        @{ Field = 'ref'; Value = 'refs/heads/main' }
        @{ Field = 'object.type'; Value = 'tag' }
        @{ Field = 'object.sha'; Value = ('b' * 40) }
    ) {
        $check = New-PublicationFixture
        $reference = Get-GitHubApiFixture -Name git/get-ref -Set @{
            ref = 'refs/heads/source-publication/v1'; 'object.sha' = $check.head_sha
        }
        if ($Field -eq 'ref') { $reference.ref = $Value }
        elseif ($Field -eq 'object.type') { $reference.object.type = $Value }
        else { $reference.object.sha = $Value }
        {
            Resolve-PlatformPublicationWitness -CheckRuns (New-PublicationCheckList -Checks @($check)) `
                -CheckId $check.id -PublisherAppId $check.app.id -Commit $check.head_sha `
                -ReceiptSha256 ('a' * 64) -Reference $reference
        } | Should -Throw '*publication reference*'
    }

    It 'does not finalize admitted success from an exact ref alone after a lost push response' {
        $check = New-PublicationFixture -Phase admitted
        $reference = Get-GitHubApiFixture -Name git/get-ref -Set @{
            ref = 'refs/heads/source-publication/v1'; 'object.sha' = $check.head_sha
        }
        $result = Resolve-PlatformPublicationWitness -CheckRuns (New-PublicationCheckList -Checks @($check)) `
            -CheckId $check.id -PublisherAppId $check.app.id -Commit $check.head_sha `
            -ReceiptSha256 ('a' * 64) -Reference $reference
        $result.Phase | Should -BeExactly 'admitted'
        $result.Disposition | Should -BeExactly 'unverified'
        $result.Requires | Should -BeExactly 'rule-suite'
    }

    It 'does not treat <Case> metadata as a protected check binding for <Phase>' -Tag ProtectedCheckBinding -ForEach @(
        foreach ($phase in @('admitted', 'published')) {
            @{ Phase = $phase; Case = 'absent' }
            @{ Phase = $phase; Case = 'null' }
        }
    ) {
        $parameters = New-PublicationReconciliation -Phase $Phase
        $evaluation = $parameters.RuleSuite.rule_evaluations[0]
        if ($Case -eq 'absent') { $null = $evaluation.Remove('metadata') }
        else { $evaluation.metadata = $null }
        $result = Resolve-PlatformPublicationWitness @parameters
        $result.Phase | Should -BeExactly $Phase
        $result.Disposition | Should -BeExactly 'unverified'
        $result.Requires | Should -BeExactly 'protected-check-binding'
    }

    It 'does not infer protected binding for <Phase> from <Case> in illustrative schema-ambiguous metadata' -Tag ProtectedCheckBinding -ForEach @(
        foreach ($phase in @('admitted', 'published')) {
            @{ Phase = $phase; Case = 'opaque status-check ID' }
            @{ Phase = $phase; Case = 'an apparent check-run ID match' }
            @{ Phase = $phase; Case = 'a changed App and context under the same ruleset ID' }
        }
    ) {
        $parameters = New-PublicationReconciliation -Phase $Phase
        $parameters.RuleSuite = Get-GitHubApiFixture -Name repos/get-repo-rule-suite.opaque-metadata -Set @{
            ref = 'refs/heads/source-publication/v1'
            after_sha = $parameters.Commit
            'rule_evaluations.0.rule_source.id' = $parameters.RulesetId
            'rule_evaluations.0.metadata.checks.0.context' = 'GHE accepted source'
            'rule_evaluations.0.metadata.checks.0.app.id' = $parameters.PublisherAppId
        }
        $metadataCheck = $parameters.RuleSuite.rule_evaluations[0].metadata.checks[0]
        if ($Case -eq 'an apparent check-run ID match') { $metadataCheck.id = $parameters.CheckId }
        if ($Case -eq 'a changed App and context under the same ruleset ID') {
            $metadataCheck.app.id = 999
            $metadataCheck.context = 'Other check'
        }
        $result = Resolve-PlatformPublicationWitness @parameters
        $result.Phase | Should -BeExactly $Phase
        $result.Disposition | Should -BeExactly 'unverified'
        $result.Requires | Should -BeExactly 'protected-check-binding'
    }

    It 'keeps exact pass readbacks unverified without changing the <Phase> phase' -ForEach @(
        @{ Phase = 'admitted' }
        @{ Phase = 'published' }
    ) {
        $parameters = New-PublicationReconciliation -Phase $Phase
        $result = Resolve-PlatformPublicationWitness @parameters
        $result.Phase | Should -BeExactly $Phase
        $result.Disposition | Should -BeExactly 'unverified'
        $result.Requires | Should -BeExactly 'protected-check-binding'
        $result.CheckId | Should -Be 4
    }

    It 'rejects a rule suite from another operation or result: <Field>' -ForEach @(
        @{ Field = 'id'; Value = 22 }
        @{ Field = 'actor_id'; Value = 1 }
        @{ Field = 'repository_id'; Value = 405 }
        @{ Field = 'before_sha'; Value = ('b' * 40) }
        @{ Field = 'after_sha'; Value = ('b' * 40) }
        @{ Field = 'ref'; Value = 'refs/heads/main' }
        @{ Field = 'result'; Value = 'bypass' }
        @{ Field = 'evaluation_result'; Value = 'unknown' }
    ) {
        $parameters = New-PublicationReconciliation
        $parameters.RuleSuite[$Field] = $Value
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw "*rule suite $Field*"
    }

    It 'rejects an unproved active publication-check evaluation: <Case>' -ForEach @(
        @{ Case = 'active failure'; Error = 'active evaluation' }
        @{ Case = 'missing evaluations'; Error = 'evaluations' }
        @{ Case = 'evaluate-only required check'; Error = 'active publication check' }
        @{ Case = 'deleted required ruleset'; Error = 'active publication check' }
        @{ Case = 'another ruleset'; Error = 'active publication check' }
        @{ Case = 'another rule source'; Error = 'active publication check' }
        @{ Case = 'another rule type'; Error = 'active publication check' }
        @{ Case = 'unknown enforcement'; Error = 'enforcement' }
    ) {
        $parameters = New-PublicationReconciliation
        $evaluation = $parameters.RuleSuite.rule_evaluations[0]
        switch ($Case) {
            'active failure' { $evaluation.result = 'fail' }
            'missing evaluations' { $parameters.RuleSuite.rule_evaluations = @() }
            'evaluate-only required check' { $evaluation.enforcement = 'evaluate' }
            'deleted required ruleset' { $evaluation.enforcement = 'deleted ruleset' }
            'another ruleset' { $evaluation.rule_source.id = 3 }
            'another rule source' { $evaluation.rule_source.type = 'protected_branch' }
            'another rule type' { $evaluation.rule_type = 'pull_request' }
            'unknown enforcement' { $evaluation.enforcement = 'monitor' }
        }
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw "*$Error*"
    }

    It 'rejects an invalid persisted before-commit even when the suite repeats it' {
        $parameters = New-PublicationReconciliation
        $parameters.BeforeCommit = 'not-a-sha'
        $parameters.RuleSuite.before_sha = 'not-a-sha'
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*expected before commit*'
    }

    It 'rejects the isolated nested evaluation guard <Case>' -Tag PublicationEvaluationGuards -ForEach @(
        @{ Case = 'string source ID' }
        @{ Case = 'case-folded source type' }
        @{ Case = 'case-folded rule type' }
    ) {
        $parameters = New-PublicationReconciliation
        $evaluation = $parameters.RuleSuite.rule_evaluations[0]
        # Deliberately invalidate one nested binding field while preserving the other operation evidence.
        switch ($Case) {
            'string source ID' { $evaluation.rule_source.id = [string] $parameters.RulesetId }
            'case-folded source type' { $evaluation.rule_source.type = 'RULESET' }
            'case-folded rule type' { $evaluation.rule_type = 'Required_status_checks' }
        }
        { Resolve-PlatformPublicationWitness @parameters } |
            Should -Throw 'Missing or ambiguous active publication check rule evaluation.'
    }

    It 'rejects case-variant persisted receipt binding' {
        $parameters = New-PublicationReconciliation
        $parameters.ReceiptSha256 = 'A' * 64
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*receipt*'
    }

    It 'rejects a missing or wrong-type rule-suite binding field <Field>/<Case>' -ForEach @(
        foreach ($field in @('id', 'actor_id', 'repository_id', 'before_sha', 'after_sha', 'ref', 'result')) {
            @{ Field = $field; Case = 'missing' }
            @{ Field = $field; Case = 'matching array' }
        }
    ) {
        $parameters = New-PublicationReconciliation
        # Deliberately incomplete API shape; optional schema fields are required by this control.
        if ($Case -eq 'missing') { $parameters.RuleSuite.Remove($Field) }
        else { $parameters.RuleSuite[$Field] = @($parameters.RuleSuite[$Field]) }
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw "*rule suite $Field*"
    }

    It 'rejects case-variant rule-suite field <Field>' -ForEach @(
        @{ Field = 'before_sha' }; @{ Field = 'after_sha' }; @{ Field = 'ref' }
        @{ Field = 'result' }; @{ Field = 'evaluation_result' }
    ) {
        $parameters = New-PublicationReconciliation
        $parameters.RuleSuite[$Field] = $parameters.RuleSuite[$Field].ToUpperInvariant()
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw "*rule suite $Field*"
    }

    It 'rejects unpinned rule-suite operation identity <Field>' -ForEach @(
        @{ Field = 'RuleSuiteId' }; @{ Field = 'ActorId' }; @{ Field = 'RepositoryId' }
    ) {
        $parameters = New-PublicationReconciliation
        $parameters[$Field] = 0
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*rule suite*'
    }

    It 'rejects a duplicate active publication-check evaluation' {
        $parameters = New-PublicationReconciliation
        $other = New-PublicationReconciliation
        $parameters.RuleSuite.rule_evaluations += $other.RuleSuite.rule_evaluations[0]
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*ambiguous active publication check*'
    }

    It 'rejects failure of an unrelated active protected-branch rule' {
        $parameters = New-PublicationReconciliation
        $parameters.RuleSuite.rule_evaluations[1].result = 'fail'
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*active evaluation*'
    }

    It 'accepts documented evaluate and deleted-ruleset failures only when the active required check passes' -ForEach @(
        @{ Enforcement = 'evaluate' }; @{ Enforcement = 'deleted ruleset' }
    ) {
        $parameters = New-PublicationReconciliation
        $parameters.RuleSuite.rule_evaluations[2].enforcement = $Enforcement
        (Resolve-PlatformPublicationWitness @parameters).Disposition | Should -BeExactly 'unverified'
    }

    It 'accepts the documented null evaluation result when only active rules ran' -Tag RuleSuiteEvaluation {
        $parameters = New-PublicationReconciliation
        $parameters.RuleSuite = Get-GitHubApiFixture -Name repos/get-repo-rule-suite.pass-no-evaluate -Set @{
            ref = 'refs/heads/source-publication/v1'
            after_sha = $parameters.Commit
            'rule_evaluations.0.rule_type' = 'required_status_checks'
            'rule_evaluations.0.rule_source.id' = $parameters.RulesetId
        }
        (Resolve-PlatformPublicationWitness @parameters).Disposition | Should -BeExactly 'unverified'
    }

    It 'does not confuse documented evaluation-only <Value> with an active-rule bypass' -Tag RuleSuiteEvaluation -ForEach @(
        @{ Value = 'pass' }; @{ Value = 'fail' }; @{ Value = 'bypass' }
    ) {
        $parameters = New-PublicationReconciliation
        $parameters.RuleSuite.evaluation_result = $Value
        if ($Value -eq 'pass') { $parameters.RuleSuite.rule_evaluations[2].result = 'pass' }
        (Resolve-PlatformPublicationWitness @parameters).Disposition | Should -BeExactly 'unverified'
    }

    It 'accepts an omitted optional evaluation result without weakening active-rule proof' -Tag RuleSuiteEvaluation {
        $parameters = New-PublicationReconciliation
        $null = $parameters.RuleSuite.Remove('evaluation_result')
        (Resolve-PlatformPublicationWitness @parameters).Disposition | Should -BeExactly 'unverified'
    }

    It 'rejects malformed optional evaluation result <Case>' -ForEach @(
        @{ Case = 'number'; Value = 0 }
        @{ Case = 'array'; Value = @('fail') }
        @{ Case = 'unknown'; Value = 'unknown' }
        @{ Case = 'case-folded enum'; Value = 'Fail' }
    ) {
        $parameters = New-PublicationReconciliation
        $parameters.RuleSuite.evaluation_result = $Value
        { Resolve-PlatformPublicationWitness @parameters } | Should -Throw '*rule suite evaluation_result*'
    }

    It 'keeps reconciliation monotonic and idempotent across lost responses at <Boundary>' -ForEach @(
        @{ Boundary = 'check admission'; Phase = 'admitted'; Reference = $false; Suite = $false; Expected = 'unverified' }
        @{ Boundary = 'reference write'; Phase = 'admitted'; Reference = $true; Suite = $false; Expected = 'unverified' }
        @{ Boundary = 'suite readback'; Phase = 'admitted'; Reference = $true; Suite = $true; Expected = 'unverified' }
        @{ Boundary = 'final check update'; Phase = 'published'; Reference = $true; Suite = $true; Expected = 'unverified' }
    ) {
        $parameters = New-PublicationReconciliation -Phase $Phase
        if (-not $Reference) { $parameters.Reference = $null }
        if (-not $Suite) { $parameters.RuleSuite = $null }
        $before = $parameters | ConvertTo-Json -Depth 30 -Compress
        $first = Resolve-PlatformPublicationWitness @parameters
        $second = Resolve-PlatformPublicationWitness @parameters
        $first.Phase | Should -BeExactly $Phase
        $first.CheckId | Should -Be 4
        $first.Disposition | Should -BeExactly $Expected
        $second.Phase | Should -BeExactly $Phase
        $second.Disposition | Should -BeExactly $Expected
        ($parameters | ConvertTo-Json -Depth 30 -Compress) | Should -BeExactly $before
    }
}
