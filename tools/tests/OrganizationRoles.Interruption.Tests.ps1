BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    $stubFile = Join-Path $PSScriptRoot 'OrganizationRoles.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlock = $stubAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'BeforeAll' -and
            $node.CommandElements.Count -eq 2 -and $node.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true) | Select-Object -First 1
    if (-not $stubBlock) { throw "$stubFile has no BeforeAll block for the organization-role stub." }
    . $stubBlock.CommandElements[1].ScriptBlock.GetScriptBlock()
}

Describe 'Organization security manager interruption harness' -Tag Interruption {
    BeforeEach {
        $env:REST_API_BEARER = 'test-org-token'
        $roleStub = @{}
        $plan = Get-InterruptionPlan
        Mock -ModuleName Organizations Invoke-WebRequest {
            $method = ([string] $Method).ToUpperInvariant()
            $path = ([Uri] $Uri).PathAndQuery
            $Headers['X-GitHub-Api-Version'] | Should -BeExactly '2026-03-10'
            if ($method -ceq 'GET') { return Invoke-RoleApiStub -Method $method -Path $path }
            $identity = if ($method -ceq 'PUT') { 'demo-actions/security/8030' }
            Invoke-InterruptionStep -Plan $plan -Request "$method $path" -Identity $identity -Apply {
                Invoke-RoleApiStub -Method $method -Path $path
            } -Interrupt {
                [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption."}'; Headers = @{} }
            }
        }
        $reset = {
            $roleStub.Writes = [Collections.Generic.List[string]]::new()
            $roleStub.Roles = Get-GitHubApiFixture -Name org-roles/list-org-roles.organization-null -Set @{
                'roles.0.name' = 'security_manager'; 'roles.0.source' = 'Predefined'
            }
            $roleStub.Team = Get-GitHubApiFixture -Name org-roles/get-by-name -Set @{
                slug = 'security'; 'organization.login' = 'demo-actions'
            }
            $roleStub.Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{
                '0.id' = 2; '0.slug' = 'other'
            }
        }
        $snapshot = {
            @{
                state = Get-OrganizationSecurityManagerState @target
                assignments = @($roleStub.Assignments | Sort-Object id | ForEach-Object {
                        @{ id = $_.id; slug = $_.slug; type = $_.type; assignment = $_.assignment }
                    })
            }
        }
        $captureLocal = { $null }
        $restoreLocal = { param($Text) $null = $Text }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    It 'recovers assignment without adopting or duplicating another team assignment' {
        $run = { Set-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
                -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Set-OrganizationSecurityManager' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'recovers removal without deleting another team assignment' {
        $prepare = {
            & $reset
            $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                '0.slug' = 'security'
            }
        }
        $run = { Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $prepare -Run $run -Snapshot $snapshot `
                -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Remove-OrganizationSecurityManager' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
