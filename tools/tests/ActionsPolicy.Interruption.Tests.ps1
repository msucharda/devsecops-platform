BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    # The stub of the GitHub API lives in ActionsPolicy.Tests.ps1. The harness reuses its BeforeAll block
    # instead of a copy, so stub changes for new API calls apply here too.
    $stubFile = Join-Path $PSScriptRoot 'ActionsPolicy.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlock = $stubAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'BeforeAll' -and
            $node.CommandElements.Count -eq 2 -and $node.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true) | Select-Object -First 1
    if (-not $stubBlock) { throw "$stubFile has no BeforeAll block for the actions policy stub." }
    . $stubBlock.CommandElements[1].ScriptBlock.GetScriptBlock()
}

Describe 'Actions policy interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $env:REST_API_BEARER = $token
        $stub = Initialize-ActionsPolicyStub
        $plan = Get-InterruptionPlan
        # Both writes are idempotent PUT requests of the complete managed fields:
        # https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#set-github-actions-permissions-for-an-organization
        # https://docs.github.com/en/enterprise-cloud@latest/rest/actions/permissions#set-default-workflow-permissions-for-an-organization
        Mock -ModuleName ActionsPolicy Invoke-WebRequest {
            $uri = [Uri] $Uri
            $method = ([string] $Method).ToUpperInvariant()
            $call = @{ Method = $method; PathAndQuery = $uri.PathAndQuery; Headers = $Headers; Body = $PesterBoundParameters['Body'] }
            $respond = { param($Reply) [pscustomobject]@{ StatusCode = $Reply.Status; Content = $Reply.Body; Headers = @{} } }
            if ($method -ceq 'GET') { return & $respond (Invoke-ActionsPolicyStub @call) }
            Invoke-InterruptionStep -Plan $plan -Request "$method $($uri.AbsolutePath)" -Apply {
                & $respond (Invoke-ActionsPolicyStub @call)
            } -Interrupt {
                [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption."}'; Headers = @{} }
            }
        }
        $resetStub = {
            param([scriptblock] $Prepare)
            $initial = Initialize-ActionsPolicyStub
            $stub.Clear()
            foreach ($key in $initial.Keys) { $stub[$key] = $initial[$key] }
            if ($Prepare) { & $Prepare }
        }
        # The module keeps no local state; Terraform records a resource only after its provisioner succeeds.
        $captureLocal = { $null }
        $restoreLocal = { param($Text) $null = $Text }
        $snapshot = { @{ actions = @{} + $stub.Actions; workflow = @{} + $stub.Workflow } }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    It 'recovers from an interruption at every mutating step of <Name>' -ForEach @(
        @{ Name = 'the managed policy'; Policy = 'managed' }
        @{ Name = 'the GitHub defaults'; Policy = 'default' }
    ) {
        $policy = if ($Policy -ceq 'managed') { $managedPolicy } else { $defaultPolicy }
        $reset = {
            & $resetStub {
                if ($Policy -ceq 'default') {
                    $stub.Actions['allowed_actions'] = 'local_only'
                    $stub.Actions['sha_pinning_required'] = $true
                    $stub.Workflow['can_approve_pull_request_reviews'] = $true
                }
            }
        }
        $run = { Set-ActionsPolicy @target -Policy $policy }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name "Set-ActionsPolicy ($Name)" -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
