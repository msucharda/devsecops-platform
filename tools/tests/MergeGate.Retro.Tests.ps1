BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../agents/MergeGate.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'MergeGateStub.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force

    function Invoke-RetroGate {
        param([hashtable] $Parameters = @{})

        Invoke-MergeGate -Repository 'msucharda/devsecops-platform' -Pr $stub.Number -Now $stub.Now @Parameters
    }

    function Invoke-RetroCli {
        param([string] $Acknowledgement = '', [switch] $Merge)

        $directory = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) "artifacts/g12-cli-$([guid]::NewGuid().ToString('N'))"
        $null = New-Item -ItemType Directory -Path $directory -Force
        $state = @{}
        foreach ($key in @('PullRequest', 'RestPullRequest', 'Retro', 'Files', 'Trees', 'Contents', 'Responses', 'Failures', 'TreeRefs', 'Compare')) { $state[$key] = $stub[$key] }
        try {
            $statePath = Join-Path $directory 'state.json'
            $state | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $statePath
            $output = & pwsh -NoProfile -File (Join-Path $PSScriptRoot 'Invoke-MergeGateStubCli.ps1') `
                -StatePath $statePath -TracePath (Join-Path $directory 'trace.json') `
                -RetroAcknowledgedSha $Acknowledgement -Merge:$Merge 2>$null
            @{ ExitCode = $LASTEXITCODE; Result = ($output -join "`n" | ConvertFrom-Json -AsHashtable) }
        }
        finally { Remove-Item -LiteralPath $directory -Recurse -Force }
    }
}

