BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $repoRoot 'tools/InstanceSetup.psm1') -Force
}

Describe 'Instance setup manual steps through the public wizard' {
    BeforeEach {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $work = Join-Path $directory 'work'
        $modules = Join-Path $directory 'modules'
        $null = New-Item -ItemType Directory -Path $work -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/runner-modules') -Destination $modules -Recurse
        $instancePath = Join-Path $work 'instance.yaml'
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance['modules'] = @{ application = @{} }
        $instance | ConvertTo-Yaml | Set-Content -LiteralPath $instancePath
        $arguments = @{ RepoPath = $repoRoot; WorkPath = $work; ModulesPath = $modules; Phase = 'ManualSteps' }
        $answers = [Collections.Generic.Queue[string]]::new()
        $messages = [Collections.Generic.List[string]]::new()
        $onPrompt = $null
        Mock Read-Host -ModuleName InstanceSetup {
            if ($onPrompt) { & $onPrompt $Prompt }
            if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
            $answers.Dequeue()
        }
        Mock Write-Host -ModuleName InstanceSetup { $messages.Add([string] $Object) }
        Mock Invoke-WebRequest -ModuleName InstanceSetup { throw 'Manual guidance must not call an API.' }
        Mock Start-Process -ModuleName InstanceSetup { throw 'Manual guidance must not launch a process.' }
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
        $path = Join-Path $work 'manual-steps-state.json'
        $initialPrompts = 0
        $originalProgress = $null
        if ($Reconfirm) {
            $answers.Enqueue('demo')
            $answers.Enqueue('y')
            $null = Invoke-InstanceSetup @arguments -ManualStep 'application/verify-access'
            $originalProgress = [IO.File]::ReadAllText($path)
            $initialPrompts = 2
        }
        $sourcePath = Join-Path $repoRoot 'tools/InstanceSetup.ManualSteps.ps1'
        $sourceHash = (Get-FileHash -LiteralPath $sourcePath).Hash
        $start = [Diagnostics.ProcessStartInfo]::new([Environment]::ProcessPath)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @(
                '-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot 'fixtures/Invoke-ManualStepsInterruption.ps1'),
                '-ToolsPath', (Join-Path $repoRoot 'tools'), '-WorkPath', $work, '-ModulesPath', $modules,
                '-Boundary', $Boundary, '-Termination', $Termination, '-PublicationStatus', $PublicationStatus
            )) { $start.ArgumentList.Add($argument) }
        if ($Reconfirm) { $start.ArgumentList.Add('-Reconfirm') }
        $process = [Diagnostics.Process]::Start($start)
        try {
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(120000)) {
                $process.Kill($true)
                throw 'The manual-step interruption child did not finish within 120 seconds.'
            }
            $output = $stdout.GetAwaiter().GetResult() + $stderr.GetAwaiter().GetResult()
            $process.ExitCode | Should -Be $ExitCode -Because $output
        }
        finally { $process.Dispose() }
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

    It 'invalidates a saved confirmation when the <Change> changes' -ForEach @(
        @{ Change = 'configuration' }
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
