BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    $stubFile = Join-Path $PSScriptRoot 'Organizations.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlock = $stubAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'BeforeAll' -and
            $node.CommandElements.Count -eq 2 -and $node.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true) | Select-Object -First 1
    if (-not $stubBlock) { throw "$stubFile has no BeforeAll block for the organizations stub." }
    . $stubBlock.CommandElements[1].ScriptBlock.GetScriptBlock()
}

Describe 'Organizations installation interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $env:REST_API_BEARER = $token
        $stub = Initialize-OrganizationsStub
        $plan = Get-InterruptionPlan
        Mock -ModuleName Organizations Invoke-WebRequest {
            $uri = [Uri] $Uri
            $method = ([string] $Method).ToUpperInvariant()
            $call = @{ Method = $method; PathAndQuery = $uri.PathAndQuery; Headers = $Headers; Body = $PesterBoundParameters['Body'] }
            $respond = {
                param($Reply)
                [pscustomobject]@{ StatusCode = $Reply.Status; Content = $Reply.Body; Headers = @{ Link = $Reply['Link'] } }
            }
            if ($method -ceq 'GET') { return & $respond (Invoke-OrganizationsStub @call) }
            $identity = if ($method -ceq 'POST') {
                $request = ConvertFrom-Json -InputObject $Body -AsHashtable
                "$($uri.AbsolutePath)/$($request.client_id)"
            }
            Invoke-InterruptionStep -Plan $plan -Request "$method $($uri.AbsolutePath)" -Identity $identity -Apply {
                & $respond (Invoke-OrganizationsStub @call)
            } -Interrupt {
                [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption."}'; Headers = @{ Link = $null } }
            }
        }
        $reset = {
            $initial = Initialize-OrganizationsStub
            $stub.Clear()
            foreach ($key in $initial.Keys) { $stub[$key] = $initial[$key] }
            Add-StubOrganization -Login 'demo-a1b2c3-actions'
        }
        $snapshot = {
            @{
                installations = @($stub.Installations['demo-a1b2c3-actions'] | ForEach-Object {
                        @{ client_id = $_.client_id; repository_selection = $_.repository_selection; repositories = @($_.repositories) }
                    })
            }
        }
        $captureLocal = { $null }
        $restoreLocal = { param($Text) $null = $Text }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    It 'recovers every installation write for the <Selection> repository selection' -ForEach @(
        @{ Selection = 'none' }
        @{ Selection = 'all' }
    ) {
        $run = {
            $null = Install-OrganizationApp @target -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01' -RepositorySelection $Selection
        }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
                -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name "Install-OrganizationApp ($Selection)" -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'recovers every uninstall write for the <Selection> repository selection' -ForEach @(
        @{ Selection = 'selected' }
        @{ Selection = 'all' }
    ) {
        $prepare = {
            & $reset
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01' -Selection $Selection
        }
        $run = { Uninstall-OrganizationApp @target -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01' }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $prepare -Run $run -Snapshot $snapshot `
                -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name "Uninstall-OrganizationApp ($Selection)" -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
