BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force -Global
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force -Global
    $shard = Get-InterruptionShard
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $root 'tools/InstanceSetup.psm1') -Force
}

Describe 'Acceptance preparation interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $work
        $statePath = Join-Path $work 'setup-state.json'
        $inventoryPath = Join-Path $work 'bootstrap-resources.json'
        $keysPath = Join-Path $work 'keys.json'
        [IO.File]::WriteAllText($keysPath, '{}')
        $plan = Get-InterruptionPlan
        $remote = @{ Plan = $plan; Rules = @{}; Runs = @{}; EvidenceChecks = 0 }
        InModuleScope InstanceSetup -Parameters @{ Remote = $remote } {
            param($Remote)
            $script:AcceptanceInterruption = $Remote
            Mock Confirm-SetupAction { $true }
            Mock Start-Sleep {}
            Mock Show-SetupMessage {}
            Mock Test-SetupAcceptanceRunEvidence { $script:AcceptanceInterruption.EvidenceChecks++ }
            Mock Invoke-WebRequest {
                param([uri] $Uri, [string] $Method = 'GET', [string] $Body)
                $Method = $Method.ToUpperInvariant()
                $s = $script:AcceptanceInterruption
                $path = $Uri.AbsolutePath
                $data = if ($Body) { ConvertFrom-Json -InputObject $Body -AsHashtable } else { @{} }
                $respond = {
                    param([int] $Code, $Value)
                    [pscustomobject]@{
                        StatusCode = $Code
                        Content = if ($null -eq $Value) { '' } else { ConvertTo-Json -InputObject $Value -Depth 100 -Compress }
                        Headers = @{}
                    }
                }
                switch -CaseSensitive ("$Method $path") {
                    'GET /orgs/demo-platform/rulesets' {
                        $rules = @(foreach ($rule in $s.Rules.Values) {
                            (Get-GitHubApiFixture -Name repos/get-org-rulesets -Set @{
                                '0.id' = $rule.id; '0.name' = $rule.name; '0.source' = 'demo-platform'; '0.enforcement' = 'disabled'
                            })[0]
                        })
                        return & $respond 200 $rules
                    }
                    'GET /orgs/demo-platform/rulesets/7' {
                        $rule = $s.Rules['7']
                        return & $respond 200 (Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{
                            id = $rule.id; name = $rule.name; source = $rule.source; enforcement = $rule.enforcement
                            target = $rule.target; bypass_actors = $rule.bypass_actors; conditions = $rule.conditions; rules = $rule.rules
                        })
                    }
                    'POST /orgs/demo-platform/rulesets' {
                        return Invoke-InterruptionStep -Plan $s.Plan -Request "$Method $path" -Identity 'acceptance ruleset' -Apply {
                            if ($s.Rules.Count) { throw 'Duplicate acceptance ruleset creation.' }
                            $s.Rules['7'] = Get-GitHubApiFixture -Name repos/create-org-ruleset -Set @{
                                id = 7; name = $data.name; source = 'demo-platform'; enforcement = $data.enforcement
                                target = $data.target; bypass_actors = $data.bypass_actors; conditions = $data.conditions; rules = $data.rules
                            }
                            & $respond 201 $s.Rules['7']
                        } -Interrupt { & $respond 503 @{ message = 'Injected interruption.' } }
                    }
                    'GET /repos/demo-platform/instance/git/ref/heads/main' {
                        return & $respond 200 (Get-GitHubApiFixture -Name git/get-ref -Set @{
                            ref = 'refs/heads/main'; 'object.sha' = ('a' * 40)
                        })
                    }
                    'GET /repos/demo-platform/instance/actions/workflows/bootstrap-acceptance.yml/runs' {
                        return & $respond 200 (Get-GitHubApiFixture -Name actions/list-workflow-runs -Set @{
                            total_count = $s.Runs.Count; workflow_runs = @($s.Runs.Values)
                        })
                    }
                    'GET /repos/demo-platform/instance/actions/runs/123' { return & $respond 200 $s.Runs['123'] }
                    'POST /repos/demo-platform/instance/actions/workflows/bootstrap-acceptance.yml/dispatches' {
                        return Invoke-InterruptionStep -Plan $s.Plan -Request "$Method $path" -Identity 'acceptance dispatch' -Apply {
                            if ($s.Runs.Count) { throw 'Duplicate acceptance workflow dispatch.' }
                            $s.Runs['123'] = (Get-GitHubApiFixture -Name actions/list-workflow-runs -Set @{
                                'workflow_runs.0.id' = 123; 'workflow_runs.0.head_sha' = ('a' * 40)
                                'workflow_runs.0.head_branch' = 'main'; 'workflow_runs.0.event' = 'workflow_dispatch'
                                'workflow_runs.0.display_title' = "Bootstrap acceptance $($data.inputs.evidence_id)"
                                'workflow_runs.0.status' = 'completed'; 'workflow_runs.0.conclusion' = 'success'
                            }).workflow_runs[0]
                            & $respond 200 (Get-GitHubApiFixture -Name actions/create-workflow-dispatch -Set @{
                                workflow_run_id = 123
                                run_url = 'https://api.example.ghe.com/repos/demo-platform/instance/actions/runs/123'
                                html_url = 'https://example.ghe.com/demo-platform/instance/actions/runs/123'
                            })
                        } -Interrupt { & $respond 503 @{ message = 'Injected interruption.' } }
                    }
                    default { throw "Unexpected acceptance request: $Method $Uri" }
                }
            }
        }
        $reset = {
            $remote.Rules.Clear()
            $remote.Runs.Clear()
            $remote.EvidenceChecks = 0
            if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
            [IO.File]::WriteAllText($inventoryPath, '{"repository":"demo-platform/instance","resources":[]}')
        }
        $run = {
            InModuleScope InstanceSetup -Parameters @{ Root = $root; Work = $work; Scenario = $scenario } {
                param($Root, $Work, $Scenario)
                $setup = Initialize-SetupContext -RepoPath $Root -WorkPath $Work -ModulesPath (Join-Path $Root 'modules')
                $setup.Settings = @{ name = 'demo'; githubHost = 'example.ghe.com' }
                $setup.GitHubToken = 'gho_test'
                $setup.Acceptance = @{ directory = $Work; repository = 'demo-platform/instance'; azure = @{}; releasePath = $Root; releaseVersion = '0.0.0-test' }
                if (-not $setup.State.ContainsKey('acceptance')) { $setup.State.acceptance = @{} }
                if ($Scenario -ceq 'ruleset') { $null = Invoke-StepAcceptanceRuleset -Setup $setup }
                else { $null = Invoke-StepAcceptanceWorkflow -Setup $setup }
            }
        }
        $captureLocal = {
            @{
                State = if (Test-Path -LiteralPath $statePath) { [IO.File]::ReadAllText($statePath) } else { $null }
                Inventory = [IO.File]::ReadAllText($inventoryPath)
            }
        }.GetNewClosure()
        $restoreLocal = {
            param($Local)
            if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
            if ($null -ne $Local.State) { [IO.File]::WriteAllText($statePath, $Local.State) }
            [IO.File]::WriteAllText($inventoryPath, $Local.Inventory)
        }.GetNewClosure()
        $snapshot = {
            $state = if (Test-Path -LiteralPath $statePath) { Get-Content $statePath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
            $runs = @($remote.Runs.Values | ForEach-Object { $_.Clone() })
            if ($state['acceptance'] -and $state.acceptance['run']) { $state.acceptance.run.evidenceId = '<evidence-id>' }
            foreach ($item in $runs) { $item.display_title = 'Bootstrap acceptance <evidence-id>' }
            @{
                inventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json -AsHashtable
                state = $state; rulesets = $remote.Rules; runs = $runs
                evidenceVerified = $remote.EvidenceChecks -gt 0
            }
        }
    }

    It 'records a disabled acceptance ruleset for teardown after every interrupted creation' {
        $scenario = 'ruleset'
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
            -CaptureLocal $captureLocal -RestoreLocal $restoreLocal -ShardByInterruption @shard)
        $report = Format-InterruptionResult -Name 'acceptance ruleset' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'retains a dispatch identity and never duplicates a workflow after an interrupted request' {
        $scenario = 'workflow'
        $recover = {
            param($InterruptedError)
            $null = $InterruptedError
            # A request that never reached GitHub requires the documented human verification of absence.
            # Confirm-SetupAction acknowledges that decision; the first retry records it and stops.
            try { & $run }
            catch {
                if ($_.Exception.Message -notlike '*The run is missing or pending*') { throw }
                & $run
            }
        }
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Recover $recover -Snapshot $snapshot `
            -CaptureLocal $captureLocal -RestoreLocal $restoreLocal -ShardByInterruption @shard)
        $report = Format-InterruptionResult -Name 'acceptance workflow dispatch (human confirms an absent run)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
