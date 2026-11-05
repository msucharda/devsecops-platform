BeforeAll {
    $tools = Split-Path $PSScriptRoot -Parent
    $root = Split-Path $tools -Parent
    Import-Module (Join-Path $tools 'MutationTesting.psm1') -Force
    $runner = Join-Path $tools 'Invoke-MutationTests.ps1'
    $worker = Join-Path $PSScriptRoot 'Invoke-MutationWorker.ps1'
    $checkName = 'teardown-workflow-predicates'
    $targetNames = @(
        'cancellation', 'selected-node', 'selection-success', 'approval-success', 'owner-success'
        'prerequisite-success', 'dependent-success', 'dependent-skipped', 'dependent-unselected'
        'identity-dependents', 'nonempty-state', 'always-revoke'
    )
    $contract = @{
        Path = 'tools/tests/TeardownWorkflow.Tests.ps1'
        FullName = @(
            'Teardown workflow generation.destroys <Module> only after every selected dependent and after the owner check'
            'Teardown workflow generation.destroys only selected phase roots*'
            'Teardown workflow generation.destroys emu-identity last*'
            'Teardown workflow generation.passes prerequisite outputs*'
            'Teardown workflow generation.destroys with apply installation tokens and no PAT'
            'Teardown workflow generation.reads every state root*'
            'Teardown identity approval boundary*'
        )
    }

    function Initialize-TeardownMutationRepository {
        $copy = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path (Join-Path $copy 'tools/tests/fixtures') -Force
        foreach ($name in @('Generate-TeardownWorkflow.ps1', 'PlatformTools.psm1', 'ToolDependencies.psm1', 'requirements.psd1')) {
            Copy-Item -LiteralPath (Join-Path $tools $name) -Destination (Join-Path $copy 'tools')
        }
        Copy-Item -LiteralPath (Join-Path $tools 'vendor') -Destination (Join-Path $copy 'tools/vendor') -Recurse
        Copy-Item -LiteralPath (Join-Path $root 'schemas') -Destination (Join-Path $copy 'schemas') -Recurse
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/modules') -Destination (Join-Path $copy 'tools/tests/fixtures/modules') -Recurse
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'TeardownWorkflow.Tests.ps1') -Destination (Join-Path $copy $contract.Path)
        foreach ($module in Get-ChildItem -LiteralPath (Join-Path $root 'modules') -Directory) {
            $manifest = Join-Path $module.FullName 'module.yaml'
            if (-not (Test-Path -LiteralPath $manifest -PathType Leaf)) { continue }
            $destination = Join-Path $copy "modules/$($module.Name)"
            $null = New-Item -ItemType Directory -Path $destination -Force
            Copy-Item -LiteralPath $manifest -Destination $destination
            foreach ($phase in Get-ChildItem -LiteralPath $module.FullName -Directory) {
                $null = New-Item -ItemType Directory -Path (Join-Path $destination $phase.Name) -Force
            }
        }
        return $copy
    }

    function Get-TeardownMutationConfiguration {
        param([string] $Repository)

        return @{
            Checks = @(
                foreach ($marker in @(Get-SecurityCheckMarker -RepoPath $Repository)) {
                    @{ Name = $marker.Name; Tests = @($contract) }
                }
                @{
                    Name = $checkName
                    Kind = 'TeardownWorkflow'
                    File = 'tools/Generate-TeardownWorkflow.ps1'
                    Tests = @($contract)
                }
            )
            Exceptions = @()
        }
    }

    function Get-TeardownMutationInventory {
        param([string] $Repository, [hashtable] $Configuration)

        $markers = @(Get-SecurityCheckMarker -RepoPath $Repository -Configuration $Configuration)
        Assert-SecurityCheckConfiguration -Marker $markers -Configuration $Configuration
        Get-SecurityCheckMutant -RepoPath $Repository -Marker $markers | Where-Object Check -CEQ $checkName
    }

    function Write-TeardownMutationConfiguration {
        param([string] $Path, [hashtable] $Test = $contract)

        $entries = @(foreach ($check in $configuration.Checks) {
            $adapter = if ($check.ContainsKey('Kind')) { "; Kind = '$($check.Kind)'; File = '$($check.File)'" } else { '' }
            $patterns = @($Test.FullName | ForEach-Object { "'$($_.Replace("'", "''"))'" }) -join ', '
            "@{ Name = '$($check.Name)'$adapter; Tests = @(@{ Path = '$($Test.Path)'; FullName = @($patterns) }) }"
        })
        "@{ Checks = @($($entries -join "`n")); Exceptions = @() }" | Set-Content -LiteralPath $Path
    }

    function Get-EmittedPredicate {
        param([System.Collections.IDictionary] $Workflow, [string] $Target)

        switch ($Target) {
            'prerequisite-success' { return $Workflow.jobs.destroy_service.if }
            'dependent-success' { return $Workflow.jobs.destroy_foundation.if }
            'dependent-skipped' { return $Workflow.jobs.destroy_foundation.if }
            'dependent-unselected' { return $Workflow.jobs.destroy_foundation.if }
            'identity-dependents' { return $Workflow.jobs.destroy_emu_identity.if }
            'nonempty-state' {
                return @($Workflow.jobs.destroy_enterprise_baseline.steps |
                    Where-Object { $_.Contains('run') -and $_.run -like '*New-PlatformGitHubToken.ps1*' })[0].if
            }
            'always-revoke' { return $Workflow.jobs.destroy_application.steps[-1].if }
            default { return $Workflow.jobs.destroy_application.if }
        }
    }

    $repo = Initialize-TeardownMutationRepository
    $configuration = Get-TeardownMutationConfiguration -Repository $repo
    $generator = Join-Path $repo 'tools/Generate-TeardownWorkflow.ps1'
    $generatorBytes = [IO.File]::ReadAllBytes($generator)
    $fixtureOutput = Join-Path $repo 'fixture.yml'
    $realOutput = Join-Path $repo 'real.yml'
    & $generator -ModulesPath (Join-Path $repo 'tools/tests/fixtures/modules') -OutputPath $fixtureOutput
    & $generator -ModulesPath (Join-Path $repo 'modules') -OutputPath $realOutput
    $fixtureWorkflow = ConvertFrom-Yaml (Get-Content -LiteralPath $fixtureOutput -Raw)
    $realWorkflow = ConvertFrom-Yaml (Get-Content -LiteralPath $realOutput -Raw)
}

Describe 'Teardown generated-predicate mutation inventory' {
    It 'registers the generated target against the existing teardown contracts without exceptions' {
        $shared = Import-PowerShellDataFile -LiteralPath (Join-Path $PSScriptRoot 'security-checks.psd1')
        $configured = @($shared.Checks | Where-Object { $_.Name -ceq $checkName })

        $configured.Count | Should -Be 1
        $configured[0].Kind | Should -BeExactly 'TeardownWorkflow'
        $configured[0].File | Should -BeExactly 'tools/Generate-TeardownWorkflow.ps1'
        @($configured[0].Tests).Count | Should -Be 1
        $configured[0].Tests[0].Path | Should -BeExactly $contract.Path
        @($configured[0].Tests[0].FullName | Sort-Object) | Should -BeExactly @($contract.FullName | Sort-Object)
        @($shared.Exceptions | Where-Object { $_.Mutant -clike "${checkName}:*" }).Count | Should -Be 0
    }

    It 'discovers the explicit generator adapter without adding a production function marker' {
        $legacy = @(Get-SecurityCheckMarker -RepoPath $repo)
        $markers = @(Get-SecurityCheckMarker -RepoPath $repo -Configuration $configuration)
        $generated = @($markers | Where-Object Name -CEQ $checkName)

        $generated.Count | Should -Be 1
        $generated[0].Kind | Should -BeExactly 'TeardownWorkflow'
        $generated[0].File | Should -BeExactly 'tools/Generate-TeardownWorkflow.ps1'
        @($legacy | Where-Object Name -CEQ $checkName).Count | Should -Be 0
        @($markers | Where-Object Name -CNE $checkName | ConvertTo-Json -Depth 5) |
            Should -BeExactly @($legacy | ConvertTo-Json -Depth 5)
        (Get-Content -LiteralPath $generator -Raw) | Should -Not -Match '# security-check:'
    }

    It 'adds only the bounded emitted predicates and preserves every existing function mutant record' {
        $legacyMarkers = @(Get-SecurityCheckMarker -RepoPath $repo)
        $legacy = @(Get-SecurityCheckMutant -RepoPath $repo -Marker $legacyMarkers)
        $markers = @(Get-SecurityCheckMarker -RepoPath $repo -Configuration $configuration)
        Assert-SecurityCheckConfiguration -Marker $markers -Configuration $configuration
        $inventory = @(Get-SecurityCheckMutant -RepoPath $repo -Marker $markers)
        $generated = @($inventory | Where-Object Check -CEQ $checkName)

        @($generated.Id | Sort-Object) | Should -BeExactly @($targetNames | ForEach-Object { "${checkName}: ${_}#1" } | Sort-Object)
        @($inventory | Where-Object Check -CNE $checkName | ConvertTo-Json -Depth 5) |
            Should -BeExactly @($legacy | ConvertTo-Json -Depth 5)
        @($inventory.Id | Sort-Object -Unique).Count | Should -Be $inventory.Count
        $generated.File | Select-Object -Unique | Should -BeExactly 'tools/Generate-TeardownWorkflow.ps1'
    }

    It 'keeps the existing function mutant IDs and replacements unchanged' {
        $ast = [Management.Automation.Language.Parser]::ParseInput(
            "function Test-Stable { if (`$value -cne 'yes') { return `$false }; return `$true }",
            [ref] $null, [ref] $null)
        $function = $ast.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $true)
        $mutants = @(Get-FunctionMutant -Function $function)

        @($mutants.Id | Sort-Object) | Should -BeExactly @(
            "Test-Stable: condition '`$value -cne 'yes'' -> `$false#1"
            "Test-Stable: condition '`$value -cne 'yes'' negated#1"
            "Test-Stable: operator '-cne' -> -ine in '`$value -cne 'yes''#1"
        )
        @($mutants.Replacement | Sort-Object) |
            Should -BeExactly @(@('(-not ($value -cne ''yes''))', '($false)', '-ine') | Sort-Object)
    }

    It 'changes the actual emitted <Target> predicate while the generator and YAML remain executable' -ForEach @(
        @{ Target = 'cancellation'; Required = '!cancelled()' }
        @{ Target = 'selected-node'; Required = "contains(fromJSON(needs.select.outputs.phaseNodes), 'application')" }
        @{ Target = 'selection-success'; Required = "needs.select.result == 'success'" }
        @{ Target = 'approval-success'; Required = "needs.approve_teardown.result == 'success'" }
        @{ Target = 'owner-success'; Required = "needs.enterprise_owner.result == 'success'" }
        @{ Target = 'prerequisite-success'; Required = "needs.outputs_application.result == 'success'" }
        @{ Target = 'dependent-success'; Required = "needs.destroy_application.result == 'success'" }
        @{ Target = 'dependent-skipped'; Required = "needs.destroy_application.result == 'skipped'" }
        @{ Target = 'dependent-unselected'; Required = "!contains(fromJSON(needs.select.outputs.phaseNodes), 'application')" }
        @{ Target = 'identity-dependents'; Required = "needs.destroy_organization_rulesets.result == 'success'" }
        @{ Target = 'nonempty-state'; Required = "steps.state.outputs.empty != 'true'" }
        @{ Target = 'always-revoke'; Required = 'always()' }
    ) {
        $inventory = @(Get-TeardownMutationInventory -Repository $repo -Configuration $configuration)
        $mutant = @($inventory | Where-Object Id -CEQ "${checkName}: ${Target}#1")
        $mutant.Count | Should -Be 1
        $original = if ($Target -ceq 'identity-dependents') { $realWorkflow } else { $fixtureWorkflow }
        (Get-EmittedPredicate -Workflow $original -Target $Target) | Should -Match ([regex]::Escape($Required))
        try {
            [IO.File]::WriteAllText($generator, $mutant[0].Text)
            $parseErrors = $null
            $null = [Management.Automation.Language.Parser]::ParseFile($generator, [ref] $null, [ref] $parseErrors)
            @($parseErrors).Count | Should -Be 0
            $modules = if ($Target -ceq 'identity-dependents') { 'modules' } else { 'tools/tests/fixtures/modules' }
            $emitted = Join-Path $repo "emitted-$Target.yml"
            { & $generator -ModulesPath (Join-Path $repo $modules) -OutputPath $emitted } | Should -Not -Throw
            $yaml = ConvertFrom-Yaml (Get-Content -LiteralPath $emitted -Raw) -ErrorAction Stop
            $yaml | Should -BeOfType ([System.Collections.IDictionary])
            $predicate = Get-EmittedPredicate -Workflow $yaml -Target $Target
            $predicate | Should -Not -BeNullOrEmpty
            $predicate | Should -Not -Match ([regex]::Escape($Required))
            if ($Target -ceq 'cancellation') {
                $predicate | Should -Match '^\$\{\{ always\(\) && '
            }
        }
        finally { [IO.File]::WriteAllBytes($generator, $generatorBytes) }
    }

    It 'fails closed for an invalid adapter <Case>' -ForEach @(
        @{ Case = 'kind'; Key = 'Kind'; Value = 'Unknown'; Message = '*Unsupported mutation adapter*' }
        @{ Case = 'empty kind'; Key = 'Kind'; Value = ''; Message = '*Unsupported mutation adapter*' }
        @{ Case = 'array kind'; Key = 'Kind'; Value = @('TeardownWorkflow'); Message = '*Unsupported mutation adapter*' }
        @{ Case = 'wrong file'; Key = 'File'; Value = 'tools/PlatformTools.psm1'; Message = '*TeardownWorkflow*File*' }
        @{ Case = 'empty file'; Key = 'File'; Value = ''; Message = '*TeardownWorkflow*File*' }
        @{ Case = 'array file'; Key = 'File'; Value = @('tools/Generate-TeardownWorkflow.ps1'); Message = '*TeardownWorkflow*File*' }
        @{ Case = 'path escape'; Key = 'File'; Value = '../Generate-TeardownWorkflow.ps1'; Message = '*TeardownWorkflow*File*' }
        @{ Case = 'empty name'; Key = 'Name'; Value = ''; Message = '*valid security check Name*' }
        @{ Case = 'invalid name'; Key = 'Name'; Value = 'teardown workflow'; Message = '*valid security check Name*' }
        @{ Case = 'array name'; Key = 'Name'; Value = @('teardown-workflow-predicates'); Message = '*valid security check Name*' }
    ) {
        $invalid = Get-TeardownMutationConfiguration -Repository $repo
        $invalid.Checks[-1][$Key] = $Value

        { Get-SecurityCheckMarker -RepoPath $repo -Configuration $invalid } | Should -Throw $Message
    }

    It 'rejects configuring the same generator adapter more than once under different check names' {
        $invalid = Get-TeardownMutationConfiguration -Repository $repo
        $second = @{} + $invalid.Checks[-1]
        $second.Name = 'another-teardown-workflow'
        $invalid.Checks += @($second)

        { Get-SecurityCheckMarker -RepoPath $repo -Configuration $invalid } |
            Should -Throw '*TeardownWorkflow adapter must be configured exactly once*'
    }

    It 'rejects an unsupported adapter marker before generating mutants' {
        $invalid = [pscustomobject]@{
            Name = $checkName; Kind = 'Unknown'; File = 'tools/Generate-TeardownWorkflow.ps1'; Line = 1
        }

        { Get-SecurityCheckMutant -RepoPath $repo -Marker @($invalid) } |
            Should -Throw '*Unsupported mutation adapter target*'
    }

    It 'fails closed instead of silently omitting a <Case> generated predicate target' -ForEach @(
        @{ Case = 'missing'; Duplicate = $false }
        @{ Case = 'duplicate'; Duplicate = $true }
    ) {
        $source = [Text.Encoding]::UTF8.GetString($generatorBytes)
        $literal = '!cancelled() && $gateCondition'
        # Deliberately invalid adapter input: the supported source target is absent or ambiguous.
        $changed = if ($Duplicate) { $source + "`n# $literal" } else { $source.Replace($literal, '$gateCondition') }
        try {
            [IO.File]::WriteAllText($generator, $changed)
            { Get-TeardownMutationInventory -Repository $repo -Configuration $configuration } |
                Should -Throw '*cancellation*exactly once*'
        }
        finally { [IO.File]::WriteAllBytes($generator, $generatorBytes) }
    }

    It 'rejects a missing generator instead of returning an empty inventory' {
        $missing = Initialize-TeardownMutationRepository
        $missingConfiguration = Get-TeardownMutationConfiguration -Repository $missing
        Remove-Item -LiteralPath (Join-Path $missing 'tools/Generate-TeardownWorkflow.ps1')

        { Get-TeardownMutationInventory -Repository $missing -Configuration $missingConfiguration } |
            Should -Throw '*Generate-TeardownWorkflow.ps1*'
    }
}

