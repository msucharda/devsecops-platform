BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    # The stub of Publish-VendoringPullRequest.ps1 lives in VendoringPullRequest.Tests.ps1. The harness reuses its
    # BeforeAll and first BeforeEach blocks, so stub changes for new API calls apply here too.
    $stubFile = Join-Path $PSScriptRoot 'VendoringPullRequest.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlocks = @{}
    foreach ($command in $stubAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -cin @('BeforeAll', 'BeforeEach') -and -not $stubBlocks.ContainsKey($name) -and
            $command.CommandElements.Count -eq 2 -and $command.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
            $stubBlocks[$name] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
    }
    foreach ($name in @('BeforeAll', 'BeforeEach')) {
        if (-not $stubBlocks.ContainsKey($name)) { throw "$stubFile has no $name block for the vendoring stub." }
    }
    . $stubBlocks.BeforeAll
}

Describe 'Vendoring pull request interruption harness' -Tag 'Interruption' {
    BeforeEach {
        . $stubBlocks.BeforeEach
        $plan = Get-InterruptionPlan
        # The pristine remote: every reset clones it again, and every run starts from a fresh checkout of its main.
        $seed = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        & $gitExecutable clone --quiet --bare $bare $seed
        $originalReceipt = Get-Content -LiteralPath $receipt -Raw
        Mock git {
            if ($Arguments -contains 'push') {
                # Pushing the same branch again does not conflict, so the harness counts repeated pushes.
                Invoke-InterruptionStep -Plan $plan -Request 'git push' -Identity 'push import branch' -Apply {
                    & $gitTransport $Arguments
                } -Interrupt {
                    $global:LASTEXITCODE = 128
                }
                return
            }
            & $gitTransport $Arguments
        }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method, $Body)
            if (-not $Method -or $Method -eq 'GET') { return & $apiTransport -Uri $Uri -Method GET -Body $Body }
            # Pull requests of one head branch do not conflict in the stub, so a repeated creation is a duplicate.
            $identity = if ($Method -eq 'POST') { 'pull request' } else { '' }
            Invoke-InterruptionStep -Plan $plan -Request "$Method $($Uri.AbsolutePath)" -Identity $identity -Apply {
                & $apiTransport -Uri $Uri -Method $Method -Body $Body
            } -Interrupt {
                throw [Net.Http.HttpRequestException]::new('Injected interruption.')
            }
        }
        $reset = {
            Remove-Item -LiteralPath $bare -Recurse -Force
            & $gitExecutable clone --quiet --bare $seed $bare
            $cloud.pulls.Clear()
            $cloud.nextNumber = 1
        }
        # The tool keeps no local state; recovery relies only on the remote branch and the pull request list.
        $captureLocal = { $null }
        $restoreLocal = { param($Text) $null = $Text }
        $snapshot = {
            @{
                branches = @(& $gitExecutable --git-dir=$bare for-each-ref --format='%(refname) %(tree) %(parent) %(committeremail) %(subject)' refs/heads)
                pulls = @(foreach ($pull in $cloud.pulls) {
                        @{ head = $pull.head; base = $pull.base; state = $pull.state; title = $pull.title; body = $pull.body }
                    })
            }
        }
        $run = {
            $checkout = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            & $gitExecutable clone --quiet --branch main $bare $checkout
            $null = & $publisher -PreparedPath $prepared -TargetPath $checkout -ReceiptPath $receipt -Kind action `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com
        }
    }

    It 'recovers from an interruption after the branch push and after a lost PR creation response' {
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Publish-VendoringPullRequest.ps1' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'recovers from an interruption while it replaces a stale import branch and updates its PR' {
        $reset = {
            Remove-Item -LiteralPath $bare -Recurse -Force
            & $gitExecutable clone --quiet --bare $seed $bare
            $cloud.pulls.Clear()
            $cloud.nextNumber = 1
            # A complete import of the earlier content of tag v1 leaves the branch and PR that the run replaces.
            'updated' | Set-Content -LiteralPath (Join-Path $prepared 'action.yml')
            Set-Content -LiteralPath $receipt -Value $originalReceipt
            & $run
            'retagged' | Set-Content -LiteralPath (Join-Path $prepared 'action.yml')
            '{"Repository":"upstream/action","Tag":"v1","Commit":"4444444444444444444444444444444444444444","Sha256":"bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb","Attestation":"not-present","Asset":""}' |
                Set-Content -LiteralPath $receipt
        }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Publish-VendoringPullRequest.ps1 (stale branch)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
