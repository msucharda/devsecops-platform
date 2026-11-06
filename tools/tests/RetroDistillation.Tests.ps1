BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $gitExecutable = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    $publisher = Join-Path $PSScriptRoot '..\agents\Invoke-RetroDistillation.ps1'
    function gh { param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments) $null = $Arguments }
    function git { param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments) & $gitTransport -Arguments $Arguments }
    function Add-RetroBatch {
        Copy-Item (Join-Path $PSScriptRoot 'fixtures\retro-distillation\*.md') (Join-Path $target 'docs\agents\retros')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m 'Three synthetic retrospectives'
        & $gitExecutable -C $target push --quiet origin main
    }
    function Get-RetroPullFixture {
        param([string] $Branch, [string] $Sha, [string] $State = 'open')
        $fixture = Get-GitHubApiFixture -Name 'pulls/list' -Set @{
            '0.head.ref' = $Branch
            '0.head.sha' = $Sha
            '0.head.repo.full_name' = 'msucharda/devsecops-platform'
            '0.base.repo.full_name' = 'msucharda/devsecops-platform'
            '0.base.ref' = 'main'
            '0.state' = $State
            '0.merged_at' = $null
            '0.body' = '<!-- retro: none distillation -->'
        }
        return $fixture[0]
    }
    function Initialize-RetroOutput {
        param([string] $Source)
        $null = New-Item -ItemType Directory -Path (Join-Path $target 'docs\agents\guide') -Force
        "# Čtení zdrojů`n`nAgent musí číst inventář i obsah z jednoho uloženého SHA.`n`n- **Počet nezávislých session:** 2`n- **Zdroje:** [fixture-a R1](https://github.com/msucharda/devsecops-platform/blob/$Source/docs/agents/retros/2026-11-06-fixture-a.md), [fixture-b R1](https://github.com/msucharda/devsecops-platform/blob/$Source/docs/agents/retros/2026-11-06-fixture-b.md)" |
            Set-Content (Join-Path $target 'docs\agents\guide\source-reading.md')
        "# Agent instructions`n`n### Průvodce agentů`n`n- Čtení zdrojů: [source-reading](docs/agents/guide/source-reading.md)." |
            Set-Content (Join-Path $target 'AGENTS.md')
        "# Kandidáti`n`n## Opakování nápovědy`n`n- **Počet nezávislých session:** 1`n- **Zdroje:** [fixture-c R1](https://github.com/msucharda/devsecops-platform/blob/$Source/docs/agents/retros/2026-11-06-fixture-c.md)" |
            Set-Content (Join-Path $target 'docs\agents\retros\candidates.md')
        foreach ($inputFile in Get-ChildItem (Join-Path $target 'docs\agents\retros\2026-*.md')) {
            Remove-Item -LiteralPath $inputFile.FullName
        }
        $bodyPath = Join-Path $TestDrive 'pr-body.txt'
        "## Zdroj`n`n$Source`n`n## Otevřené otázky`n`nŽádné`n`n<!-- retro: none distillation -->" |
            Set-Content $bodyPath
        & $publisher -Mode Commit -RepositoryPath $target -SourceSha $Source -BodyPath $bodyPath
    }
}

