BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    $stubFile = Join-Path $PSScriptRoot 'VendoringPullRequest.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlocks = @{}
    foreach ($command in $stubAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -cin @('BeforeAll', 'BeforeEach', 'AfterEach') -and -not $stubBlocks.ContainsKey($name) -and
            $command.CommandElements.Count -eq 2 -and $command.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
            $stubBlocks[$name] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
    }
    foreach ($name in @('BeforeAll', 'BeforeEach', 'AfterEach')) {
        if (-not $stubBlocks.ContainsKey($name)) { throw "$stubFile has no $name block for the vendoring stub." }
    }
    . $stubBlocks.BeforeAll
}

Describe 'Vendoring publication interruption harness' -Tag 'Interruption' {
    BeforeEach {
        . $stubBlocks.BeforeEach
        if ($ImportKind -ceq 'release') {
            Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
            $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
            'release content' | Set-Content -LiteralPath (Join-Path $prepared 'platform/README.md')
        }
        $plan = Get-InterruptionPlan
        Mock git {
            if ($Arguments -notcontains 'push') { return & $gitTransport -Arguments $Arguments }
            $ref = $Arguments[-1]
            Invoke-InterruptionStep -Plan $plan -Request "git push $ref" -Identity "branch $ref" -Apply {
                & $gitTransport -Arguments $Arguments
            } -Interrupt { throw 'Injected git push interruption.' }
        }
        Mock Invoke-RestMethod {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            if ($Method -eq 'GET') { return & $cloudTransport -Uri $Uri -Method $Method -Body $Body }
            $request = $Body | ConvertFrom-Json -AsHashtable
            Invoke-InterruptionStep -Plan $plan -Request "$($Method.ToUpperInvariant()) $($Uri.AbsolutePath)" -Identity "PR $($request.head)" -Apply {
                & $cloudTransport -Uri $Uri -Method $Method -Body $Body
            } -Interrupt { throw 'Injected PR creation interruption.' }
        }
        $reset = {
            $cloud.pulls.Clear()
            $cloud.attempt = 0
            foreach ($ref in @(& $gitExecutable --git-dir=$remotePath for-each-ref '--format=%(refname)' refs/heads)) {
                & $gitExecutable --git-dir=$remotePath update-ref -d $ref
            }
        }
        # Each workflow retry checks out trusted main again; local candidate commits are not a recovery journal.
        $captureLocal = { $null }
        $restoreLocal = { param($Text) $null = $Text }
        $run = {
            & $gitExecutable -C $target switch --quiet main
            $cloud.attempt++
            $cloud.result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind $ImportKind `
                -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier "attempt-$($cloud.attempt)"
        }
        $snapshot = {
            @{
                branches = @(& $gitExecutable --git-dir=$remotePath for-each-ref '--format=%(refname) %(tree)' refs/heads)
                pulls = @(foreach ($pull in $cloud.pulls) { @{ head = $pull.head.ref; base = $pull.base.ref; url = $pull.html_url; state = $pull.state } })
                result = @{ branch = $cloud.result.Branch; url = $cloud.result.PullRequest; changes = $cloud.result.HasChanges }
            }
        }
    }

    AfterEach { . $stubBlocks.AfterEach }

    It 'recovers <ImportKind> after branch push and PR creation without duplicate branches or PRs' -ForEach @(
        @{ ImportKind = 'action' }
        @{ ImportKind = 'release' }
    ) {
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
            -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)
        $report = Format-InterruptionResult -Name "Publish-VendoringPullRequest.ps1 ($ImportKind)" -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
        $plan.Requests.Count | Should -Be 2
        $plan.Requests[0] | Should -MatchExactly "^git push HEAD:refs/heads/vendor/$ImportKind/[a-f0-9]{64}$"
        $plan.Requests[1] | Should -BeExactly 'POST /repos/customer-actions/upstream-action/pulls'
    }
}