Describe 'Merge gate G12' {
    BeforeEach {
        $stub = Initialize-MergeGateStub -Scenario pr-78
        $stub.Retro = $null
        Mock -ModuleName MergeGate Invoke-MergeGateGh { Invoke-MergeGateStub -Stub $stub -Arguments $Arguments }
    }

    It 'G12 refuses a pull request without an added retrospective' {
        $result = Invoke-RetroGate

        $result.verdict | Should -Be 'fail'
        $result.reasons.code | Should -Contain 'retro-missing'
    }

    It 'G12 accepts a retrospective added in the pinned head tree with the matching PR' {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Files = @()
        $result = Invoke-RetroGate

        $result.verdict | Should -Be 'pass'
        $result.details.retro.path | Should -Be 'docs/agents/retros/2026-11-06-test-session.md'
        @($stub.Calls | Where-Object { $_[-1] -match '/contents/docs/agents/retros/' })[0][-1] |
            Should -Match "\\?ref=$($stub.PullRequest.headRefOid)$"
    }

    It 'G12 rejects invalid frontmatter: <Case>' -ForEach @(
        @{ Case = 'quoted PR'; From = 'pr: 78'; To = 'pr: "78"'; Error = "'pr'.*positive integer" }
        @{ Case = 'boolean PR'; From = 'pr: 78'; To = 'pr: true'; Error = "'pr'.*positive integer" }
        @{ Case = 'null PR'; From = 'pr: 78'; To = 'pr: null'; Error = "'pr'.*positive integer" }
        @{ Case = 'floating PR'; From = 'pr: 78'; To = 'pr: 78.0'; Error = "'pr'.*positive integer" }
        @{ Case = 'zero PR'; From = 'pr: 78'; To = 'pr: 0'; Error = "'pr'.*positive integer" }
        @{ Case = 'negative PR'; From = 'pr: 78'; To = 'pr: -78'; Error = "'pr'.*positive integer" }
        @{ Case = 'another PR'; From = 'pr: 78'; To = 'pr: 79'; Error = 'PR number does not match' }
        @{ Case = 'missing PR'; From = "pr: 78`n"; To = ''; Error = "missing 'pr'" }
        @{ Case = 'missing session'; From = "session: test-session`n"; To = ''; Error = "missing 'session'" }
        @{ Case = 'missing issue'; From = "issue: 227`n"; To = ''; Error = "missing 'issue'" }
        @{ Case = 'missing date'; From = "date: `"2026-11-06`"`n"; To = ''; Error = "missing 'date'" }
        @{ Case = 'missing model'; From = "model: test-model`n"; To = ''; Error = "missing 'model'" }
        @{ Case = 'empty session'; From = 'session: test-session'; To = 'session: ""'; Error = "'session'.*nonempty string" }
        @{ Case = 'boolean session'; From = 'session: test-session'; To = 'session: true'; Error = "'session'.*nonempty string" }
        @{ Case = 'empty model'; From = 'model: test-model'; To = 'model: ""'; Error = "'model'.*nonempty string" }
        @{ Case = 'null model'; From = 'model: test-model'; To = 'model: null'; Error = "'model'.*nonempty string" }
        @{ Case = 'numeric model'; From = 'model: test-model'; To = 'model: 123'; Error = "'model'.*nonempty string" }
        @{ Case = 'zero issue'; From = 'issue: 227'; To = 'issue: 0'; Error = "'issue'.*positive integer" }
        @{ Case = 'quoted issue'; From = 'issue: 227'; To = 'issue: "227"'; Error = "'issue'.*positive integer" }
        @{ Case = 'plain date'; From = 'date: "2026-11-06"'; To = 'date: 2026-11-06'; Error = 'quoted calendar date' }
        @{ Case = 'invalid calendar date'; From = 'date: "2026-11-06"'; To = 'date: "2026-02-30"'; Error = 'quoted calendar date' }
        @{ Case = 'date differs from filename'; From = 'date: "2026-11-06"'; To = 'date: "2026-11-07"'; Error = 'filename.*date and session' }
        @{ Case = 'session differs from filename'; From = 'session: test-session'; To = 'session: another-session'; Error = 'filename.*date and session' }
        @{ Case = 'session case differs from filename'; From = 'session: test-session'; To = 'session: Test-session'; Error = 'filename.*date and session' }
        @{ Case = 'session with slash'; From = 'session: test-session'; To = 'session: test/session'; Error = 'path separator' }
        @{ Case = 'session with backslash'; From = 'session: test-session'; To = 'session: test\session'; Error = 'path separator' }
        @{ Case = 'sequence'; From = 'pr: 78'; To = 'pr: [78]'; Error = 'scalar' }
        @{ Case = 'mapping'; From = 'pr: 78'; To = 'pr: {number: 78}'; Error = 'scalar' }
        @{ Case = 'duplicate key'; From = 'pr: 78'; To = "pr: 78`npr: 78"; Error = 'duplicate|same key' }
        @{ Case = 'YAML tag'; From = 'pr: 78'; To = 'pr: !!int 78'; Error = 'tags, anchors or aliases' }
        @{ Case = 'YAML anchor'; From = 'pr: 78'; To = 'pr: &number 78'; Error = 'tags, anchors or aliases' }
        @{ Case = 'YAML alias'; From = 'pr: 78'; To = "other: &number 78`npr: *number"; Error = 'tags, anchors or aliases' }
        @{ Case = 'malformed YAML'; From = 'pr: 78'; To = 'pr: ['; Error = 'YAML|node|flow' }
        @{ Case = 'missing opening delimiter'; From = "---`nsession:"; To = 'session:'; Error = 'leading YAML frontmatter' }
        @{ Case = 'missing closing delimiter'; From = "`n---`n#"; To = "`n#"; Error = 'leading YAML frontmatter' }
        @{ Case = 'uppercase UUID'; From = 'session: test-session'; To = 'session: "00000000-0000-4000-8000-ABCDEF012345"'; Error = 'UUID session must be lowercase' }
        @{ Case = 'non-scalar key'; From = 'pr: 78'; To = '? [pr] : 78'; Error = 'scalars' }
    ) {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Retro.Content = $stub.Retro.Content.Replace($From, $To)
        $result = Invoke-RetroGate

        $result.reasons.code | Should -Contain 'retro-invalid'
        $result.details.retro.errors[$stub.Retro.Path] | Should -Match $Error
    }

    It 'G12 accepts a UTF-8 BOM before valid frontmatter' {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Retro.Content = [char] 0xfeff + $stub.Retro.Content
        (Invoke-RetroGate).verdict | Should -Be 'pass'
    }

    It 'G12 rejects a non-regular retrospective entry: <Mode>' -ForEach @(@{ Mode = '120000' }, @{ Mode = '160000' }) {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Retro.Mode = $Mode
        if ($Mode -eq '160000') {
            $head = $stub.PullRequest.headRefOid
            $stub.Retro = $null
            $stub.Trees[$head] = Get-GitHubApiFixture -Name 'git/get-tree' -Set @{
                sha = $stub.TreeRefs[$head]; 'tree.0.path' = 'docs/agents/retros/2026-11-06-test-session.md'
                'tree.0.type' = 'commit'; 'tree.0.mode' = '160000'
            }
        }
        $result = Invoke-RetroGate
        $result.reasons.code | Should -Contain 'retro-invalid'
        @($result.details.retro.errors.Values)[0] | Should -Match 'regular file'
    }

    It 'G12 accepts the explicit waiver <Reason> with a warning but no acknowledgement' -ForEach @(
        @{ Reason = 'bootstrap' }, @{ Reason = 'human' }, @{ Reason = 'distillation' }
    ) {
        $stub.PullRequest.body += "`n<!-- retro: none $Reason -->"
        $result = Invoke-RetroGate

        $result.verdict | Should -Be 'pass'
        $result.warnings.code | Should -Contain 'retro-waived'
        $result.details.retro.waiverReason | Should -Be $Reason
        $result.details.retro.acknowledgedFor | Should -BeNullOrEmpty
    }

    It 'G12 rejects malformed or ambiguous waiver markers: <Case>' -ForEach @(
        @{ Case = 'unknown reason'; Marker = '<!-- retro: none other -->' }
        @{ Case = 'empty reason'; Marker = '<!-- retro: none -->' }
        @{ Case = 'reason case'; Marker = '<!-- retro: none Bootstrap -->' }
        @{ Case = 'keyword case'; Marker = '<!-- RETRO: none bootstrap -->' }
        @{ Case = 'none case'; Marker = '<!-- retro: None bootstrap -->' }
        @{ Case = 'two valid markers'; Marker = '<!-- retro: none bootstrap --><!-- retro: none human -->' }
        @{ Case = 'extra uppercase marker'; Marker = '<!-- retro: none bootstrap --><!-- RETRO: none human -->' }
        @{ Case = 'extra malformed marker'; Marker = '<!-- retro: none bootstrap --><!-- retro: none -->' }
        @{ Case = 'extra reason text'; Marker = '<!-- retro: none human explanation -->' }
        @{ Case = 'unfinished marker'; Marker = '<!-- retro: none bootstrap' }
        @{ Case = 'unknown declaration'; Marker = '<!-- retro: approved -->' }
    ) {
        $stub.PullRequest.body += "`n$Marker"
        $result = Invoke-RetroGate

        $result.reasons.code | Should -Contain 'retro-invalid'
        $result.details.retro.error | Should -Match 'exactly one.*waiver marker'
    }

    It 'G12 exempts Dependabot only with its exact Bot author identity' {
        $stub.RestPullRequest.user.login = 'dependabot[bot]'
        $stub.RestPullRequest.user.type = 'Bot'
        $result = Invoke-RetroGate

        $result.verdict | Should -Be 'pass'
        $result.details.retro.exemptAuthor | Should -Be 'dependabot[bot]'
        $result.warnings.code | Should -Not -Contain 'retro-waived'
    }

    It 'G12 requires a retrospective for a non-Dependabot author: <Case>' -ForEach @(
        @{ Case = 'different bot'; Login = 'another[bot]'; Type = 'Bot' }
        @{ Case = 'login case'; Login = 'Dependabot[bot]'; Type = 'Bot' }
        @{ Case = 'type case'; Login = 'dependabot[bot]'; Type = 'bot' }
        @{ Case = 'user named Dependabot'; Login = 'dependabot[bot]'; Type = 'User' }
        @{ Case = 'GraphQL login on REST'; Login = 'dependabot'; Type = 'Bot' }
    ) {
        $stub.RestPullRequest.user.login = $Login
        $stub.RestPullRequest.user.type = $Type
        (Invoke-RetroGate).reasons.code | Should -Contain 'retro-missing'
    }

    It 'G12 fails closed on malformed or mismatched author snapshot: <Case>' -ForEach @(
        @{ Case = 'missing author'; Field = 'user'; Value = $null; Error = 'author.*object' }
        @{ Case = 'empty login'; Field = 'user.login'; Value = ''; Error = "author.*login" }
        @{ Case = 'null login'; Field = 'user.login'; Value = $null; Error = "author.*login" }
        @{ Case = 'non-string login'; Field = 'user.login'; Value = 1; Error = "author.*login" }
        @{ Case = 'empty type'; Field = 'user.type'; Value = ''; Error = "author.*type" }
        @{ Case = 'null type'; Field = 'user.type'; Value = $null; Error = "author.*type" }
        @{ Case = 'wrong head'; Field = 'head.sha'; Value = 'a' * 40; Error = 'author snapshot.*head' }
        @{ Case = 'head case'; Field = 'head.sha'; Value = '5A86D28AA232FFF72AF137C29C1ABD9E75F398A3'; Error = 'author snapshot.*head' }
        @{ Case = 'wrong PR'; Field = 'number'; Value = 79; Error = 'author snapshot.*number' }
        @{ Case = 'quoted PR'; Field = 'number'; Value = '78'; Error = 'author snapshot.*number' }
        @{ Case = 'missing head'; Field = 'head'; Value = $null; Error = 'author snapshot.*head' }
    ) {
        # Deliberately malformed API responses test fail-closed identity verification.
        $parts = $Field.Split('.')
        $node = $stub.RestPullRequest
        for ($i = 0; $i -lt $parts.Count - 1; $i++) { $node = $node[$parts[$i]] }
        $node[$parts[-1]] = $Value
        $result = Invoke-RetroGate

        $result.reasons.code | Should -Contain 'evaluation-error'
        $result.reasons[0].message | Should -Match $Error
    }

    It 'G12 merge refuses a waived retrospective without acknowledgement for the current head: <Case>' -ForEach @(
        @{ Case = 'missing'; Ack = '' }, @{ Case = 'stale'; Ack = 'a' * 40 }
    ) {
        $stub.PullRequest.body += "`n<!-- retro: none human -->"
        $result = Invoke-GatedMerge -Repository 'msucharda/devsecops-platform' -Pr 78 `
            -ExpectedHeadSha $stub.PullRequest.headRefOid -Reason 'test consent' -Now $stub.Now -AcknowledgeRetroWaiver $Ack

        $result.gate.verdict | Should -Be 'pass'
        $result.reason | Should -Be 'retro-waiver-unacknowledged'
        $result.exitCode | Should -Be 1
        $stub.Merges | Should -Be 0
    }

    It 'G12 merge accepts acknowledgement of a waiver for the current head and records it' {
        $stub.PullRequest.body += "`n<!-- retro: none bootstrap -->"
        $result = Invoke-GatedMerge -Repository 'msucharda/devsecops-platform' -Pr 78 `
            -ExpectedHeadSha $stub.PullRequest.headRefOid -Reason 'test consent' -Now $stub.Now `
            -AcknowledgeRetroWaiver $stub.PullRequest.headRefOid.ToUpperInvariant()

        $result.exitCode | Should -Be 0
        $result.gate.details.retro.acknowledgedFor | Should -Be $stub.PullRequest.headRefOid
        $stub.Merges | Should -Be 1
    }

    It 'G12 validates acknowledgement syntax before any API call' {
        $result = Invoke-RetroGate -Parameters @{ AcknowledgeRetroWaiver = 'bad' }
        $result.exitCode | Should -Be 4
        $stub.Calls.Count | Should -Be 0
    }

    It 'G12 requires an exactly cased retrospective path: <Path>' -ForEach @(
        @{ Path = 'Docs/agents/retros/2026-11-06-test-session.md' }
        @{ Path = 'docs/agents/Retros/2026-11-06-test-session.md' }
        @{ Path = 'docs/agents/retros/2026-11-06-test-session.MD' }
        @{ Path = 'docs/agents/retros/2026-11-06-test-session.md/extra' }
        @{ Path = 'docs/agents/retros/sub/2026-11-06-test-session.md' }
        @{ Path = 'docs/agents/retros/2026-11-06-.md' }
        @{ Path = 'docs/agents/retros/2026-1-6-test-session.md' }
        @{ Path = 'docs/agents/retros/README.md' }
        @{ Path = 'docs/agents/retros/candidates.md' }
    ) {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Retro.Path = $Path
        (Invoke-RetroGate).reasons.code | Should -Contain 'retro-missing'
    }

    It 'G12 does not count a modified retrospective already present at the merge base' {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $base = $stub.PullRequest.baseRefOid
        $stub.Trees[$base] = Get-GitHubApiFixture -Name 'git/get-tree' -Set @{
            sha = $stub.TreeRefs[$base]; 'tree.0.path' = $stub.Retro.Path
        }
        (Invoke-RetroGate).reasons.code | Should -Contain 'retro-missing'
    }

    It 'G12 rejects documented non-file content variant <Variant>' -ForEach @(
        @{ Variant = 'directory' }, @{ Variant = 'symlink' }, @{ Variant = 'submodule' }
    ) {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $response = Get-GitHubApiFixture -Name "repos/get-content.$Variant"
        $stub.Responses['/contents/docs/agents/retros/'] = ConvertTo-Json -InputObject $response -Depth 50
        $result = Invoke-RetroGate
        $result.reasons.code | Should -Contain 'retro-invalid'
        $result.details.retro.errors[$stub.Retro.Path] | Should -Match 'not a file object|not an inline base64 file'
    }

    It 'G12 rejects an invalid content snapshot: <Case>' -ForEach @(
        @{ Case = 'wrong blob SHA'; Set = @{ sha = 'a' * 40 }; Error = 'blob SHA' }
        @{ Case = 'uppercase blob SHA'; Set = @{ sha = 'F' * 40 }; Error = 'blob SHA' }
        @{ Case = 'missing blob SHA'; Set = @{ sha = $null }; Error = 'blob SHA' }
        @{ Case = 'wrong path'; Set = @{ path = 'README.md' }; Error = 'Content path' }
        @{ Case = 'path case'; Set = @{ path = 'docs/agents/RETROS/2026-11-06-test-session.md' }; Error = 'Content path' }
        @{ Case = 'encoding case'; Set = @{ encoding = 'BASE64' }; Error = 'inline base64' }
        @{ Case = 'unavailable content'; Set = @{ encoding = 'none' }; Error = 'inline base64' }
        @{ Case = 'type case'; Set = @{ type = 'FILE' }; Error = 'inline base64' }
        @{ Case = 'missing content'; Set = @{ content = $null }; Error = 'inline base64' }
        @{ Case = 'invalid base64'; Set = @{ content = '***' }; Error = 'Base-64' }
        @{ Case = 'invalid UTF-8'; Set = @{ content = '/w==' }; Error = 'Unable to translate' }
    ) {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $values = @{
            path = $stub.Retro.Path; sha = 'f' * 40
            content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($stub.Retro.Content))
        }
        foreach ($key in $Set.Keys) { $values[$key] = $Set[$key] }
        # Deliberately malformed snapshots vary one field from the documented file response.
        $response = Get-GitHubApiFixture -Name 'repos/get-content.file' -Set $values
        $stub.Responses['/contents/docs/agents/retros/'] = ConvertTo-Json -InputObject $response -Depth 50
        $result = Invoke-RetroGate

        $result.reasons.code | Should -Contain 'retro-invalid'
        $result.details.retro.errors[$stub.Retro.Path] | Should -Match $Error
    }

    It 'G12 rejects an unreadable retrospective without falling back to success' {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Failures['/contents/docs/agents/retros/'] = 'HTTP 403'
        $result = Invoke-RetroGate
        $result.reasons.code | Should -Contain 'retro-invalid'
        $result.details.retro.errors[$stub.Retro.Path] | Should -Match 'HTTP 403'
    }

    It 'G12 rejects invalid frontmatter document structure: <Case>' -ForEach @(
        @{ Case = 'empty YAML'; Yaml = ''; Error = 'exactly one document' }
        @{ Case = 'scalar root'; Yaml = '78'; Error = 'mapping root' }
        @{ Case = 'sequence root'; Yaml = '- 78'; Error = 'mapping root' }
    ) {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Retro.Content = "---`n$Yaml`n---`n"
        $result = Invoke-RetroGate
        $result.reasons.code | Should -Contain 'retro-invalid'
        $result.details.retro.errors[$stub.Retro.Path] | Should -Match $Error
    }

    It 'G12 accepts a retrospective with CRLF, quoted string fields and executable regular mode' {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Retro.Mode = '100755'
        $stub.Retro.Content = $stub.Retro.Content.Replace('session: test-session', 'session: "test-session"').
            Replace('date: "2026-11-06"', "date: '2026-11-06'").Replace("`n", "`r`n")
        (Invoke-RetroGate).verdict | Should -Be 'pass'
    }

    It 'G12 author contract rejects an incoherent body snapshot: <Case>' -ForEach @(
        @{ Case = 'changed body'; Body = 'changed'; Error = 'mismatched body' }
        @{ Case = 'non-string body'; Body = 78; Error = 'invalid body' }
    ) {
        # Deliberately malformed snapshot: only body differs from the valid fixture.
        $response = $stub.RestPullRequest.Clone()
        $response.body = $Body
        $stub.Responses['/pulls/\d+$'] = ConvertTo-Json -InputObject $response -Depth 50
        $result = Invoke-RetroGate
        $result.reasons.code | Should -Contain 'evaluation-error'
        $result.reasons[0].message | Should -Match $Error
    }

    It 'G12 author contract accepts the documented null REST body for an empty GraphQL body' {
        $stub.PullRequest.body = ''
        $response = $stub.RestPullRequest.Clone()
        $response.body = $null
        $response.user.login = 'dependabot[bot]'
        $response.user.type = 'Bot'
        $stub.Responses['/pulls/\d+$'] = ConvertTo-Json -InputObject $response -Depth 50
        (Invoke-RetroGate).verdict | Should -Be 'pass'
    }

    It 'G12 author contract rejects a body snapshot differing only in case' {
        $response = $stub.RestPullRequest.Clone()
        $response.body = $stub.PullRequest.body.ToUpperInvariant()
        $stub.Responses['/pulls/\d+$'] = ConvertTo-Json -InputObject $response -Depth 50
        $result = Invoke-RetroGate
        $result.reasons.code | Should -Contain 'evaluation-error'
        $result.reasons[0].message | Should -Match 'mismatched body'
    }

    It 'G12 author contract rejects a missing required REST body even when GraphQL body is empty' {
        $stub.PullRequest.body = ''
        $response = $stub.RestPullRequest.Clone()
        $response.user.login = 'dependabot[bot]'
        $response.user.type = 'Bot'
        # Deliberately invalid response: body is required and nullable, not optional.
        $null = $response.Remove('body')
        $stub.Responses['/pulls/\d+$'] = ConvertTo-Json -InputObject $response -Depth 50
        $result = Invoke-RetroGate
        $result.verdict | Should -Be 'fail'
        $result.reasons[0].message | Should -Match 'missing.*body'
    }

    It 'G12 accepts matching metadata without evaluating the retrospective body' {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $stub.Retro.Content = $stub.Retro.Content.Replace("# Retrospektiva session", '')
        (Invoke-RetroGate).verdict | Should -Be 'pass'
    }

    It 'G12 merge also accepts a non-waived retrospective without acknowledgement' {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        $result = Invoke-GatedMerge -Repository 'msucharda/devsecops-platform' -Pr 78 `
            -ExpectedHeadSha $stub.PullRequest.headRefOid -Reason 'test consent' -Now $stub.Now
        $result.exitCode | Should -Be 0
    }

    It 'G12 acknowledgement contract fails closed: <Case>' -ForEach @(
        @{ Case = 'missing details'; Gate = @{ headSha = 'a' * 40 }; Expected = $false }
        @{ Case = 'missing declaration'; Gate = @{ headSha = 'a' * 40; details = @{ retro = @{} } }; Expected = $false }
        @{ Case = 'unknown reason'; Gate = @{ headSha = 'a' * 40; details = @{ retro = @{ waiverReason = 'other'; acknowledgedFor = 'a' * 40 } } }; Expected = $false }
        @{ Case = 'reason case'; Gate = @{ headSha = 'a' * 40; details = @{ retro = @{ waiverReason = 'Human'; acknowledgedFor = 'a' * 40 } } }; Expected = $false }
        @{ Case = 'acknowledgement case'; Gate = @{ headSha = 'a' * 40; details = @{ retro = @{ waiverReason = 'human'; acknowledgedFor = 'A' * 40 } } }; Expected = $false }
        @{ Case = 'empty declaration'; Gate = @{ headSha = 'a' * 40; details = @{ retro = @{ waiverReason = ''; acknowledgedFor = 'a' * 40 } } }; Expected = $false }
    ) {
        InModuleScope MergeGate -Parameters $_ { Test-MergeGateRetroWaiverAcknowledged -Gate $Gate | Should -Be $Expected }
    }

    It 'G12 CLI records head-pinned acknowledgement during read-only evaluation' {
        $stub.PullRequest.body += "`n<!-- retro: none distillation -->"
        $result = Invoke-RetroCli -Acknowledgement $stub.PullRequest.headRefOid.ToUpperInvariant()
        $result.ExitCode | Should -Be 0
        $result.Result.details.retro.acknowledgedFor | Should -Be $stub.PullRequest.headRefOid
        $result.Result.warnings.code | Should -Contain 'retro-waived'
    }

    It 'G12 CLI refuses a merge with a waiver and no acknowledgement' {
        $stub.PullRequest.body += "`n<!-- retro: none human -->"
        $result = Invoke-RetroCli -Merge
        $result.ExitCode | Should -Be 1
        $result.Result.reason | Should -Be 'retro-waiver-unacknowledged'
    }

    It 'G12 CLI merges a waived PR only with acknowledgement for the current head' {
        $stub.PullRequest.body += "`n<!-- retro: none human -->"
        $result = Invoke-RetroCli -Merge -Acknowledgement $stub.PullRequest.headRefOid
        $result.ExitCode | Should -Be 0
        $result.Result.action | Should -Be 'merged'
        $result.Result.postVerify.verified | Should -BeTrue
    }

    It 'G12 rejects a body edit made during the pinned content read' {
        $stub.Retro = (Initialize-MergeGateStub -Scenario pr-78).Retro
        Mock -ModuleName MergeGate Invoke-MergeGateGh {
            $response = Invoke-MergeGateStub -Stub $stub -Arguments $Arguments
            if ($Arguments[-1] -match '/contents/docs/agents/retros/') { $stub.PullRequest.body += "`n<!-- retro: none human -->" }
            $response
        }
        $result = Invoke-RetroGate
        $result.reasons.code | Should -Contain 'evaluation-error'
        $result.reasons[0].message | Should -Match 'head, base or body changed'
    }
}