Describe 'Retrospective distillation public command' {
BeforeEach {
    $target = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
    $remote = "$target.git"
    $null = New-Item -ItemType Directory -Path $target
    & $gitExecutable init --quiet --bare $remote
    & $gitExecutable -C $target init --quiet -b main
    & $gitExecutable -C $target config user.name 'Fixture'
    & $gitExecutable -C $target config user.email 'fixture@example.invalid'
    & $gitExecutable -C $target config core.autocrlf false
    $null = New-Item -ItemType Directory -Path (Join-Path $target 'docs\agents\retros') -Force
    $null = New-Item -ItemType Directory -Path (Join-Path $target 'tools') -Force
    # The real local gate is an external process; this isolated fixture substitutes its exit status.
    'exit 0' | Set-Content (Join-Path $target 'tools\Test-LocalCiResult.ps1')
    'fixture format' | Set-Content (Join-Path $target 'docs\agents\retros\README.md')
    '# Agent instructions' | Set-Content (Join-Path $target 'AGENTS.md')
    & $gitExecutable -C $target add .
    & $gitExecutable -C $target commit --quiet -m 'Fixture source'
    & $gitExecutable -C $target remote add origin $remote
    & $gitExecutable -C $target push --quiet origin main
    & $gitExecutable -C $target fetch --quiet origin main
    $cloud = @{ pulls = [Collections.Generic.List[object]]::new(); writes = 0 }
    $gitTransport = {
        param([string[]] $Arguments)
        if ($Arguments -contains 'remote' -and $Arguments -contains 'get-url') {
            $global:LASTEXITCODE = 0
            return 'https://github.com/msucharda/devsecops-platform.git'
        }
        & $gitExecutable @Arguments
        $global:LASTEXITCODE = $LASTEXITCODE
    }
    $ghTransport = {
        param([string[]] $Arguments)
        $global:LASTEXITCODE = 0
        if ($Arguments -contains 'GET') {
            $pages = [object[]] @(,$cloud.pulls.ToArray())
            return ConvertTo-Json -InputObject $pages -Depth 100 -Compress
        }
        if ($Arguments -contains 'POST') {
            $branch = ($Arguments | Where-Object { $_ -clike 'head=*' }).Substring(5)
            $body = ($Arguments | Where-Object { $_ -clike 'body=*' }).Substring(5)
            $sha = & $gitExecutable --git-dir=$remote rev-parse "refs/heads/$branch"
            if (@($cloud.pulls | Where-Object { $_.head.ref -ceq $branch -and $_.state -ceq 'open' }).Count) {
                throw 'HTTP 422: duplicate PR'
            }
            $pull = Get-GitHubApiFixture -Name 'pulls/create' -Set @{
                number = 1; html_url = 'https://github.com/msucharda/devsecops-platform/pull/1'
                'head.ref' = $branch; 'head.sha' = $sha; 'head.repo.full_name' = 'msucharda/devsecops-platform'
                'base.ref' = 'main'; 'base.repo.full_name' = 'msucharda/devsecops-platform'
                state = 'open'; merged_at = $null; body = $body
            }
            $cloud.pulls.Add($pull)
            $cloud.writes++
            return $pull | ConvertTo-Json -Depth 100 -Compress
        }
        throw 'Unexpected GitHub operation.'
    }
    Mock gh { & $ghTransport -Arguments $Arguments }
}

    It 'returns no change for fewer than three retrospective inputs' {
        $result = & $publisher -Mode Inspect -RepositoryPath $target
        $result.Action | Should -BeExactly 'NoOp'
        $result.Reason | Should -BeExactly 'threshold'
        $result.Retrospectives.Count | Should -Be 0
        $cloud.writes | Should -Be 0
    }

    It 'pins a batch of three synthetic retrospectives without counting candidates or README' {
        Add-RetroBatch
        'not a retrospective' | Set-Content (Join-Path $target 'docs\agents\retros\candidates.md')
        $result = & $publisher -Mode Inspect -RepositoryPath $target
        $result.Action | Should -BeExactly 'Prepare'
        $result.SourceSha | Should -BeExactly (& $gitExecutable -C $target rev-parse main)
        $result.Retrospectives.Count | Should -Be 3
        $result.Branch | Should -BeExactly "retro-distillation/$($result.SourceSha)"
    }

    It 'makes no changes when an open distillation PR exists even below the threshold' {
        $sha = & $gitExecutable -C $target rev-parse main
        $cloud.pulls.Add((Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha))
        $result = & $publisher -Mode Inspect -RepositoryPath $target
        $result.Action | Should -BeExactly 'NoOp'
        $result.Reason | Should -BeExactly 'open-pr'
        $cloud.writes | Should -Be 0
    }

    It 'preserves the pushed output and original source when resuming after push before PR creation' {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $commit = Initialize-RetroOutput -Source $source
        $branch = "retro-distillation/$source"
        & $gitExecutable -C $target push --quiet origin "HEAD:refs/heads/$branch"
        & $gitExecutable -C $target switch --quiet -c later $source
        'later unrelated source' | Set-Content (Join-Path $target 'unrelated.txt')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m 'Main advanced'
        & $gitExecutable -C $target push --quiet origin HEAD:main

        $result = & $publisher -Mode Inspect -RepositoryPath $target
        $result.Action | Should -BeExactly 'Resume'
        $result.SourceSha | Should -BeExactly $source
        $result.HeadSha | Should -BeExactly $commit.HeadSha
        $result.Branch | Should -BeExactly $branch
        $result.Body | Should -MatchExactly ([regex]::Escape($source))
        @(& $gitExecutable --git-dir=$remote for-each-ref '--format=%(refname)' refs/heads/retro-distillation).Count | Should -Be 1
    }

    It 'accepts merged history with a retained branch and a deserialized timestamp' -Tag RetroHistory {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $commit = Initialize-RetroOutput -Source $source
        $branch = "retro-distillation/$source"
        & $gitExecutable -C $target push --quiet origin "HEAD:refs/heads/$branch" HEAD:main
        $pull = Get-RetroPullFixture -Branch $branch -Sha $commit.HeadSha -State closed
        $pull.merged_at = '2026-11-06T09:00:00Z'
        $cloud.pulls.Add($pull)
        (& $publisher -Mode Inspect -RepositoryPath $target).Reason | Should -BeExactly 'threshold'
    }

    It 'blocks the same closed unmerged batch even after its remote branch was deleted' -Tag RetroHistory {
        Add-RetroBatch
        $sha = & $gitExecutable -C $target rev-parse main
        $checkpoint = Initialize-RetroOutput -Source $sha
        $pull = Get-RetroPullFixture -Branch $checkpoint.Branch -Sha $checkpoint.HeadSha -State closed
        $pull.body = $checkpoint.Body
        $cloud.pulls.Add($pull)
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw '*unmerged*'
        $cloud.writes | Should -Be 0
    }

    It 'publishes a new batch after another retrospective is added to a rejected batch' -Tag RetroHistory {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $checkpoint = Initialize-RetroOutput -Source $source
        $pull = Get-RetroPullFixture -Branch $checkpoint.Branch -Sha $checkpoint.HeadSha -State closed
        $pull.body = $checkpoint.Body
        $cloud.pulls.Add($pull)
        & $gitExecutable -C $target switch --quiet --detach $source
        Copy-Item (Join-Path $PSScriptRoot 'fixtures\retro-distillation\2026-11-06-fixture-a.md') `
            (Join-Path $target 'docs\agents\retros\2026-11-06-fixture-d.md')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m 'Add another synthetic input'
        & $gitExecutable -C $target push --quiet origin HEAD:main
        $inspection = & $publisher -Mode Inspect -RepositoryPath $target
        $inspection.Action | Should -BeExactly 'Prepare'
        $inspection.Retrospectives.Count | Should -Be 4
        $next = Initialize-RetroOutput -Source $inspection.SourceSha
        $next.Body | Should -Not -BeExactly $checkpoint.Body
        $result = & $publisher -Mode Publish -RepositoryPath $target
        $result.Action | Should -BeExactly 'Published'
        $cloud.writes | Should -Be 1
        $cloud.pulls.Count | Should -Be 2
        $cloud.pulls[1].body | Should -MatchExactly "<!-- distillation-batch: sha256:$($inspection.BatchId) -->"
    }

    It 'blocks rejected history with an unreadable batch identity' -Tag RetroHistory {
        Add-RetroBatch
        $sha = & $gitExecutable -C $target rev-parse main
        $cloud.pulls.Add((Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha -State closed))
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw '*readable batch identity*'
        $cloud.writes | Should -Be 0
    }

    It 'publishes the three-input fixture batch and reuses its PR on the next run' {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $commit = Initialize-RetroOutput -Source $source
        $result = & $publisher -Mode Publish -RepositoryPath $target
        $result.Action | Should -BeExactly 'Published'
        $result.HeadSha | Should -BeExactly $commit.HeadSha
        $cloud.pulls.Count | Should -Be 1
        $cloud.pulls[0].body | Should -MatchExactly '<!-- retro: none distillation -->'
        $files = @(& $gitExecutable --git-dir=$remote ls-tree -r --name-only "refs/heads/$($result.Branch)")
        $files | Should -Contain 'docs/agents/guide/source-reading.md'
        $files | Should -Contain 'docs/agents/retros/candidates.md'
        @($files | Where-Object { $_ -like '*2026-11-06-fixture-*.md' }).Count | Should -Be 0
        $second = & $publisher -Mode Publish -RepositoryPath $target
        $second.Reason | Should -BeExactly 'open-pr'
        $cloud.writes | Should -Be 1
    }

    It 'rejects a checkpoint with <Case>' -ForEach @(
        @{ Case = 'a changed source format'; Path = 'docs\agents\retros\README.md'; Text = 'changed'; Error = '*outside the distillation output*' }
        @{ Case = 'a changed agent rule outside the index'; Path = 'AGENTS.md'; Text = '# Changed instructions'; Error = '*outside its guide index*' }
        @{ Case = 'a changed unrelated file'; Path = 'unrelated.txt'; Text = 'changed'; Error = '*outside the distillation output*' }
        @{ Case = 'an uppercase guide path'; Path = 'docs\agents\guide\SOURCE.md'; Text = 'changed'; Error = '*outside the distillation output*' }
    ) {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $null = Initialize-RetroOutput -Source $source
        $body = Join-Path $TestDrive 'pr-body.txt'
        $head = & $gitExecutable -C $target rev-parse HEAD
        & $gitExecutable -C $target switch --quiet --detach $source
        & $gitExecutable -C $target restore --source=$head --staged --worktree .
        $Text | Set-Content (Join-Path $target $Path)
        { & $publisher -Mode Commit -RepositoryPath $target -SourceSha $source -BodyPath $body } | Should -Throw $Error
    }

    It 'rejects PR body <Case>' -ForEach @(
        @{ Case = 'without marker'; Body = "## Otevřené otázky`nŽádné`nSOURCE"; Error = '*exactly one distillation marker*' }
        @{ Case = 'with two markers'; Body = "## Otevřené otázky`nŽádné`nSOURCE`n<!-- retro: none distillation -->`n<!-- retro: none human -->"; Error = '*exactly one distillation marker*' }
        @{ Case = 'with a different waiver'; Body = "## Otevřené otázky`nŽádné`nSOURCE`n<!-- retro: none human -->"; Error = '*exactly one distillation marker*' }
        @{ Case = 'with changed source casing'; Body = "## Otevřené otázky`nŽádné`nUPPER`n<!-- retro: none distillation -->"; Error = '*identify the source SHA*' }
        @{ Case = 'with changed heading casing'; Body = "## otevřené otázky`nŽádné`nSOURCE`n<!-- retro: none distillation -->"; Error = '*open-questions section*' }
        @{ Case = 'without source SHA'; Body = "## Otevřené otázky`nŽádné`n<!-- retro: none distillation -->"; Error = '*identify the source SHA*' }
        @{ Case = 'without open questions'; Body = "SOURCE`n<!-- retro: none distillation -->"; Error = '*open-questions section*' }
    ) {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $commit = Initialize-RetroOutput -Source $source
        & $gitExecutable -C $target switch --quiet --detach $source
        & $gitExecutable -C $target restore --source=$($commit.HeadSha) --staged --worktree .
        $path = Join-Path $TestDrive 'invalid-body.txt'
        $Body.Replace('SOURCE', $source).Replace('UPPER', $source.ToUpperInvariant()) | Set-Content $path
        { & $publisher -Mode Commit -RepositoryPath $target -SourceSha $source -BodyPath $path } | Should -Throw $Error
    }

    It 'rejects a checkpoint that deletes fewer than three retrospectives' {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $commit = Initialize-RetroOutput -Source $source
        & $gitExecutable -C $target switch --quiet --detach $source
        & $gitExecutable -C $target restore --source=$($commit.HeadSha) --staged --worktree .
        & $gitExecutable -C $target restore --source=$source --staged --worktree docs/agents/retros/2026-11-06-fixture-c.md
        { & $publisher -Mode Commit -RepositoryPath $target -SourceSha $source -BodyPath (Join-Path $TestDrive 'pr-body.txt') } |
            Should -Throw '*at least three retrospective inputs*'
    }

    It 'rejects a nonregular guide output with core.filemode=<FileMode>' -ForEach @(
        @{ FileMode = 'false' }
        if (-not $IsWindows) { @{ FileMode = 'true' } }
    ) {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $commit = Initialize-RetroOutput -Source $source
        & $gitExecutable -C $target switch --quiet --detach $source
        & $gitExecutable -C $target restore --source=$($commit.HeadSha) --staged --worktree .
        & $gitExecutable -C $target config core.filemode $FileMode
        if (-not $IsWindows) {
            # The publisher restages the worktree, so an index-only executable bit would be lost with core.filemode=true.
            $guidePath = Join-Path $target 'docs\agents\guide\source-reading.md'
            [IO.File]::SetUnixFileMode($guidePath, [IO.File]::GetUnixFileMode($guidePath) -bor [IO.UnixFileMode]::UserExecute)
        }
        & $gitExecutable -C $target update-index --chmod=+x docs/agents/guide/source-reading.md
        (& $gitExecutable -C $target ls-files --stage docs/agents/guide/source-reading.md) | Should -Match '^100755 '
        { & $publisher -Mode Commit -RepositoryPath $target -SourceSha $source -BodyPath (Join-Path $TestDrive 'pr-body.txt') } |
            Should -Throw '*regular file*'
        (& $gitExecutable -C $target ls-files --stage docs/agents/guide/source-reading.md) | Should -Match '^100755 '
    }

    It 'rejects an unknown PR state instead of treating it as an absent PR' {
        $sha = & $gitExecutable -C $target rev-parse main
        $pull = Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha
        # Intentionally invalid API input: the documented state is open or closed.
        $pull.state = ''
        $cloud.pulls.Add($pull)
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw '*unknown distillation PR*'
    }

    It 'accepts the documented nullable list user without an author-type assumption' {
        $sha = & $gitExecutable -C $target rev-parse main
        $pull = Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha
        $pull.user = $null
        $cloud.pulls.Add($pull)
        (& $publisher -Mode Inspect -RepositoryPath $target).Reason | Should -BeExactly 'open-pr'
    }

    It 'ignores a foreign fork with the same branch and waiver marker' {
        $sha = & $gitExecutable -C $target rev-parse main
        $pull = Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha
        $pull.head.repo.full_name = 'other/devsecops-platform'
        $cloud.pulls.Add($pull)
        (& $publisher -Mode Inspect -RepositoryPath $target).Reason | Should -BeExactly 'threshold'
    }

    It 'ignores a PR targeting <Field> outside this distillation target' -ForEach @(
        @{ Field = 'repo'; Value = 'other/repository' }
        @{ Field = 'ref'; Value = 'other' }
        @{ Field = 'ref'; Value = 'MAIN' }
    ) {
        $sha = & $gitExecutable -C $target rev-parse main
        $pull = Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha
        if ($Field -ceq 'repo') { $pull.base.repo.full_name = $Value } else { $pull.base.ref = $Value }
        $cloud.pulls.Add($pull)
        (& $publisher -Mode Inspect -RepositoryPath $target).Reason | Should -BeExactly 'threshold'
    }

    It 'rejects unreadable PR inventory <Case>' -Tag 'RetroRegression' -ForEach @(
        @{ Case = 'zero pages'; Json = '[]'; Error = '*at least one page*' }
        @{ Case = 'nonarray root'; Json = '{}'; Error = '*at least one page*' }
        @{ Case = 'nonarray page'; Json = '[{}]'; Error = '*page must be an array*' }
        @{ Case = 'nonobject PR'; Json = '[[null]]'; Error = '*must be an object*' }
    ) {
        Mock gh { $Json }
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw $Error
    }

    It 'rejects a failed PR lookup even when stdout contains valid JSON' {
        Mock gh { $global:LASTEXITCODE = 1; '[[]]' }
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw '*listing failed*'
        $global:LASTEXITCODE = 0
    }

    It 'rejects unreadable documented field <Field>' -ForEach @(
        @{ Field = 'head'; Value = $null; Error = 'Unreadable pull request identity: head' }
        @{ Field = 'base'; Value = $null; Error = 'Unreadable pull request identity: base' }
        @{ Field = 'head.ref'; Value = $null; Error = 'Unreadable pull request identity: head.ref' }
        @{ Field = 'base.ref'; Value = ''; Error = 'Unreadable pull request identity: base.ref' }
        @{ Field = 'head.ref'; Value = @('branch'); Error = 'Unreadable pull request identity: head.ref' }
        @{ Field = 'base.ref'; Value = @('main'); Error = 'Unreadable pull request identity: base.ref' }
        @{ Field = 'state'; Value = @('open'); Error = '*unknown distillation PR*' }
        @{ Field = 'state'; Value = 'OPEN'; Error = '*unknown distillation PR*' }
        @{ Field = 'body'; Value = @('body'); Error = '*request body*' }
        @{ Field = 'head.repo'; Value = ''; Error = 'Unreadable pull request identity: head.repo' }
        @{ Field = 'base.repo'; Value = $null; Error = 'Unreadable pull request identity: base.repo' }
        @{ Field = 'head.repo.full_name'; Value = ''; Error = '*identity: head.repo.full_name*' }
        @{ Field = 'base.repo.full_name'; Value = @('msucharda/devsecops-platform'); Error = '*identity: base.repo.full_name*' }
    ) {
        $sha = & $gitExecutable -C $target rev-parse main
        $pull = Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha -State closed
        # Intentionally invalid API input: required scalars/objects are unreadable.
        $parts = $Field.Split('.')
        $node = $pull
        for ($index = 0; $index -lt $parts.Count - 1; $index++) { $node = $node[$parts[$index]] }
        $node[$parts[-1]] = $Value
        $cloud.pulls.Add($pull)
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw $Error
    }

    It 'rejects a null repository instead of losing potentially blocking PR history' -Tag RetroIdentity {
        $sha = & $gitExecutable -C $target rev-parse main
        $pull = Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha -State closed
        # Intentionally invalid API input: repository is nonnullable in the pinned schema.
        $pull.head.repo = $null
        $pull.body = $null
        $cloud.pulls.Add($pull)
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw '*identity: head.repo*'
    }

    It 'accepts a documented nullable body without losing an open source PR' {
        $sha = & $gitExecutable -C $target rev-parse main
        $pull = Get-RetroPullFixture -Branch "retro-distillation/$sha" -Sha $sha
        $pull.body = $null
        $cloud.pulls.Add($pull)
        (& $publisher -Mode Inspect -RepositoryPath $target).Reason | Should -BeExactly 'open-pr'
    }

    It 'rejects a mismatched <Side> remote before reading or publishing a batch' -Tag RetroIdentity -ForEach @(
        @{ Side = 'fetch'; Value = 'https://github.com/other/devsecops-platform.git' }
        @{ Side = 'push'; Value = 'git@other.example:msucharda/devsecops-platform.git' }
        @{ Side = 'fetch'; Value = @() }
        @{ Side = 'push'; Value = @('https://github.com/msucharda/devsecops-platform.git', 'https://github.com/other/repository.git') }
    ) {
        Mock git {
            if ($Arguments -contains 'get-url' -and (($Arguments -contains '--push') -eq ($Side -ceq 'push'))) { return $Value }
            & $gitTransport -Arguments $Arguments
        }
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw '*origin must target*'
    }

    It 'rejects creation response with changed <Field> instead of reporting success' -Tag 'RetroRegression' -ForEach @(
        @{ Field = 'head.sha'; Value = '1111111111111111111111111111111111111111' }
        @{ Field = 'head.ref'; Value = 'other' }
        @{ Field = 'head.repo.full_name'; Value = 'other/repository' }
        @{ Field = 'base.ref'; Value = 'other' }
        @{ Field = 'base.repo.full_name'; Value = 'other/repository' }
        @{ Field = 'state'; Value = 'closed' }
        @{ Field = 'body'; Value = '' }
        @{ Field = 'number'; Value = 0 }
        @{ Field = 'html_url'; Value = 'https://github.com/other/repository/pull/1' }
        @{ Field = 'state'; Value = @() }
        @{ Field = 'head.sha'; Value = @() }
        @{ Field = 'state'; Value = @('open') }
        @{ Field = 'state'; Value = @('open', 'open') }
        @{ Field = 'number'; Value = '1' }
        @{ Field = 'html_url'; Value = @('https://github.com/msucharda/devsecops-platform/pull/1') }
        @{ Field = 'base.ref'; Value = 'MAIN' }
        @{ Field = 'state'; Value = 'OPEN' }
    ) {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $null = Initialize-RetroOutput -Source $source
        Mock gh {
            $text = & $ghTransport -Arguments $Arguments
            if ($Arguments -contains 'POST') {
                $pull = $text | ConvertFrom-Json -AsHashtable
                $parts = $Field.Split('.')
                $node = $pull
                for ($index = 0; $index -lt $parts.Count - 1; $index++) { $node = $node[$parts[$index]] }
                $node[$parts[-1]] = $Value
                return $pull | ConvertTo-Json -Depth 100 -Compress
            }
            return $text
        }
        { & $publisher -Mode Publish -RepositoryPath $target } | Should -Throw '*creation response*'
    }

    It 'rejects a remote checkpoint with <Case>' -ForEach @(
        @{ Case = 'another parent'; Kind = 'parent'; Error = '*one commit on its source SHA*' }
        @{ Case = 'multiple parents'; Kind = 'merge'; Error = '*one commit on its source SHA*' }
        @{ Case = 'no parent'; Kind = 'root'; Error = '*one commit on its source SHA*' }
        @{ Case = 'missing body'; Kind = 'missing'; Error = '*one persisted PR body*' }
        @{ Case = 'duplicate body'; Kind = 'duplicate'; Error = '*one persisted PR body*' }
    ) {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $commit = Initialize-RetroOutput -Source $source
        $message = (& $gitExecutable -C $target show -s --format=%B HEAD) -join "`n"
        $tree = & $gitExecutable -C $target rev-parse 'HEAD^{tree}'
        switch ($Kind) {
            'parent' { $head = $message | & $gitExecutable -C $target commit-tree $tree -p $commit.HeadSha }
            'merge' { $head = $message | & $gitExecutable -C $target commit-tree $tree -p $source -p $commit.HeadSha }
            'root' { $head = $message | & $gitExecutable -C $target commit-tree $tree }
            'missing' { $head = & $gitExecutable -C $target commit-tree $tree -p $source -m 'No checkpoint body' }
            'duplicate' {
                $trailer = [regex]::Match($message, '(?m)^Retro-Body: .+$').Value
                $head = "$message`n$trailer" | & $gitExecutable -C $target commit-tree $tree -p $source
            }
        }
        & $gitExecutable -C $target push --quiet origin "${head}:refs/heads/retro-distillation/$source"
        { & $publisher -Mode Inspect -RepositoryPath $target } | Should -Throw $Error
    }

    It 'finishes a local checkpoint after losing <Step> without a second commit' -ForEach @(
        @{ Step = 'add' }
        @{ Step = 'commit' }
    ) {
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $commit = Initialize-RetroOutput -Source $source
        & $gitExecutable -C $target switch --quiet --detach $source
        & $gitExecutable -C $target restore --source=$($commit.HeadSha) --staged --worktree .
        Mock git {
            & $gitTransport -Arguments $Arguments
            if ($Arguments -contains $Step) { throw 'Injected local interruption after apply.' }
        }
        { & $publisher -Mode Commit -RepositoryPath $target -SourceSha $source -BodyPath (Join-Path $TestDrive 'pr-body.txt') } |
            Should -Throw '*local interruption*'
        Mock git { & $gitTransport -Arguments $Arguments }
        $result = & $publisher -Mode Commit -RepositoryPath $target -SourceSha $source -BodyPath (Join-Path $TestDrive 'pr-body.txt')
        $result.SourceSha | Should -BeExactly $source
        (& $gitExecutable -C $target rev-list --count "$source..$($result.HeadSha)") | Should -BeExactly '1'
    }
}
