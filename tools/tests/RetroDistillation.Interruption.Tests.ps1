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
            } else { & $gitExecutable @Arguments }
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
}
