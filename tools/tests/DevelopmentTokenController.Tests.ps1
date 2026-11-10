BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../DevelopmentTokenLifecycle.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../DevelopmentControl.psm1') -Force
}

Describe 'Protected development token controller' {
    BeforeEach {
        $key = [Convert]::ToBase64String([byte[]] (1..32))
        $document = '{"version":2,"reference":"https://example.test/platform/instance","source":"https://github.com/example/platform","approval":"immutable approval","disposition":""}'
        $controlFile = Get-GitHubApiFixture -Name repos/get-content.file -Set @{
            name = 'development-control.json'; path = 'development-control.json'; sha = 'e' * 40
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes($document)
        $controlFile.content = [Convert]::ToBase64String($bytes)
        $controlFile.size = $bytes.Length
        $initialTree = Get-GitHubApiFixture -Name git/get-tree -Set @{
            sha = 'a' * 40; 'tree.0.path' = 'development-control.json'; 'tree.0.sha' = $controlFile.sha
        }
        $journalEntry = Get-GitHubApiFixture -Name git/get-tree -Set @{
            'tree.0.path' = 'development-token-journal.json'; 'tree.0.sha' = 'f' * 40
        }
        $initialTree.tree += $journalEntry.tree[0]
        $parent = Get-GitHubApiFixture -Name git/get-commit -Set @{
            sha = 'c' * 40; 'tree.sha' = 'a' * 40
        }
        $server = @{
            Head = 'c' * 40; Sequence = 0; Trees = @{ ('a' * 40) = $initialTree }
            Commits = @{ ('c' * 40) = $parent }
            Journals = @{ ('a' * 40) = '{"version":1,"records":[]}' }
            Requests = [Collections.Generic.List[object]]::new()
            Changes = [Collections.Generic.List[object]]::new()
            Fault = ''; Corrupt = ''; LeafStatus = 200; RevokeFault = ''; RevokeCount = 0; InstallationStatus = 200
            RevokeStatus = 204; AfterRevokeStatus = 401
            HttpKind = ''; HttpStatus = 0; ForeignAt = ''
            ReplyKind = ''; ReplyField = ''; ReplyMode = ''; ReplyValue = $null
        }
        $installation = Get-GitHubApiFixture -Name apps/get-installation -Set @{
            id = 456; app_id = 123; 'account.login' = 'workloads'; 'account.type' = 'Organization'
        }
        $rules = Get-GitHubApiFixture -Name repos/get-branch-rules -Set @{
            '0.type' = 'update'; '0.ruleset_id' = 42; '1.type' = 'deletion'; '1.ruleset_id' = 42
        }
        $ruleset = Get-GitHubApiFixture -Name repos/get-repo-ruleset.control
        $contextValue = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/development-token-context.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $contextValue.authorizationRevision = 'c' * 40
        $context = New-DevelopmentTokenContext -Value $contextValue
        $arguments = @{
            ApiUrl = 'https://api.example.test'; Repository = 'platform/instance'
            ReadToken = 'offline-reader'; WriterToken = 'offline-protected-writer'; RecoveryKey = $key
            Context = $context; ExpectedHead = 'c' * 40; ExpectedControlBlobSha = 'e' * 40
        }
        function Set-TestIssuedLeaf {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes only offline fixture state.')]
            [CmdletBinding()]
            param()
            $pending = Write-DevelopmentTokenEvent @arguments -Event pending
            $arguments.ExpectedHead = $pending.ControlRevision
            $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
            $journal = Read-DevelopmentTokenJournal -Json $snapshot.TokenJournal
            $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $journal.ContextSha256
            $issued = Write-DevelopmentTokenEvent @arguments -Event issued -Envelope $envelope
            $arguments.ExpectedHead = $issued.ControlRevision
        }
        Mock Invoke-WebRequest -ModuleName DevelopmentControl {
            param($Uri, $Method, $Body, $Headers, $MaximumRedirection, $MaximumRetryCount)
            $methodName = ([string] $Method).ToUpperInvariant()
            $server.Requests.Add(@{
                Uri = [string] $Uri; Method = $methodName; Body = $Body
                Authorization = $Headers.Authorization; Redirects = $MaximumRedirection; Retries = $MaximumRetryCount
            })
            $value = $null
            $responseKind = ''
            $statusCode = 200
            if ($methodName -cin @('POST', 'PATCH')) {
                $inputValue = ConvertFrom-Json -InputObject $Body -AsHashtable
                $kind = if ($Uri -like '*/git/trees') { 'tree' } elseif ($Uri -like '*/git/commits') { 'commit' } else { 'ref' }
                $responseKind = $kind
                if ($server.ForeignAt -ceq $kind) {
                    $server.Head = '9' * 40
                    $server.Commits[$server.Head] = Get-GitHubApiFixture -Name git/get-commit -Set @{
                        sha = $server.Head; 'tree.sha' = 'a' * 40
                    }
                }
                if ($server.Fault -ceq "before-$kind") { throw "Offline interruption before $kind." }
                $server.Sequence++
                $sha = $server.Sequence.ToString('x40')
                if ($kind -ceq 'tree') {
                    $value = Get-GitHubApiFixture -Name git/create-tree -Set @{ sha = $sha }
                    $base = $server.Trees[$inputValue.base_tree]
                    $value.tree = ConvertFrom-Json (ConvertTo-Json $base.tree -Depth 20) -AsHashtable -NoEnumerate
                    $value.tree[-1].sha = '3' * 40
                    $server.Trees[$sha] = $value
                    $server.Journals[$sha] = $inputValue.tree[0].content
                    $statusCode = 201
                }
                elseif ($kind -ceq 'commit') {
                    $value = Get-GitHubApiFixture -Name git/create-commit -Set @{
                        sha = $sha; 'tree.sha' = $inputValue.tree; 'parents.0.sha' = $inputValue.parents[0]; message = $inputValue.message
                    }
                    $server.Commits[$sha] = $value
                    $statusCode = 201
                }
                else {
                    $newCommit = $server.Commits[$inputValue.sha]
                    if (-not $inputValue.force -and $newCommit.parents[0].sha -cne $server.Head) {
                        return [pscustomobject]@{ StatusCode = 422; Content = '{}' }
                    }
                    $server.Head = $inputValue.sha
                    $value = Get-GitHubApiFixture -Name git/update-ref -Set @{
                        ref = 'refs/heads/platform-control'; 'object.sha' = $server.Head
                    }
                }
                $server.Changes.Add(@{ Kind = $kind; Input = $inputValue })
                if ($server.Fault -ceq "after-$kind") { throw "Offline lost response after $kind." }
                # Intentionally invalid status/body combinations isolate the status guard.
                if ($server.HttpKind -ceq $kind) { $statusCode = $server.HttpStatus }
                switch ($server.Corrupt) {
                    'parent-sha' { if ($kind -ceq 'commit') { $value.parents[0].sha = 'b' * 40 } }
                    'parent-array-sha' { if ($kind -ceq 'commit') { $value.parents[0].sha = @('c' * 40) } }
                    'parent-count' { if ($kind -ceq 'commit') { $value.parents = @($value.parents[0], $value.parents[0]) } }
                    'child-tree' { if ($kind -ceq 'commit') { $value.tree.sha = 'b' * 40 } }
                    'child-array-tree' { if ($kind -ceq 'commit') { $value.tree.sha = @($inputValue.tree) } }
                    'acknowledged-head' { if ($kind -ceq 'ref') { $value.object.sha = '8' * 40 } }
                    'readback-journal' {
                        if ($kind -ceq 'ref') { $server.Journals[$newCommit.tree.sha] += ' ' }
                    }
                    'readback-head' {
                        if ($kind -ceq 'ref') {
                            $server.Head = '9' * 40
                            $foreign = ConvertFrom-Json (ConvertTo-Json $newCommit -Depth 30) -AsHashtable
                            $foreign.sha = $server.Head
                            $foreign.parents[0].sha = $inputValue.sha
                            $server.Commits[$server.Head] = $foreign
                        }
                    }
                }
            }
            elseif ($Uri -ceq 'https://api.example.test/installation/token' -and $methodName -ceq 'DELETE') {
                if ($server.RevokeFault -ceq 'before') { throw 'Offline interruption before DELETE.' }
                $server.RevokeCount++
                if ($server.RevokeStatus -eq 204) { $server.LeafStatus = $server.AfterRevokeStatus }
                if ($server.RevokeFault -ceq 'after') { throw 'Offline lost DELETE response.' }
                return [pscustomobject]@{ StatusCode = $server.RevokeStatus; Content = '' }
            }
            elseif ($Uri -ceq 'https://api.example.test/app/installations/456') {
                $statusCode = if ($Headers.Authorization -ceq 'Bearer offline-app-jwt') { $server.InstallationStatus } else { 401 }
                $value = $installation
            }
            elseif ($Uri -ceq 'https://api.example.test/installation/repositories') {
                $value = Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation
                return [pscustomobject]@{ StatusCode = $server.LeafStatus; Content = ConvertTo-Json $value -Depth 30 }
            }
            elseif ($Uri -like '*/git/ref/heads/main') {
                $value = Get-GitHubApiFixture -Name git/get-ref -Set @{ ref = 'refs/heads/main' }
            }
            elseif ($Uri -like '*/git/ref/heads/platform-control') {
                $value = Get-GitHubApiFixture -Name git/get-ref -Set @{
                    ref = 'refs/heads/platform-control'; 'object.sha' = $server.Head
                }
            }
            elseif ($Uri -match '/git/commits/([a-f0-9]{40})$') {
                $responseKind = 'parent'
                $value = ConvertFrom-Json (ConvertTo-Json $server.Commits[$Matches[1]] -Depth 30) -AsHashtable
                # Deliberately invalid discriminator, preserving the otherwise valid fixture.
                if ($server.Corrupt -ceq 'canonical-array-sha') { $value.sha = @('c' * 40) }
            }
            elseif ($Uri -match '/git/trees/([a-f0-9]{40})$') {
                $revision = $Matches[1]
                $value = $server.Trees[$server.Commits[$revision].tree.sha]
                # Deliberately inconsistent immutable-object metadata isolates exact readback checks.
                if (($server.Corrupt -ceq 'pre-cas-authorization' -and $server.Changes.Count -eq 2) -or
                    ($server.Corrupt -ceq 'readback-authorization' -and $server.Changes.Count -eq 3)) {
                    $value = ConvertFrom-Json (ConvertTo-Json $value -Depth 30) -AsHashtable
                    $value.tree[0].sha = 'd' * 40
                }
            }
            elseif ($Uri -match '/contents/(development-control.json|development-token-journal.json)\?ref=([a-f0-9]{40})$') {
                $fileName = $Matches[1]
                $revision = $Matches[2]
                if ($fileName -ceq 'development-control.json') {
                    $value = $controlFile
                    if (($server.Corrupt -ceq 'pre-cas-authorization' -and $server.Changes.Count -eq 2) -or
                        ($server.Corrupt -ceq 'readback-authorization' -and $server.Changes.Count -eq 3)) {
                        $value = ConvertFrom-Json (ConvertTo-Json $value -Depth 30) -AsHashtable
                        $value.sha = 'd' * 40
                    }
                }
                else {
                    $journal = $server.Journals[$server.Commits[$revision].tree.sha]
                    if ($server.Corrupt -ceq 'readback-journal-case' -and $server.Changes.Count -eq 6) {
                        $record = (ConvertFrom-Json $journal -AsHashtable).records[-1]
                        $ciphertext = (ConvertFrom-Json $record.envelope -AsHashtable).ciphertext
                        $letter = [regex]::Match($ciphertext, '[a-zA-Z]')
                        if (-not $letter.Success -or [regex]::Matches($journal, [regex]::Escape($ciphertext)).Count -ne 1) {
                            throw 'Offline ciphertext case-corruption fixture requires one unambiguous ASCII letter.'
                        }
                        $replacement = if ($letter.Value -cmatch '[a-z]') { $letter.Value.ToUpperInvariant() } else { $letter.Value.ToLowerInvariant() }
                        $changedCiphertext = $ciphertext.Remove($letter.Index, 1).Insert($letter.Index, $replacement)
                        $journal = $journal.Replace($ciphertext, $changedCiphertext)
                    }
                    $value = Get-GitHubApiFixture -Name repos/get-content.file -Set @{
                        name = 'development-token-journal.json'; path = 'development-token-journal.json'
                        sha = $server.Trees[$server.Commits[$revision].tree.sha].tree[-1].sha
                    }
                    $bytes = [Text.Encoding]::UTF8.GetBytes($journal)
                    $value.content = [Convert]::ToBase64String($bytes)
                    $value.size = $bytes.Length
                }
            }
            elseif ($Uri -like '*/rules/branches/platform-control`?*') { $value = $rules }
            elseif ($Uri -like '*/rulesets/42`?includes_parents=true') { $value = $ruleset }
            else { throw "Unexpected offline controller request: $Method $Uri" }
            # Deliberately invalid responses change one field of a primary-schema fixture.
            if ($responseKind -cne '' -and $server.ReplyKind -ceq $responseKind) {
                $value = ConvertFrom-Json (ConvertTo-Json -InputObject $value -Depth 30) -AsHashtable -NoEnumerate
                if ($server.ReplyField -ceq '$root') {
                    $value = if ($server.ReplyMode -ceq 'array') { ,@($value) } else { $server.ReplyValue }
                }
                else {
                    $parts = $server.ReplyField.Split('.')
                    $cursor = $value
                    for ($index = 0; $index -lt $parts.Count - 1; $index++) {
                        if ($cursor -is [Collections.IList]) { $cursor = $cursor[[int] $parts[$index]] }
                        else { $cursor = $cursor[$parts[$index]] }
                    }
                    $field = $parts[-1]
                    $replacement = switch ($server.ReplyMode) {
                        'array' { ,@($cursor[$field]) }
                        'upper' { $cursor[$field].ToUpperInvariant() }
                        default { $server.ReplyValue }
                    }
                    $cursor[$field] = $replacement
                }
            }
            return [pscustomobject]@{ StatusCode = $statusCode; Content = ConvertTo-Json -InputObject $value -Depth 30 }
        }
    }

    It 'appends one journal file as a non-force direct child and reads it back without changing authorization' {
        $result = Write-DevelopmentTokenEvent @arguments -Event pending
        $result.ControlRevision | Should -BeExactly ('0000000000000000000000000000000000000002')
        $result.ControlBlobSha | Should -BeExactly ('e' * 40)
        $result.TokenJournalPhase | Should -BeExactly 'pending'
        $server.Changes.Count | Should -Be 3
        $server.Changes[0].Input.base_tree | Should -BeExactly ('a' * 40)
        $server.Changes[0].Input.tree.Count | Should -Be 1
        $server.Changes[0].Input.tree[0].path | Should -BeExactly 'development-token-journal.json'
        $server.Changes[1].Input.parents.Count | Should -Be 1
        $server.Changes[1].Input.parents[0] | Should -BeExactly ('c' * 40)
        $server.Changes[2].Input.force | Should -BeFalse
        $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $snapshot.Approval | Should -BeExactly 'immutable approval'
        $snapshot.Source | Should -BeExactly 'https://github.com/example/platform'
        $snapshot.Reference | Should -BeExactly 'https://example.test/platform/instance'
        $snapshot.Disposition | Should -BeExactly ''
        $record = (Read-DevelopmentTokenJournal -Json $snapshot.TokenJournal).Records[0]
        $record.previousHead | Should -BeExactly ('c' * 40)
        $record.context | Should -BeExactly $context
        @($server.Requests | Where-Object { $_.Method -cin @('POST', 'PATCH') -and $_.Authorization -cne 'Bearer offline-protected-writer' }).Count |
            Should -Be 0
        @($server.Requests | Where-Object { $_.Redirects -ne 0 -or $_.Retries -ne 0 }).Count | Should -Be 0
    }

    It 'persists a context-bound encrypted leaf only after that exact bearer authenticates on the fixed endpoint' {
        $pending = Write-DevelopmentTokenEvent @arguments -Event pending
        $arguments.ExpectedHead = $pending.ControlRevision
        $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $journal = Read-DevelopmentTokenJournal -Json $snapshot.TokenJournal
        $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $journal.ContextSha256
        $issued = Write-DevelopmentTokenEvent @arguments -Event issued -Envelope $envelope
        $issued.TokenJournalPhase | Should -BeExactly 'issued'
        $again = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $again.ControlRevision | Should -BeExactly $issued.ControlRevision
        $known = Read-DevelopmentTokenJournal -Json $again.TokenJournal
        Unprotect-DevelopmentLeafToken -Envelope $known.Envelope -RecoveryKey $key -ContextSha256 $known.ContextSha256 |
            Should -BeExactly 'offline-leaf'
        @($server.Requests | Where-Object {
            $_.Uri -ceq 'https://api.example.test/installation/repositories' -and $_.Authorization -ceq 'Bearer offline-leaf' -and
            $_.Method -ceq 'GET' -and $_.Redirects -eq 0 -and $_.Retries -eq 0
        }).Count | Should -Be 1
        $again.TokenJournal | Should -Not -Match 'offline-leaf'
    }

    It 'fails closed on <Fault> and observes only the remotely committed journal on a fresh read' -ForEach @(
        @{ Fault = 'before-tree'; ExpectedPhase = 'clear' }
        @{ Fault = 'after-tree'; ExpectedPhase = 'clear' }
        @{ Fault = 'before-commit'; ExpectedPhase = 'clear' }
        @{ Fault = 'after-commit'; ExpectedPhase = 'clear' }
        @{ Fault = 'before-ref'; ExpectedPhase = 'clear' }
        @{ Fault = 'after-ref'; ExpectedPhase = 'pending' }
    ) {
        $server.Fault = $Fault
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw '*Offline*'
        $server.Fault = ''
        $fresh = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $fresh.TokenJournalPhase | Should -BeExactly $ExpectedPhase
        @($server.Requests | Where-Object { $_.Uri -like '*/installation/*' }).Count | Should -Be 0
        if ($ExpectedPhase -ceq 'clear') {
            (Write-DevelopmentTokenEvent @arguments -Event pending).TokenJournalPhase | Should -BeExactly 'pending'
        }
        else {
            { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw '*head or authorization blob changed*'
            $contextValue.runId = '999'
            $contextValue.authorizationRevision = $fresh.ControlRevision
            $arguments.Context = New-DevelopmentTokenContext -Value $contextValue
            $arguments.ExpectedHead = $fresh.ControlRevision
            { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw '*Unfinished*'
        }
    }

    It 'rejects <Case> before any API credential is sent' -ForEach @(
        @{ Case = 'missing writer'; Field = 'WriterToken'; Value = ''; Expected = '*explicit protected*' }
        @{ Case = 'whitespace writer'; Field = 'WriterToken'; Value = ' '; Expected = '*explicit protected*' }
        @{ Case = 'wrong purpose key size'; Field = 'RecoveryKey'; Value = [Convert]::ToBase64String([byte[]] (1..31)); Expected = '*purpose-only*' }
        @{ Case = 'context origin'; ContextField = 'apiUrl'; Value = 'https://api.other.test'; Expected = '*exact canonical context*' }
        @{ Case = 'context repository'; ContextField = 'repository'; Value = 'platform/other'; Expected = '*exact canonical context*' }
        @{ Case = 'context authorization blob'; ContextField = 'authorizationBlob'; Value = 'f' * 40; Expected = '*exact canonical context*' }
        @{ Case = 'noncanonical context'; Field = 'Context'; Value = ' '; Expected = '*exact canonical context*' }
        @{ Case = 'short head'; Field = 'ExpectedHead'; Value = 'abc'; Expected = '*exact canonical context*' }
        @{ Case = 'uppercase head'; Field = 'ExpectedHead'; Value = 'C' * 40; Expected = '*exact canonical context*' }
        @{ Case = 'API case alias'; Field = 'ApiUrl'; Value = 'https://API.example.test'; Expected = '*exact canonical context*' }
        @{ Case = 'repository case alias'; Field = 'Repository'; Value = 'Platform/instance'; Expected = '*exact canonical context*' }
        @{ Case = 'authorization blob case alias'; Field = 'ExpectedControlBlobSha'; Value = 'E' * 40; Expected = '*exact canonical context*' }
    ) {
        if ($Case -ceq 'noncanonical context') { $arguments.Context += ' ' }
        elseif ($Case -like 'context*') {
            $contextValue[$ContextField] = $Value
            $arguments.Context = New-DevelopmentTokenContext -Value $contextValue
        }
        else { $arguments[$Field] = $Value }
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw $Expected
        $server.Requests.Count | Should -Be 0
    }

    It 'rejects a stale caller head without adopting the newer protected head' {
        $arguments.ExpectedHead = 'b' * 40
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw '*head or authorization blob changed*'
        $server.Changes.Count | Should -Be 0
    }

    It 'rejects an authorization blob replaced by another writer' {
        $controlFile.sha = 'd' * 40
        $server.Trees[('a' * 40)].tree[0].sha = 'd' * 40
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw '*head or authorization blob changed*'
        $server.Changes.Count | Should -Be 0
    }

    It 'rejects an incorrect <Case> during append and readback' -ForEach @(
        @{ Case = 'parent-sha'; Expected = '*one new direct child*' }
        @{ Case = 'parent-array-sha'; Expected = '*one new direct child*' }
        @{ Case = 'parent-count'; Expected = '*one new direct child*' }
        @{ Case = 'child-tree'; Expected = '*one new direct child*' }
        @{ Case = 'child-array-tree'; Expected = '*one new direct child*' }
        @{ Case = 'canonical-array-sha'; Expected = '*canonical parent commit tree*' }
        @{ Case = 'acknowledged-head'; Expected = '*acknowledge the exact new head*' }
        @{ Case = 'readback-journal'; Expected = '*immutable readback differs*' }
        @{ Case = 'pre-cas-authorization'; Expected = '*foreign heads are not accepted*' }
        @{ Case = 'readback-head'; Expected = '*immutable readback differs*' }
        @{ Case = 'readback-authorization'; Expected = '*immutable readback differs*' }
    ) {
        $server.Corrupt = $Case
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw $Expected
    }

    It 'rejects HTTP <Code> for the <Kind> write even when a successful-looking body exists' -ForEach @(
        foreach ($kind in @('tree', 'commit', 'ref')) {
            foreach ($code in @(200, 201, 301, 401, 403, 404, 422, 429, 500)) {
                if (($kind -ceq 'ref' -and $code -ne 200) -or ($kind -cne 'ref' -and $code -ne 201)) {
                    @{ Kind = $kind; Code = $code }
                }
            }
        }
    ) {
        $server.HttpKind = $Kind
        $server.HttpStatus = $Code
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw "*journal write failed: HTTP $Code*"
    }

    It 'refuses a competing head at <Stage> rather than rebasing or forcing the journal' -ForEach @(
        @{ Stage = 'commit'; Expected = '*foreign heads are not accepted*' }
        @{ Stage = 'ref'; Expected = '*HTTP 422*' }
    ) {
        $server.ForeignAt = $Stage
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw $Expected
        $server.Head | Should -BeExactly ('9' * 40)
        @($server.Changes | Where-Object Kind -CEQ ref).Count | Should -Be 0
    }

    It 'rejects malformed <Kind> response <Field> <Mode> before accepting an append' -ForEach @(
        @(
        foreach ($kind in @('parent', 'tree', 'commit')) {
            $expected = switch ($kind) {
                parent { '*canonical parent commit tree*' }
                tree { '*invalid tree*' }
                commit { '*one new direct child*' }
            }
            @{ Kind = $kind; Field = '$root'; Mode = 'array'; Expected = $expected }
            @{ Kind = $kind; Field = '$root'; Value = $null; Expected = $expected }
            @{ Kind = $kind; Field = 'sha'; Mode = 'array'; Expected = $expected }
            if ($kind -ceq 'parent') {
                @{ Kind = $kind; Field = 'sha'; Value = 'b' * 40; Expected = $expected }
                @{ Kind = $kind; Field = 'sha'; Mode = 'upper'; Expected = $expected }
            }
            else {
                @{ Kind = $kind; Field = 'sha'; Value = 'not-a-sha'; Expected = $expected }
                @{ Kind = $kind; Field = 'sha'; Mode = 'upper'; Expected = $expected }
            }
        }
        @{ Kind = 'parent'; Field = 'tree'; Mode = 'array'; Expected = '*canonical parent commit tree*' }
        @{ Kind = 'parent'; Field = 'tree.sha'; Mode = 'array'; Expected = '*canonical parent commit tree*' }
        @{ Kind = 'parent'; Field = 'tree.sha'; Value = 'not-a-sha'; Expected = '*canonical parent commit tree*' }
        @{ Kind = 'parent'; Field = 'tree.sha'; Mode = 'upper'; Expected = '*canonical parent commit tree*' }
        @{ Kind = 'tree'; Field = 'tree.0.sha'; Value = 'b' * 40; Expected = '*authorization blob*' }
        @{ Kind = 'commit'; Field = 'sha'; Value = 'c' * 40; Expected = '*one new direct child*' }
        @{ Kind = 'commit'; Field = 'tree'; Mode = 'array'; Expected = '*one new direct child*' }
        @{ Kind = 'commit'; Field = 'tree.sha'; Mode = 'upper'; Expected = '*one new direct child*' }
        @{ Kind = 'commit'; Field = 'parents'; Value = 'not-an-array'; Expected = '*one new direct child*' }
        @{ Kind = 'commit'; Field = 'parents.0'; Value = 'not-an-object'; Expected = '*one new direct child*' }
        @{ Kind = 'commit'; Field = 'parents.0.sha'; Mode = 'upper'; Expected = '*one new direct child*' }
        ) | ForEach-Object {
            if (-not $_.Contains('Mode')) { $_.Mode = 'value' }
            if (-not $_.Contains('Value')) { $_.Value = $null }
            $_
        }
    ) {
        param($Kind, $Field, $Mode = '', $Value, $Expected)
        $server.Sequence = 9
        $server.ReplyKind = $Kind
        $server.ReplyField = $Field
        $server.ReplyMode = $Mode
        $server.ReplyValue = $Value
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw $Expected
    }

    It 'does not persist or hand off a leaf rejected with HTTP <Code>' -ForEach @(
        foreach ($code in @(401, 403, 404, 429, 500)) { @{ Code = $code } }
    ) {
        $pending = Write-DevelopmentTokenEvent @arguments -Event pending
        $arguments.ExpectedHead = $pending.ControlRevision
        $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $journal = Read-DevelopmentTokenJournal -Json $snapshot.TokenJournal
        $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $journal.ContextSha256
        $server.LeafStatus = $Code
        { Write-DevelopmentTokenEvent @arguments -Event issued -Envelope $envelope } | Should -Throw '*exact issued leaf must authenticate*'
        $server.Changes.Count | Should -Be 3
    }

    It 'rejects case-only encrypted journal readback corruption without accepting an issued handoff' {
        $pending = Write-DevelopmentTokenEvent @arguments -Event pending
        $arguments.ExpectedHead = $pending.ControlRevision
        $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $journal = Read-DevelopmentTokenJournal -Json $snapshot.TokenJournal
        $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $journal.ContextSha256
        $server.Corrupt = 'readback-journal-case'
        { Write-DevelopmentTokenEvent @arguments -Event issued -Envelope $envelope } | Should -Throw '*immutable readback differs*'
        $server.Corrupt = ''
        $persisted = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $known = Read-DevelopmentTokenJournal -Json $persisted.TokenJournal
        $known.Phase | Should -BeExactly 'issued'
        Unprotect-DevelopmentLeafToken -Envelope $known.Envelope -RecoveryKey $key -ContextSha256 $known.ContextSha256 |
            Should -BeExactly 'offline-leaf'
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw '*do not adopt a newer head*'
    }

    It 'refuses a new pending intent bound to a different original authorization revision' {
        $contextValue.authorizationRevision = 'b' * 40
        $arguments.Context = New-DevelopmentTokenContext -Value $contextValue
        { Write-DevelopmentTokenEvent @arguments -Event pending } | Should -Throw '*original exact authorization head*'
        $server.Changes.Count | Should -Be 0
    }

    It 'does not probe or persist an issued leaf with <Case>' -ForEach @(
        @{ Case = 'no pending intent' }
        @{ Case = 'a different pending context' }
    ) {
        if ($Case -ceq 'a different pending context') {
            $pending = Write-DevelopmentTokenEvent @arguments -Event pending
            $arguments.ExpectedHead = $pending.ControlRevision
            $contextValue.runId = '12345'
            $arguments.Context = New-DevelopmentTokenContext -Value $contextValue
        }
        $writes = $server.Changes.Count
        { Write-DevelopmentTokenEvent @arguments -Event issued } | Should -Throw '*no matching pending intent*'
        $server.Changes.Count | Should -Be $writes
        @($server.Requests | Where-Object { $_.Uri -like '*/installation/*' }).Count | Should -Be 0
    }

    It 'retires the persisted exact leaf only after DELETE 204 and direct GET 401' {
        Set-TestIssuedLeaf
        $result = Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999'
        $result.TokenJournalPhase | Should -BeExactly 'retired'
        $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $record = (Read-DevelopmentTokenJournal -Json $snapshot.TokenJournal).Records[-1]
        $record.proofKind | Should -BeExactly 'revoked'
        $record.revokeStatus | Should -Be 204
        $record.negativeStatus | Should -Be 401
        $server.RevokeCount | Should -Be 1
    }

    It 'returns the same acknowledged retirement without issuing another revocation or journal append' {
        Set-TestIssuedLeaf
        $retired = Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999'
        $arguments.ExpectedHead = $retired.ControlRevision
        $writes = $server.Changes.Count
        $result = Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '1000'
        $result.ControlRevision | Should -BeExactly $retired.ControlRevision
        $result.TokenJournalPhase | Should -BeExactly 'retired'
        $server.Changes.Count | Should -Be $writes
        $server.RevokeCount | Should -Be 1
    }

    It 'rejects invalid retirement run <Run> before any API credential is sent' -ForEach @(
        @{ Run = '0' }; @{ Run = '01' }; @{ Run = '999bad' }; @{ Run = '12345678901234567890' }
    ) {
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId $Run } |
            Should -Throw '*exact trusted recovery run ID*'
        $server.Requests.Count | Should -Be 0
    }

    It 'recovers a lost successful DELETE response from the same durable issued journal without inventing DELETE success' {
        Set-TestIssuedLeaf
        $server.RevokeFault = 'after'
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999' } |
            Should -Throw '*lost DELETE response*'
        $interrupted = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $interrupted.ControlRevision | Should -BeExactly $arguments.ExpectedHead
        $interrupted.TokenJournalPhase | Should -BeExactly 'issued'
        $server.RevokeFault = ''
        $result = Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '1000'
        $result.TokenJournalPhase | Should -BeExactly 'retired'
        $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $record = (Read-DevelopmentTokenJournal -Json $snapshot.TokenJournal).Records[-1]
        $record.proofKind | Should -BeExactly 'already-invalid'
        $record.revokeStatus | Should -Be 0
        $record.negativeStatus | Should -Be 401
        $record.activeInstallationId | Should -BeExactly '456'
        $record.retirementRunId | Should -BeExactly '1000'
        $server.RevokeCount | Should -Be 1
    }

    It 'models fresh recovery after a committed issued CAS loses its acknowledgement without adopting latest as an own head' {
        $pending = Write-DevelopmentTokenEvent @arguments -Event pending
        $arguments.ExpectedHead = $pending.ControlRevision
        $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $journal = Read-DevelopmentTokenJournal -Json $snapshot.TokenJournal
        $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -RecoveryKey $key -ContextSha256 $journal.ContextSha256
        $server.Fault = 'after-ref'
        { Write-DevelopmentTokenEvent @arguments -Event issued -Envelope $envelope } | Should -Throw '*lost response after ref*'
        $server.Fault = ''

        # A fresh caller retains only original authorization, not the failed call's in-memory result.
        $arguments.ExpectedHead = $contextValue.authorizationRevision
        $fresh = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $fresh.TokenJournalPhase | Should -BeExactly 'issued'
        $fresh.ControlRevision | Should -Not -BeExactly $arguments.ExpectedHead
        $known = Read-DevelopmentTokenJournal -Json $fresh.TokenJournal
        Unprotect-DevelopmentLeafToken -Envelope $known.Envelope -RecoveryKey $key -ContextSha256 $known.ContextSha256 |
            Should -BeExactly 'offline-leaf'
        $server.Requests.Clear()
        {
            Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '1000'
        } | Should -Throw '*head or authorization blob changed*'
        {
            Write-DevelopmentTokenEvent @arguments -Event pending
        } | Should -Throw '*head or authorization blob changed*'
        foreach ($mode in @('standard', 'development')) {
            $outputPath = Join-Path $TestDrive "unacknowledged-$mode.txt"
            {
                & (Join-Path $PSScriptRoot '../Read-DevelopmentControl.ps1') -Mode $mode -Repository 'platform/instance' `
                    -ApiUrl 'https://api.example.test' -ServerUrl 'https://example.test' -ReadToken 'offline-reader' `
                    -RunAttempt '1' -GitHubOutputPath $outputPath
            } | Should -Throw '*Unfinished development token*'
            Test-Path -LiteralPath $outputPath | Should -BeFalse
        }
        $server.Changes.Count | Should -Be 6
        @($server.Requests | Where-Object { $_.Method -cne 'GET' -or $_.Uri -like '*/installation/*' -or $_.Uri -like '*/app/installations/*' }).Count |
            Should -Be 0
    }

    It 'does not retire on <Stage> HTTP <Code>' -ForEach @(
        foreach ($code in @(200, 301, 304, 403, 404, 429, 500)) {
            @{ Stage = 'negative probe'; Code = $code; Expected = '*direct negative GET 401*' }
        }
        foreach ($code in @(200, 301, 401, 403, 404, 429, 500)) {
            @{ Stage = 'DELETE'; Code = $code; Expected = '*documented DELETE 204*' }
        }
        foreach ($code in @(301, 304, 403, 404, 429, 500)) {
            @{ Stage = 'initial probe'; Code = $code; Expected = '*statuses remain blocked*' }
        }
        foreach ($code in @(301, 401, 403, 404, 429, 500)) {
            @{ Stage = 'installation lookup'; Code = $code; Expected = '*HTTP*' }
        }
    ) {
        Set-TestIssuedLeaf
        switch ($Stage) {
            'negative probe' { $server.AfterRevokeStatus = $Code }
            'DELETE' { $server.RevokeStatus = $Code }
            'initial probe' { $server.LeafStatus = $Code }
            'installation lookup' { $server.LeafStatus = 401; $server.InstallationStatus = $Code }
        }
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999' } | Should -Throw $Expected
        $snapshot = Read-DevelopmentControl -ApiUrl $arguments.ApiUrl -Repository $arguments.Repository -ReadToken $arguments.ReadToken
        $snapshot.ControlRevision | Should -BeExactly $arguments.ExpectedHead
        $snapshot.TokenJournalPhase | Should -BeExactly 'issued'
        $server.Changes.Count | Should -Be 6
    }

    # Deliberately invalid installation variants change one documented discriminator.
    It 'blocks already-invalid retirement for installation <Case>' -ForEach @(
        @{ Case = 'null root' }
        @{ Case = 'array root' }
        @{ Case = 'wrong ID'; Field = 'id'; Value = 457 }
        @{ Case = 'string ID'; Field = 'id'; Value = '456' }
        @{ Case = 'wrong App'; Field = 'app_id'; Value = 124 }
        @{ Case = 'string App'; Field = 'app_id'; Value = '123' }
        @{ Case = 'wrong target type'; Field = 'target_type'; Value = 'User' }
        @{ Case = 'target type case alias'; Field = 'target_type'; Value = 'organization' }
        @{ Case = 'target type array'; Field = 'target_type'; Value = @('Organization') }
        @{ Case = 'null account'; Field = 'account'; Value = $null }
        @{ Case = 'account array'; Field = 'account'; Value = @(@{ type = 'Organization'; login = 'workloads' }) }
        @{ Case = 'wrong account type'; Field = 'account.type'; Value = 'User' }
        @{ Case = 'account type case alias'; Field = 'account.type'; Value = 'organization' }
        @{ Case = 'account type array'; Field = 'account.type'; Value = @('Organization') }
        @{ Case = 'wrong organization'; Field = 'account.login'; Value = 'other' }
        @{ Case = 'non-string login'; Field = 'account.login'; Value = @('workloads') }
        @{ Case = 'suspended'; Field = 'suspended_at'; Value = '2026-01-01T00:00:00Z' }
        @{ Case = 'suspended actor'; Field = 'suspended_by'; Value = @{ login = 'actor' } }
        @{ Case = 'missing suspension time'; Field = 'suspended_at'; Remove = $true }
        @{ Case = 'missing suspension actor'; Field = 'suspended_by'; Remove = $true }
        @{ Case = 'enterprise account' }
    ) {
        Set-TestIssuedLeaf
        $server.LeafStatus = 401
        if ($Case -ceq 'null root') { $installation = $null }
        elseif ($Case -ceq 'array root') { $installation = @($installation) }
        elseif ($Case -ceq 'enterprise account') {
            $installation.account = (Get-GitHubApiFixture -Name apps/get-app.owner-enterprise).owner
        }
        elseif ($Case -like 'missing*') { $null = $installation.Remove($Field) }
        elseif ($Field -like 'account.*') { $installation.account[$Field.Split('.')[1]] = $Value }
        else { $installation[$Field] = $Value }
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999' } |
            Should -Throw '*exact original active, unsuspended organization installation*'
        $server.Changes.Count | Should -Be 6
        $server.RevokeCount | Should -Be 0
    }

    It 'accepts the same active installation with the documented case-insensitive organization identity' {
        Set-TestIssuedLeaf
        $server.LeafStatus = 401
        $installation.account.login = 'Workloads'
        (Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999').TokenJournalPhase |
            Should -BeExactly 'retired'
    }

    It 'blocks recovery using a wrong App JWT without falling back to reader or writer credentials' {
        Set-TestIssuedLeaf
        $server.LeafStatus = 401
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-wrong-jwt' -RetirementRunId '999' } | Should -Throw '*HTTP 401*'
        $server.Changes.Count | Should -Be 6
    }

    It 'blocks recovery with a missing App JWT instead of treating a negative probe as sufficient' {
        Set-TestIssuedLeaf
        $server.LeafStatus = 401
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt '' -RetirementRunId '999' } | Should -Throw '*explicit App JWT*'
        $server.Changes.Count | Should -Be 6
    }

    It 'does not decrypt or probe an unknown pending leaf' {
        $pending = Write-DevelopmentTokenEvent @arguments -Event pending
        $arguments.ExpectedHead = $pending.ControlRevision
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999' } |
            Should -Throw '*unknown pending issuance remains blocked*'
        $server.RevokeCount | Should -Be 0
        @($server.Requests | Where-Object { $_.Uri -like '*/installation/*' -or $_.Uri -like '*/app/installations/*' }).Count |
            Should -Be 0
    }

    It 'does not decrypt or revoke a known leaf for a different recovery context' {
        Set-TestIssuedLeaf
        $contextValue.runId = '12345'
        $arguments.Context = New-DevelopmentTokenContext -Value $contextValue
        $server.Requests.Clear()
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999' } |
            Should -Throw '*exact persisted known issued leaf*'
        $server.RevokeCount | Should -Be 0
        @($server.Requests | Where-Object { $_.Uri -like '*/installation/*' -or $_.Uri -like '*/app/installations/*' }).Count |
            Should -Be 0
    }

    It 'never uses a wrong purpose key to authenticate a known leaf' {
        Set-TestIssuedLeaf
        $arguments.RecoveryKey = [Convert]::ToBase64String([byte[]] (2..33))
        $server.Requests.Clear()
        { Complete-DevelopmentTokenRetirement @arguments -AppJwt 'offline-app-jwt' -RetirementRunId '999' } |
            Should -Throw '*purpose-only recovery key does not match*'
        @($server.Requests | Where-Object { $_.Uri -like '*/installation/*' -or $_.Uri -like '*/app/installations/*' }).Count |
            Should -Be 0
    }
}
