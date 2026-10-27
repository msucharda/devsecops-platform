BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $workflow = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.github/workflows/ci.yml') -Raw)
}

Describe 'Source CI job dependencies' {
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
