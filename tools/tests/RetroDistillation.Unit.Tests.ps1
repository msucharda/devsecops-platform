BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $publisher = Join-Path $PSScriptRoot '..\agents\Invoke-RetroDistillation.ps1'
    function git {
        param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
        $global:LASTEXITCODE = 0
        if ($Arguments -contains 'get-url') {
            if ($Arguments -contains '--push') { return $state.PushUrls }
            return $state.FetchUrls
        }
        if ($Arguments -contains 'fetch' -or $Arguments -contains 'merge-base' -or
            $Arguments -contains 'status') { return }
        if ($Arguments -contains 'add' -or $Arguments -contains 'switch') { $state.Writes++; return }
        if ($Arguments -contains 'rev-parse') {
            if ($Arguments[-1] -ceq 'HEAD') { return $state.Head }
            return $state.Source
        }
        if ($Arguments -contains 'ls-remote') {
            if ($state.Remote) { return "$($state.Commit)`trefs/heads/$($state.Branch)" }
            return
        }
        if ($Arguments -contains 'ls-tree') {
            if ($Arguments -contains '-r') { return $state.Retrospectives }
            return "$($state.FileMode) blob $($state.Tree)`t$($Arguments[-1])"
        }
        if ($Arguments -contains 'rev-list') { return $state.Parents }
        if ($Arguments -contains 'show') {
            if ($Arguments -contains '--format=%B') { return $state.Message }
            if ($Arguments[-1].StartsWith($state.Source + ':', [StringComparison]::Ordinal)) { return '# Original' }
            return $state.Agents
        }
        if ($Arguments -contains 'diff') {
            if ($Arguments -contains '--name-status') { return $state.Diff }
            return
        }
        if ($Arguments -contains 'write-tree') { return $state.Tree }
        if ($Arguments -contains 'commit') { $state.Writes++; $state.Head = $state.Commit; return }
        if ($Arguments -contains 'push') { $state.Writes++; $state.Remote = $true; return }
        throw "Unexpected Git boundary: $($Arguments -join ' ')"
    }
    function gh {
        param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
        $global:LASTEXITCODE = $state.ApiExit
        if ($Arguments -contains 'GET') {
            if ($null -ne $state.RawPages) { return $state.RawPages }
            return ConvertTo-Json -InputObject ([object[]] @(,$state.Pulls)) -Depth 100 -Compress
        }
        $state.Writes++
        $set = @{
            number = 1; html_url = 'https://github.com/msucharda/devsecops-platform/pull/1'
            state = 'open'; 'head.ref' = $state.Branch; 'head.sha' = $state.Commit
            'head.repo.full_name' = 'msucharda/devsecops-platform'
            'base.ref' = 'main'; 'base.repo.full_name' = 'msucharda/devsecops-platform'
            body = $state.Body
        }
        $created = Get-GitHubApiFixture -Name pulls/create -Set $set
        foreach ($key in $state.Creation.Keys) {
            $parts = $key.Split('.')
            $node = $created
            for ($index = 0; $index -lt $parts.Count - 1; $index++) { $node = $node[$parts[$index]] }
            $node[$parts[-1]] = $state.Creation[$key]
        }
        return $created | ConvertTo-Json -Depth 100 -Compress
    }
    function pwsh {
        param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
        $null = $Arguments
        $global:LASTEXITCODE = 0
    }
    function Get-ListedPull {
        $fixture = Get-GitHubApiFixture -Name pulls/list -Set @{
            '0.head.ref' = $state.Branch; '0.head.sha' = $state.Commit
            '0.head.repo.full_name' = 'msucharda/devsecops-platform'
            '0.base.ref' = 'main'; '0.base.repo.full_name' = 'msucharda/devsecops-platform'
            '0.state' = 'open'; '0.merged_at' = $null; '0.body' = $state.Body
        }
        return $fixture[0]
    }
}

