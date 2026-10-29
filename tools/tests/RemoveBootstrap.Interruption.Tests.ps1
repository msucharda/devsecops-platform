BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    $stubFile = Join-Path $PSScriptRoot 'RemoveBootstrap.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlocks = @{}
    foreach ($command in $stubAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -cin @('BeforeAll', 'BeforeEach', 'AfterAll') -and
            $command.CommandElements.Count -eq 2 -and
            $command.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
            if (-not $stubBlocks.ContainsKey($name)) { $stubBlocks[$name] = [Collections.Generic.List[scriptblock]]::new() }
            $stubBlocks[$name].Add($command.CommandElements[1].ScriptBlock.GetScriptBlock())
        }
    }
    if ($stubBlocks.BeforeAll.Count -lt 2 -or $stubBlocks.BeforeEach.Count -lt 1 -or $stubBlocks.AfterAll.Count -lt 1) {
        throw "$stubFile has no public setup, per-test setup, or token cleanup for the removal stub."
    }
    $webMock = $stubAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'Mock' -and
            $node.CommandElements.Count -eq 3 -and $node.CommandElements[1].Extent.Text -ceq 'Invoke-WebRequest' -and
            $node.CommandElements[2] -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true) | Select-Object -First 1
    if (-not $webMock) { throw "$stubFile has no Invoke-WebRequest removal stub." }
    $stubTransport = $webMock.CommandElements[2].ScriptBlock.GetScriptBlock()
    . $stubBlocks.BeforeAll[0]
    $invokeStub = {
        param($Transport, $Uri, $Method, $Body, $Headers, $world, $requests, $failure, $ghLogin, $azureLogin)
        & $Transport
    }
}

Describe 'Bootstrap removal interruption harness' -Tag 'Interruption' {
    BeforeAll {
        . $stubBlocks.BeforeAll[1]
    }

    AfterAll {
        . $stubBlocks.AfterAll[0]
    }

    BeforeEach {
        . $stubBlocks.BeforeEach[0]
        $plan = Get-InterruptionPlan
        Mock Invoke-WebRequest {
            $verb = ([string] $Method).ToUpperInvariant()
            $call = @{
                Transport = $stubTransport; Uri = $Uri; Method = $verb; Body = $Body; Headers = $Headers
                world = $world; requests = $requests; failure = $failure
                ghLogin = $ghLogin; azureLogin = $azureLogin
            }
            if ($verb -ceq 'GET') { return & $invokeStub @call }
            $address = [uri] $Uri
            $invocation = @{ Transport = $invokeStub; Arguments = $call }
            $apply = {
                $transport = $invocation.Transport
                $arguments = $invocation.Arguments
                & $transport @arguments
            }.GetNewClosure()
            Invoke-InterruptionStep -Plan $plan -Request "$verb $($address.PathAndQuery)" -Apply $apply -Interrupt {
                throw 'Injected interruption during bootstrap removal.'
            }
        }

        $initialInventory = [IO.File]::ReadAllText($inventoryPath)
        $reset = {
            $freshWorld = Get-TestWorld
            $world.Clear()
            foreach ($key in $freshWorld.Keys) { $world[$key] = $freshWorld[$key] }
            $requests.Clear()
            $failure.At = 0
            $failure.After = $false
            $failure.Count = 0
            [IO.File]::WriteAllText($inventoryPath, $initialInventory)
        }
        $captureLocal = { if (Test-Path -LiteralPath $inventoryPath) { [IO.File]::ReadAllText($inventoryPath) } }.GetNewClosure()
        $restoreLocal = {
            param($Text)
            if ($null -eq $Text) {
                Remove-Item -LiteralPath $inventoryPath -ErrorAction SilentlyContinue
            }
            else {
                [IO.File]::WriteAllText($inventoryPath, $Text)
            }
        }
        $snapshot = {
            @{
                inventory = & $readInventory
                remote = @{
                    repository = $world.Repository
                    organization = $world.Organization
                    organizationDeleting = $world.OrganizationDeleting
                    actionsEnabled = $world.ActionsEnabled
                    resourceGroup = $world.ResourceGroup
                    resourceGroupDeleting = $world.ResourceGroupDeleting
                    lock = $world.Lock
                    identities = @($world.Identities.ToArray())
                    roleAssignments = @($world.RoleAssignments.ToArray())
                    roleDefinitions = @($world.RoleDefinitions.ToArray())
                    directoryAssignments = @($world.DirectoryAssignments.ToArray())
                }
            }
        }
    }

    It 'recovers from every mutating request of a full bootstrap removal' {
        $runRemoval = {
            $result = & $run 3>$null 6>$null
            if (-not $result.Completed) { throw 'Bootstrap removal did not complete.' }
            & $assertRemoved
        }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $runRemoval -Snapshot $snapshot `
                -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Remove-Bootstrap.ps1 (full removal)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
