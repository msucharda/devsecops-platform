BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $platformTools = Import-Module (Join-Path $repoRoot 'tools/PlatformTools.psm1') -Force -PassThru
    Import-Module (Join-Path $repoRoot 'tools/InstanceSetup.psm1') -Force
}

Describe 'Instance setup manual steps through the public wizard' {
    BeforeAll {
        $interruptionChildren = @{}
        $schemaLoader = $null
        $schemaLoader = & $platformTools { (Get-Command Get-PlatformJsonSchema -CommandType Function).ScriptBlock }
        # These tests change fixture data, never the repository schemas. Prepare each with the real loader.
        & $platformTools {
            $script:ManualStepsTestSchemaJson = @{}
            foreach ($name in @('module', 'instance')) {
                $script:ManualStepsTestSchemaJson[$name] = ConvertTo-Json -InputObject (Get-PlatformJsonSchema -Name $name) -Depth 100 -Compress
            }
            function script:Get-PlatformJsonSchema {
                [CmdletBinding()]
                [OutputType([System.Collections.IDictionary])]
                param([Parameter(Mandatory)][ValidateSet('instance', 'module')][string] $Name)

                # Instance validation adds module-specific properties; no caller may share a mutable schema.
                return ConvertFrom-Json -InputObject $script:ManualStepsTestSchemaJson[$Name] -AsHashtable
            }
        }
        $sourcePath = Join-Path $repoRoot 'tools/InstanceSetup.ManualSteps.ps1'
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath).Hash
        $instanceTemplate = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instanceTemplate['modules'] = @{ application = @{} }
        $instanceYaml = $instanceTemplate | ConvertTo-Yaml
        $instanceJson = $instanceTemplate | ConvertTo-Json -Depth 30
        $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/runner-modules'
        $fixtureFiles = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File | ForEach-Object {
            @{ Source = $_.FullName; Relative = [IO.Path]::GetRelativePath($fixtureRoot, $_.FullName) }
        })
        $newFixture = {
            param([string] $Directory)
            $work = Join-Path $Directory 'work'
            $modules = Join-Path $Directory 'modules'
            $null = [IO.Directory]::CreateDirectory($work)
            foreach ($file in $fixtureFiles) {
                $destination = Join-Path $modules $file.Relative
                $null = [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($destination))
                [IO.File]::Copy($file.Source, $destination)
            }
            $instancePath = Join-Path $work 'instance.yaml'
            [IO.File]::WriteAllText($instancePath, $instanceYaml)
            return @{ Work = $work; Modules = $modules; InstancePath = $instancePath }
        }
        $answers = [Collections.Generic.Queue[string]]::new()
        $messages = [Collections.Generic.List[string]]::new()
        $onPrompt = $null
        Mock Read-Host -ModuleName InstanceSetup {
            if ($onPrompt) { & $onPrompt $Prompt }
            if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
            $answers.Dequeue()
        }
        # Capture guidance at the host boundary without per-line mock dispatch.
        $hostOutput = @{ Messages = $messages }
        & (Get-Module InstanceSetup) {
            param($Output)
            $script:ManualStepsTestOutput = $Output
            function script:Write-Host {
                [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Matches the Write-Host boundary; these tests assert text, not color.')]
                [CmdletBinding()]
                param([AllowEmptyString()][string] $Object, [ConsoleColor] $ForegroundColor)
                $script:ManualStepsTestOutput.Messages.Add($Object)
            }
        } $hostOutput
        Mock Invoke-WebRequest -ModuleName InstanceSetup { throw 'Manual guidance must not call an API.' }
        Mock Start-Process -ModuleName InstanceSetup { throw 'Manual guidance must not launch a process.' }
        $interruptionParallelism = 12
        if ($null -ne $env:LOCAL_CI_WORKER_BUDGET) {
            $budget = 0
            if (-not [int]::TryParse($env:LOCAL_CI_WORKER_BUDGET, [ref] $budget) -or $budget -le 0) {
                throw 'LOCAL_CI_WORKER_BUDGET must be a positive integer.'
            }
            $interruptionParallelism = [Math]::Min($interruptionParallelism, $budget)
        }
        $pendingChildren = [Collections.Generic.Queue[hashtable]]::new()
        $runningChildren = [Collections.Generic.List[hashtable]]::new()
        $startAvailableChildren = {
            for ($index = $runningChildren.Count - 1; $index -ge 0; $index--) {
                if ($runningChildren[$index].Process.HasExited) { $runningChildren.RemoveAt($index) }
            }
            while ($pendingChildren.Count -gt 0 -and $runningChildren.Count -lt $interruptionParallelism) {
                $child = $pendingChildren.Dequeue()
                $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
                $start.UseShellExecute = $false
                $start.RedirectStandardOutput = $true
                $start.RedirectStandardError = $true
                foreach ($argument in @(
                        '-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'fixtures/Invoke-ManualStepsInterruption.ps1'),
                        '-ToolsPath', (Join-Path $repoRoot 'tools'), '-WorkPath', $child.Work, '-ModulesPath', $child.Modules,
                        '-Boundary', $child.Boundary, '-Termination', $child.Termination, '-PublicationStatus', $child.PublicationStatus
                    )) { $start.ArgumentList.Add($argument) }
                if ($child.Reconfirm) { $start.ArgumentList.Add('-Reconfirm') }
                $process = [Diagnostics.Process]::Start($start)
                $child.Process = $process
                $child.Stdout = $process.StandardOutput.ReadToEndAsync()
                $child.Stderr = $process.StandardError.ReadToEndAsync()
                $runningChildren.Add($child)
            }
        }
        # Start lazily so mutation runs filtered to name validation do not launch unrelated children.
        $startInterruptionChildren = {
            $initialPromptCount = 0
            foreach ($scenario in @('Confirmation', 'InitialPending', 'ReconfirmPending')) {
                foreach ($boundary in @('BeforePublish', 'AfterPublish')) {
                    foreach ($termination in @('Error', 'Abrupt')) {
                        $directory = Join-Path $TestDrive "$scenario-$boundary-$termination"
                        $fixture = & $newFixture $directory
                        $originalProgress = $null
                        if ($scenario -ceq 'ReconfirmPending') {
                            $answers.Enqueue('demo')
                            $answers.Enqueue('y')
                            $null = Invoke-InstanceSetup -RepoPath $repoRoot -WorkPath $fixture.Work -ModulesPath $fixture.Modules `
                                -Phase ManualSteps -ManualStep 'application/verify-access'
                            $originalProgress = [IO.File]::ReadAllText((Join-Path $fixture.Work 'manual-steps-state.json'))
                            $initialPromptCount += 2
                            Should -Invoke Read-Host -ModuleName InstanceSetup -Times $initialPromptCount -Exactly
                        }
                        $child = @{
                            Work = $fixture.Work; Modules = $fixture.Modules
                            OriginalProgress = $originalProgress
                            Boundary = $boundary; Termination = $termination
                            PublicationStatus = $(if ($scenario -ceq 'Confirmation') { 'Confirmed' } else { 'Pending' })
                            Reconfirm = $scenario -ceq 'ReconfirmPending'
                        }
                        $interruptionChildren["$scenario-$boundary-$termination"] = $child
                        $pendingChildren.Enqueue($child)
                    }
                }
            }
            & $startAvailableChildren
            # The parent lends its share to the children and blocks until all of them return it.
            while ($runningChildren.Count -gt 0) {
                if (-not $runningChildren[0].Process.WaitForExit(120000)) {
                    throw 'The manual-step interruption child did not finish within 120 seconds.'
                }
                & $startAvailableChildren
            }
            return $initialPromptCount
        }
    }

    AfterAll {
        try {
            foreach ($child in $interruptionChildren.Values) {
                if ($child.ContainsKey('Process')) {
                    try {
                        if (-not $child.Process.HasExited) {
                            $child.Process.Kill($true)
                            $child.Process.WaitForExit()
                        }
                    }
                    finally { $child.Process.Dispose() }
                }
            }
        }
        finally {
            try {
                & (Get-Module InstanceSetup) {
                    if (Get-Variable -Name ManualStepsTestOutput -Scope Script -ErrorAction SilentlyContinue) {
                        Remove-Item Function:script:Write-Host
                        Remove-Variable -Name ManualStepsTestOutput -Scope Script
                    }
                }
            }
            finally {
                if ($schemaLoader) {
                    & $platformTools {
                        param([scriptblock] $Original)
                        Set-Item -Path Function:script:Get-PlatformJsonSchema -Value $Original
                        Remove-Variable -Name ManualStepsTestSchemaJson -Scope Script -ErrorAction SilentlyContinue
                    } $schemaLoader
                }
            }
        }
    }

    BeforeEach {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $fixture = & $newFixture $directory
        $work = $fixture.Work
        $modules = $fixture.Modules
        $instancePath = $fixture.InstancePath
        $instance = ConvertFrom-Json -InputObject $instanceJson -AsHashtable
        $arguments = @{ RepoPath = $repoRoot; WorkPath = $work; ModulesPath = $modules; Phase = 'ManualSteps' }
        $answers = [Collections.Generic.Queue[string]]::new()
        $messages = [Collections.Generic.List[string]]::new()
        $hostOutput.Messages = $messages
        $onPrompt = $null
    }

    It 'guides a selected manifest step and records human evidence without changing the configuration' {
        $before = [IO.File]::ReadAllText($instancePath)
        $answers.Enqueue('demo')
        $answers.Enqueue('y')

        $result = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'

        $result.Phase | Should -BeExactly 'ManualSteps'
        $result.ManualSteps.Count | Should -Be 1
        $result.ManualSteps[0].Id | Should -BeExactly 'application/verify-access'
        $result.ManualSteps[0].Status | Should -BeExactly 'Confirmed'
        $result.ManualSteps[0].Verified | Should -BeFalse
        $result.Completed | Should -BeTrue
        [IO.File]::ReadAllText($instancePath) | Should -BeExactly $before
        Test-Path -LiteralPath $result.ProgressPath -PathType Leaf | Should -BeTrue
        ($messages -join "`n") | Should -Match 'Verify application access after deployment'
        ($messages -join "`n") | Should -Match 'reference-instance\.md'
        ($messages -join "`n") | Should -Match 'module\.yaml'
        Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 0
        Should -Invoke Start-Process -ModuleName InstanceSetup -Times 0
    }

    It 'resumes a confirmed step without another prompt and leaves unchanged progress byte-identical' {
        $answers.Enqueue('demo')
        $answers.Enqueue('y')
        $first = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'
        $before = [IO.File]::ReadAllText($first.ProgressPath)
        $old = [datetime]::new(2000, 1, 1)
        (Get-Item -LiteralPath $first.ProgressPath).LastWriteTimeUtc = $old

        $resumed = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'

        $resumed.Completed | Should -BeTrue
        [IO.File]::ReadAllText($first.ProgressPath) | Should -BeExactly $before
        (Get-Item -LiteralPath $first.ProgressPath).LastWriteTimeUtc | Should -Be $old
        Should -Invoke Read-Host -ModuleName InstanceSetup -Times 2 -Exactly
    }

    It 'rejects a name that is not an exact match (<Case>)' -ForEach @(
        @{ Case = 'different instance'; Answer = 'another' }
        @{ Case = 'case'; Answer = 'Demo' }
        @{ Case = 'empty'; Answer = '' }
        @{ Case = 'whitespace'; Answer = ' demo ' }
        @{ Case = 'wildcard'; Answer = 'd*' }
    ) {
        $answers.Enqueue($Answer)

        { Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access' } | Should -Throw '*instance name*exactly*'

        $state = Get-Content -LiteralPath (Join-Path $work 'manual-steps-state.json') -Raw | ConvertFrom-Json -AsHashtable
        $state['steps']['application/verify-access']['status'] | Should -BeExactly 'Pending'
        ($messages -join "`n") | Should -Not -Match 'Verify application access after deployment'
    }

    It 'refuses a confirmed record bound to another instance' {
        $answers.Enqueue('demo')
        $answers.Enqueue('y')
        $first = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'
        $state = Get-Content -LiteralPath $first.ProgressPath -Raw | ConvertFrom-Json -AsHashtable
        $state['instanceName'] = 'another'
        $state | ConvertTo-Json -Depth 30 | Set-Content -LiteralPath $first.ProgressPath

        { Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access' } | Should -Throw '*progress*instance name*'
    }

    It 'exposes the manual phase through Start-InstanceSetup with PassThru' {
        $answers.Enqueue('demo')
        $answers.Enqueue('y')

        $result = & (Join-Path $repoRoot 'tools/Start-InstanceSetup.ps1') -WorkPath $work -ModulesPath $modules `
            -Phase manualsteps -ManualStep 'application/verify-access' -PassThru

        $result.Completed | Should -BeTrue
        $result.Phase | Should -BeExactly 'ManualSteps'
    }

    It 'keeps a pending intent after interruption and asks the user to verify rather than repeat the action' {
        $answers.Enqueue('demo')
        { Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access' } | Should -Throw '*Unexpected prompt*'
        $path = Join-Path $work 'manual-steps-state.json'
        $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
        $state['steps']['application/verify-access']['status'] | Should -BeExactly 'Pending'

        $answers.Enqueue('demo')
        $answers.Enqueue('y')
        $resumed = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'

        $resumed.Completed | Should -BeTrue
        ($messages -join "`n") | Should -Match 'Do not repeat an irreversible operation blindly'
        @(Get-ChildItem -LiteralPath $work -Filter '*.tmp').Count | Should -Be 0
    }

    It 'opens the documented separate work folder with matching real module manifests' {
        $instanceRepo = Join-Path $directory 'instance-repo'
        $null = New-Item -ItemType Directory -Path (Join-Path $instanceRepo 'platform') -Force
        $configuration = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $repoRoot 'templates/instance/instance.yaml') -Raw)
        $configuration['modules'] = @{
            organizations = @{ parameters = @{ admin_logins = @('platform-admin'); billing_email = 'platform@example.test' } }
        }
        $repositoryConfiguration = Join-Path $instanceRepo 'instance.yaml'
        $configuration | ConvertTo-Yaml | Set-Content -LiteralPath $repositoryConfiguration
        $manualModules = Join-Path $instanceRepo 'platform/modules'
        Copy-Item -LiteralPath (Join-Path $repoRoot 'modules') -Destination $manualModules -Recurse
        Copy-Item -LiteralPath $repositoryConfiguration -Destination $instancePath
        $before = [IO.File]::ReadAllText($repositoryConfiguration)
        $answers.Enqueue('q')

        $result = & (Join-Path $repoRoot 'tools/Start-InstanceSetup.ps1') -WorkPath $work -ModulesPath $manualModules `
            -Phase ManualSteps -PassThru

        $result.ManualSteps.Id | Should -BeExactly 'organizations/delete-instance-organizations'
        $result.Completed | Should -BeFalse
        [IO.File]::ReadAllText($repositoryConfiguration) | Should -BeExactly $before
        Should -Invoke Read-Host -ModuleName InstanceSetup -Times 1 -Exactly
        Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 0
        Should -Invoke Start-Process -ModuleName InstanceSetup -Times 0
    }

    It 'guides upstream teardown restoration before deleting the actions organization' {
        $configuration = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $repoRoot 'templates/instance/instance.yaml') -Raw)
        $configuration['modules'] = @{
            organizations = @{ parameters = @{ admin_logins = @('platform-admin'); billing_email = 'platform@example.test' } }
        }
        $configuration | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath
        $arguments.ModulesPath = Join-Path $repoRoot 'modules'
        $before = [IO.File]::ReadAllText($instancePath)
        $answers.Enqueue($configuration.instance.name)
        $answers.Enqueue('n')

        $result = Invoke-InstanceSetup @arguments -ManualStep 'organizations/delete-instance-organizations'

        $guidance = $messages -join "`n"
        $guidance | Should -Match '(?s)enterprise-baseline.*PR.*\.github/workflows/teardown\.yml.*merged into main.*delete the actions and workloads organizations.*workflow_dispatch.*main'
        $guidance | Should -Match 'Generate-TeardownWorkflow\.ps1'
        $guidance | Should -Match '(?s)exact upstream SHA.*organization.*selected.*Read back.*stop'
        $guidance | Should -Match '(?s)merged into main.*cancel.*deploy\.yml.*completed.*delete the actions'
        $guidance | Should -Match 'Re-run'
        $result.Completed | Should -BeFalse
        $result.ManualSteps[0].Verified | Should -BeFalse
        [IO.File]::ReadAllText($instancePath) | Should -BeExactly $before
        Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 0
        Should -Invoke Start-Process -ModuleName InstanceSetup -Times 0
    }

    It 'recovers <Scenario> publication interrupted <Boundary> with <Termination>' -ForEach @(
        foreach ($scenario in @('Confirmation', 'InitialPending', 'ReconfirmPending')) {
            foreach ($boundary in @('BeforePublish', 'AfterPublish')) {
                foreach ($termination in @('Error', 'Abrupt')) {
                    $expected = if ($scenario -ceq 'Confirmation') {
                        if ($boundary -ceq 'BeforePublish') { 'Pending' } else { 'Confirmed' }
                    }
                    elseif ($scenario -ceq 'InitialPending') {
                        if ($boundary -ceq 'BeforePublish') { 'Missing' } else { 'Pending' }
                    }
                    else {
                        if ($boundary -ceq 'BeforePublish') { 'Confirmed' } else { 'Pending' }
                    }
                    @{
                        Scenario = $scenario; Boundary = $boundary; Termination = $termination
                        PublicationStatus = $(if ($scenario -ceq 'Confirmation') { 'Confirmed' } else { 'Pending' })
                        Reconfirm = $scenario -ceq 'ReconfirmPending'; ExpectedStatus = $expected
                        ExitCode = $(if ($termination -ceq 'Error') { 78 } else { 77 })
                        TemporaryCount = $(if ($boundary -ceq 'BeforePublish' -and $termination -ceq 'Abrupt') { 1 } else { 0 })
                    }
                }
            }
        }
    ) {
        $initialPrompts = 0
        if ($interruptionChildren.Count -eq 0) {
            $initialPrompts = & $startInterruptionChildren
        }
        $child = $interruptionChildren["$Scenario-$Boundary-$Termination"]
        $work = $child.Work
        $arguments.WorkPath = $work
        $arguments.ModulesPath = $child.Modules
        $path = Join-Path $work 'manual-steps-state.json'
        $originalProgress = $child.OriginalProgress
        $output = $child.Stdout.GetAwaiter().GetResult() + $child.Stderr.GetAwaiter().GetResult()
        # The parent resumes the wizard only after its full slot share is returned by the children.
        @($interruptionChildren.Values | Where-Object { -not $_.ContainsKey('Process') -or -not $_.Process.HasExited }).Count | Should -Be 0
        $child.Process.ExitCode | Should -Be $ExitCode -Because $output
        (Get-FileHash -LiteralPath $sourcePath).Hash | Should -BeExactly $sourceHash
        if ($ExpectedStatus -ceq 'Missing') {
            Test-Path -LiteralPath $path | Should -BeFalse
        }
        else {
            $state = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable
            $record = $state['steps']['application/verify-access']
            $record['status'] | Should -BeExactly $ExpectedStatus
            if ($ExpectedStatus -ceq 'Pending') {
                $record.Contains('confirmedAt') | Should -BeFalse
                $record.Contains('method') | Should -BeFalse
                $record.Contains('verified') | Should -BeFalse
            }
            elseif ($Reconfirm) {
                [IO.File]::ReadAllText($path) | Should -BeExactly $originalProgress
            }
        }
        @(Get-ChildItem -LiteralPath $work -Filter '*.tmp').Count | Should -Be $TemporaryCount
        if ($ExpectedStatus -cne 'Confirmed') {
            $answers.Enqueue('demo')
            $answers.Enqueue('y')
        }

        $resumed = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'

        $resumed.Completed | Should -BeTrue
        $expectedPrompts = $initialPrompts + $(if ($ExpectedStatus -ceq 'Confirmed') { 0 } else { 2 })
        Should -Invoke Read-Host -ModuleName InstanceSetup -Times $expectedPrompts -Exactly
    }

    It 'does not confirm a declined step or the configured manualSteps flag without a new declaration' {
        $instance['manualSteps'] = @{ application = @{ 'verify-access' = $true } }
        $instance | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath
        $answers.Enqueue('demo')
        $answers.Enqueue('n')

        $result = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'

        $result.Completed | Should -BeFalse
        $result.ManualSteps[0].Status | Should -BeExactly 'Pending'
        $state = Get-Content -LiteralPath $result.ProgressPath -Raw | ConvertFrom-Json -AsHashtable
        $state['steps']['application/verify-access'].ContainsKey('confirmedAt') | Should -BeFalse
    }

    It 'offers the next pending step on resume without replaying a completed step' {
        $manifestPath = Join-Path $modules 'application/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest['manualSteps'] += @{ id = 'review-setting'; description = 'Review the setting manually.'; owner = 'security' }
        $manifest | ConvertTo-Yaml | Set-Content -LiteralPath $manifestPath
        $answers.Enqueue('')
        $answers.Enqueue('demo')
        $answers.Enqueue('y')
        $answers.Enqueue('q')
        $first = Invoke-InstanceSetup @arguments
        $first.Completed | Should -BeFalse

        $answers.Enqueue('')
        $answers.Enqueue('demo')
        $answers.Enqueue('y')
        $answers.Enqueue('q')
        $second = Invoke-InstanceSetup @arguments

        $second.Completed | Should -BeTrue
        @($second.ManualSteps.Status) | Should -Be @('Confirmed', 'Confirmed')
        @($second.ManualSteps.Owner) | Should -Be @('platform', 'security')
        Should -Invoke Read-Host -ModuleName InstanceSetup -Times 1 -Exactly -ParameterFilter {
            $Prompt -like "Before starting or reviewing application/verify-access*"
        }
    }

    It 'retains human evidence when only manualSteps results change (<Change>)' -Tag ManualStepBinding -ForEach @(
        @{ Change = 'value' }
        @{ Change = 'addition' }
        @{ Change = 'removal' }
    ) {
        $instance['manualSteps'] = if ($Change -ceq 'addition') { @{} } else { @{ application = @{ 'verify-access' = $false } } }
        $instance | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath
        $answers.Enqueue('demo')
        $answers.Enqueue('y')
        $first = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'
        $before = [IO.File]::ReadAllText($first.ProgressPath)
        if ($Change -ceq 'removal') { $instance.Remove('manualSteps') }
        else { $instance['manualSteps'] = @{ application = @{ 'verify-access' = $true } } }
        $instance | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath

        $resumed = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'

        $resumed.Completed | Should -BeTrue
        $resumed.ManualSteps[0].Verified | Should -BeFalse
        [IO.File]::ReadAllText($first.ProgressPath) | Should -BeExactly $before
        $state = Get-Content -LiteralPath $first.ProgressPath -Raw | ConvertFrom-Json -AsHashtable
        $state['steps']['application/verify-access']['method'] | Should -BeExactly 'human'
        $state['steps']['application/verify-access']['verified'] | Should -BeFalse
        Should -Invoke Read-Host -ModuleName InstanceSetup -Times 2 -Exactly
    }

    It 'invalidates a saved confirmation when the <Change> changes' -Tag ManualStepBinding -ForEach @(
        @{ Change = 'configuration' }
        @{ Change = 'teams' }
        @{ Change = 'manifest' }
    ) {
        $answers.Enqueue('demo')
        $answers.Enqueue('y')
        $first = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'
        $before = Get-Content -LiteralPath $first.ProgressPath -Raw | ConvertFrom-Json -AsHashtable
        if ($Change -ceq 'configuration') {
            $instance['regions']['primary'] = 'northeurope'
            $instance | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath
        }
        elseif ($Change -ceq 'teams') {
            $instance['teams']['platform'] = @('another@example.test')
            $instance | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath
        }
        else {
            $manifestPath = Join-Path $modules 'application/module.yaml'
            $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
            $manifest['manualSteps'][0]['description'] = 'Verify changed access after deployment.'
            $manifest | ConvertTo-Yaml | Set-Content -LiteralPath $manifestPath
        }
        $answers.Enqueue('demo')
        $answers.Enqueue('n')

        $result = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'

        $result.Completed | Should -BeFalse
        $after = Get-Content -LiteralPath $result.ProgressPath -Raw | ConvertFrom-Json -AsHashtable
        $after['steps']['application/verify-access']['binding'] | Should -Not -BeExactly $before['steps']['application/verify-access']['binding']
    }

    It 'withdraws a previous confirmation before a forced review can be interrupted' {
        $answers.Enqueue('demo')
        $answers.Enqueue('y')
        $first = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'
        $answers.Enqueue('wrong')

        { Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access' -Reconfirm } | Should -Throw '*instance name*exactly*'

        $state = Get-Content -LiteralPath $first.ProgressPath -Raw | ConvertFrom-Json -AsHashtable
        $state['steps']['application/verify-access']['status'] | Should -BeExactly 'Pending'
    }

    It 'refuses a second writer without overwriting progress' {
        $path = Join-Path $work 'manual-steps-state.json'
        $lease = [IO.File]::Open("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            { Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access' } | Should -Throw '*manual-step progress*'
            Test-Path -LiteralPath $path | Should -BeFalse
            Should -Invoke Read-Host -ModuleName InstanceSetup -Times 0
        }
        finally { $lease.Dispose() }
    }

    It 'refuses configuration drift while the user is performing the manual action' {
        $onPrompt = {
            param($Prompt)
            if ($Prompt -like 'Have you completed*') {
                $instance['regions']['primary'] = 'northeurope'
                $instance | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath
            }
        }
        $answers.Enqueue('demo')
        $answers.Enqueue('y')

        { Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access' } | Should -Throw '*changed*during*'

        $state = Get-Content -LiteralPath (Join-Path $work 'manual-steps-state.json') -Raw | ConvertFrom-Json -AsHashtable
        $state['steps']['application/verify-access']['status'] | Should -BeExactly 'Pending'
    }

    It 'refuses an unavailable or noncanonical step (<Step>) before a prompt' -ForEach @(
        @{ Step = 'unknown/verify-access' }
        @{ Step = 'application/unknown' }
        @{ Step = 'Application/verify-access' }
        @{ Step = 'sensitive/verify-access' }
    ) {
        { Invoke-InstanceSetup @arguments -ManualStep $Step } | Should -Throw '*does not belong to the selected modules*'
        Should -Invoke Read-Host -ModuleName InstanceSetup -Times 0
    }

    It 'refuses incompatible phase options before creating a work folder' {
        $absent = Join-Path $TestDrive 'not-created'
        { Invoke-InstanceSetup -RepoPath $repoRoot -ModulesPath $modules -WorkPath $absent -Phase ManualSteps -GitHubAcceptance } |
            Should -Throw '*cannot run together*'
        { Invoke-InstanceSetup -RepoPath $repoRoot -ModulesPath $modules -WorkPath $absent -ManualStep 'application/verify-access' } |
            Should -Throw '*requires -Phase ManualSteps*'
        Test-Path -LiteralPath $absent | Should -BeFalse
    }

    It 'refuses invalid progress without overwriting it (<Case>)' -ForEach @(
        @{ Case = 'unreadable JSON' }
        @{ Case = 'array root' }
        @{ Case = 'unknown version' }
        @{ Case = 'missing version' }
        @{ Case = 'empty instance name' }
        @{ Case = 'wrong instance name type' }
        @{ Case = 'array steps' }
        @{ Case = 'missing steps' }
        @{ Case = 'array record' }
        @{ Case = 'empty status' }
        @{ Case = 'unknown status' }
        @{ Case = 'missing binding' }
        @{ Case = 'invalid binding' }
        @{ Case = 'missing start time' }
        @{ Case = 'invalid timestamp' }
        @{ Case = 'missing confirmation time' }
        @{ Case = 'missing method' }
        @{ Case = 'automatic method' }
        @{ Case = 'missing verified flag' }
        @{ Case = 'verified true' }
    ) {
        # Deliberately invalid local progress, not an external API response.
        $record = @{ binding = 'a' * 64; status = 'Confirmed'; startedAt = '2026-10-29T20:00:00Z'; confirmedAt = '2026-10-29T20:01:00Z'; method = 'human'; verified = $false }
        $state = @{ version = 1; instanceName = 'demo'; steps = @{ 'application/verify-access' = $record } }
        switch ($Case) {
            'array root' { $state = @($state) }
            'unknown version' { $state['version'] = 2 }
            'missing version' { $state.Remove('version') }
            'empty instance name' { $state['instanceName'] = '' }
            'wrong instance name type' { $state['instanceName'] = 42 }
            'array steps' { $state['steps'] = @($record) }
            'missing steps' { $state.Remove('steps') }
            'array record' { $state['steps']['application/verify-access'] = @($record) }
            'empty status' { $record['status'] = '' }
            'unknown status' { $record['status'] = 'Success' }
            'missing binding' { $record.Remove('binding') }
            'invalid binding' { $record['binding'] = '' }
            'missing start time' { $record.Remove('startedAt') }
            'invalid timestamp' { $record['confirmedAt'] = 'not-a-date' }
            'missing confirmation time' { $record.Remove('confirmedAt') }
            'missing method' { $record.Remove('method') }
            'automatic method' { $record['method'] = 'api' }
            'missing verified flag' { $record.Remove('verified') }
            'verified true' { $record['verified'] = $true }
        }
        $json = if ($Case -ceq 'unreadable JSON') { '{' } else { ConvertTo-Json -InputObject $state -Depth 30 }
        $path = Join-Path $work 'manual-steps-state.json'
        [IO.File]::WriteAllText($path, $json)

        { Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access' } | Should -Throw '*Invalid manual-step progress*'

        [IO.File]::ReadAllText($path) | Should -BeExactly $json
        Should -Invoke Read-Host -ModuleName InstanceSetup -Times 0
    }

    It 'reports an empty manual phase explicitly without creating progress' {
        $instance['modules'] = @{ foundation = @{} }
        $instance | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath

        $result = Invoke-InstanceSetup @arguments

        $result.ManualSteps.Count | Should -Be 0
        $result.Completed | Should -BeTrue
        Test-Path -LiteralPath $result.ProgressPath | Should -BeFalse
        ($messages -join "`n") | Should -Match 'declare no manual steps'
        Should -Invoke Read-Host -ModuleName InstanceSetup -Times 0
    }
}
