BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $repositoryRoot = Split-Path $toolsPath -Parent
    $generator = Join-Path $toolsPath 'Generate-TeardownWorkflow.ps1'
    $configurationCheck = Join-Path $toolsPath 'Test-TeardownConfiguration.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
    $output = Join-Path $TestDrive 'teardown.yml'
    & $generator -ModulesPath $fixtures -OutputPath $output
    $text = Get-Content -LiteralPath $output -Raw
    $workflow = ConvertFrom-Yaml $text
    $graph = @{
        foundation = @()
        application = @('foundation')
        service = @('application', 'foundation')
        'enterprise-baseline' = @('service')
        observer = @()
    }

    function Get-StepRun {
        param([Parameter(Mandatory)][string] $Job)
        @($workflow.jobs[$Job].steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run })
    }
}

Describe 'Teardown workflow generation' {
    It 'is started only manually from main with read-only defaults and serialized with main deployments' {
        @($workflow.on.Keys) | Should -Be @('workflow_dispatch')
        $workflow.on.workflow_dispatch.inputs.instance.required | Should -BeTrue
        $workflow.permissions.Keys | Should -Be @('contents')
        $workflow.permissions.contents | Should -Be 'read'
        $workflow.concurrency.group | Should -Be 'deploy-instance-main'
        $workflow.concurrency['cancel-in-progress'] | Should -BeFalse
        $workflow.jobs.select.if | Should -Be '${{ github.ref == ''refs/heads/main'' }}'
        $text | Should -Not -Match 'pull_request|schedule:|push:'
    }

    It 'checks the configuration gate before selecting modules and before any approval' {
        $runs = Get-StepRun -Job select
        $gate = [array]::FindIndex([string[]] $runs, [Predicate[string]] { param($r) $r -match 'Test-TeardownConfiguration\.ps1' })
        $selection = [array]::FindIndex([string[]] $runs, [Predicate[string]] { param($r) $r -match 'Select-InstanceModules\.ps1' })
        $gate | Should -BeGreaterOrEqual 0
        $runs[$gate] | Should -Match '-ConfirmInstanceName \$env:TEARDOWN_CONFIRMATION'
        $selection | Should -BeGreaterThan $gate
        $workflow.jobs.select.Contains('environment') | Should -BeFalse
        $workflow.jobs.select.permissions.Keys | Should -Be @('contents')
        $workflow.jobs.approve_teardown_platform.needs | Should -Be @('select')
    }

    It 'requires platform approval and then security approval in the teardown environment' {
        $workflow.jobs.approve_teardown_platform.environment | Should -Be 'approve-teardown-platform'
        $workflow.jobs.approve_teardown_platform.if | Should -Be '${{ needs.select.result == ''success'' }}'
        $workflow.jobs.approve_teardown.environment | Should -Be 'teardown'
        $workflow.jobs.approve_teardown.needs | Should -Be @('select', 'approve_teardown_platform')
        $workflow.jobs.approve_teardown.if | Should -Be '${{ needs.select.result == ''success'' && needs.approve_teardown_platform.result == ''success'' }}'
        foreach ($job in @('approve_teardown_platform', 'approve_teardown')) {
            $workflow.jobs[$job].Contains('permissions') | Should -BeTrue
            $workflow.jobs[$job].permissions.Count | Should -Be 0
            ($workflow.jobs[$job].steps | ConvertTo-Json -Depth 5) | Should -Not -Match 'secrets\.|vars\.|Azure/login'
        }
    }

    It 'verifies the direct Enterprise Owner assignment with the emu-identity plan identity after both approvals' {
        $job = $workflow.jobs.enterprise_owner
        $job.needs | Should -Be @('select', 'approve_teardown')
        $job.if | Should -Be '${{ needs.select.result == ''success'' && needs.approve_teardown.result == ''success'' }}'
        $job.environment | Should -Be '${{ fromJSON(needs.select.outputs.environments)[''emu-identity''] }}'
        (Get-StepRun -Job enterprise_owner) -join "`n" | Should -Match 'Test-TeardownEnterpriseOwner\.ps1 -InstancePath \./instance/instance\.yaml'
        ($job.steps | ConvertTo-Json -Depth 5) | Should -Not -Match 'New-PlatformGitHubToken|PLATFORM_APP_PRIVATE_KEY'
    }

    It 'destroys <Module> only after every selected dependent and after the owner check' -ForEach @(
        @{ Module = 'foundation' }
        @{ Module = 'application' }
        @{ Module = 'service' }
        @{ Module = 'enterprise-baseline' }
        @{ Module = 'observer' }
    ) {
        $suffix = $Module.Replace('-', '_')
        $job = $workflow.jobs["destroy_$suffix"]
        $dependents = @($graph.Keys | Where-Object { $graph[$_] -contains $Module })
        foreach ($dependent in $dependents) {
            $name = 'destroy_' + $dependent.Replace('-', '_')
            $job.needs | Should -Contain $name
            $job.if | Should -Match ([regex]::Escape("(needs.$name.result == 'success' || (needs.$name.result == 'skipped' && !contains(fromJSON(needs.select.outputs.modules), '$dependent')))"))
        }
        $destroyNeeds = @($job.needs | Where-Object { $_ -like 'destroy_*' })
        $destroyNeeds.Count | Should -Be $dependents.Count
        foreach ($required in @('select', 'approve_teardown', 'enterprise_owner')) {
            $job.needs | Should -Contain $required
            $job.if | Should -Match ([regex]::Escape("needs.$required.result == 'success'"))
        }
        $job.if | Should -Match ([regex]::Escape("contains(fromJSON(needs.select.outputs.modules), '$Module')"))
        $job.if | Should -Match '^\$\{\{ !cancelled\(\) && '
        $job.environment | Should -Be ('${{ fromJSON(needs.select.outputs.applyEnvironments)[''' + $Module + '''] }}')
    }

    It 'orders destroy jobs as the reverse of the prerequisite order' {
        $positions = @{}
        $index = 0
        foreach ($name in $workflow.jobs.Keys) { $positions[$name] = $index++ }
        $text.IndexOf('  destroy_enterprise_baseline:') | Should -BeLessThan $text.IndexOf('  destroy_service:')
        $text.IndexOf('  destroy_service:') | Should -BeLessThan $text.IndexOf('  destroy_application:')
        $text.IndexOf('  destroy_application:') | Should -BeLessThan $text.IndexOf('  destroy_foundation:')
        foreach ($module in $graph.Keys) {
            foreach ($prerequisite in $graph[$module]) {
                $workflow.jobs['destroy_' + $prerequisite.Replace('-', '_')].needs |
                    Should -Contain ('destroy_' + $module.Replace('-', '_'))
            }
        }
    }

    It 'passes prerequisite outputs read from state by read-only jobs in the plan environment' {
        $workflow.jobs.Keys | Should -Contain 'outputs_foundation'
        $workflow.jobs.Keys | Should -Contain 'outputs_application'
        $workflow.jobs.Keys | Should -Contain 'outputs_service'
        $workflow.jobs.Keys | Should -Not -Contain 'outputs_observer'
        $workflow.jobs.Keys | Should -Not -Contain 'outputs_enterprise_baseline'
        $job = $workflow.jobs.outputs_foundation
        $job.environment | Should -Be '${{ fromJSON(needs.select.outputs.environments)[''foundation''] }}'
        $job.needs | Should -Be @('select', 'enterprise_owner')
        $job.if | Should -Match ([regex]::Escape("needs.enterprise_owner.result == 'success'"))
        (Get-StepRun -Job outputs_foundation) -join "`n" | Should -Match "Invoke-Module\.ps1 -Module 'foundation' -Action output "
        ($job.steps | ConvertTo-Json -Depth 5) | Should -Not -Match 'New-PlatformGitHubToken|PLATFORM_APP_PRIVATE_KEY'
        $destroy = $workflow.jobs.destroy_service
        $destroy.needs | Should -Contain 'outputs_application'
        $destroy.needs | Should -Contain 'outputs_foundation'
        $destroy.if | Should -Match ([regex]::Escape("needs.outputs_application.result == 'success'"))
        $downloads = @($destroy.steps | Where-Object { $_.Contains('uses') -and $_.uses -like 'actions/download-artifact@*' } | ForEach-Object { $_.with.name })
        $downloads | Should -Be @('teardown-outputs-application', 'teardown-outputs-foundation')
    }

    It 'destroys with apply installation tokens and no PAT' {
        $runs = (Get-StepRun -Job destroy_application) -join "`n"
        $runs | Should -Match "New-PlatformGitHubToken\.ps1 -Module 'application' -Phase apply "
        $runs | Should -Match "Invoke-Module\.ps1 -Module 'application' -Action destroy "
        $text | Should -Not -Match '(?i)\bPAT\b|ADMIN_PAT|personal access'
        $secrets = [regex]::Matches($text, 'secrets\.[A-Z_]+') | ForEach-Object Value | Sort-Object -Unique
        $secrets | Should -Be @('secrets.PLATFORM_APP_PRIVATE_KEY')
        $revoke = $workflow.jobs.destroy_application.steps[-1]
        $revoke.if | Should -Be '${{ always() && env.PLATFORM_GITHUB_TOKENS != '''' }}'
    }

    It 'destroys the isolated rulesets root before the ordinary root of a ruleset module' {
        $runs = Get-StepRun -Job destroy_enterprise_baseline
        $rulesets = [array]::FindIndex([string[]] $runs, [Predicate[string]] { param($r) $r -match '-Action destroy .*-Rulesets$' })
        $ordinary = [array]::FindIndex([string[]] $runs, [Predicate[string]] { param($r) $r -match '-Action destroy ' -and $r -notmatch '-Rulesets' })
        $rulesets | Should -BeGreaterOrEqual 0
        $ordinary | Should -BeGreaterThan $rulesets
        (Get-StepRun -Job destroy_service) -join "`n" | Should -Not -Match '-Rulesets'
    }

    It 'runs scripts only from the dispatched main commit without persisted credentials' {
        $checkouts = @($workflow.jobs.Values | ForEach-Object { $_.steps } | Where-Object { $_.Contains('uses') -and $_.uses -like 'actions/checkout@*' })
        $checkouts.Count | Should -Be ($workflow.jobs.Count - 2)
        foreach ($checkout in $checkouts) {
            $checkout.with.ref | Should -Be '${{ github.sha }}'
            $checkout.with['persist-credentials'] | Should -BeFalse
        }
        foreach ($match in [regex]::Matches($text, 'uses: (\S+)')) {
            $match.Groups[1].Value | Should -Match '@[0-9a-f]{40}$'
        }
    }

    It 'fails the check when the committed workflow differs and passes when it matches' {
        & $generator -ModulesPath $fixtures -OutputPath $output -Check
        [IO.File]::AppendAllText($output, '# drift')
        { & $generator -ModulesPath $fixtures -OutputPath $output -Check } | Should -Throw '*Generate-TeardownWorkflow.ps1*'
        & $generator -ModulesPath $fixtures -OutputPath $output
    }

    It 'keeps the committed instance template and fixture current' {
        { & $generator -Check } | Should -Not -Throw
        { & $generator -ModulesPath $fixtures -OutputPath (Join-Path $PSScriptRoot 'fixtures/teardown.yml') -Check } | Should -Not -Throw
    }
}

Describe 'Teardown configuration gate' {
    BeforeEach {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ 'emu-identity' = @{} }
        $instance.teardown = @{ allowed = $true }
        $instancePath = Join-Path $TestDrive 'instance.yaml'
        $modulesPath = Join-Path $repositoryRoot 'modules'
        $write = { ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath }
        & $write
    }

    It 'allows teardown only when enabled, confirmed and the owner check module is selected' {
        { & $configurationCheck -InstancePath $instancePath -ModulesPath $modulesPath -ConfirmInstanceName 'demo' } |
            Should -Not -Throw
    }

    It 'fails closed when teardown is <Case>' -ForEach @(
        @{ Case = 'disabled'; Value = @{ allowed = $false } }
        @{ Case = 'not configured'; Value = $null }
        @{ Case = 'empty'; Value = @{} }
    ) {
        if ($null -eq $Value) { $instance.Remove('teardown') } else { $instance.teardown = $Value }
        & $write

        { & $configurationCheck -InstancePath $instancePath -ModulesPath $modulesPath -ConfirmInstanceName 'demo' } |
            Should -Throw '*$.teardown.allowed*'
    }

    It 'rejects a non-boolean allowed value' {
        $instance.teardown = @{ allowed = 'true' }
        & $write

        { & $configurationCheck -InstancePath $instancePath -ModulesPath $modulesPath -ConfirmInstanceName 'demo' } |
            Should -Throw
    }

    It 'rejects a confirmation <Case>' -ForEach @(
        @{ Case = 'for another instance'; Value = 'other' }
        @{ Case = 'with different case'; Value = 'Demo' }
        @{ Case = 'that is blank'; Value = ' ' }
    ) {
        { & $configurationCheck -InstancePath $instancePath -ModulesPath $modulesPath -ConfirmInstanceName $Value } |
            Should -Throw '*confirmation*'
    }

    It 'refuses teardown when emu-identity is not selected because the owner check needs its plan identity' {
        $instance.modules = @{}
        & $write

        { & $configurationCheck -InstancePath $instancePath -ModulesPath $modulesPath -ConfirmInstanceName 'demo' } |
            Should -Throw '*emu-identity*'
    }

    It 'rejects an invalid instance configuration' {
        $instance.Remove('teams')
        & $write

        { & $configurationCheck -InstancePath $instancePath -ModulesPath $modulesPath -ConfirmInstanceName 'demo' } |
            Should -Throw '*teams*'
    }
}
