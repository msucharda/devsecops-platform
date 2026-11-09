BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.github/workflows/ci.yml') -Raw)
}

Describe 'Source CI job dependencies' {
    It 'restores pinned dependencies but always verifies them in <Job>' -ForEach @(
        @{ Job = 'platform-checks' }, @{ Job = 'pester' },
        @{ Job = 'interruption' }, @{ Job = 'mutation-shards' }
    ) {
        $steps = @($workflow.jobs[$Job].steps)
        $cache = @($steps | Where-Object { $_['name'] -eq 'Cache verified tool dependencies' })
        $cache.Count | Should -Be 1
        $cache[0].uses | Should -BeExactly 'actions/cache@55cc8345863c7cc4c66a329aec7e433d2d1c52a9'
        $cache[0].with.path | Should -BeExactly 'tools/.dependencies'
        $cache[0].with.key | Should -BeExactly 'tool-dependencies-v1-${{ runner.os }}-${{ runner.arch }}-${{ hashFiles(''tools/requirements.psd1'', ''tools/ToolDependencies.psm1'', ''tools/Install-ToolDependencies.ps1'') }}'
        $cache[0].with['restore-keys'] | Should -BeNullOrEmpty
        $install = @($steps | Where-Object { $_['name'] -eq 'Install tool dependencies' })
        $install.Count | Should -Be 1
        $install[0].run | Should -BeExactly './tools/Install-ToolDependencies.ps1 -Development'
        $install[0]['if'] | Should -BeNullOrEmpty
        $install[0]['continue-on-error'] | Should -Not -BeTrue
        [array]::IndexOf($steps, $cache[0]) | Should -BeLessThan ([array]::IndexOf($steps, $install[0]))
    }

    It 'requires all 24 mutation shards before the stable mutation check can pass' {
        $shards = $workflow.jobs['mutation-shards']
        $shards['timeout-minutes'] | Should -Be 20
        @($shards.strategy.matrix.shard) | Should -BeExactly @(0..23)
        $shards.strategy['fail-fast'] | Should -BeFalse
        $shards['continue-on-error'] | Should -Not -BeTrue
        $shards.env.MUTATION_SHARD | Should -BeExactly '${{ matrix.shard }}/24'
        $step = @($shards.steps | Where-Object { $_['name'] -eq 'Weaken every marked security check' })
        $step[0].run | Should -BeExactly './tools/Invoke-MutationTests.ps1 -Shard $env:MUTATION_SHARD -BaselineTimeoutSeconds 480 -TimeoutSeconds 720 -ReportPath ./artifacts/mutation-report.json'
        $workflow.jobs.mutation.name | Should -BeExactly 'Security check mutation tests'
        @($workflow.jobs.mutation.needs) | Should -BeExactly @('mutation-shards')
        $workflow.jobs.mutation.if | Should -BeExactly '${{ always() }}'
        $workflow.jobs.mutation.steps[0].env.MUTATION_RESULT | Should -BeExactly '${{ needs.mutation-shards.result }}'
        $upload = @($shards.steps | Where-Object { $_['name'] -eq 'Upload mutation report' })
        $upload[0].with.name | Should -BeExactly 'mutation-report-${{ matrix.shard }}'
        $download = @($workflow.jobs.mutation.steps | Where-Object { $_['name'] -eq 'Download mutation shards' })
        $download[0].with.pattern | Should -BeExactly 'mutation-report-*'
        $download[0].with.path | Should -BeExactly 'artifacts/mutation-shards'
        $merge = @($workflow.jobs.mutation.steps | Where-Object { $_['name'] -eq 'Verify the full mutation inventory' })
        $merge.Count | Should -Be 1
        $merge[0].run | Should -BeExactly './tools/Invoke-MutationTests.ps1 -MergeReport @(Get-ChildItem ./artifacts/mutation-shards -Recurse -Filter mutation-report.json | Select-Object -ExpandProperty FullName) -ShardCount 24 -ReportPath ./artifacts/mutation-report.json'
    }

    It 'covers every real security check and mutant exactly once with the configured partition' {
        $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
        Import-Module (Join-Path $repository 'tools/MutationTesting.psm1') -Force
        $configuration = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'security-checks.psd1')
        $allMarkers = @(Get-SecurityCheckMarker -RepoPath $repository -Configuration $configuration)
        $allMutants = @(Get-SecurityCheckMutant -RepoPath $repository -Marker $allMarkers)
        $ast = [Management.Automation.Language.Parser]::ParseFile(
            (Join-Path $repository 'tools/Invoke-MutationTests.ps1'), [ref] $null, [ref] $null)
        $guards = @($ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.IfStatementAst] -and
                $node.Clauses[0].Item1.Extent.Text -ceq '$Shard'
        }, $false))
        $guards.Count | Should -Be 1
        $body = $guards[0].Clauses[0].Item2.Extent.Text
        $selector = [scriptblock]::Create($body.Substring(1, $body.Length - 2))
        $count = @($workflow.jobs['mutation-shards'].strategy.matrix.shard).Count
        $seenChecks = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $seenMutants = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        foreach ($index in 0..($count - 1)) {
            $selection = & {
                $Shard = "$index/$count"
                $markers = @($allMarkers)
                $mutants = @($allMutants)
                . $selector
                @{ Markers = $markers; Mutants = $mutants }
            } 6>$null
            @($selection.Markers).Count | Should -BeGreaterThan 0
            @($selection.Mutants).Count | Should -BeGreaterThan 0
            foreach ($marker in $selection.Markers) {
                $seenChecks.Add($marker.Name) | Should -BeTrue -Because "check $($marker.Name) must occur exactly once"
            }
            foreach ($mutant in $selection.Mutants) {
                $seenMutants.Add($mutant.Id) | Should -BeTrue -Because "mutant $($mutant.Id) must occur exactly once"
                $mutant.Check | Should -BeIn @($selection.Markers.Name)
            }
        }
        @($seenChecks | Sort-Object -CaseSensitive) | Should -BeExactly @($allMarkers.Name | Sort-Object -CaseSensitive)
        @($seenMutants | Sort-Object -CaseSensitive) | Should -BeExactly @($allMutants.Id | Sort-Object -CaseSensitive)
    }

    It 'fails the mutation aggregate when its shards are <Result>' -ForEach @(
        @{ Result = 'failure' }, @{ Result = 'cancelled' }, @{ Result = 'skipped' },
        @{ Result = '' }, @{ Result = 'unknown' }
    ) {
        $saved = [Environment]::GetEnvironmentVariable('MUTATION_RESULT')
        try {
            [Environment]::SetEnvironmentVariable('MUTATION_RESULT', $Result)
            { & ([scriptblock]::Create($workflow.jobs.mutation.steps[0].run)) } | Should -Throw '*Mutation shards did not pass*'
        }
        finally { [Environment]::SetEnvironmentVariable('MUTATION_RESULT', $saved) }
    }

    It 'starts Terraform after root discovery without waiting for any Pester shard' {
        @($workflow.jobs.terraform.needs) | Should -BeExactly @('terraform-roots')
        $workflow.jobs['terraform-roots']['needs'] | Should -BeNullOrEmpty
        $workflow.jobs['terraform-roots'].outputs.roots | Should -BeExactly '${{ steps.terraform-roots.outputs.roots }}'
        $workflow.jobs.terraform.strategy.matrix.root | Should -BeExactly '${{ fromJSON(needs.terraform-roots.outputs.roots) }}'
    }

    It 'runs all four Pester shards and preserves failures instead of cancelling other shards' {
        @($workflow.jobs.pester.strategy.matrix.shard) | Should -BeExactly @(0, 1, 2, 3)
        $workflow.jobs.pester.strategy['fail-fast'] | Should -BeFalse
        $workflow.jobs.pester['continue-on-error'] | Should -Not -BeTrue
        $step = @($workflow.jobs.pester.steps | Where-Object { $_['name'] -eq 'Run Pester' })
        $step.Count | Should -Be 1
        $step[0].run | Should -BeExactly './tools/Invoke-Tests.ps1 -CI -Shard $env:PESTER_SHARD'
        $workflow.jobs.pester.env.PESTER_SHARD | Should -BeExactly '${{ matrix.shard }}/4'
    }

    It 'preserves Platform tools as an aggregate that observes failures and skipped jobs' {
        $workflow.name | Should -BeExactly 'Source CI'
        $workflow.jobs.platform.name | Should -BeExactly 'Platform tools'
        @($workflow.jobs.platform.needs | Sort-Object) | Should -BeExactly @('pester', 'platform-checks', 'terraform-roots')
        $workflow.jobs.platform.if | Should -BeExactly '${{ always() }}'
        $workflow.jobs.platform.steps[0].env.PESTER_RESULT | Should -BeExactly '${{ needs.pester.result }}'
        $workflow.jobs.platform.steps[0].env.PLATFORM_RESULT | Should -BeExactly '${{ needs.platform-checks.result }}'
        $workflow.jobs.platform.steps[0].env.ROOTS_RESULT | Should -BeExactly '${{ needs.terraform-roots.result }}'
    }

    It 'fails Platform tools when <Dependency> is <Result>' -ForEach @(
        foreach ($dependency in 'PESTER_RESULT', 'PLATFORM_RESULT', 'ROOTS_RESULT') {
            foreach ($result in 'failure', 'cancelled', 'skipped', '', 'unknown') {
                @{ Dependency = $dependency; Result = $result }
            }
        }
    ) {
        $saved = @{}
        foreach ($name in 'PLATFORM_RESULT', 'PESTER_RESULT', 'ROOTS_RESULT') {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, 'success')
        }
        try {
            [Environment]::SetEnvironmentVariable($Dependency, $Result)
            { & ([scriptblock]::Create($workflow.jobs.platform.steps[0].run)) } | Should -Throw '*Platform checks did not pass*'
        }
        finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }

    It 'passes Platform tools only when all dependencies succeeded' {
        $saved = @{}
        foreach ($name in 'PLATFORM_RESULT', 'PESTER_RESULT', 'ROOTS_RESULT') {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, 'success')
        }
        try {
            { & ([scriptblock]::Create($workflow.jobs.platform.steps[0].run)) } | Should -Not -Throw
        }
        finally {
            foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }
}
