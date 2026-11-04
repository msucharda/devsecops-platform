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

    function Get-DestroyPhaseNode {
        param([Parameter(Mandatory)][string] $Job)
        if ($Job -ceq 'destroy_enterprise_baseline_code_security') { return 'enterprise-baseline:code-security' }
        $Job.Substring('destroy_'.Length).Replace('_', '-')
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

    It 'destroys only selected phase roots when rulesets require the early baseline but not the late baseline' {
        $realOutput = Join-Path $TestDrive 'teardown-selected-phases.yml'
        & $generator -ModulesPath (Join-Path $repositoryRoot 'modules') -OutputPath $realOutput
        $real = ConvertFrom-Yaml (Get-Content -LiteralPath $realOutput -Raw)

        $real.jobs.select.outputs.phaseNodes | Should -Be '${{ steps.modules.outputs.phaseNodes }}'
        ($real.jobs.select.steps | Where-Object { $_.Contains('run') -and $_.run -match 'Select-InstanceModules' }).run |
            Should -Match '-DeploymentScope full'
        $real.jobs.destroy_enterprise_baseline_code_security.if |
            Should -Match ([regex]::Escape("contains(fromJSON(needs.select.outputs.phaseNodes), 'enterprise-baseline:code-security')"))
        $real.jobs.destroy_enterprise_baseline.if |
            Should -Match ([regex]::Escape("contains(fromJSON(needs.select.outputs.phaseNodes), 'enterprise-baseline')"))
        $real.jobs.outputs_enterprise_baseline_code_security.if |
            Should -Match ([regex]::Escape("contains(fromJSON(needs.select.outputs.phaseNodes), 'enterprise-baseline:code-security')"))
        $real.jobs.destroy_enterprise_baseline_code_security.if |
            Should -Match ([regex]::Escape("needs.destroy_organization_rulesets.result == 'skipped' && !contains(fromJSON(needs.select.outputs.phaseNodes), 'organization-rulesets')"))
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
            $job.if | Should -Match ([regex]::Escape("(needs.$name.result == 'success' || (needs.$name.result == 'skipped' && !contains(fromJSON(needs.select.outputs.phaseNodes), '$dependent')))"))
        }
        $destroyNeeds = @($job.needs | Where-Object { $_ -like 'destroy_*' })
        $destroyNeeds.Count | Should -Be $dependents.Count
        foreach ($required in @('select', 'approve_teardown', 'enterprise_owner')) {
            $job.needs | Should -Contain $required
            $job.if | Should -Match ([regex]::Escape("needs.$required.result == 'success'"))
        }
        $job.if | Should -Match ([regex]::Escape("contains(fromJSON(needs.select.outputs.phaseNodes), '$Module')"))
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

    It 'destroys emu-identity last because it owns the teams that approve the other apply environments' {
        $realOutput = Join-Path $TestDrive 'teardown-real.yml'
        & $generator -ModulesPath (Join-Path $repositoryRoot 'modules') -OutputPath $realOutput
        $realText = Get-Content -LiteralPath $realOutput -Raw
        $real = ConvertFrom-Yaml $realText
        $others = @($real.jobs.Keys | Where-Object { $_ -like 'destroy_*' -and $_ -cne 'destroy_emu_identity' })
        $others | Should -Not -BeNullOrEmpty
        $job = $real.jobs.destroy_emu_identity
        foreach ($other in $others) {
            $runs = @($real.jobs[$other].steps | Where-Object { $_.Contains('run') } | ForEach-Object { $_.run })
            $targets = @([regex]::Matches(($runs -join "`n"), "Invoke-Module\.ps1 -Module '([^']+)' -Action destroy") |
                ForEach-Object { $_.Groups[1].Value } | Sort-Object -Unique)
            $targets.Count | Should -Be 1
            $module = $targets[0]
            $job.needs | Should -Contain $other
            $key = Get-DestroyPhaseNode -Job $other
            $job.if | Should -Match ([regex]::Escape("(needs.$other.result == 'success' || (needs.$other.result == 'skipped' && !contains(fromJSON(needs.select.outputs.phaseNodes), '$key')))"))
            $realText.IndexOf("  ${other}:") | Should -BeLessThan $realText.IndexOf('  destroy_emu_identity:')
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
        $runs | Should -Match "-Action destroy .*-PlatformOrganization \`$env:GITHUB_REPOSITORY_OWNER"
        $text | Should -Not -Match '(?i)\bPAT\b|ADMIN_PAT|personal access'
        $secrets = [regex]::Matches($text, 'secrets\.[A-Z_]+') | ForEach-Object Value | Sort-Object -Unique
        $secrets | Should -Be @('secrets.PLATFORM_APP_PRIVATE_KEY')
        $revoke = $workflow.jobs.destroy_application.steps[-1]
        $revoke.if | Should -Be '${{ always() && env.PLATFORM_GITHUB_TOKENS != '''' }}'
    }

    It 'checks that main still points to the dispatched commit immediately before every destroy step' {
        $destroyJobs = @($workflow.jobs.Keys | Where-Object { $_ -like 'destroy_*' })
        $destroyJobs.Count | Should -Be $graph.Count
        foreach ($job in $destroyJobs) {
            $steps = @($workflow.jobs[$job].steps)
            $destroySteps = @(0..($steps.Count - 1) | Where-Object { $steps[$_].Contains('run') -and $steps[$_].run -match '-Action destroy ' })
            $destroySteps.Count | Should -BeGreaterThan 0
            foreach ($index in $destroySteps) {
                $check = $steps[$index - 1]
                $check.run | Should -BeExactly './instance/platform/tools/Assert-TeardownMainCommit.ps1'
                $check.env.TEARDOWN_MAIN_TOKEN | Should -BeExactly '${{ github.token }}'
            }
            $workflow.jobs[$job].permissions.contents | Should -BeExactly 'read'
        }
        @($workflow.jobs.destroy_enterprise_baseline.steps | Where-Object { $_.Contains('run') -and $_.run -like '*Assert-TeardownMainCommit.ps1' }).Count | Should -Be 2
    }

    It 'reads every state root of an organization-scoped module before issuing GitHub tokens and skips only when all are empty' {
        $steps = @($workflow.jobs.destroy_enterprise_baseline.steps)
        $stateIndex = [array]::FindIndex([object[]] $steps, [Predicate[object]] { param($s) $s.Contains('id') -and $s.id -ceq 'state' })
        $tokenIndex = [array]::FindIndex([object[]] $steps, [Predicate[object]] { param($s) $s.Contains('run') -and $s.run -like '*New-PlatformGitHubToken.ps1*' })
        $stateIndex | Should -BeGreaterOrEqual 0
        $tokenIndex | Should -Be ($stateIndex + 1)
        $state = $steps[$stateIndex]
        $state.Contains('if') | Should -BeFalse
        $state.Contains('env') | Should -BeFalse
        $state.run | Should -Match "Invoke-Module\.ps1 -Module 'enterprise-baseline' -Action state [^\n]*-PlatformOrganization \`$env:GITHUB_REPOSITORY_OWNER\n"
        $state.run | Should -Match "Invoke-Module\.ps1 -Module 'enterprise-baseline' -Action state [^\n]*-Rulesets\n"
        foreach ($step in $steps[$tokenIndex..($steps.Count - 2)]) {
            $step.if | Should -BeExactly '${{ steps.state.outputs.empty != ''true'' }}'
        }
        $steps[-1].if | Should -Be '${{ always() && env.PLATFORM_GITHUB_TOKENS != '''' }}'
    }

    It 'writes empty=<Expected> when the state roots report <Case>' -ForEach @(
        @{ Case = 'all empty'; Results = @($true, $true); Expected = 'true' }
        @{ Case = 'a non-empty rulesets root'; Results = @($true, $false); Expected = 'false' }
        @{ Case = 'a non-empty ordinary root'; Results = @($false, $true); Expected = 'false' }
        @{ Case = 'a missing result'; Results = @($true); Expected = 'false' }
        @{ Case = 'a non-boolean result'; Results = @($true, 'true'); Expected = 'false' }
    ) {
        $run = @($workflow.jobs.destroy_enterprise_baseline.steps | Where-Object { $_.Contains('id') -and $_.id -ceq 'state' })[0].run
        $script:stateResults = [Collections.Generic.Queue[object]]::new()
        foreach ($result in $Results) { $script:stateResults.Enqueue($result) }
        function Get-FixtureState {
            if ($script:stateResults.Count -gt 0) { [pscustomobject]@{ Empty = $script:stateResults.Dequeue() } }
        }
        $outputFile = Join-Path $TestDrive "state-$([guid]::NewGuid()).txt"
        $previousOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = $outputFile
        try {
            & ([scriptblock]::Create(($run -replace '\./instance/platform/tools/Invoke-Module\.ps1 [^\n]*', 'Get-FixtureState')))
        }
        finally {
            $env:GITHUB_OUTPUT = $previousOutput
        }

        (Get-Content -LiteralPath $outputFile) | Should -Be @("empty=$Expected")
    }

    It 'fails the state step when a state root cannot be read' {
        $run = @($workflow.jobs.destroy_enterprise_baseline.steps | Where-Object { $_.Contains('id') -and $_.id -ceq 'state' })[0].run
        function Get-FixtureState { throw 'backend unavailable' }
        $outputFile = Join-Path $TestDrive "state-$([guid]::NewGuid()).txt"
        $previousOutput = $env:GITHUB_OUTPUT
        $env:GITHUB_OUTPUT = $outputFile
        try {
            { & ([scriptblock]::Create(($run -replace '\./instance/platform/tools/Invoke-Module\.ps1 [^\n]*', 'Get-FixtureState'))) } |
                Should -Throw '*backend unavailable*'
        }
        finally {
            $env:GITHUB_OUTPUT = $previousOutput
        }
        Test-Path -LiteralPath $outputFile | Should -BeFalse
    }

    It 'does not read the state of a module without organization-scoped tokens' {
        foreach ($job in @('destroy_foundation', 'destroy_application', 'destroy_service', 'destroy_observer')) {
            $steps = @($workflow.jobs[$job].steps)
            @($steps | Where-Object { $_.Contains('id') -and $_.id -ceq 'state' }).Count | Should -Be 0
            @($steps | Where-Object { $_.Contains('run') -and $_.run -match '-Action state ' }).Count | Should -Be 0
            @($steps | Where-Object { $_.Contains('if') -and $_.if -like '*steps.state*' }).Count | Should -Be 0
        }
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

    It 'documents the restoration PR before organization deletion and a fresh dispatch afterwards' {
        $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
        $plan = [regex]::Match($readme, '(?s)### Pl\u00e1n teardownu s pov\u00fd\u0161en\u00fdmi workflow\r?\n(?<plan>.*?)(?=\r?\n### |\z)')

        $plan.Success | Should -BeTrue
        $plan.Groups['plan'].Value | Should -Match '(?s)destroy_organizations.*Generate-TeardownWorkflow\.ps1.*organizations/delete-instance-organizations.*workflow_dispatch.*Re-run jobs'
        $plan.Groups['plan'].Value | Should -Match '(?s)Po review a merge PR.*deploy\.yml.*completed.*organizations/delete-instance-organizations.*workflow_dispatch'
        $plan.Groups['plan'].Value | Should -Match '(?s)Po p\u0159eru\u0161en\u00ed.*kroku 5.*kroku 6'
        $plan.Groups['plan'].Value | Should -Match ([regex]::Escape('-ModulesPath .\platform\modules'))
        $plan.Groups['plan'].Value | Should -Match ([regex]::Escape('-OutputPath (Join-Path $PWD ''.github\workflows\teardown.yml'')'))
    }

    It 'documents temporary teardown reviewers and their restoration after interruption or a later deployment' {
        $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
        $recovery = [regex]::Match($readme, '(?s)### Nouzov\u00e9 schv\u00e1len\u00ed opakovan\u00e9ho teardownu\r?\n(?<recovery>.*?)(?=\r?\n### |\z)')

        $recovery.Success | Should -BeTrue
        $instructions = $recovery.Groups['recovery'].Value
        foreach ($environment in @('approve-teardown-platform', 'teardown', 'enterprise-baseline-apply', 'organization-rulesets-apply')) {
            $instructions | Should -Match ([regex]::Escape($environment))
        }
        $instructions | Should -Match 'credentials.*apply\.environment'
        $instructions | Should -Match 'Enterprise Owner'
        $instructions | Should -Match 'mimo repozit\u00e1\u0159 instance'
        $instructions | Should -Match 'Prevent self-review'
        $instructions | Should -Match '#195'
        $instructions | Should -Match '(?s)deploy\.yml.*completed.*workflow_dispatch.*Re-run jobs'
        $instructions | Should -Match 'Remove-Bootstrap\.ps1'
        $instructions | Should -Match 'odeber.*do\u010dasn'
        $instructions | Should -Match 'obnov.*p\u016fvodn'
        $instructions | Should -Match 'Po p\u0159eru\u0161en\u00ed'
    }

    It 'documents <Case> before emergency teardown can continue' -ForEach @(
        @{ Case = 'effective reviewer access'; Pattern = 'P\u0159ed prvn\u00ed zm\u011bnou reviewer\u016f.*ka\u017ed\u00e9ho.*aktivn.*`read`' }
        @{ Case = 'unconditional deploy cancellation'; Pattern = '(?s)P\u0159ed ka\u017ed\u00fdm.*deploy\.yml.*completed.*workflow_dispatch' }
        @{ Case = 'abandoned run cancellation'; Pattern = '(?s)Pokud nouzov\u00fd b\u011bh nepokra\u010duje.*zru\u0161.*completed.*odeber' }
        @{ Case = 'changes limited to empty reviewer teams'; Pattern = 'Uprav pouze.*pr\u00e1zdn.*`platform`.*`security`.*Ostatn.*beze zm\u011bny' }
        @{ Case = 'default apply environment names'; Pattern = 'neuveden.*<module>-apply' }
        @{ Case = 'restoration before the deployment block and reviewer changes'; Pattern = '(?s)obnovovac\u00ed PR.*vypni pouze workflow `deploy.yml`.*P\u0159ed prvn\u00ed zm\u011bnou reviewer\u016f' }
        @{ Case = 'cancellation after disabling deployments'; Pattern = '(?s)Disable workflow.*completed.*Required reviewers' }
        @{ Case = 'teardown remaining enabled'; Pattern = '`teardown.yml` mus\u00ed z\u016fstat zapnut\u00fd' }
        @{ Case = 'the deployment block lasting through reviewer restoration'; Pattern = 'Blokaci deploy dr\u017e a\u017e do ov\u011b\u0159en\u00e9 obnovy p\u016fvodn\u00edch reviewer\u016f' }
    ) {
        $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
        $recovery = [regex]::Match($readme, '(?s)### Nouzov\u00e9 schv\u00e1len\u00ed opakovan\u00e9ho teardownu\r?\n(?<recovery>.*?)(?=\r?\n### |\z)')

        $recovery.Groups['recovery'].Value | Should -Match $Pattern
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

Describe 'Teardown identity approval boundary' {
    BeforeAll {
        $realOutput = Join-Path $TestDrive 'teardown-approval-boundary.yml'
        & $generator -ModulesPath (Join-Path $repositoryRoot 'modules') -OutputPath $realOutput
        $real = ConvertFrom-Yaml (Get-Content -LiteralPath $realOutput -Raw)
        $identity = $real.jobs.destroy_emu_identity
        $otherDestroyJobs = @($real.jobs.Keys | Where-Object { $_ -like 'destroy_*' -and $_ -cne 'destroy_emu_identity' })

        function Test-IdentityCondition {
            param(
                [hashtable] $Results,
                [string[]] $Selected,
                [bool] $Cancelled = $false
            )

            $selectedNodes = $Selected
            $jobResults = $Results
            $condition = $identity.if -replace '^\$\{\{\s*|\s*\}\}$', ''
            $condition = $condition.Replace('always()', '$true')
            $condition = $condition.Replace('cancelled()', ('$' + $Cancelled.ToString().ToLowerInvariant()))
            $condition = [regex]::Replace($condition, "contains\(fromJSON\(needs.select.outputs.phaseNodes\), '([^']+)'\)", {
                param($match)
                '$' + ($selectedNodes -ccontains $match.Groups[1].Value).ToString().ToLowerInvariant()
            })
            $condition = [regex]::Replace($condition, 'needs\.([a-z_]+)\.result', {
                param($match)
                "'$($jobResults[$match.Groups[1].Value])'"
            })
            $condition = $condition.Replace('==', '-ceq').Replace('&&', '-and').Replace('||', '-or').Replace('!', '-not ')
            & ([scriptblock]::Create($condition))
        }
    }

    It 'places every other environment approval before identity destruction in the dependency DAG' {
        $ancestors = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
        $pending = [Collections.Generic.Queue[string]]::new()
        foreach ($job in $identity.needs) { $pending.Enqueue($job) }
        while ($pending.Count -gt 0) {
            $job = $pending.Dequeue()
            if (-not $ancestors.Add($job)) { continue }
            if ($real.jobs[$job].Contains('needs')) {
                foreach ($need in @($real.jobs[$job].needs)) { $pending.Enqueue($need) }
            }
        }
        $ancestors.Contains('destroy_emu_identity') | Should -BeFalse
        foreach ($job in $real.jobs.Keys | Where-Object { $_ -cne 'destroy_emu_identity' -and $real.jobs[$_].Contains('environment') }) {
            $ancestors.Contains($job) | Should -BeTrue -Because "$job must finish its environment approval before identity destruction"
        }
    }

    It 'allows identity after a partial run only when each preceding destroy is <Case>' -ForEach @(
        @{ Case = 'successful and selected'; Result = 'success'; Selected = $true; Expected = $true }
        @{ Case = 'skipped and unselected'; Result = 'skipped'; Selected = $false; Expected = $true }
        @{ Case = 'failed'; Result = 'failure'; Selected = $true; Expected = $false }
        @{ Case = 'cancelled'; Result = 'cancelled'; Selected = $true; Expected = $false }
        @{ Case = 'skipped but selected'; Result = 'skipped'; Selected = $true; Expected = $false }
        @{ Case = 'missing'; Result = ''; Selected = $true; Expected = $false }
        @{ Case = 'unknown'; Result = 'unknown'; Selected = $true; Expected = $false }
        @{ Case = 'failed even if unselected'; Result = 'failure'; Selected = $false; Expected = $false }
    ) {
        foreach ($interruptedJob in $otherDestroyJobs) {
            $results = @{}
            foreach ($job in $identity.needs) { $results[$job] = 'success' }
            $results[$interruptedJob] = $Result
            $selectedNodes = @('emu-identity')
            foreach ($job in $otherDestroyJobs) {
                if ($job -ceq $interruptedJob -and -not $Selected) { continue }
                $selectedNodes += Get-DestroyPhaseNode -Job $job
            }

            Test-IdentityCondition -Results $results -Selected $selectedNodes |
                Should -Be $Expected -Because "identity must respect the $Result result of $interruptedJob"
        }
    }

    It 'does not destroy identity when the run is cancelled after preceding modules finished' {
        $results = @{}
        foreach ($job in $identity.needs) { $results[$job] = 'success' }

        Test-IdentityCondition -Results $results -Selected @('emu-identity') -Cancelled $true | Should -BeFalse
    }

    It 'allows identity only when each configuration approval and owner gate is <Case>' -ForEach @(
        @{ Case = 'successful'; Result = 'success'; Expected = $true }
        @{ Case = 'failed'; Result = 'failure'; Expected = $false }
        @{ Case = 'cancelled'; Result = 'cancelled'; Expected = $false }
        @{ Case = 'skipped'; Result = 'skipped'; Expected = $false }
        @{ Case = 'missing'; Result = ''; Expected = $false }
        @{ Case = 'unknown'; Result = 'unknown'; Expected = $false }
    ) {
        foreach ($gate in @('select', 'approve_teardown', 'enterprise_owner')) {
            $results = @{}
            foreach ($job in $identity.needs) { $results[$job] = 'success' }
            $results[$gate] = $Result
            $selectedNodes = @('emu-identity') + @($otherDestroyJobs | ForEach-Object { Get-DestroyPhaseNode -Job $_ })

            Test-IdentityCondition -Results $results -Selected $selectedNodes |
                Should -Be $Expected -Because "identity must respect the $Result result of $gate"
        }
    }
}

Describe 'Teardown action allowlist instructions' {
    BeforeAll {
        $readme = Get-Content -LiteralPath (Join-Path $repositoryRoot 'README.md') -Raw
        $snippets = @([regex]::Matches($readme, '(?s)```powershell\r?\n(?<code>.*?)\r?\n\s*```') |
            Where-Object { $_.Groups['code'].Value -match 'Select-String -LiteralPath' })
        $snippets.Count | Should -Be 1
        $allowlistCommand = [scriptblock]::Create($snippets[0].Groups['code'].Value)
    }

    BeforeEach {
        $instanceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $workflowsPath = Join-Path $instanceRoot '.github/workflows'
        $null = New-Item -ItemType Directory -Path $workflowsPath -Force
        $restoredPath = Join-Path $workflowsPath 'teardown.yml'
        $readActions = {
            Push-Location $instanceRoot
            try { & $allowlistCommand }
            finally { Pop-Location }
        }
    }

    It 'derives the exact unique SHA references from the restored template, including a newly added action' {
        $extra = 'example/new-action@1234567890123456789012345678901234567890'
        $extended = $text + "`n  extra_job:`n    runs-on: ubuntu-latest`n    steps:`n      - uses: $extra`n"
        Set-Content -LiteralPath $restoredPath -Value $extended
        $parsed = ConvertFrom-Yaml $extended
        $expected = @($parsed.jobs.Values | ForEach-Object { $_.steps } |
            Where-Object { $_.Contains('uses') } | ForEach-Object { $_.uses } | Sort-Object -Unique -CaseSensitive)

        $actual = @(& $readActions)

        $actual | Should -Be $expected
        $actual | Should -Contain $extra
        @($actual | Where-Object { $_ -like 'actions/checkout@*' }).Count | Should -Be 1
    }

    It 'stops instead of returning a policy list for <Case>' -ForEach @(
        @{ Case = 'an empty template'; Reference = $null }
        @{ Case = 'an action pinned to a tag'; Reference = 'actions/checkout@v7' }
        @{ Case = 'an action without a pin'; Reference = 'actions/checkout' }
        @{ Case = 'a wildcard allowance'; Reference = 'actions/*@1234567890123456789012345678901234567890' }
        @{ Case = 'a short commit pin'; Reference = 'actions/checkout@3d3c42e' }
        @{ Case = 'an uppercase commit pin'; Reference = 'actions/checkout@3D3C42E5AAC5BA805825DA76410C181273BA90B1' }
    ) {
        $content = if ($null -eq $Reference) { 'jobs: {}' }
        else { $text + "`n  extra_job:`n    runs-on: ubuntu-latest`n    steps:`n      - uses: $Reference`n" }
        Set-Content -LiteralPath $restoredPath -Value $content

        { & $readActions } | Should -Throw '*non-empty list*full commit SHAs*'
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