Describe 'Teardown mutation execution through the existing worker and runner' -Tag Integration {
    It 'kills an emitted cancellation mutant with an existing contract assertion, not a generator or runner error, and restores the source' {
        $inventory = @(Get-TeardownMutationInventory -Repository $repo -Configuration $configuration)
        $mutant = @($inventory | Where-Object Id -CEQ "${checkName}: cancellation#1")[0]
        $cancellationContract = @{
            Path = $contract.Path
            FullName = @('Teardown identity approval boundary.does not destroy identity when the run is cancelled after preceding modules finished')
        }
        $jobs = @(
            @{ Id = 'baseline-before'; File = $mutant.File; Text = $null; Tests = @($cancellationContract) }
            @{ Id = $mutant.Id; File = $mutant.File; Text = $mutant.Text; Tests = @($cancellationContract); RequireAssertionFailure = $true }
            @{ Id = 'baseline-after'; File = $mutant.File; Text = $null; Tests = @($cancellationContract) }
        )
        $jobsPath = Join-Path $repo 'jobs.json'
        $resultsPath = Join-Path $repo 'worker-results.jsonl'
        ConvertTo-Json -InputObject $jobs -Depth 6 | Set-Content -LiteralPath $jobsPath

        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $worker -RepoPath $repo -JobsPath $jobsPath -ResultPath $resultsPath

        $LASTEXITCODE | Should -Be 0
        $results = @(Get-Content -LiteralPath $resultsPath | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $results.Count | Should -Be 3
        foreach ($index in @(0, 2)) {
            (Get-MutationJobStatus -Result $results[$index])[0] | Should -BeExactly 'Survived'
            $results[$index].Passed | Should -BeGreaterThan 0
            $results[$index].Errors | Should -Be 0
        }
        $results[1].Errors | Should -Be 0
        $results[1].Failed | Should -BeGreaterThan 0
        $results[1].Failures -join ' ' | Should -Match 'does not destroy identity when the run is cancelled after preceding modules finished'
        @($results[1].FailedTests).Count | Should -Be 1
        $results[1].FailedTests[0].ExpandedPath | Should -BeExactly $cancellationContract.FullName[0]
        @($results[1].FailedTests[0].FullyQualifiedErrorId) | Should -BeExactly @('PesterAssertionFailed')
        (Get-MutationJobStatus -Result $results[1])[0] | Should -BeExactly 'Killed'
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($generator)) | Should -BeExactly ([Convert]::ToBase64String($generatorBytes))
    }

    It 'does not count an unexpected exception inside It as a killed generated mutant' {
        $inventory = @(Get-TeardownMutationInventory -Repository $repo -Configuration $configuration)
        $mutant = @($inventory | Where-Object Id -CEQ "${checkName}: cancellation#1")[0]
        $unexpectedContract = @{
            Path = 'tools/tests/Unexpected.Tests.ps1'
            FullName = @('Unexpected contract failure.rejects cancellation')
        }
        @'
BeforeAll {
    $generator = Join-Path $PSScriptRoot '../Generate-TeardownWorkflow.ps1'
}
Describe 'Unexpected contract failure' {
    It 'rejects cancellation' {
        $output = Join-Path $TestDrive 'unexpected.yml'
        & $generator -ModulesPath (Join-Path $PSScriptRoot 'fixtures/modules') -OutputPath $output
        $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath $output -Raw)
        if ($workflow.jobs.destroy_application.if -notmatch [regex]::Escape('!cancelled()')) {
            throw [InvalidOperationException]::new('Unexpected exception inside It.')
        }
        $workflow.jobs.destroy_application.if | Should -Not -BeNullOrEmpty
    }
}
'@ | Set-Content -LiteralPath (Join-Path $repo $unexpectedContract.Path)
        $jobs = @(
            @{ Id = 'unexpected-baseline-before'; File = $mutant.File; Text = $null; Tests = @($unexpectedContract) }
            @{ Id = $mutant.Id; File = $mutant.File; Text = $mutant.Text; Tests = @($unexpectedContract); RequireAssertionFailure = $true }
            @{ Id = 'unexpected-baseline-after'; File = $mutant.File; Text = $null; Tests = @($unexpectedContract) }
        )
        $jobsPath = Join-Path $repo 'unexpected-jobs.json'
        $resultsPath = Join-Path $repo 'unexpected-results.jsonl'
        ConvertTo-Json -InputObject $jobs -Depth 6 | Set-Content -LiteralPath $jobsPath

        & (Get-Process -Id $PID).Path -NoLogo -NoProfile -NonInteractive -File $worker -RepoPath $repo -JobsPath $jobsPath -ResultPath $resultsPath

        $LASTEXITCODE | Should -Be 0
        $results = @(Get-Content -LiteralPath $resultsPath | ForEach-Object { $_ | ConvertFrom-Json -AsHashtable })
        $results.Count | Should -Be 3
        foreach ($index in @(0, 2)) {
            (Get-MutationJobStatus -Result $results[$index])[0] | Should -BeExactly 'Survived'
            $results[$index].Passed | Should -Be 1
            @($results[$index].FailedTests).Count | Should -Be 0
        }
        $results[1].Failed | Should -Be 1
        @($results[1].FailedTests).Count | Should -Be 1
        $results[1].FailedTests[0].ExpandedPath | Should -BeExactly $unexpectedContract.FullName[0]
        @($results[1].FailedTests[0].FullyQualifiedErrorId) | Should -BeExactly @('Unexpected exception inside It.')
        (Get-MutationJobStatus -Result $results[1])[0] | Should -BeExactly 'Error'
        $results[1].Errors | Should -Be 1
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($generator)) | Should -BeExactly ([Convert]::ToBase64String($generatorBytes))

        $configurationPath = Join-Path $repo 'unexpected-checks.psd1'
        Write-TeardownMutationConfiguration -Path $configurationPath -Test $unexpectedContract
        $reportPath = Join-Path $repo 'unexpected-report.json'

        { & $runner -RepoPath $repo -ConfigurationPath $configurationPath -Check $checkName -ThrottleLimit 1 -ReportPath $reportPath 6>$null } |
            Should -Throw '*Mutation testing failed*'

        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        $cancelled = @($report.mutants | Where-Object Id -CEQ $mutant.Id)
        $cancelled.Count | Should -Be 1
        $cancelled[0].Status | Should -BeExactly 'Error'
        $cancelled[0].Detail | Should -Match '\[Unexpected exception inside It\.\]'
        @($report.mutants | Where-Object Status -CEQ 'Killed').Count | Should -Be 0
        $report.problems -join ' ' | Should -Match 'cancellation#1 ended with Error'
    }

    It 'runs every configured generated mutant through the normal report machinery without survivors or exemptions' {
        $configurationPath = Join-Path $repo 'checks.psd1'
        Write-TeardownMutationConfiguration -Path $configurationPath
        $reportPath = Join-Path $repo 'report.json'

        & $runner -RepoPath $repo -ConfigurationPath $configurationPath -Check $checkName -Shard 0/1 -ThrottleLimit 1 -ReportPath $reportPath 6>$null

        $report = Get-Content -LiteralPath $reportPath -Raw | ConvertFrom-Json
        @($report.problems).Count | Should -Be 0
        @($report.mutants).Count | Should -Be $targetNames.Count
        $report.mutants.Status | Select-Object -Unique | Should -BeExactly 'Killed'
        $report.mutants.Detail -join ' ' | Should -Match 'Teardown (workflow generation|identity approval boundary)'
        foreach ($mutant in $report.mutants) {
            $mutant.Detail | Should -Match '\[PesterAssertionFailed\]'
        }
        $report.phases.baseline.completed | Should -Be 1
        $report.phases.mutant.completed | Should -Be $targetNames.Count
        $report.phases.mutant.unfinished | Should -Be 0
        [Convert]::ToBase64String([IO.File]::ReadAllBytes($generator)) | Should -BeExactly ([Convert]::ToBase64String($generatorBytes))
    }
}
