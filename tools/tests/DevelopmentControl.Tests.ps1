BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../DevelopmentTokenLifecycle.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../DevelopmentControl.psm1') -Force
    $controlCommand = Join-Path $PSScriptRoot '../Read-DevelopmentControl.ps1'
}

Describe 'Protected development control snapshot' {
    BeforeEach {
        $state = @{
            version = 1
            reference = 'https://example.test/platform/instance'
            source = 'https://github.com/example/platform'
            approval = '{"revision":"approved"}'
            disposition = ''
        }
        $controlRef = Get-GitHubApiFixture -Name git/get-ref -Set @{
            ref = 'refs/heads/platform-control'; 'object.sha' = 'c' * 40
        }
        $mainRef = Get-GitHubApiFixture -Name git/get-ref -Set @{ ref = 'refs/heads/main' }
        $content = Get-GitHubApiFixture -Name repos/get-content.file -Set @{
            name = 'development-control.json'; path = 'development-control.json'
        }
        $journalContent = Get-GitHubApiFixture -Name repos/get-content.file -Set @{
            name = 'development-token-journal.json'; path = 'development-token-journal.json'; sha = 'f' * 40
        }
        $tree = Get-GitHubApiFixture -Name git/get-tree -Set @{
            'tree.0.path' = 'development-control.json'; 'tree.0.sha' = $content.sha
        }
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $state -Compress))
        $content.content = [Convert]::ToBase64String($bytes)
        $content.size = $bytes.Length
        $status = @{}
        $reads = @{ Control = 0; Total = 0 }
        $failAt = 0
        $changed = $false
        $nullControlRef = $false
        $ruleset = Get-GitHubApiFixture -Name repos/get-repo-ruleset.control
        $rules = Get-GitHubApiFixture -Name repos/get-branch-rules -Set @{
            '0.type' = 'update'; '0.ruleset_id' = 42
            '1.type' = 'deletion'; '1.ruleset_id' = 42
        }
        Mock Invoke-WebRequest -ModuleName DevelopmentControl {
            param($Uri)
            $reads.Total++
            if ($reads.Total -eq $failAt) { return [pscustomobject]@{ StatusCode = 500; Content = '{}' } }
            if ($status.ContainsKey([string] $Uri)) {
                return [pscustomobject]@{ StatusCode = $status[[string] $Uri]; Content = '{}' }
            }
            if ($nullControlRef -and $Uri -like '*/git/ref/heads/platform-control') {
                return [pscustomobject]@{ StatusCode = 200; Content = 'null' }
            }
            $body = if ($Uri -like '*/git/ref/heads/main') { $mainRef }
                elseif ($Uri -like '*/git/ref/heads/platform-control') {
                    $reads.Control++
                    if ($changed -and $reads.Control -gt 1) {
                        Get-GitHubApiFixture -Name git/get-ref -Set @{
                            ref = 'refs/heads/platform-control'; 'object.sha' = 'd' * 40
                        }
                    } else { $controlRef }
                }
                elseif ($Uri -ceq ('https://api.example.test/repos/platform/instance/git/trees/' + ('c' * 40))) { ,$tree }
                elseif ($Uri -like '*/rules/branches/platform-control`?*') { ,$rules }
                elseif ($Uri -like '*/rulesets/42`?includes_parents=true') { ,$ruleset }
                elseif ($Uri -ceq ('https://api.example.test/repos/platform/instance/contents/development-control.json?ref=' + ('c' * 40))) { $content }
                elseif ($Uri -ceq ('https://api.example.test/repos/platform/instance/contents/development-token-journal.json?ref=' + ('c' * 40))) { $journalContent }
                else { throw "Unexpected offline request: $Uri" }
            [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-Json $body -Depth 30 }
        }
        $arguments = @{ ApiUrl = 'https://api.example.test'; Repository = 'platform/instance'; ReadToken = 'fake-token' }
        function Set-TestControlV2 {
            [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Changes only offline fixture state.')]
            [CmdletBinding()]
            param([string] $Journal = '{"version":1,"records":[]}')
            $state.version = 2
            $controlBytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $state -Compress))
            $content.content = [Convert]::ToBase64String($controlBytes)
            $content.size = $controlBytes.Length
            $journalBytes = [Text.Encoding]::UTF8.GetBytes($Journal)
            $journalContent.content = [Convert]::ToBase64String($journalBytes)
            $journalContent.size = $journalBytes.Length
            $entry = Get-GitHubApiFixture -Name git/get-tree -Set @{
                'tree.0.path' = 'development-token-journal.json'; 'tree.0.sha' = $journalContent.sha
            }
            $tree.tree += $entry.tree[0]
        }
    }

    It 'reads the protected file at a fixed commit and reconfirms the ref without minting credentials' {
        $result = Read-DevelopmentControl @arguments
        $result.Reference | Should -BeExactly 'https://example.test/platform/instance'
        $result.Source | Should -BeExactly 'https://github.com/example/platform'
        $result.Approval | Should -BeExactly '{"revision":"approved"}'
        $result.Disposition | Should -BeExactly ''
        $result.ControlRevision | Should -BeExactly ('c' * 40)
        Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 7 -Exactly -ParameterFilter {
            $Method -ceq 'GET' -and $MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0 -and
            $Headers.Accept -ceq 'application/vnd.github+json' -and
            $Headers['X-GitHub-Api-Version'] -ceq '2026-03-10' -and $TimeoutSec -eq 60 -and
            $Headers.Authorization -ceq 'Bearer fake-token'
        }
        Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 2 -Exactly -ParameterFilter {
            $Uri -ceq 'https://api.example.test/repos/platform/instance/git/ref/heads/platform-control'
        }
    }

    It 'rejects a ref changed while the immutable snapshot was read' {
        $changed = $true
        { Read-DevelopmentControl @arguments } | Should -Throw '*changed*'
    }

    It 'fails closed after read <Read> and recovers with a fresh snapshot without a local issuance journal' -ForEach @(
        foreach ($read in 1..7) { @{ Read = $read } }
    ) {
        $failAt = $Read
        { Read-DevelopmentControl @arguments } | Should -Throw '*HTTP 500*'
        $failAt = 0
        $reads.Control = 0
        (Read-DevelopmentControl @arguments).ControlRevision | Should -BeExactly ('c' * 40)
    }

    It 'rejects HTTP <Code> at <Endpoint> without assuming absent authorization' -ForEach @(
        @{ Code = 401; Endpoint = 'git/ref/heads/main' }
        @{ Code = 403; Endpoint = 'git/ref/heads/main' }
        @{ Code = 404; Endpoint = 'git/ref/heads/main' }
        @{ Code = 404; Endpoint = 'git/ref/heads/platform-control' }
        @{ Code = 301; Endpoint = 'git/ref/heads/platform-control' }
        @{ Code = 403; Endpoint = 'git/ref/heads/platform-control' }
        @{ Code = 500; Endpoint = 'git/ref/heads/platform-control' }
    ) {
        $status["https://api.example.test/repos/platform/instance/$Endpoint"] = $Code
        { Read-DevelopmentControl @arguments } | Should -Throw '*HTTP*'
    }

    It 'allows an absent control ref only explicitly after proving contents read on this repository' {
        $status['https://api.example.test/repos/platform/instance/git/ref/heads/platform-control'] = 404
        Read-DevelopmentControl @arguments -AllowAbsent | Should -BeNullOrEmpty
        Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 1 -Exactly -ParameterFilter {
            $Uri -ceq 'https://api.example.test/repos/platform/instance/git/ref/heads/main'
        }
    }

    It 'does not treat a hidden repository as a non-reference' {
        $status['https://api.example.test/repos/platform/instance/git/ref/heads/main'] = 404
        { Read-DevelopmentControl @arguments -AllowAbsent } | Should -Throw '*HTTP*'
    }

    It 'does not treat a malformed successful control response as an absent ref' {
        $nullControlRef = $true
        { Read-DevelopmentControl @arguments -AllowAbsent } | Should -Throw '*control ref*'
    }

    # These cases deliberately violate one field of a documented Git-ref response.
    It 'rejects an invalid control ref <Case>' -ForEach @(
        @{ Case = 'wrong ref'; Field = 'ref'; Value = 'refs/heads/other' }
        @{ Case = 'case changed ref'; Field = 'ref'; Value = 'refs/heads/Platform-control' }
        @{ Case = 'array ref'; Field = 'ref'; Value = @('refs/heads/platform-control') }
        @{ Case = 'non-commit'; Field = 'object.type'; Value = 'tag' }
        @{ Case = 'case changed type'; Field = 'object.type'; Value = 'Commit' }
        @{ Case = 'array type'; Field = 'object.type'; Value = @('commit') }
        @{ Case = 'array commit'; Field = 'object'; Value = @(@{ type = 'commit'; sha = 'c' * 40 }) }
        @{ Case = 'short SHA'; Field = 'object.sha'; Value = 'abc' }
        @{ Case = 'uppercase SHA'; Field = 'object.sha'; Value = 'C' * 40 }
        @{ Case = 'array SHA'; Field = 'object.sha'; Value = @('c' * 40) }
    ) {
        $parts = $Field.Split('.')
        if ($parts.Count -eq 1) { $controlRef[$Field] = $Value } else { $controlRef[$parts[0]][$parts[1]] = $Value }
        { Read-DevelopmentControl @arguments } | Should -Throw '*control ref*'
    }

    It 'rejects unsupported Git entry <Case> before content is read' -ForEach @(
        @{ Case = 'symlink'; Mode = '120000'; Type = 'blob' }
        @{ Case = 'submodule'; Mode = '160000'; Type = 'commit' }
        @{ Case = 'directory'; Mode = '040000'; Type = 'tree' }
        @{ Case = 'executable'; Mode = '100755'; Type = 'blob' }
    ) {
        $tree.tree[0].mode = $Mode
        $tree.tree[0].type = $Type
        { Read-DevelopmentControl @arguments } | Should -Throw '*regular control file*'
        Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 0 -Exactly -ParameterFilter {
            $Uri -like '*/contents/*'
        }
    }

    It 'rejects a truncated Git tree' {
        $tree.truncated = $true
        { Read-DevelopmentControl @arguments } | Should -Throw '*complete control tree*'
    }

    # Deliberately invalid tree response variants isolate each tree discriminator.
    It 'rejects tree response <Case>' -ForEach @(
        @{ Case = 'null root' }; @{ Case = 'non-boolean truncation' }; @{ Case = 'scalar entries' }
        @{ Case = 'duplicate entry' }; @{ Case = 'wrong blob type' }; @{ Case = 'case changed blob type' }
        @{ Case = 'array path' }; @{ Case = 'array blob type' }; @{ Case = 'array mode' }
        @{ Case = 'array blob SHA' }; @{ Case = 'invalid blob SHA' }; @{ Case = 'uppercase blob SHA' }
    ) {
        switch ($Case) {
            'null root' { $tree = $null }
            'non-boolean truncation' { $tree.truncated = 0 }
            'scalar entries' { $tree.tree = $tree.tree[0] }
            'duplicate entry' { $tree.tree = @($tree.tree[0], $tree.tree[0]) }
            'wrong blob type' { $tree.tree[0].type = 'tree' }
            'case changed blob type' { $tree.tree[0].type = 'Blob' }
            'array path' { $tree.tree[0].path = @('development-control.json') }
            'array blob type' { $tree.tree[0].type = @('blob') }
            'array mode' { $tree.tree[0].mode = @('100644') }
            'array blob SHA' { $tree.tree[0].sha = @($tree.tree[0].sha) }
            'invalid blob SHA' { $tree.tree[0].sha = 'not-a-sha' }
            'uppercase blob SHA' { $tree.tree[0].sha = $tree.tree[0].sha.ToUpperInvariant() }
        }
        $errorMessage = if ($Case -in @('null root', 'non-boolean truncation', 'scalar entries')) {
            '*complete control tree*'
        } else { '*regular control file*' }
        { Read-DevelopmentControl @arguments } | Should -Throw $errorMessage
    }

    It 'rejects each unsupported documented contents variant: <Variant>' -ForEach @(
        @{ Variant = 'directory' }; @{ Variant = 'symlink' }; @{ Variant = 'submodule' }
    ) {
        $content = Get-GitHubApiFixture -Name "repos/get-content.$Variant"
        { Read-DevelopmentControl @arguments } | Should -Throw '*control content*'
    }

    It 'rejects content with a different Git object' {
        $content.sha = 'e' * 40
        { Read-DevelopmentControl @arguments } | Should -Throw '*control content*'
    }

    It 'rejects invalid file field <Field>: <Case>' -ForEach @(
        @{ Field = 'type'; Case = 'case changed'; Value = 'File' }
        @{ Field = 'name'; Case = 'wrong name'; Value = 'other.json' }
        @{ Field = 'name'; Case = 'case changed name'; Value = 'Development-control.json' }
        @{ Field = 'path'; Case = 'wrong path'; Value = 'nested/development-control.json' }
        @{ Field = 'path'; Case = 'case changed path'; Value = 'Development-control.json' }
        @{ Field = 'encoding'; Case = 'unsupported encoding'; Value = 'none' }
        @{ Field = 'encoding'; Case = 'case changed encoding'; Value = 'Base64' }
        @{ Field = 'size'; Case = 'string size'; Value = '1' }
        @{ Field = 'size'; Case = 'empty size'; Value = 0 }
        @{ Field = 'size'; Case = 'oversized'; Value = 65537 }
        @{ Field = 'content'; Case = 'array'; Value = @('e30=') }
    ) {
        $content[$Field] = $Value
        { Read-DevelopmentControl @arguments } | Should -Throw '*Invalid protected control content;*'
    }

    # Deliberately invalid scalar discriminators in an otherwise valid file response.
    It 'rejects array-valued file discriminator <Field>' -ForEach @(
        @{ Field = 'type' }; @{ Field = 'name' }; @{ Field = 'path' }
        @{ Field = 'sha' }; @{ Field = 'encoding' }
    ) {
        $content[$Field] = @($content[$Field])
        { Read-DevelopmentControl @arguments } | Should -Throw '*Invalid protected control content;*'
    }

    It 'rejects <Case> while preserving every other file invariant' -ForEach @(
        @{ Case = 'fractional size' }; @{ Case = 'oversized matching bytes' }; @{ Case = 'empty matching bytes' }
        @{ Case = 'array of matching base64' }; @{ Case = 'case changed matching object SHA' }
    ) {
        switch ($Case) {
            'fractional size' { $content.size = [double] $content.size + 0.0 }
            'oversized matching bytes' {
                $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $state -Compress).PadRight(65537))
                $content.content = [Convert]::ToBase64String($bytes); $content.size = $bytes.Length
            }
            'empty matching bytes' { $content.content = ''; $content.size = 0 }
            'array of matching base64' { $content.content = @($content.content) }
            'case changed matching object SHA' { $content.sha = $content.sha.ToUpperInvariant() }
        }
        { Read-DevelopmentControl @arguments } | Should -Throw '*Invalid protected control content;*'
    }

    It 'rejects a decoded length different from the declared file size' {
        $content.size++
        { Read-DevelopmentControl @arguments } | Should -Throw '*content size*'
    }

    It 'accepts a valid control document at the exact 64 KiB limit' {
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $state -Compress).PadRight(65536))
        $content.content = [Convert]::ToBase64String($bytes); $content.size = $bytes.Length
        (Read-DevelopmentControl @arguments).ControlRevision | Should -BeExactly ('c' * 40)
    }

    It 'rejects invalid base64 rather than returning an empty authorization record' {
        $content.content = '!not-base64!'
        { Read-DevelopmentControl @arguments } | Should -Throw '*Base-64*'
    }

    It 'rejects invalid UTF-8 rather than replacing bytes in protected state' {
        $content.content = '/w=='; $content.size = 1
        { Read-DevelopmentControl @arguments } | Should -Throw '*Unable to translate bytes*'
    }

    It 'rejects a control document <Case>' -ForEach @(
        @{ Case = 'array'; Json = '[{"version":1}]'; Error = '*must be an object*' }
        @{ Case = 'string version'; Json = '{"version":"1","reference":"","source":"","approval":"","disposition":""}'; Error = '*document version*' }
        @{ Case = 'fractional version'; Json = '{"version":1.0,"reference":"","source":"","approval":"","disposition":""}'; Error = '*document version*' }
        @{ Case = 'different version'; Json = '{"version":3,"reference":"","source":"","approval":"","disposition":""}'; Error = '*document version*' }
        @{ Case = 'duplicate field'; Json = '{"version":1,"reference":"","reference":"x","source":"","approval":"","disposition":""}'; Error = '*duplicate*' }
        @{ Case = 'case-folded duplicate'; Json = '{"version":1,"reference":"","Reference":"x","source":"","approval":"","disposition":""}'; Error = '*duplicate*' }
        @{ Case = 'non-string reference'; Json = '{"version":1,"reference":null,"source":"","approval":"","disposition":""}'; Error = "*requires string 'reference'*" }
        @{ Case = 'non-string source'; Json = '{"version":1,"reference":"","source":[],"approval":"","disposition":""}'; Error = "*requires string 'source'*" }
        @{ Case = 'non-string approval'; Json = '{"version":1,"reference":"","source":"","approval":{},"disposition":""}'; Error = "*requires string 'approval'*" }
        @{ Case = 'non-string disposition'; Json = '{"version":1,"reference":"","source":"","approval":"","disposition":false}'; Error = "*requires string 'disposition'*" }
    ) {
        $bytes = [Text.Encoding]::UTF8.GetBytes($Json)
        $content.content = [Convert]::ToBase64String($bytes)
        $content.size = $bytes.Length
        { Read-DevelopmentControl @arguments } | Should -Throw $Error
    }

    It 'reads the mandatory immutable journal for control v2 with the same reader identity' {
        Set-TestControlV2
        $result = Read-DevelopmentControl @arguments
        $result.ControlVersion | Should -Be 2
        $result.ControlBlobSha | Should -BeExactly $content.sha
        $result.TokenJournalPhase | Should -BeExactly 'clear'
        $result.TokenJournal | Should -BeExactly '{"version":1,"records":[]}'
        Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 1 -Exactly -ParameterFilter {
            $Uri -ceq ('https://api.example.test/repos/platform/instance/contents/development-token-journal.json?ref=' + ('c' * 40)) -and
            $Method -ceq 'GET'
        }
    }

    It 'proves the exact historical v1 reader accepts v1 and rejects v2' {
        $historical = Join-Path $PSScriptRoot 'fixtures/DevelopmentControlV1.psm1'
        # Exact tools/DevelopmentControl.psm1 at 480e86681e347718678494aed9dfe2590997a9c5.
        (Get-FileHash -LiteralPath $historical -Algorithm SHA256).Hash |
            Should -BeExactly 'F248138DC825BDCC90781BF7220055BFAA6FAF20206C193E863DCBE1C4778521'
        Import-Module $historical -Prefix Historical -Force
        try {
            Mock Invoke-WebRequest -ModuleName DevelopmentControlV1 {
                param($Uri)
                $body = if ($Uri -like '*/git/ref/heads/main') { $mainRef }
                    elseif ($Uri -like '*/git/ref/heads/platform-control') { $controlRef }
                    elseif ($Uri -like '*/git/trees/*') { $tree }
                    elseif ($Uri -like '*/contents/development-control.json`?*') { $content }
                    elseif ($Uri -like '*/rules/branches/platform-control`?*') { ,$rules }
                    elseif ($Uri -like '*/rulesets/42`?includes_parents=true') { $ruleset }
                    else { throw "Unexpected historical offline request: $Uri" }
                [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-Json $body -Depth 30 }
            }
            (Read-HistoricalDevelopmentControl @arguments).ControlRevision | Should -BeExactly ('c' * 40)
            Set-TestControlV2
            { Read-HistoricalDevelopmentControl @arguments } | Should -Throw '*Unsupported control document version*'
        }
        finally { Remove-Module DevelopmentControlV1 -Force }
    }

    It 'rejects a v1 downgrade while a lifecycle journal is present' {
        Set-TestControlV2
        $state.version = 1
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $state -Compress))
        $content.content = [Convert]::ToBase64String($bytes)
        $content.size = $bytes.Length
        { Read-DevelopmentControl @arguments } | Should -Throw '*journal requires protected control document v2*'
    }

    It 'requires an explicit protected writer before any read, mint or handoff without a workflow-token fallback' {
        $contextValue = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/development-token-context.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $context = New-DevelopmentTokenContext -Value $contextValue
        {
            Write-DevelopmentTokenEvent @arguments -WriterToken '' -RecoveryKey ([Convert]::ToBase64String([byte[]] (1..32))) `
                -Event pending -Context $context -ExpectedHead ('c' * 40) -ExpectedControlBlobSha $content.sha
        } | Should -Throw '*explicit protected control-ref writer*'
        Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 0
    }

    It 'does not issue from a legacy v1 control snapshot without a journal' {
        $value = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/development-token-context.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $value.authorizationBlob = $content.sha
        $value.authorizationRevision = 'c' * 40
        {
            Write-DevelopmentTokenEvent @arguments -WriterToken 'offline-writer' -RecoveryKey ([Convert]::ToBase64String([byte[]] (1..32))) `
                -Event pending -Context (New-DevelopmentTokenContext -Value $value) -ExpectedHead ('c' * 40) -ExpectedControlBlobSha $content.sha
        } | Should -Throw '*New token issuance requires protected control document v2*'
        Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 0 -ParameterFilter { $Method -ne 'GET' }
    }

    It 'rejects a journal copied from another <Field> at the protected reader boundary' -ForEach @(
        @{ Field = 'apiUrl'; Value = 'https://api.other.test' }
        @{ Field = 'repository'; Value = 'platform/other' }
    ) {
        $contextFields = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/development-token-context.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $contextFields[$Field] = $Value
        $journal = Add-DevelopmentTokenJournalEvent -Json (New-DevelopmentTokenJournal) -Event pending `
            -Context (New-DevelopmentTokenContext -Value $contextFields) -PreviousHead ('d' * 40)
        Set-TestControlV2 -Journal $journal
        { Read-DevelopmentControl @arguments } | Should -Throw '*journal origin or repository*'
    }

    It 'rejects control v2 without its journal before deployment credentials' {
        Set-TestControlV2
        $tree.tree = @($tree.tree | Where-Object path -CNE development-token-journal.json)
        { Read-DevelopmentControl @arguments } | Should -Throw '*development-token-journal.json*'
    }

    It 'rejects an unreadable or malformed v2 journal rather than assuming retirement' -ForEach @(
        @{ Json = '{}' }; @{ Json = 'null' }; @{ Json = '{"version":1,"records":null}' }
    ) {
        Set-TestControlV2 -Journal $Json
        { Read-DevelopmentControl @arguments } | Should -Throw
    }

    It 'rejects a missing version or <Field> field explicitly' -ForEach @(
        @{ Field = 'version' }; @{ Field = 'reference' }; @{ Field = 'source' }
        @{ Field = 'approval' }; @{ Field = 'disposition' }
    ) {
        $state.Remove($Field)
        $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $state -Compress))
        $content.content = [Convert]::ToBase64String($bytes)
        $content.size = $bytes.Length
        { Read-DevelopmentControl @arguments } | Should -Throw '*Control document requires*'
    }

    It 'requires active enterprise update and deletion rules from the same ruleset: <Case>' -ForEach @(
        @{ Case = 'no rules'; Action = 'none' }
        @{ Case = 'no update restriction'; Action = 'update' }
        @{ Case = 'no deletion restriction'; Action = 'deletion' }
        @{ Case = 'repository-only protection'; Action = 'repository' }
        @{ Case = 'organization-only protection'; Action = 'organization' }
        @{ Case = 'case changed source'; Action = 'case' }
        @{ Case = 'different rulesets'; Action = 'different' }
        @{ Case = 'string ruleset ID'; Action = 'string' }
        @{ Case = 'zero ruleset ID'; Action = 'zero' }
        @{ Case = 'non-list response'; Action = 'object' }
        @{ Case = 'array-valued source'; Action = 'arraySource' }
        @{ Case = 'array-valued rule type'; Action = 'arrayType' }
    ) {
        switch ($Action) {
            none { $rules = @() }
            update { $rules[0].type = 'non_fast_forward' }
            deletion { $rules[1].type = 'non_fast_forward' }
            repository { $ruleset.source_type = 'Repository' }
            organization { $ruleset.source_type = 'Organization' }
            case { $ruleset.source_type = 'enterprise' }
            different { $rules[1].ruleset_id = 43 }
            string { $rules[0].ruleset_id = '42' }
            zero { $rules[0].ruleset_id = 0 }
            object { $rules = @{} }
            arraySource { $ruleset.source_type = @('Enterprise') }
            arrayType { $rules[0].type = @('update', 'deletion') }
        }
        $message = if ($Action -in @('case', 'arraySource')) { '*control ruleset identity*' } else { '*enterprise update and deletion*' }
        { Read-DevelopmentControl @arguments } | Should -Throw $message
    }

    # Deliberately malformed or non-protecting variants of the documented ruleset response.
    It 'rejects enterprise control ruleset <Case>' -ForEach @(
        @{ Case = 'non-object' }; @{ Case = 'wrong ID' }; @{ Case = 'string ID' }
        @{ Case = 'wrong target' }; @{ Case = 'target case' }; @{ Case = 'array target' }; @{ Case = 'inactive' }
        @{ Case = 'enforcement case' }
        @{ Case = 'array enforcement' }; @{ Case = 'non-list rules' }; @{ Case = 'no update' }
        @{ Case = 'no deletion' }; @{ Case = 'array rule type' }; @{ Case = 'upstream updates allowed' }
        @{ Case = 'missing update parameters' }; @{ Case = 'unknown upstream update policy' }
    ) {
        switch ($Case) {
            'non-object' { $ruleset = @($ruleset) }
            'wrong ID' { $ruleset.id = 43 }
            'string ID' { $ruleset.id = '42' }
            'wrong target' { $ruleset.target = 'tag' }
            'target case' { $ruleset.target = 'Branch' }
            'array target' { $ruleset.target = @('branch') }
            'inactive' { $ruleset.enforcement = 'evaluate' }
            'enforcement case' { $ruleset.enforcement = 'Active' }
            'array enforcement' { $ruleset.enforcement = @('active') }
            'non-list rules' { $ruleset.rules = @{} }
            'no update' { $ruleset.rules[0].type = 'non_fast_forward' }
            'no deletion' { $ruleset.rules[1].type = 'non_fast_forward' }
            'array rule type' { $ruleset.rules[0].type = @('update') }
            'upstream updates allowed' { $ruleset.rules[0].parameters.update_allows_fetch_and_merge = $true }
            'missing update parameters' { $ruleset.rules[0].Remove('parameters') }
            'unknown upstream update policy' { $ruleset.rules[0].parameters.update_allows_fetch_and_merge = $null }
        }
        { Read-DevelopmentControl @arguments } | Should -Throw '*control*ruleset*'
    }

    Describe 'Control command' {
        BeforeEach {
            $command = @{
                Mode = 'development'; Repository = 'platform/instance'; ApiUrl = 'https://api.example.test'
                ServerUrl = 'https://example.test'; ReadToken = 'fake-token'; RunAttempt = '1'
                GitHubOutputPath = Join-Path $TestDrive "$([guid]::NewGuid()).txt"
            }
            $savedEnvironment = @{}
            foreach ($name in @('PLATFORM_REFERENCE_REPOSITORY', 'PLATFORM_DEVELOPMENT_APPROVAL', 'PLATFORM_DEVELOPMENT_DISPOSITION')) {
                $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
                [Environment]::SetEnvironmentVariable($name, $null)
            }
        }
        AfterEach {
            foreach ($name in $savedEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
            }
        }

        It 'exposes only the protected snapshot as single-line authorization outputs' {
            $result = & $controlCommand @command
            $result.ControlRevision | Should -BeExactly ('c' * 40)
            $output = Get-Content -LiteralPath $command.GitHubOutputPath
            $output.Count | Should -Be 5
            $output | Should -Contain 'reference=https://example.test/platform/instance'
            $output | Should -Contain 'approval={"revision":"approved"}'
        }

        It 'rejects invalid request <Field>: <Value> before sending the token' -ForEach @(
            @{ Field = 'Repository'; Value = 'platform/instance/extra' }
            @{ Field = 'ServerUrl'; Value = 'http://example.test' }
            @{ Field = 'ServerUrl'; Value = 'https://example.test:444' }
            @{ Field = 'ServerUrl'; Value = 'https://user@example.test' }
            @{ Field = 'ServerUrl'; Value = 'https://example.test?query' }
            @{ Field = 'ServerUrl'; Value = 'https://example.test#fragment' }
            @{ Field = 'ServerUrl'; Value = 'https://example.test/path' }
            @{ Field = 'ApiUrl'; Value = 'https://api.other.test' }
            @{ Field = 'ApiUrl'; Value = 'https://API.example.test' }
            @{ Field = 'ReadToken'; Value = ' ' }
        ) {
            $command[$Field] = $Value
            if ($Field -eq 'ServerUrl') { $command.ApiUrl = "https://api.$(([uri] $Value).DnsSafeHost)" }
            { & $controlCommand @command } | Should -Throw '*exact HTTPS Cloud API*'
            Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 0
        }

        It 'rejects reruns for a configured reference before publishing outputs' {
            $command.RunAttempt = '2'
            { & $controlCommand @command } | Should -Throw '*fresh dispatch*'
            Test-Path $command.GitHubOutputPath | Should -BeFalse
        }

        It 'blocks <Mode> while a protected token remains <Phase>' -ForEach @(
            @{ Mode = 'standard'; Phase = 'pending' }; @{ Mode = 'standard'; Phase = 'issued' }
            @{ Mode = 'development'; Phase = 'pending' }; @{ Mode = 'development'; Phase = 'issued' }
        ) {
            Import-Module (Join-Path $PSScriptRoot '../DevelopmentTokenLifecycle.psm1')
            $value = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/development-token-context.json') -Raw |
                ConvertFrom-Json -AsHashtable
            $context = New-DevelopmentTokenContext -Value $value
            $journal = Add-DevelopmentTokenJournalEvent -Json (New-DevelopmentTokenJournal) -Event pending `
                -Context $context -PreviousHead ('d' * 40)
            if ($Phase -ceq 'issued') {
                $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($context))).ToLowerInvariant()
                $envelope = Protect-DevelopmentLeafToken -Token 'offline-leaf' -ContextSha256 $digest `
                    -RecoveryKey ([Convert]::ToBase64String([byte[]] (1..32)))
                $journal = Add-DevelopmentTokenJournalEvent -Json $journal -Event issued -Context $context `
                    -PreviousHead ('3' * 40) -Envelope $envelope -IssuanceProbeStatusCode 200
            }
            Set-TestControlV2 -Journal $journal
            $command.Mode = $Mode
            { & $controlCommand @command } | Should -Throw '*Unfinished development token*'
            Test-Path $command.GitHubOutputPath | Should -BeFalse
        }

        It 'rejects a changed protected <Field> designation' -ForEach @(
            @{ Field = 'reference'; Value = 'https://example.test/other/instance' }
            @{ Field = 'reference'; Value = 'https://EXAMPLE.test/platform/instance' }
            @{ Field = 'source'; Value = '' }
            @{ Field = 'source'; Value = 'https://github.com/example/platform/extra' }
            @{ Field = 'source'; Value = 'HTTPS://github.com/example/platform' }
        ) {
            $state[$Field] = $Value
            $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $state -Compress))
            $content.content = [Convert]::ToBase64String($bytes); $content.size = $bytes.Length
            { & $controlCommand @command } | Should -Throw '*exact reference*'
        }

        It 'supports a whole-workflow rerun only for an explicitly allowed non-reference' {
            $status['https://api.example.test/repos/platform/instance/git/ref/heads/platform-control'] = 404
            $command.Mode = 'standard'
            $command.RunAttempt = '2'
            & $controlCommand @command -AllowNonReference | Should -BeNullOrEmpty
            Get-Content $command.GitHubOutputPath | Should -Contain 'reference='
        }

        It 'rejects output injection through a non-reference source using <Case>' -ForEach @(
            @{ Case = 'LF'; Newline = "`n" }; @{ Case = 'CR'; Newline = "`r" }
        ) {
            $savedSource = $env:PLATFORM_SOURCE_REPOSITORY
            try {
                $status['https://api.example.test/repos/platform/instance/git/ref/heads/platform-control'] = 404
                $command.Mode = 'standard'
                $env:PLATFORM_SOURCE_REPOSITORY = "https://github.com/example/platform${Newline}approval=injected"
                { & $controlCommand @command -AllowNonReference } | Should -Throw '*single-line*'
                Test-Path $command.GitHubOutputPath | Should -BeFalse
            }
            finally { $env:PLATFORM_SOURCE_REPOSITORY = $savedSource }
        }

        It 'does not let a missing control ref silently deactivate legacy reference designation <Variable>' -ForEach @(
            @{ Variable = 'PLATFORM_REFERENCE_REPOSITORY' }
            @{ Variable = 'PLATFORM_DEVELOPMENT_APPROVAL' }
            @{ Variable = 'PLATFORM_DEVELOPMENT_DISPOSITION' }
        ) {
            $status['https://api.example.test/repos/platform/instance/git/ref/heads/platform-control'] = 404
            $command.Mode = 'standard'
            [Environment]::SetEnvironmentVariable($Variable, 'configured')
            { & $controlCommand @command -AllowNonReference } | Should -Throw '*not an authorization fallback*'
        }

        It 'never allows development without protected reference state, including <Spelling>' -ForEach @(
            @{ Spelling = 'development' }; @{ Spelling = 'Development' }; @{ Spelling = 'DEVELOPMENT' }
        ) {
            $status['https://api.example.test/repos/platform/instance/git/ref/heads/platform-control'] = 404
            $command.Mode = $Spelling
            { & $controlCommand @command -AllowNonReference } | Should -Throw '*protected control ref*'
        }
    }

    Describe 'Protected credential boundary' {
        BeforeEach {
            $approval = @{
                version = 1L; repository = 'https://example.test/platform/instance'
                baseRevision = 'a' * 40; revision = 'b' * 40; digest = 'c' * 64; pullRequest = '42'
                operation = 'apply'; approvedBy = 'reviewer'; approvalUrl = 'https://example.test/approval/1'
                expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
            }
            $state.approval = ConvertTo-Json $approval
            $bytes = [Text.Encoding]::UTF8.GetBytes((ConvertTo-Json $state -Compress))
            $content.content = [Convert]::ToBase64String($bytes)
            $content.size = $bytes.Length
            $phaseCommand = Join-Path $PSScriptRoot '../Test-DevelopmentProtectedState.ps1'
            $phaseArguments = @{
                Mode = 'development'; ExpectedReference = $state.reference; ExpectedControlRevision = 'c' * 40
                ExpectedApproval = $state.approval; ExpectedSourceRepository = $state.source; ExpectedAttempt = '1'
                Repository = 'platform/instance'; ServerUrl = 'https://example.test'; ApiUrl = 'https://api.example.test'
                Revision = 'a' * 40; EventName = 'workflow_dispatch'; RunAttempt = '1'; ReadToken = 'fake-token'
            }
        }

        It 'revalidates current authorization using only GETs with the existing job token' {
            { & $phaseCommand @phaseArguments 6>$null } | Should -Not -Throw
            Should -Invoke Invoke-WebRequest -ModuleName DevelopmentControl -Times 7 -Exactly -ParameterFilter {
                $Method -ceq 'GET' -and $Headers.Authorization -ceq 'Bearer fake-token'
            }
        }

        It 'requires the exact authorization snapshot after an environment wait: <Field>' -ForEach @(
            @{ Field = 'ExpectedControlRevision'; Value = 'd' * 40 }
            @{ Field = 'ExpectedControlRevision'; Value = '' }
            @{ Field = 'ExpectedControlRevision'; Value = 'C' * 40 }
            @{ Field = 'ExpectedReference'; Value = 'https://example.test/platform/other' }
            @{ Field = 'ExpectedReference'; Value = 'https://EXAMPLE.test/platform/instance' }
            @{ Field = 'ExpectedSourceRepository'; Value = 'https://github.com/example/other' }
        ) {
            $phaseArguments[$Field] = $Value
            { & $phaseCommand @phaseArguments 6>$null } | Should -Throw '*changed*'
        }

        It 'rejects a revoked or replaced expected approval for <Spelling>' -ForEach @(
            @{ Spelling = 'development' }; @{ Spelling = 'Development' }; @{ Spelling = 'DEVELOPMENT' }
        ) {
            $phaseArguments.Mode = $Spelling
            $phaseArguments.ExpectedApproval = '{"revision":"not-current"}'
            { & $phaseCommand @phaseArguments 6>$null } | Should -Throw '*revoked or replaced*'
        }

        It 'rejects a stale authorized attempt' {
            $phaseArguments.ExpectedAttempt = '2'
            { & $phaseCommand @phaseArguments 6>$null } | Should -Throw '*fresh dispatch*'
        }

        It 'does not treat disappeared <Designation> as a non-reference' -ForEach @(
            @{ Designation = 'reference only'; Clear = 'ExpectedControlRevision' }
            @{ Designation = 'control revision only'; Clear = 'ExpectedReference' }
            @{ Designation = 'both values'; Clear = '' }
        ) {
            $status['https://api.example.test/repos/platform/instance/git/ref/heads/platform-control'] = 404
            $phaseArguments.Mode = 'standard'
            if ($Clear) { $phaseArguments[$Clear] = '' }
            { & $phaseCommand @phaseArguments 6>$null } | Should -Throw '*disappeared*'
        }

        It 'requires a standard disposition instead of silently adopting outstanding development' {
            $phaseArguments.Mode = 'standard'
            { & $phaseCommand @phaseArguments 6>$null } | Should -Throw '*locked*'
        }
    }
}
