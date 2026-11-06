BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    $stubFile = Join-Path $PSScriptRoot 'RetroDistillation.Tests.ps1'
    $errors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $errors)
    if ($errors) { throw 'Cannot parse distillation fixture setup.' }
    $blocks = @{}
    foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -cin @('BeforeAll', 'BeforeEach') -and -not $blocks.ContainsKey($name)) {
            $blocks[$name] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
    }
    . $blocks.BeforeAll
}

Describe 'Distillation publication interruption harness' -Tag 'Interruption' {
    BeforeEach {
        . $blocks.BeforeEach
        Add-RetroBatch
        $source = & $gitExecutable -C $target rev-parse main
        $plan = Get-InterruptionPlan
        Mock git {
            if ($Arguments -contains 'push') {
                Invoke-InterruptionStep -Plan $plan -Request 'git push distillation' -Identity 'distillation branch' -Apply {
                    & $gitExecutable @Arguments
                } -Interrupt { throw 'Injected push interruption.' }
            } else { & $gitTransport -Arguments $Arguments }
        }
        Mock gh {
            if ($Arguments -contains 'POST') {
                Invoke-InterruptionStep -Plan $plan -Request 'POST pulls' -Identity 'distillation PR' -Apply {
                    & $ghTransport -Arguments $Arguments
                } -Interrupt { throw 'Injected PR interruption.' }
            } else { & $ghTransport -Arguments $Arguments }
        }
        $reset = {
            & $gitExecutable -C $target switch --quiet --detach $source
            foreach ($ref in @(& $gitExecutable --git-dir=$remote for-each-ref '--format=%(refname)' refs/heads/retro-distillation)) {
                & $gitExecutable --git-dir=$remote update-ref -d $ref
            }
            $cloud.pulls.Clear()
            $cloud.writes = 0
            $cloud.result = $null
        }
        $run = {
            $inspection = & $publisher -Mode Inspect -RepositoryPath $target
            if ($inspection.Action -ceq 'Prepare') {
                & $gitExecutable -C $target switch --quiet --detach $source
                $null = Initialize-RetroOutput -Source $source
            }
            $cloud.result = & $publisher -Mode Publish -RepositoryPath $target
        }
        $snapshot = {
            @{
                branches = @(& $gitExecutable --git-dir=$remote for-each-ref '--format=%(refname) %(tree)' refs/heads/retro-distillation)
                pulls = @($cloud.pulls | ForEach-Object { @{ branch = $_.head.ref; body = $_.body; state = $_.state } })
                writes = $cloud.writes
            }
        }
    }

    It 'recovers before or after push and PR writes without another branch, PR or regenerated output' {
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
            -CaptureLocal { $null } -RestoreLocal { param($State) $null = $State } @shard)
        $report = Format-InterruptionResult -Name 'Retrospective distillation' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
        $plan.Requests.Count | Should -Be 2
    }

    It 'preserves every finding when restarted midway through deleting processed retrospectives' {
        Mock git { & $gitTransport -Arguments $Arguments }
        Mock gh { & $ghTransport -Arguments $Arguments }
        Mock Remove-Item {
            Invoke-InterruptionStep -Plan $plan -Request "delete $([IO.Path]::GetFileName($LiteralPath))" -Apply {
                Microsoft.PowerShell.Management\Remove-Item -LiteralPath $LiteralPath
            } -Interrupt { throw 'Injected retrospective deletion interruption.' }
        } -ParameterFilter { $LiteralPath -like '*2026-11-06-fixture-*.md' }
        $capture = {
            $files = @{}
            foreach ($file in Get-ChildItem -LiteralPath $target -Recurse -File) {
                $files[[IO.Path]::GetRelativePath($target, $file.FullName)] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
            }
            @{ Files = $files }
        }
        $restore = {
            param($State)
            foreach ($file in Get-ChildItem -LiteralPath $target -Recurse -File) {
                if (-not $State.Files.ContainsKey([IO.Path]::GetRelativePath($target, $file.FullName))) {
                    Microsoft.PowerShell.Management\Remove-Item -LiteralPath $file.FullName
                }
            }
            foreach ($path in $State.Files.Keys) {
                $fullPath = Join-Path $target $path
                $null = New-Item -ItemType Directory -Path (Split-Path $fullPath -Parent) -Force
                [IO.File]::WriteAllBytes($fullPath, [Convert]::FromBase64String($State.Files[$path]))
            }
        }
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
            -CaptureLocal $capture -RestoreLocal $restore @shard)
        $report = Format-InterruptionResult -Name 'Retrospective source deletion' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
        $plan.Requests.Count | Should -Be 3
        if ($result.Count -eq 0) { return }
        @($result | Where-Object { $_.Step -eq 2 -and $_.Kind -ceq 'LoseResponse' }).Count |
            Should -Be $(if ((1 % $shard.ShardCount) -eq $shard.ShardIndex) { 2 } else { 0 })
        $branch = $cloud.pulls[0].head.ref
        $guide = (& $gitExecutable --git-dir=$remote show "${branch}:docs/agents/guide/source-reading.md") -join "`n"
        $candidates = (& $gitExecutable --git-dir=$remote show "${branch}:docs/agents/retros/candidates.md") -join "`n"
        $guide | Should -MatchExactly 'Agent musí číst inventář i obsah z jednoho uloženého SHA'
        $guide | Should -MatchExactly "$source/docs/agents/retros/2026-11-06-fixture-a.md"
        $guide | Should -MatchExactly "$source/docs/agents/retros/2026-11-06-fixture-b.md"
        $candidates | Should -MatchExactly 'Opakování nápovědy'
        $candidates | Should -MatchExactly "$source/docs/agents/retros/2026-11-06-fixture-c.md"
        $cloud.pulls.Count | Should -Be 1
        $cloud.writes | Should -Be 1
        @(& $gitExecutable --git-dir=$remote ls-tree -r --name-only $branch |
            Where-Object { $_ -like 'docs/agents/retros/2026-*.md' }).Count | Should -Be 0
    }
}
