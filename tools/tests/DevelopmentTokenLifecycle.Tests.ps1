BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../DevelopmentTokenLifecycle.psm1') -Force
}

Describe 'Recoverable development leaf token' {
    BeforeEach {
        $key = [Convert]::ToBase64String([byte[]] (1..32))
        $context = 'a' * 64
        $token = 'offline-only-known-installation-token'
    }

    It 'rejects a recovery <Case>' -ForEach @(
        @{ Case = 'different key'; KeyChange = 'other'; Expected = '*key does not match*' }
        @{ Case = 'different context'; ContextChange = 'b' * 64; Expected = '*context does not match*' }
        @{ Case = 'uppercase context'; ContextChange = 'A' * 64; Expected = '*canonical immutable context*' }
        @{ Case = 'short context'; ContextChange = 'abc'; Expected = '*canonical immutable context*' }
        @{ Case = 'short key'; KeyChange = 'short'; Expected = '*32-byte purpose-only*' }
        @{ Case = 'noncanonical key'; KeyChange = 'whitespace'; Expected = '*32-byte purpose-only*' }
    ) {
        $sealed = Protect-DevelopmentLeafToken -Token $token -RecoveryKey $key -ContextSha256 $context
        switch ($Case) {
            'different key' { $key = [Convert]::ToBase64String([byte[]] (2..33)) }
            'short key' { $key = [Convert]::ToBase64String([byte[]] (1..31)) }
            'noncanonical key' { $key += "`n" }
        }
        if ($Case -in @('different context', 'uppercase context', 'short context')) { $context = $ContextChange }
        { Unprotect-DevelopmentLeafToken -Envelope $sealed -RecoveryKey $key -ContextSha256 $context } | Should -Throw $Expected
    }

    It 'rejects <Case> token values without persisting or displaying them' -ForEach @(
        @{ Case = 'oversized'; Value = 'x' * 4097 }
        @{ Case = 'space'; Value = 'not a header token' }
        @{ Case = 'newline'; Value = "not-a-token`n" }
        @{ Case = 'non-ASCII'; Value = 'token' + [char] 0x7f }
    ) {
        { Protect-DevelopmentLeafToken -Token $Value -RecoveryKey $key -ContextSha256 $context } |
            Should -Throw '*bounded ASCII*'
    }

    It 'rejects encrypted token <Case>' -ForEach @(
        @{ Case = 'wrong version'; Field = 'version'; Value = 2; Expected = '*version*' }
        @{ Case = 'numeric context'; Field = 'contextSha256'; Value = 123; Expected = '*fields must be strings*' }
        @{ Case = 'different bound envelope context'; Field = 'contextSha256'; Value = 'b' * 64; Expected = '*context does not match*' }
        @{ Case = 'array key digest'; Field = 'keySha256'; Value = @('a'); Expected = '*fields must be strings*' }
        @{ Case = 'invalid key digest'; Field = 'keySha256'; Value = 'invalid'; Expected = '*key digest*' }
        @{ Case = 'uppercase key digest'; Field = 'keySha256'; Upper = $true; Expected = '*key digest*' }
        @{ Case = 'invalid token digest'; Field = 'tokenSha256'; Value = 'invalid'; Expected = '*token digest*' }
        @{ Case = 'uppercase token digest'; Field = 'tokenSha256'; Upper = $true; Expected = '*token digest*' }
        @{ Case = 'different valid token digest'; Field = 'tokenSha256'; Value = 'e' * 64; Expected = '*token digest does not match*' }
        @{ Case = 'short nonce'; Field = 'nonce'; Value = [Convert]::ToBase64String([byte[]] (1..11)); Expected = '*field lengths*' }
        @{ Case = 'long nonce'; Field = 'nonce'; Value = [Convert]::ToBase64String([byte[]] (1..13)); Expected = '*field lengths*' }
        @{ Case = 'short tag'; Field = 'tag'; Value = [Convert]::ToBase64String([byte[]] (1..15)); Expected = '*field lengths*' }
        @{ Case = 'long tag'; Field = 'tag'; Value = [Convert]::ToBase64String([byte[]] (1..17)); Expected = '*field lengths*' }
        @{ Case = 'empty ciphertext'; Field = 'ciphertext'; Value = ''; Expected = '*field lengths*' }
        @{ Case = 'large ciphertext'; Field = 'ciphertext'; Value = [Convert]::ToBase64String([byte[]]::new(4097)); Expected = '*field lengths*' }
        @{ Case = 'noncanonical nonce'; Field = 'nonce'; Whitespace = $true; Expected = '*canonical base64*' }
        @{ Case = 'noncanonical ciphertext'; Field = 'ciphertext'; Whitespace = $true; Expected = '*canonical base64*' }
        @{ Case = 'noncanonical tag'; Field = 'tag'; Whitespace = $true; Expected = '*canonical base64*' }
        @{ Case = 'altered nonce'; Field = 'nonce'; Value = [Convert]::ToBase64String([byte[]]::new(12)); Expected = '*' }
        @{ Case = 'altered ciphertext'; Field = 'ciphertext'; Value = [Convert]::ToBase64String([byte[]]::new(8)); Expected = '*' }
        @{ Case = 'altered tag'; Field = 'tag'; Value = [Convert]::ToBase64String([byte[]]::new(16)); Expected = '*' }
    ) {
        $parsedEnvelope = Protect-DevelopmentLeafToken -Token $token -RecoveryKey $key -ContextSha256 $context | ConvertFrom-Json -AsHashtable
        if ($Case -like 'uppercase*digest') { $parsedEnvelope[$Field] = $parsedEnvelope[$Field].ToUpperInvariant() }
        elseif ($Case -like 'noncanonical*') { $parsedEnvelope[$Field] += "`n" }
        else { $parsedEnvelope[$Field] = $Value }
        $sealed = ConvertTo-Json $parsedEnvelope -Compress
        { Unprotect-DevelopmentLeafToken -Envelope $sealed -RecoveryKey $key -ContextSha256 $context } | Should -Throw $Expected
    }

    It 'rejects malformed encrypted token document <Case>' -ForEach @(
        @{ Case = 'array' }; @{ Case = 'unknown field' }; @{ Case = 'missing field' }
        @{ Case = 'duplicate field' }; @{ Case = 'case changed field' }; @{ Case = 'oversized' }
    ) {
        $sealed = Protect-DevelopmentLeafToken -Token $token -RecoveryKey $key -ContextSha256 $context
        switch ($Case) {
            'array' { $sealed = "[$sealed]" }
            'unknown field' { $sealed = $sealed.Replace('"version":1', '"version":1,"extra":""') }
            'missing field' { $sealed = $sealed.Replace('"version":1,', '') }
            'duplicate field' { $sealed = $sealed.Replace('"version":1', '"version":1,"version":1') }
            'case changed field' { $sealed = $sealed.Replace('"version"', '"Version"') }
            'oversized' { $sealed += ' ' * 16385 }
        }
        { Unprotect-DevelopmentLeafToken -Envelope $sealed -RecoveryKey $key -ContextSha256 $context } | Should -Throw
    }

    Describe 'Protected development token journal' {
        BeforeEach {
            $contextValue = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/development-token-context.json') -Raw |
                ConvertFrom-Json -AsHashtable
            $key = [Convert]::ToBase64String([byte[]] (1..32))
            function New-TestJournalTrace {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Constructs only an in-memory offline journal trace.')]
                [CmdletBinding()]
                param()
                $canonical = New-DevelopmentTokenContext -Value $contextValue
                $pending = Add-DevelopmentTokenJournalEvent -Json (New-DevelopmentTokenJournal) -Event pending `
                    -Context $canonical -PreviousHead ('d' * 40)
                $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
                $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $sha
                $issued = Add-DevelopmentTokenJournalEvent -Json $pending -Event issued -Context $canonical -PreviousHead ('3' * 40) `
                    -Envelope $envelope -IssuanceProbeStatusCode 200
                $retired = Add-DevelopmentTokenJournalEvent -Json $issued -Event retired -Context $canonical -PreviousHead ('4' * 40) `
                    -RevokeStatusCode 204 -NegativeStatusCode 401 -RetirementRunId '999' -ProofKind revoked
                $already = Add-DevelopmentTokenJournalEvent -Json $issued -Event retired -Context $canonical -PreviousHead ('4' * 40) `
                    -NegativeStatusCode 401 -RetirementRunId '999' -ProofKind already-invalid -ActiveInstallationId '456'
                return @{ pending = $pending; issued = $issued; retired = $retired; already = $already }
            }
        }

        It 'persists pending, the encrypted exact leaf and proven retirement before allowing another candidate' {
            $context = New-DevelopmentTokenContext -Value $contextValue
            $journal = New-DevelopmentTokenJournal
            (Read-DevelopmentTokenJournal -Json $journal).Phase | Should -BeExactly 'clear'
            $journal = Add-DevelopmentTokenJournalEvent -Json $journal -Event pending -Context $context -PreviousHead ('d' * 40)
            (Read-DevelopmentTokenJournal -Json $journal).Phase | Should -BeExactly 'pending'
            $contextSha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($context))).ToLowerInvariant()
            $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $contextSha
            $journal = Add-DevelopmentTokenJournalEvent -Json $journal -Event issued -Context $context -PreviousHead ('3' * 40) `
                -Envelope $envelope -IssuanceProbeStatusCode 200
            $issued = Read-DevelopmentTokenJournal -Json $journal
            $issued.Phase | Should -BeExactly 'issued'
            Unprotect-DevelopmentLeafToken -Envelope $issued.Envelope -RecoveryKey $key -ContextSha256 $issued.ContextSha256 |
                Should -BeExactly 'offline-leaf'
            $journal | Should -Not -Match 'offline-leaf'
            $journal = Add-DevelopmentTokenJournalEvent -Json $journal -Event retired -Context $context -PreviousHead ('4' * 40) `
                -RevokeStatusCode 204 -NegativeStatusCode 401 -RetirementRunId '999' -ProofKind revoked
            (Read-DevelopmentTokenJournal -Json $journal).Phase | Should -BeExactly 'retired'
            $contextValue.runId = '1000'
            $nextContext = New-DevelopmentTokenContext -Value $contextValue
            $journal = Add-DevelopmentTokenJournalEvent -Json $journal -Event pending -Context $nextContext -PreviousHead ('5' * 40)
            $next = Read-DevelopmentTokenJournal -Json $journal
            $next.Phase | Should -BeExactly 'pending'
            $next.Records.Count | Should -Be 4
        }

        It 'rejects duplicate nested journal fields instead of normalizing a forged retirement' {
            $context = New-DevelopmentTokenContext -Value $contextValue
            $journal = Add-DevelopmentTokenJournalEvent -Json (New-DevelopmentTokenJournal) -Event pending `
                -Context $context -PreviousHead ('d' * 40)
            $journal = $journal.Replace('"event":"pending"', '"event":"issued","event":"pending"')
            { Read-DevelopmentTokenJournal -Json $journal } | Should -Throw '*duplicate*'
        }

        It 'records an already-invalid known leaf without claiming an unobserved revoke success' {
            $context = New-DevelopmentTokenContext -Value $contextValue
            $pending = Add-DevelopmentTokenJournalEvent -Json (New-DevelopmentTokenJournal) -Event pending `
                -Context $context -PreviousHead ('d' * 40)
            $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($context))).ToLowerInvariant()
            $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $sha
            $issued = Add-DevelopmentTokenJournalEvent -Json $pending -Event issued -Context $context -PreviousHead ('3' * 40) `
                -Envelope $envelope -IssuanceProbeStatusCode 200
            $retired = Add-DevelopmentTokenJournalEvent -Json $issued -Event retired -Context $context -PreviousHead ('4' * 40) `
                -ProofKind already-invalid -NegativeStatusCode 401 -ActiveInstallationId '456' -RetirementRunId '999'
            $known = Read-DevelopmentTokenJournal -Json $retired
            $known.Phase | Should -BeExactly 'retired'
            $known.Records[-1].proofKind | Should -BeExactly 'already-invalid'
            $known.Records[-1].revokeStatus | Should -Be 0
            $known.Records[-1].negativeStatus | Should -Be 401
            $known.Records[-1].activeInstallationId | Should -BeExactly '456'
        }

        It 'rejects context <Field> with invalid <Case>' -ForEach @(
            @{ Field = 'apiUrl'; Case = 'HTTP'; Value = 'http://api.example.test'; Expected = '*API origin*' }
            @{ Field = 'apiUrl'; Case = 'path'; Value = 'https://api.example.test/other'; Expected = '*API origin*' }
            @{ Field = 'apiUrl'; Case = 'uppercase origin'; Value = 'https://API.example.test'; Expected = '*API origin*' }
            @{ Field = 'repository'; Case = 'malformed'; Value = 'platform'; Expected = '*repository*' }
            @{ Field = 'referenceOwner'; Case = 'different'; Value = 'other'; Expected = '*non-reference*' }
            @{ Field = 'organization'; Case = 'reference authority'; Value = 'platform'; Expected = '*non-reference*' }
            @{ Field = 'organization'; Case = 'case alias'; Value = 'Platform'; Expected = "*'organization'*" }
            @{ Field = 'runAttempt'; Case = 'rerun'; Value = '2'; Expected = '*fresh run attempt 1*' }
            foreach ($field in @('appId', 'installationId', 'runId', 'publicKeyArtifactId')) {
                @{ Field = $field; Case = 'zero'; Value = '0'; Expected = "*'$field'*" }
                @{ Field = $field; Case = 'suffix'; Value = '123garbage'; Expected = "*'$field'*" }
            }
            foreach ($field in @('workflowRevision', 'baselineRevision', 'candidateRevision', 'authorizationRevision', 'authorizationBlob',
                'snapshotSha256', 'publicKeyArtifactDigest', 'publicKeySha256')) {
                @{ Field = $field; Case = 'uppercase'; Value = 'A' * $(if ($field -like '*Sha256' -or $field -ceq 'publicKeyArtifactDigest') { 64 } else { 40 }); Expected = "*'$field'*" }
                @{ Field = $field; Case = 'short'; Value = 'abc'; Expected = "*'$field'*" }
            }
            foreach ($field in @(
                'apiUrl', 'repository', 'referenceOwner', 'organization', 'appId', 'installationId', 'runId', 'runAttempt',
                'workflowRevision', 'baselineRevision', 'candidateRevision', 'authorizationRevision', 'authorizationBlob',
                'snapshotSha256', 'publicKeyArtifactId', 'publicKeyArtifactDigest', 'publicKeySha256'
            )) {
                @{ Field = $field; Case = 'non-string'; Value = @('array'); Expected = "*requires string '$field'*" }
            }
        ) {
            $contextValue[$Field] = $Value
            { New-DevelopmentTokenContext -Value $contextValue } | Should -Throw $Expected
        }

        It 'rejects an incomplete context rather than silently filling defaults' {
            $contextValue.Remove('appId')
            { New-DevelopmentTokenContext -Value $contextValue } | Should -Throw '*incomplete*'
        }

        It 'rejects an unknown context field rather than dropping it from the authorization digest' {
            $contextValue['other'] = 'unbound'
            { New-DevelopmentTokenContext -Value $contextValue } | Should -Throw '*unknown*'
        }

        It 'rejects malformed journal <Case>' -ForEach @(
            @{ Case = 'array'; Json = '[]'; Expected = '*must be an object*' }
            @{ Case = 'missing records'; Json = '{"version":1}'; Expected = '*incomplete*' }
            @{ Case = 'unknown root'; Json = '{"version":1,"records":[],"other":0}'; Expected = '*unknown*' }
            @{ Case = 'duplicate root'; Json = '{"version":1,"version":1,"records":[]}'; Expected = '*duplicate*' }
            @{ Case = 'case alias root'; Json = '{"Version":1,"records":[]}'; Expected = '*unknown*' }
            @{ Case = 'unsupported version'; Json = '{"version":2,"records":[]}'; Expected = '*schema*' }
            @{ Case = 'string version'; Json = '{"version":"1","records":[]}'; Expected = '*schema*' }
            @{ Case = 'scalar records'; Json = '{"version":1,"records":{}}'; Expected = '*schema*' }
            @{ Case = 'null records'; Json = '{"version":1,"records":null}'; Expected = '*schema*' }
            @{ Case = 'too many records'; Json = '{"version":1,"records":[' + (@('null') * 257 -join ',') + ']}'; Expected = '*record count*' }
            @{ Case = 'oversized'; Json = ' ' * 1048577; Expected = '*size bound*' }
            @{ Case = 'multibyte oversized'; Json = '{"version":1,"records":["' + (([string] [char] 0x010d) * 524289) + '"]}'; Expected = '*size bound*' }
        ) {
            { Read-DevelopmentTokenJournal -Json $Json } | Should -Throw $Expected
        }

        It 'refuses transition <Before> to <Event> without verified retirement' -ForEach @(
            @{ Before = 'clear'; Event = 'issued'; Expected = '*matching pending*' }
            @{ Before = 'clear'; Event = 'retired'; Expected = '*Retirement requires*' }
            @{ Before = 'pending'; Event = 'pending'; Expected = '*Unfinished*' }
            @{ Before = 'pending'; Event = 'retired'; Expected = '*Retirement requires*' }
            @{ Before = 'issued'; Event = 'pending'; Expected = '*Unfinished*' }
            @{ Before = 'issued'; Event = 'issued'; Expected = '*matching pending*' }
            @{ Before = 'retired'; Event = 'pending'; Expected = '*repeated issuance*' }
            @{ Before = 'retired'; Event = 'issued'; Expected = '*matching pending*' }
            @{ Before = 'retired'; Event = 'retired'; Expected = '*Retirement requires*' }
        ) {
            $context = New-DevelopmentTokenContext -Value $contextValue
            $journal = New-DevelopmentTokenJournal
            $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($context))).ToLowerInvariant()
            $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $sha
            if ($Before -cne 'clear') {
                $journal = Add-DevelopmentTokenJournalEvent -Json $journal -Event pending -Context $context -PreviousHead ('d' * 40)
            }
            if ($Before -cin @('issued', 'retired')) {
                $journal = Add-DevelopmentTokenJournalEvent -Json $journal -Event issued -Context $context -PreviousHead ('3' * 40) `
                    -Envelope $envelope -IssuanceProbeStatusCode 200
            }
            if ($Before -ceq 'retired') {
                $journal = Add-DevelopmentTokenJournalEvent -Json $journal -Event retired -Context $context -PreviousHead ('4' * 40) `
                    -RevokeStatusCode 204 -NegativeStatusCode 401 -RetirementRunId '999' -ProofKind revoked
            }
            { Add-DevelopmentTokenJournalEvent -Json $journal -Event $Event -Context $context -PreviousHead ('5' * 40) } |
                Should -Throw $Expected
        }

        # Each case changes one field of a valid protocol trace, not an API response.
        It 'rejects journal record <Phase> <Field> <Case>' -ForEach @(
            foreach ($field in @('event', 'context', 'previousHead', 'envelope', 'retirementRunId', 'proofKind', 'activeInstallationId')) {
                @{ Phase = 'pending'; Field = $field; Case = 'non-string'; Value = @('array'); Expected = "*requires string '$field'*" }
            }
            foreach ($field in @('revokeStatus', 'negativeStatus', 'issuanceProbeStatus')) {
                @{ Phase = 'pending'; Field = $field; Case = 'string'; Value = '0'; Expected = '*status types*' }
            }
            @{ Phase = 'pending'; Field = 'event'; Case = 'unknown'; Value = 'other'; Expected = '*Unknown*' }
            @{ Phase = 'pending'; Field = 'event'; Case = 'case alias'; Value = 'Pending'; Expected = '*Unknown*' }
            @{ Phase = 'pending'; Field = 'previousHead'; Case = 'short'; Value = 'abc'; Expected = '*journal parent*' }
            @{ Phase = 'pending'; Field = 'previousHead'; Case = 'uppercase'; Value = 'A' * 40; Expected = '*journal parent*' }
            @{ Phase = 'pending'; Field = 'envelope'; Case = 'unexpected'; Value = 'cipher'; Expected = '*Only issued records*' }
            @{ Phase = 'pending'; Field = 'issuanceProbeStatus'; Case = 'unexpected'; Value = 200; Expected = '*Only issued records*' }
            foreach ($field in @('revokeStatus', 'negativeStatus')) {
                @{ Phase = 'pending'; Field = $field; Case = 'unexpected evidence'; Value = 401; Expected = '*Only retired records*' }
            }
            foreach ($field in @('retirementRunId', 'proofKind', 'activeInstallationId')) {
                @{ Phase = 'pending'; Field = $field; Case = 'unexpected evidence'; Value = '999'; Expected = '*Only retired records*' }
            }
            @{ Phase = 'issued'; Field = 'issuanceProbeStatus'; Case = 'unproven'; Value = 0; Expected = '*observed GET*200*' }
            @{ Phase = 'retired'; Field = 'negativeStatus'; Case = 'successful authentication'; Value = 200; Expected = '*direct negative 401*' }
            @{ Phase = 'retired'; Field = 'retirementRunId'; Case = 'empty'; Value = ''; Expected = '*Retirement requires*' }
            @{ Phase = 'retired'; Field = 'retirementRunId'; Case = 'non-ID'; Value = '999bad'; Expected = '*Retirement requires*' }
            @{ Phase = 'retired'; Field = 'envelope'; Case = 'unexpected'; Value = 'cipher'; Expected = '*Only issued records*' }
            @{ Phase = 'retired'; Field = 'proofKind'; Case = 'unknown'; Value = 'ttl'; Expected = '*Unsupported*proof kind*' }
            @{ Phase = 'retired'; Field = 'proofKind'; Case = 'case alias'; Value = 'Revoked'; Expected = '*Unsupported*proof kind*' }
            @{ Phase = 'retired'; Field = 'revokeStatus'; Case = 'unknown'; Value = 0; Expected = '*observed DELETE 204*' }
            @{ Phase = 'retired'; Field = 'activeInstallationId'; Case = 'unrelated proof'; Value = '456'; Expected = '*observed DELETE 204*' }
            @{ Phase = 'already'; Field = 'revokeStatus'; Case = 'invented success'; Value = 204; Expected = '*unknown prior revoke outcome*' }
            @{ Phase = 'already'; Field = 'activeInstallationId'; Case = 'missing'; Value = ''; Expected = '*exact active installation*' }
            @{ Phase = 'already'; Field = 'activeInstallationId'; Case = 'wrong'; Value = '457'; Expected = '*exact active installation*' }
        ) {
            $trace = New-TestJournalTrace
            $journalDocument = ConvertFrom-Json -InputObject $trace[$Phase] -AsHashtable
            $journalDocument.records[-1][$Field] = $Value
            { Read-DevelopmentTokenJournal -Json (ConvertTo-Json $journalDocument -Depth 20 -Compress) } | Should -Throw $Expected
        }

        It 'rejects a changed immutable context at <Phase>' -ForEach @(
            @{ Phase = 'issued'; Expected = '*matching pending*' }
            @{ Phase = 'retired'; Expected = '*exact known issuance*' }
        ) {
            $trace = New-TestJournalTrace
            $value = ConvertFrom-Json -InputObject $trace[$Phase] -AsHashtable
            $contextValue.runId = '12345'
            $value.records[-1].context = New-DevelopmentTokenContext -Value $contextValue
            { Read-DevelopmentTokenJournal -Json (ConvertTo-Json $value -Depth 20 -Compress) } | Should -Throw $Expected
        }

        It 'rejects a noncanonical immutable journal context' {
            $value = ConvertFrom-Json -InputObject (New-TestJournalTrace).pending -AsHashtable
            $value.records[0].context += ' '
            { Read-DevelopmentTokenJournal -Json (ConvertTo-Json $value -Depth 20 -Compress) } | Should -Throw '*canonical immutable context*'
        }

        It 'rejects changed <Field> across finished cycles' -ForEach @(
            @{ Field = 'apiUrl'; Value = 'https://api.other.test' }
            @{ Field = 'repository'; Value = 'platform/other' }
        ) {
            $retired = (New-TestJournalTrace).retired
            $contextValue.runId = '12345'
            $contextValue[$Field] = $Value
            { Add-DevelopmentTokenJournalEvent -Json $retired -Event pending -Context (New-DevelopmentTokenContext -Value $contextValue) `
                -PreviousHead ('5' * 40) } | Should -Throw '*journal origin or repository changed*'
        }

        It 'accepts the exact JSON size bound and rejects a valid document one character above it' {
            $prefix = New-DevelopmentTokenJournal
            $boundary = $prefix + (' ' * (1048576 - $prefix.Length))
            (Read-DevelopmentTokenJournal -Json $boundary).Phase | Should -BeExactly 'clear'
            { Read-DevelopmentTokenJournal -Json ($boundary + ' ') } | Should -Throw '*size bound*'
        }

        It 'reads 256 valid records, rejects 257 and reserves complete retirement capacity before a new intent' {
            $trace = New-TestJournalTrace
            $templates = @(
                (ConvertFrom-Json $trace.pending -AsHashtable).records[0]
                (ConvertFrom-Json $trace.issued -AsHashtable).records[1]
                (ConvertFrom-Json $trace.retired -AsHashtable).records[2]
            )
            $records = [Collections.Generic.List[object]]::new()
            foreach ($cycle in 1..86) {
                $contextValue.runId = ([string] (1000 + $cycle))
                $canonical = New-DevelopmentTokenContext -Value $contextValue
                $sha = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($canonical))).ToLowerInvariant()
                foreach ($template in $templates) {
                    $record = ConvertFrom-Json (ConvertTo-Json $template -Compress) -AsHashtable
                    $record.context = $canonical
                    if ($record.event -ceq 'issued') {
                        $record.envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $sha
                    }
                    $records.Add($record)
                }
            }
            $retired = ConvertTo-Json -Depth 20 -Compress -InputObject @{ version = 1; records = @($records)[0..254] }
            (Read-DevelopmentTokenJournal -Json $retired).Phase | Should -BeExactly 'retired'
            {
                Add-DevelopmentTokenJournalEvent -Json $retired -Event pending -Context $canonical -PreviousHead ('5' * 40)
            } | Should -Throw '*capacity before mint*'
            $boundary = ConvertTo-Json -Depth 20 -Compress -InputObject @{ version = 1; records = @($records)[0..255] }
            (Read-DevelopmentTokenJournal -Json $boundary).Phase | Should -BeExactly 'pending'
            $oversized = ConvertTo-Json -Depth 20 -Compress -InputObject @{ version = 1; records = @($records)[0..256] }
            { Read-DevelopmentTokenJournal -Json $oversized } | Should -Throw '*record count*'
            $largeRecords = @($records)[0..164]
            $large = ConvertTo-Json -Depth 20 -Compress -InputObject @{ version = 1; records = $largeRecords }
            $remaining = 1044480 - $large.Length
            foreach ($record in $largeRecords | Where-Object event -CEQ issued) {
                $padding = [Math]::Min($remaining, 16384 - $record.envelope.Length)
                $record.envelope += ' ' * $padding
                $remaining -= $padding
            }
            $remaining | Should -Be 0
            $large = ConvertTo-Json -Depth 20 -Compress -InputObject @{ version = 1; records = $largeRecords }
            $large.Length | Should -Be 1044480
            (Read-DevelopmentTokenJournal -Json $large).Phase | Should -BeExactly 'retired'
            {
                Add-DevelopmentTokenJournalEvent -Json $large -Event pending -Context $canonical -PreviousHead ('5' * 40)
            } | Should -Throw '*capacity before mint*'
        }
    }

    It 'recovers the exact known leaf only with its purpose key and immutable context' {
        $sealed = Protect-DevelopmentLeafToken -Token $token -RecoveryKey $key -ContextSha256 $context
        $sealed | Should -Not -Match ([regex]::Escape($token))
        Unprotect-DevelopmentLeafToken -Envelope $sealed -RecoveryKey $key -ContextSha256 $context |
            Should -BeExactly $token
    }

    It 'round-trips the maximum 4096-byte ASCII leaf and the exact envelope size bound' {
        $sealed = Protect-DevelopmentLeafToken -Token ('x' * 4096) -RecoveryKey $key -ContextSha256 $context
        $boundary = $sealed + (' ' * (16384 - $sealed.Length))
        Unprotect-DevelopmentLeafToken -Envelope $boundary -RecoveryKey $key -ContextSha256 $context |
            Should -BeExactly ('x' * 4096)
        { Unprotect-DevelopmentLeafToken -Envelope ($boundary + ' ') -RecoveryKey $key -ContextSha256 $context } |
            Should -Throw '*size bound*'
    }
}