Describe 'Distillation security at process boundaries' {
    BeforeEach {
        $source = 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'
        $commit = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'
        $body = "## Zdroj`n$source`n## Otevřené otázky`nŽádné`n<!-- retro: none distillation -->`n<!-- distillation-batch: sha256:8e28ad4fe99818fd777938e94997ba0c22777c4dc9d45c419b5ffef0b5baa0c5 -->"
        $state = @{
            Source = $source; Commit = $commit; Head = $commit
            Branch = "retro-distillation/$source"; Tree = 'cccccccccccccccccccccccccccccccccccccccc'
            Parents = "$commit $source"; Remote = $false
            Body = $body; Message = 'Retro-Body: ' + [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($body))
            FetchUrls = @('https://github.com/msucharda/devsecops-platform.git')
            PushUrls = @('https://github.com/msucharda/devsecops-platform.git')
            Pulls = @(); Creation = @{}; ApiExit = 0; RawPages = $null; Writes = 0
            Agents = "# Original`n`n### Průvodce agentů`n`n- Téma: [průvodce](docs/agents/guide/topic.md)."
            FileMode = '100644'
            Retrospectives = @(
                'docs/agents/retros/2026-11-06-fixture-a.md'
                'docs/agents/retros/2026-11-06-fixture-b.md'
                'docs/agents/retros/2026-11-06-fixture-c.md'
            )
            Diff = @(
                "D`tdocs/agents/retros/2026-11-06-fixture-a.md"
                "D`tdocs/agents/retros/2026-11-06-fixture-b.md"
                "D`tdocs/agents/retros/2026-11-06-fixture-c.md"
                "A`tdocs/agents/guide/topic.md"
                "A`tdocs/agents/retros/candidates.md"
                "M`tAGENTS.md"
            )
        }
        $bodyPath = Join-Path $TestDrive 'body.md'
        [IO.File]::WriteAllText($bodyPath, $body)
    }

    It 'allows a complete publication at the public command boundary' {
        (& $publisher -Mode Publish -RepositoryPath $TestDrive).Action | Should -BeExactly 'Published'
    }

    It 'Mode inspection <Mode> never writes even with a ready checkpoint' -ForEach @(
        @{ Mode = 'Inspect' }, @{ Mode = 'inspect' }, @{ Mode = 'iNsPeCt' }, @{ Mode = 'INSPECT' }
    ) {
        (& $publisher -Mode $Mode -RepositoryPath $TestDrive).Action | Should -BeExactly 'Prepare'
        $state.Writes | Should -Be 0
        $state.Remote | Should -BeFalse
    }

    It 'Mode <Mode> commits locally without publication' -ForEach @(
        @{ Mode = 'Commit' }, @{ Mode = 'commit' }, @{ Mode = 'cOmMiT' }
    ) {
        $state.Head = $state.Source
        (& $publisher -Mode $Mode -RepositoryPath $TestDrive -SourceSha $state.Source -BodyPath $bodyPath).Action |
            Should -BeExactly 'Resume'
        $state.Remote | Should -BeFalse
        $state.Writes | Should -Be 2
    }

    It 'Mode explicitly publishes with mixed casing' {
        (& $publisher -Mode pUbLiSh -RepositoryPath $TestDrive).Action | Should -BeExactly 'Published'
        $state.Remote | Should -BeTrue
    }

    It 'Origin rejects <Case>' -ForEach @(
        @{ Case = 'foreign fetch'; Side = 'FetchUrls'; Urls = @('https://github.com/other/repository.git') }
        @{ Case = 'foreign push'; Side = 'PushUrls'; Urls = @('git@other.example:msucharda/devsecops-platform.git') }
        @{ Case = 'no URL'; Side = 'FetchUrls'; Urls = @() }
        @{ Case = 'multiple URLs'; Side = 'PushUrls'; Urls = @('https://github.com/msucharda/devsecops-platform.git', 'https://github.com/other/repository.git') }
    ) {
        $state[$Side] = $Urls
        { & $publisher -Mode Inspect -RepositoryPath $TestDrive } | Should -Throw '*origin must target*'
    }

    It 'Origin accepts <Url>' -ForEach @(
        @{ Url = 'https://github.com/msucharda/devsecops-platform' }
        @{ Url = 'git@github.com:msucharda/devsecops-platform.git' }
        @{ Url = 'ssh://git@github.com/msucharda/devsecops-platform.git' }
    ) {
        $state.FetchUrls = @($Url)
        $state.PushUrls = @($Url)
        (& $publisher -Mode Inspect -RepositoryPath $TestDrive).Action | Should -BeExactly 'Prepare'
    }

    It 'Inventory rejects malformed pages <Json>' -ForEach @(
        @{ Json = '[]'; Error = '*at least one page*' }
        @{ Json = '{}'; Error = '*at least one page*' }
        @{ Json = '{"unexpected":1}'; Error = '*at least one page*' }
        @{ Json = '[{}]'; Error = '*page must be an array*' }
        @{ Json = '[[null]]'; Error = '*must be an object*' }
    ) {
        $state.RawPages = $Json
        { & $publisher -Mode Inspect -RepositoryPath $TestDrive } | Should -Throw $Error
    }

    It 'Inventory rejects unreadable <Field>' -ForEach @(
        @{ Field = 'head'; Value = $null; Error = 'Unreadable pull request identity: head' }
        @{ Field = 'base'; Value = $null; Error = 'Unreadable pull request identity: base' }
        @{ Field = 'head.ref'; Value = ''; Error = 'Unreadable pull request identity: head.ref' }
        @{ Field = 'base.ref'; Value = @('main'); Error = 'Unreadable pull request identity: base.ref' }
        @{ Field = 'head.repo'; Value = $null; Error = 'Unreadable pull request identity: head.repo' }
        @{ Field = 'base.repo'; Value = @(); Error = 'Unreadable pull request identity: base.repo' }
        @{ Field = 'head.repo.full_name'; Value = ''; Error = 'Unreadable pull request identity: head.repo.full_name' }
        @{ Field = 'base.repo.full_name'; Value = @('msucharda/devsecops-platform'); Error = 'Unreadable pull request identity: base.repo.full_name' }
        @{ Field = 'state'; Value = @(); Error = '*unknown distillation PR*' }
        @{ Field = 'state'; Value = @('open'); Error = '*unknown distillation PR*' }
        @{ Field = 'state'; Value = 'OPEN'; Error = '*unknown distillation PR*' }
        @{ Field = 'body'; Value = @(); Error = '*request body*' }
    ) {
        $pull = Get-ListedPull
        # Intentionally invalid API input: replace exactly one documented field.
        $parts = $Field.Split('.')
        $node = $pull
        for ($index = 0; $index -lt $parts.Count - 1; $index++) { $node = $node[$parts[$index]] }
        $node[$parts[-1]] = $Value
        $state.Pulls = @($pull)
        { & $publisher -Mode Inspect -RepositoryPath $TestDrive } | Should -Throw $Error
    }

    It 'Inventory accepts documented nullable user and body' {
        $pull = Get-ListedPull
        $pull.user = $null
        $pull.body = $null
        $state.Pulls = @($pull)
        (& $publisher -Mode Inspect -RepositoryPath $TestDrive).Reason | Should -BeExactly 'open-pr'
    }

    It 'History leaves an open PR untouched even with unreadable closed history' {
        $open = Get-ListedPull
        $closed = Get-ListedPull
        $closed.state = 'closed'
        $closed.body = $null
        $state.Pulls = @($open, $closed)
        (& $publisher -Mode Publish -RepositoryPath $TestDrive).Reason | Should -BeExactly 'open-pr'
        $state.Writes | Should -Be 0
    }

    It 'Source rejects a failed lookup with valid stdout' {
        $state.ApiExit = 1
        { & $publisher -Mode Inspect -RepositoryPath $TestDrive } | Should -Throw '*listing failed*'
    }

    It 'Source ignores <Field> outside the publication target' -ForEach @(
        @{ Field = 'head.repo.full_name'; Value = 'other/repository' }
        @{ Field = 'base.repo.full_name'; Value = 'other/repository' }
        @{ Field = 'base.ref'; Value = 'other' }
        @{ Field = 'base.ref'; Value = 'MAIN' }
    ) {
        $pull = Get-ListedPull
        $parts = $Field.Split('.')
        $node = $pull
        for ($index = 0; $index -lt $parts.Count - 1; $index++) { $node = $node[$parts[$index]] }
        $node[$parts[-1]] = $Value
        $state.Pulls = @($pull)
        (& $publisher -Mode Inspect -RepositoryPath $TestDrive).Action | Should -BeExactly 'Prepare'
    }

    It 'History blocks closed unmerged PRs without a surviving branch' {
        $pull = Get-ListedPull
        $pull.state = 'closed'
        $state.Pulls = @($pull)
        { & $publisher -Mode Inspect -RepositoryPath $TestDrive } | Should -Throw '*unmerged*'
    }

    It 'History permits a different batch after a closed unmerged PR' {
        $pull = Get-ListedPull
        $pull.state = 'closed'
        $pull.body = $pull.body.Replace('8e28ad4fe99818fd777938e94997ba0c22777c4dc9d45c419b5ffef0b5baa0c5', ('d' * 64))
        $state.Pulls = @($pull)
        $result = & $publisher -Mode Inspect -RepositoryPath $TestDrive
        $result.Action | Should -BeExactly 'Prepare'
        $result.BatchId | Should -BeExactly '8e28ad4fe99818fd777938e94997ba0c22777c4dc9d45c419b5ffef0b5baa0c5'
        $state.Writes | Should -Be 0
    }

    It 'History blocks the same path set despite source SHA or inventory order changes' {
        $pull = Get-ListedPull
        $pull.state = 'closed'
        $state.Pulls = @($pull)
        $state.Source = 'e' * 40
        [Array]::Reverse($state.Retrospectives)
        { & $publisher -Mode Inspect -RepositoryPath $TestDrive } | Should -Throw '*unmerged*same batch*'
        $state.Writes | Should -Be 0
    }

    It 'History fails closed on unreadable batch identity <Case>' -ForEach @(
        @{ Case = 'missing'; Marker = ''; Error = '*exactly one readable batch identity*' }
        @{ Case = 'null body'; Marker = $null; Error = '*exactly one readable batch identity*' }
        @{ Case = 'duplicate'; Marker = "<!-- distillation-batch: sha256:$('d' * 64) --><!-- distillation-batch: sha256:$('e' * 64) -->"; Error = '*exactly one readable batch identity*' }
        @{ Case = 'uppercase declaration'; Marker = "<!-- DISTILLATION-BATCH: sha256:$('d' * 64) -->"; Error = '*canonical batch identity*' }
        @{ Case = 'uppercase digest'; Marker = "<!-- distillation-batch: sha256:$('D' * 64) -->"; Error = '*canonical batch identity*' }
        @{ Case = 'short digest'; Marker = '<!-- distillation-batch: sha256:abc -->'; Error = '*canonical batch identity*' }
        @{ Case = 'unknown scheme'; Marker = "<!-- distillation-batch: sha1:$('d' * 64) -->"; Error = '*canonical batch identity*' }
    ) {
        $pull = Get-ListedPull
        $pull.state = 'closed'
        $pull.body = $Marker
        $state.Pulls = @($pull)
        { & $publisher -Mode Inspect -RepositoryPath $TestDrive } | Should -Throw $Error
        $state.Writes | Should -Be 0
    }

    It 'History rejects an unknown merge timestamp <Case>' -ForEach @(
        @{ Case = 'string'; Value = 'unknown' }
        @{ Case = 'array'; Value = @('2026-11-06T09:00:00Z', '2026-11-06T09:00:00Z') }
    ) {
        $pull = Get-ListedPull
        $pull.state = 'closed'
        # Intentionally invalid API input: merged_at is a nullable date-time scalar.
        $pull.merged_at = $Value
        $state.Pulls = @($pull)
        { & $publisher -Mode Inspect -RepositoryPath $TestDrive } | Should -Throw '*unknown distillation merge state*'
    }

    It 'Batch commit persists an automatically generated identity before publication' {
        $state.Head = $state.Source
        [IO.File]::WriteAllText($bodyPath, ($state.Body -split "`n<!-- distillation-batch:")[0])
        $result = & $publisher -Mode Commit -RepositoryPath $TestDrive -SourceSha $state.Source -BodyPath $bodyPath
        $result.Body | Should -BeExactly $state.Body
        $state.Remote | Should -BeFalse
    }

    It 'Batch output rejects an identity for a different deletion set' {
        $state.Head = $state.Source
        [IO.File]::WriteAllText($bodyPath, $state.Body.Replace('8e28ad4fe99818fd777938e94997ba0c22777c4dc9d45c419b5ffef0b5baa0c5', ('d' * 64)))
        { & $publisher -Mode Commit -RepositoryPath $TestDrive -SourceSha $state.Source -BodyPath $bodyPath } |
            Should -Throw '*deletions must match*batch identity*'
    }

    It 'Batch <Mode> rejects a canonical subset marker with a retained source input' -Tag BatchSubset -ForEach @(
        @{ Mode = 'Commit'; Writes = 1 }
        @{ Mode = 'Publish'; Writes = 0 }
    ) {
        $state.Retrospectives += 'docs/agents/retros/2026-11-06-fixture-d.md'
        if ($Mode -ceq 'Commit') { $state.Head = $state.Source }
        { & $publisher -Mode $Mode -RepositoryPath $TestDrive -SourceSha $state.Source -BodyPath $bodyPath } |
            Should -Throw '*complete source inventory*'
        $state.Remote | Should -BeFalse
        $state.Writes | Should -Be $Writes
    }

    It 'History accepts a merged retained branch with a deserialized date' {
        $pull = Get-ListedPull
        $pull.state = 'closed'
        $pull.merged_at = '2026-11-06T09:00:00Z'
        $state.Pulls = @($pull)
        $state.Remote = $true
        (& $publisher -Mode Inspect -RepositoryPath $TestDrive).Action | Should -BeExactly 'Prepare'
    }

    It 'Checkpoint rejects <Case>' -ForEach @(
        @{ Case = 'wrong parent'; Parents = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb dddddddddddddddddddddddddddddddddddddddd'; Message = $null; Error = '*one commit on its source SHA*' }
        @{ Case = 'root commit'; Parents = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; Message = $null; Error = '*one commit on its source SHA*' }
        @{ Case = 'merge commit'; Parents = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa dddddddddddddddddddddddddddddddddddddddd'; Message = $null; Error = '*one commit on its source SHA*' }
        @{ Case = 'missing body'; Parents = $null; Message = 'No metadata'; Error = '*one persisted PR body*' }
        @{ Case = 'duplicate body'; Parents = $null; Message = 'duplicate'; Error = '*one persisted PR body*' }
    ) {
        if ($Parents) { $state.Parents = $Parents }
        if ($Message -ceq 'duplicate') { $state.Message += "`n" + $state.Message }
        elseif ($Message) { $state.Message = $Message }
        { & $publisher -Mode Publish -RepositoryPath $TestDrive } | Should -Throw $Error
    }

    It 'Output rejects <Case>' -ForEach @(
        @{ Case = 'no marker'; Change = 'body'; Value = "## Otevřené otázky`naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa"; Error = '*exactly one distillation marker*' }
        @{ Case = 'wrong marker'; Change = 'body'; Value = "## Otevřené otázky`naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n<!-- retro: none human -->"; Error = '*exactly one distillation marker*' }
        @{ Case = 'two markers'; Change = 'body'; Value = "## Otevřené otázky`naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n<!-- retro: none distillation --><!-- retro: none human -->"; Error = '*exactly one distillation marker*' }
        @{ Case = 'no source'; Change = 'body'; Value = "## Otevřené otázky`n<!-- retro: none distillation -->"; Error = '*identify the source SHA*' }
        @{ Case = 'no questions'; Change = 'body'; Value = "aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n<!-- retro: none distillation -->"; Error = '*open-questions section*' }
        @{ Case = 'lowercase questions'; Change = 'body'; Value = "## otevřené otázky`naaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa`n<!-- retro: none distillation -->"; Error = '*open-questions section*' }
        @{ Case = 'unrelated path'; Change = 'path'; Value = "A`tother.txt"; Error = '*outside the distillation output*' }
        @{ Case = 'uppercase guide'; Change = 'path'; Value = "A`tdocs/agents/guide/UPPER.md"; Error = '*outside the distillation output*' }
        @{ Case = 'uppercase raw suffix'; Change = 'raw-case'; Value = "D`tdocs/agents/retros/2026-11-06-fixture-a.MD"; Error = '*outside the distillation output*' }
        @{ Case = 'changed input'; Change = 'path'; Value = "M`tdocs/agents/retros/2026-11-06-fixture-a.md"; Error = '*outside the distillation output*' }
        @{ Case = 'symlink'; Change = 'mode'; Value = '120000'; Error = '*regular file*' }
        @{ Case = 'changed rules'; Change = 'agents'; Value = '# Other rules'; Error = '*outside its guide index*' }
        @{ Case = 'changed rule casing'; Change = 'agents'; Value = '# ORIGINAL'; Error = '*outside its guide index*' }
        @{ Case = 'only two deletions'; Change = 'count'; Value = ''; Error = '*at least three retrospective inputs*' }
    ) {
        $state.Head = $state.Source
        switch ($Change) {
            'body' { [IO.File]::WriteAllText($bodyPath, $Value) }
            'path' { $state.Diff += $Value }
            'mode' { $state.FileMode = $Value }
            'agents' {
                $state.Agents = $Value
                $state.Diff = @($state.Diff | Where-Object { $_ -clike "D`t*" -or $_ -ceq "M`tAGENTS.md" })
            }
            'raw-case' { $state.Diff[0] = $Value }
            'count' { $state.Diff = @($state.Diff | Select-Object -Skip 1) }
        }
        { & $publisher -Mode Commit -RepositoryPath $TestDrive -SourceSha $state.Source -BodyPath $bodyPath } | Should -Throw $Error
    }

    It 'Creation rejects <Field> with an invalid scalar or identity' -ForEach @(
        @{ Field = 'head'; Value = @(); Error = '*PR creation response: head.*' }
        @{ Field = 'head.sha'; Value = 'wrong'; Error = '*PR creation response: head.sha' }
        @{ Field = 'head.sha'; Value = @('bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb', 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'); Error = '*PR creation response: head.sha' }
        @{ Field = 'head.ref'; Value = @('retro-distillation/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'retro-distillation/aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); Error = '*PR creation response: head.ref' }
        @{ Field = 'state'; Value = @(); Error = '*PR creation response: state' }
        @{ Field = 'state'; Value = @('open', 'open'); Error = '*PR creation response: state' }
        @{ Field = 'base.ref'; Value = 'MAIN'; Error = '*PR creation response: base.ref' }
        @{ Field = 'number'; Value = '1'; Error = '*PR creation response: number type' }
        @{ Field = 'number'; Value = 0; Error = '*PR creation response: number' }
        @{ Field = 'html_url'; Value = 'https://github.com/other/repository/pull/1'; Error = '*PR creation response: html_url' }
        @{ Field = 'html_url'; Value = 'https://github.com/MSUCHARDA/devsecops-platform/pull/1'; Error = '*PR creation response: html_url' }
        @{ Field = 'html_url'; Value = @('https://github.com/msucharda/devsecops-platform/pull/1'); Error = '*PR creation response: html_url' }
    ) {
        # Intentionally invalid API input: preserve the documented fixture except for the targeted field.
        $state.Creation[$Field] = $Value
        { & $publisher -Mode Publish -RepositoryPath $TestDrive } | Should -Throw $Error
    }
}
