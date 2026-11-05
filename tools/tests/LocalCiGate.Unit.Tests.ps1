BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiGate.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../LocalCi.psm1') -Force
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
}

Describe 'Local CI step result acceptance' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../LocalCiSteps.psm1') -Force
    }

    BeforeEach {
        $record = '{"Name":"Pester","ExitCode":0,"Seconds":1.25,"StartSeconds":0.5,"Output":["passed"]}' | ConvertFrom-Json
    }

    It 'accepts a complete result for exit <Code>' -ForEach @(@{ Code = 0 }, @{ Code = 7 }) {
        $record.ExitCode = [long] $Code
        { Assert-LocalCiStepResult -Record $record -Name 'Pester' } | Should -Not -Throw
    }

    It 'rejects the missing field <Field> by name' -ForEach @(
        @{ Field = 'Name' }, @{ Field = 'ExitCode' }, @{ Field = 'Seconds' }, @{ Field = 'StartSeconds' }, @{ Field = 'Output' }
    ) {
        $record.PSObject.Properties.Remove($Field)

        { Assert-LocalCiStepResult -Record $record -Name 'Pester' } | Should -Throw "*missing field '$Field'*"
    }

    It 'rejects <Case> by its own condition' -ForEach @(
        @{ Case = 'a null record'; Field = $null; Value = $null; Message = '*missing record*' }
        @{ Case = 'an empty name array'; Field = 'Name'; Value = @(); Message = '*Name must be a string*' }
        @{ Case = 'a single-element name array'; Field = 'Name'; Value = @('Pester'); Message = '*Name must be a string*' }
        @{ Case = 'a null name'; Field = 'Name'; Value = $null; Message = '*Name must be a string*' }
        @{ Case = 'a different name'; Field = 'Name'; Value = 'Static'; Message = '*name does not match*' }
        @{ Case = 'name casing'; Field = 'Name'; Value = 'pester'; Message = '*name does not match*' }
        @{ Case = 'a string exit code'; Field = 'ExitCode'; Value = '0'; Message = '*ExitCode must be an integer*' }
        @{ Case = 'a decimal exit code'; Field = 'ExitCode'; Value = 0.5; Message = '*ExitCode must be an integer*' }
        @{ Case = 'a boolean exit code'; Field = 'ExitCode'; Value = $false; Message = '*ExitCode must be an integer*' }
        @{ Case = 'a null exit code'; Field = 'ExitCode'; Value = $null; Message = '*ExitCode must be an integer*' }
        @{ Case = 'negative duration'; Field = 'Seconds'; Value = -0.5; Message = '*Seconds must be nonnegative*' }
        @{ Case = 'negative start offset'; Field = 'StartSeconds'; Value = -0.5; Message = '*StartSeconds must be nonnegative*' }
        @{ Case = 'string duration'; Field = 'Seconds'; Value = '1'; Message = '*Seconds must be numeric*' }
        @{ Case = 'null start offset'; Field = 'StartSeconds'; Value = $null; Message = '*StartSeconds must be numeric*' }
        @{ Case = 'NaN duration'; Field = 'Seconds'; Value = [double]::NaN; Message = '*Seconds must be finite*' }
        @{ Case = 'infinite start offset'; Field = 'StartSeconds'; Value = [double]::PositiveInfinity; Message = '*StartSeconds must be finite*' }
        @{ Case = 'string output'; Field = 'Output'; Value = 'passed'; Message = '*Output must be an array*' }
        @{ Case = 'null output'; Field = 'Output'; Value = $null; Message = '*Output must be an array*' }
    ) {
        if ($null -eq $Field) { $record = $null } else { $record.$Field = $Value }

        { Assert-LocalCiStepResult -Record $record -Name 'Pester' } | Should -Throw $Message
    }
}

Describe 'Local CI step scheduling' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot '../LocalCiSteps.psm1') -Force
    }

    It 'reports every failed step and continues through the remaining steps in each child' {
        $groups = @(
            @{ Steps = @(
                @{ Name = 'Manifests'; Script = "'manifests failed'; throw 'invalid manifest'" }
                @{ Name = 'Examples'; Script = "'examples failed'; throw 'invalid example'" }
                @{ Name = 'Generated'; Script = "'generated ran'" }
            ) }
            @{ Steps = @(
                @{ Name = 'Pester'; Script = "'pester failed'; & '$([Environment]::ProcessPath)' -NoProfile -Command 'exit 7'" }
            ) }
        )

        $results = @(Invoke-LocalCiStepSchedule -Group $groups -Slots 2 -WorkingDirectory $TestDrive -TempPath $TestDrive)

        @($results.Name) | Should -BeExactly @('Manifests', 'Examples', 'Generated', 'Pester')
        @($results.ExitCode) | Should -Be @(1, 1, 0, 7)
        ($results[0].Output -join "`n") | Should -Match 'invalid manifest'
        ($results[1].Output -join "`n") | Should -Match 'invalid example'
        ($results[2].Output -join "`n") | Should -BeExactly 'generated ran'
        ($results[3].Output -join "`n") | Should -BeExactly 'pester failed'
    }

    It 'overlaps groups within the granted slots while keeping grouped steps in one process' {
        $directory = Join-Path $TestDrive 'overlap'
        $null = New-Item -ItemType Directory -Path $directory
        $barrier = @'
[IO.File]::WriteAllText('ready-NUMBER', '')
$watch = [Diagnostics.Stopwatch]::StartNew()
while (-not (Test-Path 'ready-OTHER')) {
    if ($watch.Elapsed.TotalSeconds -gt 10) { throw 'Groups did not overlap' }
    Start-Sleep -Milliseconds 20
}
"process=$PID; slots=$env:LOCAL_CI_WORKER_BUDGET"
'@
        $groups = @(
            @{ Steps = @(
                @{ Name = 'Static one'; Script = $barrier.Replace('NUMBER', '1').Replace('OTHER', '2') }
                @{ Name = 'Static two'; Script = '"process=$PID; slots=$env:LOCAL_CI_WORKER_BUDGET"' }
                @{ Name = 'Static three'; Script = '"process=$PID; slots=$env:LOCAL_CI_WORKER_BUDGET"' }
            ) }
            @{ Steps = @(@{ Name = 'Pester'; Script = $barrier.Replace('NUMBER', '2').Replace('OTHER', '1') }) }
        )

        $results = @(Invoke-LocalCiStepSchedule -Group $groups -Slots 2 -WorkingDirectory $directory -TempPath $directory)

        @($results.ExitCode) | Should -Be @(0, 0, 0, 0)
        $results[0].Output | Should -BeExactly $results[1].Output
        $results[0].Output | Should -BeExactly $results[2].Output
        $results[0].Output | Should -Not -Be $results[3].Output
        $results[0].Output[0] | Should -Match '; slots=1$'
        $results[0].Seconds | Should -BeGreaterThan 0
    }

    It 'queues a group until its full slot share is available' {
        $directory = Join-Path $TestDrive 'weighted'
        $null = New-Item -ItemType Directory -Path $directory
        $groups = @(
            @{ Slots = 2; Steps = @(@{ Name = 'Pester'; Script = @'
if ($env:LOCAL_CI_WORKER_BUDGET -ne '2') { throw 'Wrong Pester share' }
Start-Sleep -Milliseconds 150
[IO.File]::WriteAllText('pester-done', '')
'@ }) }
            @{ Steps = @(@{ Name = 'Static'; Script = "if (-not (Test-Path 'pester-done')) { throw 'Exceeded slot budget' }" }) }
        )

        $results = @(Invoke-LocalCiStepSchedule -Group $groups -Slots 2 -WorkingDirectory $directory -TempPath $directory)

        @($results.ExitCode) | Should -Be @(0, 0)
    }

    It 'fails a missing result after an abruptly exited child and still runs the next group' {
        $groups = @(
            @{ Steps = @(@{ Name = 'Interrupted'; Script = 'exit 0' }) }
            @{ Steps = @(@{ Name = 'Later'; Script = "'still ran'" }) }
        )

        $results = @(Invoke-LocalCiStepSchedule -Group $groups -Slots 1 -WorkingDirectory $TestDrive -TempPath $TestDrive)

        @($results.ExitCode) | Should -Be @(1, 0)
        ($results[0].Output -join "`n") | Should -Match 'did not return a valid result'
        $results[1].Output | Should -BeExactly @('still ran')
    }

    It 'reports every process-start failure with its actual timing offset' {
        $groups = @(
            @{ Steps = @(@{ Name = 'Static'; Script = "'unreachable'" }) }
            @{ Steps = @(@{ Name = 'Pester'; Script = "'unreachable'" }) }
        )

        $results = @(Invoke-LocalCiStepSchedule -Group $groups -Slots 1 `
            -WorkingDirectory (Join-Path $TestDrive 'missing') -TempPath $TestDrive)

        @($results.ExitCode) | Should -Be @(1, 1)
        foreach ($result in $results) {
            $result.Output[0] | Should -Match '^Cannot start step process:'
            $result.StartSeconds | Should -BeGreaterThan 0
        }
    }

    It 'preserves host output fragments as complete lines for Pester counts and log blocks' {
        $groups = @(@{ Steps = @(@{ Name = 'Pester'; Script = @'
Write-Host 'Tests Passed: 3, ' -NoNewline
Write-Host 'Failed: 0, ' -NoNewline
Write-Host 'Skipped: 0, NotRun: 0'
'@ }) })

        $result = Invoke-LocalCiStepSchedule -Group $groups -Slots 1 -WorkingDirectory $TestDrive -TempPath $TestDrive

        @($result.Output) | Should -BeExactly @('Tests Passed: 3, Failed: 0, Skipped: 0, NotRun: 0')
        (Get-PesterCount -Line $result.Output).Passed | Should -Be 3
    }
}

Describe 'Local CI gate change selection' {
    BeforeEach {
        $fixture = Join-Path $TestDrive "selection-$([guid]::NewGuid().ToString('N'))"
        $files = @{
            'tools/Invoke-LocalCi.ps1' = 'param()'
            'tools/tests/LocalCiGate.Unit.Tests.ps1' = "'LocalCiGate.psm1'"
            'tools/tests/LocalCiConcurrency.Tests.ps1' = "'LocalCiConcurrency.psm1'"
            'tools/tests/LocalCiRuntimeProbe.Tests.ps1' = "'Test-LocalCiRuntimeProbe.ps1'"
            'tools/tests/RunnerConsumer.Tests.ps1' = "'Invoke-LocalCi.ps1'"
            'tools/tests/Unrelated.Tests.ps1' = "'Other.ps1'"
            'tools/tests/RunnerIntegration.Tests.ps1' = "'Invoke-LocalCi.ps1'"
            'tools/test-profiles.psd1' = @"
@{
    Unit = @('LocalCiGate.Unit.Tests.ps1', 'LocalCiRuntimeProbe.Tests.ps1', 'RunnerConsumer.Tests.ps1', 'Unrelated.Tests.ps1')
    Contract = @('LocalCiConcurrency.Tests.ps1')
    Integration = @('RunnerIntegration.Tests.ps1')
    Interruption = @()
}
"@
        }
        foreach ($path in $files.Keys) {
            $fullPath = Join-Path $fixture $path
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $fullPath -Parent)
            Set-Content -LiteralPath $fullPath -Value $files[$path]
        }
    }

    It 'selects gate suites and isolated references rather than the whole profile for <File>' -ForEach @(
        @{ File = 'tools/Invoke-LocalCi.ps1' }
        @{ File = 'tools/LocalCi.psm1' }
        @{ File = 'tools/LocalCiGate.psm1' }
        @{ File = 'tools/LocalCiConcurrency.psm1' }
        @{ File = 'tools/LocalCiSteps.psm1' }
        @{ File = 'tools/LocalCiTiming.psm1' }
        @{ File = 'tools/Test-LocalCiResult.ps1' }
        @{ File = '.githooks/pre-push' }
    ) {
        $fullPath = Join-Path $fixture $File
        $null = New-Item -ItemType Directory -Force -Path (Split-Path $fullPath -Parent)
        Set-Content -LiteralPath $fullPath -Value 'param()'
        $reference = "'$([IO.Path]::GetFileName($File))'"
        Set-Content -LiteralPath (Join-Path $fixture 'tools/tests/RunnerConsumer.Tests.ps1') -Value $reference
        Set-Content -LiteralPath (Join-Path $fixture 'tools/tests/RunnerIntegration.Tests.ps1') -Value $reference
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile $File -TerraformRoot @()
        $testProfile = Get-LocalCiProfile -RepositoryRoot $fixture -PesterPath $selection.PesterPath -AllPester:$selection.AllPester

        $testProfile.Selected | Should -BeExactly @(
            'tools/tests/LocalCiConcurrency.Tests.ps1'
            'tools/tests/LocalCiGate.Unit.Tests.ps1'
            'tools/tests/LocalCiRuntimeProbe.Tests.ps1'
            'tools/tests/RunnerConsumer.Tests.ps1'
        )
        $testProfile.Remote | Should -Contain 'tools/tests/RunnerIntegration.Tests.ps1'
    }

    It 'selects the whole isolated profile for shared infrastructure <File>' -ForEach @(
        @{ File = 'tools/Invoke-Tests.ps1' }
        @{ File = 'tools/requirements.psd1' }
        @{ File = 'tools/test-profiles.psd1' }
        @{ File = 'tools/Test-PowerShell.ps1' }
        @{ File = '.github/workflows/ci.yml' }
    ) {
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile $File -TerraformRoot @()
        $testProfile = Get-LocalCiProfile -RepositoryRoot $fixture -PesterPath $selection.PesterPath -AllPester:$selection.AllPester

        $testProfile.Selected | Should -BeExactly @(
            'tools/tests/LocalCiConcurrency.Tests.ps1'
            'tools/tests/LocalCiGate.Unit.Tests.ps1'
            'tools/tests/LocalCiRuntimeProbe.Tests.ps1'
            'tools/tests/RunnerConsumer.Tests.ps1'
            'tools/tests/Unrelated.Tests.ps1'
        )
    }

    It 'falls back to the whole isolated profile when gate references are unknown or only name a longer file' {
        Set-Content -LiteralPath (Join-Path $fixture 'tools/tests/RunnerConsumer.Tests.ps1') -Value "'Invoke-LocalCi.ps1.extra'"
        Set-Content -LiteralPath (Join-Path $fixture 'tools/tests/RunnerIntegration.Tests.ps1') -Value ''
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile 'tools/Invoke-LocalCi.ps1' -TerraformRoot @()
        $testProfile = Get-LocalCiProfile -RepositoryRoot $fixture -PesterPath $selection.PesterPath -AllPester:$selection.AllPester

        $selection.AllPester | Should -BeTrue
        $selection.Reason | Should -Contain 'tools/Invoke-LocalCi.ps1: gate dependencies are uncertain; every Pester and interruption test runs.'
        $testProfile.Selected | Should -Contain 'tools/tests/Unrelated.Tests.ps1'
    }

    It 'does not treat selection fixture mentions as dependency evidence for a new gate module' {
        Set-Content -LiteralPath (Join-Path $fixture 'tools/LocalCiNewWorker.psm1') -Value 'param()'
        Set-Content -LiteralPath (Join-Path $fixture 'tools/tests/RunnerConsumer.Tests.ps1') -Value "@{ File = 'LocalCiNewWorker.psm1' }"
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile 'tools/LocalCiNewWorker.psm1' -TerraformRoot @()

        $selection.AllPester | Should -BeTrue
        $selection.Reason | Should -Contain 'tools/LocalCiNewWorker.psm1: gate dependencies are uncertain; every Pester and interruption test runs.'
        (Get-LocalCiProfile -RepositoryRoot $fixture -AllPester:$selection.AllPester).Selected |
            Should -Contain 'tools/tests/Unrelated.Tests.ps1'
    }

    It 'falls back to the whole isolated profile when a gate file was deleted' {
        Remove-Item -LiteralPath (Join-Path $fixture 'tools/Invoke-LocalCi.ps1')
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile 'tools/Invoke-LocalCi.ps1' -TerraformRoot @()

        $selection.AllPester | Should -BeTrue
        (Get-LocalCiProfile -RepositoryRoot $fixture -AllPester:$selection.AllPester).Selected |
            Should -Contain 'tools/tests/Unrelated.Tests.ps1'
    }

    It 'falls back to the whole isolated profile when no gate suite can be identified' {
        Get-ChildItem -LiteralPath (Join-Path $fixture 'tools/tests') -Filter 'LocalCi*.Tests.ps1' | Remove-Item
        Set-Content -LiteralPath (Join-Path $fixture 'tools/test-profiles.psd1') -Value @"
@{
    Unit = @('RunnerConsumer.Tests.ps1', 'Unrelated.Tests.ps1')
    Contract = @()
    Integration = @('RunnerIntegration.Tests.ps1')
    Interruption = @()
}
"@
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile 'tools/Invoke-LocalCi.ps1' -TerraformRoot @()

        $selection.AllPester | Should -BeTrue
        (Get-LocalCiProfile -RepositoryRoot $fixture -AllPester:$selection.AllPester).Selected |
            Should -BeExactly @('tools/tests/RunnerConsumer.Tests.ps1', 'tools/tests/Unrelated.Tests.ps1')
    }

    It 'includes a gate reference with different Windows path casing' {
        Set-Content -LiteralPath (Join-Path $fixture 'tools/tests/RunnerConsumer.Tests.ps1') -Value "'invoke-localci.ps1'"
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile 'tools/Invoke-LocalCi.ps1' -TerraformRoot @()

        $selection.PesterPath | Should -Contain 'tools/tests/RunnerConsumer.Tests.ps1'
        $selection.AllPester | Should -BeFalse
    }

    It 'falls back to the whole isolated profile when a test source cannot be read' {
        Mock Get-Content -ModuleName LocalCi {
            throw 'Test source is unreadable'
        } -ParameterFilter { $LiteralPath -like '*Unrelated.Tests.ps1' }

        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile 'tools/Invoke-LocalCi.ps1' -TerraformRoot @()

        $selection.AllPester | Should -BeTrue
        $selection.Warning | Should -Contain 'Cannot read tools/tests/Unrelated.Tests.ps1; test dependencies are uncertain.'
    }

    It 'explains each selected suite and keeps all causes when multiple changes select it' {
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile @(
            'tools/Invoke-LocalCi.ps1', 'tools/tests/RunnerConsumer.Tests.ps1'
        ) -TerraformRoot @()

        $selection.PesterReason['tools/tests/LocalCiGate.Unit.Tests.ps1'] | Should -Contain 'gate suite for tools/Invoke-LocalCi.ps1'
        $selection.PesterReason['tools/tests/RunnerConsumer.Tests.ps1'] | Should -Contain 'references tools/Invoke-LocalCi.ps1'
        $selection.PesterReason['tools/tests/RunnerConsumer.Tests.ps1'] | Should -Contain 'affected by tools/tests/RunnerConsumer.Tests.ps1'
    }

    It 'explains every suite selected by a whole-profile fallback' {
        $selection = Get-LocalCiSelection -RepoPath $fixture -ChangedFile '.github/workflows/ci.yml' -TerraformRoot @()
        $testProfile = Get-LocalCiProfile -RepositoryRoot $fixture -PesterPath $selection.PesterPath -AllPester:$selection.AllPester

        foreach ($path in $testProfile.Selected) {
            $selection.PesterReason[$path] | Should -Contain '.github/workflows/ci.yml changed: every Pester and interruption test runs.'
        }
    }
}

Describe 'Local CI profiles' {
    It 'keeps every discovered test in the full profile and only isolated suites in the local profile' {
        $testProfile = Get-LocalCiProfile -RepositoryRoot $repository -AllPester
        $discovered = @(Get-ChildItem (Join-Path $repository 'tools/tests') -Filter '*.Tests.ps1' |
            ForEach-Object Name | Sort-Object)

        @($testProfile.Full | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object) | Should -BeExactly $discovered
        $testProfile.Local | Should -Contain 'tools/tests/DeploymentIdentifier.Tests.ps1'
        $testProfile.Local | Should -Contain 'tools/tests/LocalCiGate.Unit.Tests.ps1'
        $testProfile.Local | Should -Contain 'tools/tests/CanonicalConfiguration.Tests.ps1'
        $testProfile.Local | Should -Contain 'tools/tests/ActionUpdates.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/MutationRunner.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/LocalCiGate.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/EnterpriseBaseline.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/GitHubBootstrap.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/VendoringPullRequest.Tests.ps1'
        @($testProfile.Local | Where-Object { $_ -notin $testProfile.Full }).Count | Should -Be 0
    }

    It 'selects only affected isolated suites and reports the rest as remote work' {
        $testProfile = Get-LocalCiProfile -RepositoryRoot $repository -PesterPath @(
            'tools/tests/DeploymentIdentifier.Tests.ps1', 'tools/tests/EnterpriseBaseline.Tests.ps1'
        )
        @($testProfile.Selected) | Should -BeExactly @('tools/tests/DeploymentIdentifier.Tests.ps1')
        $testProfile.Remote | Should -Contain 'tools/tests/EnterpriseBaseline.Tests.ps1'
    }

    It 'rejects a newly discovered test without an explicit category' {
        $fixture = Join-Path $TestDrive 'profile'
        $tests = Join-Path $fixture 'tools/tests'
        New-Item -ItemType Directory -Force $tests | Out-Null
        Set-Content (Join-Path $tests 'Known.Tests.ps1') ''
        Set-Content (Join-Path $tests 'Unknown.Tests.ps1') ''
        Set-Content (Join-Path $fixture 'tools/test-profiles.psd1') "@{ Unit=@('Known.Tests.ps1'); Contract=@(); Integration=@(); Interruption=@() }"
        { Get-LocalCiProfile -RepositoryRoot $fixture -AllPester } | Should -Throw '*missing*Unknown.Tests.ps1*'
    }

}

Describe 'Local CI index visibility' {
    It 'accepts visible cached entries' {
        InModuleScope LocalCiGate {
            { Assert-LocalCiIndexVisibility -Entry @('H source.ps1', 'H file with spaces.ps1') } | Should -Not -Throw
        }
    }

    It 'rejects a hidden or unsupported index tag <Tag>' -ForEach @(
        @{ Tag = 'h' }, @{ Tag = 'S' }, @{ Tag = 's' }, @{ Tag = 'M' }, @{ Tag = 'Z' }
    ) {
        InModuleScope LocalCiGate -Parameters @{ Tag = $Tag } {
            param($Tag)
            # Z deliberately models invalid Git output.
            $entries = @('H visible.ps1', "$Tag source.ps1")
            { Assert-LocalCiIndexVisibility -Entry $entries } | Should -Throw '*index flags*'
        }
    }
}

Describe 'Local CI Windows TEMP root scope' {
    BeforeEach {
        $userProfile = Join-Path $TestDrive 'profile'
    }

    It 'accepts the default root omission outside Windows' {
        { Assert-LocalCiWindowsTempRoot -Path '' -UserProfile $userProfile -Windows $false } | Should -Not -Throw
    }

    It 'rejects a custom root outside Windows: <Root>' -ForEach @(
        @{ Root = '/tmp' }, @{ Root = 'relative' }, @{ Root = ' ' }
    ) {
        { Assert-LocalCiWindowsTempRoot -Path $Root -UserProfile $userProfile -Windows $false } |
            Should -Throw '*TempRoot*only supported on Windows*'
    }

    It 'accepts a direct profile child with <Case>' -ForEach @(
        @{ Case = 'the default name'; Leaf = '.dci'; UpperCase = $false; TrailingSeparator = $false }
        @{ Case = 'a custom name'; Leaf = 'custom'; UpperCase = $false; TrailingSeparator = $false }
        @{ Case = 'different Windows casing'; Leaf = 'custom'; UpperCase = $true; TrailingSeparator = $false }
        @{ Case = 'a trailing separator'; Leaf = 'custom'; UpperCase = $false; TrailingSeparator = $true }
    ) {
        $path = Join-Path $userProfile $Leaf
        if ($UpperCase) { $path = $path.ToUpperInvariant() }
        if ($TrailingSeparator) { $path += [IO.Path]::DirectorySeparatorChar }
        { Assert-LocalCiWindowsTempRoot -Path $path -UserProfile $userProfile -Windows $true } | Should -Not -Throw
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'the profile itself'; Kind = 'Profile' }
        @{ Case = 'a nested directory'; Kind = 'Nested' }
        @{ Case = 'a profile-prefix sibling'; Kind = 'Sibling' }
        @{ Case = 'a volume-root child'; Kind = 'Volume' }
        @{ Case = 'the public C:\t directory'; Kind = 'Public' }
    ) {
        $path = switch ($Kind) {
            Profile { $userProfile }
            Nested { Join-Path $userProfile 'nested/temp' }
            Sibling { Join-Path "$userProfile-other" 'temp' }
            Volume { Join-Path ([IO.Path]::GetPathRoot($userProfile)) 'temp' }
            Public { 'C:\t' }
        }
        { Assert-LocalCiWindowsTempRoot -Path $path -UserProfile $userProfile -Windows $true } | Should -Throw '*direct child*UserProfile*'
    }

    It 'rejects a junction between the profile and root without accessing its target' -Skip:(-not $IsWindows) {
        $target = Join-Path $TestDrive 'outside-profile'
        $junction = Join-Path $userProfile 'alias'
        New-Item -ItemType Directory -Path $userProfile, $target | Out-Null
        $null = New-Item -ItemType Junction -Path $junction -Value $target
        try {
            { Assert-LocalCiWindowsTempRoot -Path (Join-Path $junction 'temp') -UserProfile $userProfile -Windows $true } |
                Should -Throw '*direct child*UserProfile*'
            Test-Path -LiteralPath (Join-Path $target 'temp') | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $junction -Force }
    }
}

Describe 'Local CI private TEMP access' {
    BeforeEach {
        $userSid = 'S-1-5-21-1-2-3-1000'
        $access = @{
            Directory = $true; ReparsePoint = $false; Owner = $userSid; Protected = $true
            Rules = @($userSid, 'S-1-5-18' | ForEach-Object {
                @{ Sid = $_; Type = 'Allow'; Rights = 2032127; Inheritance = 3; Propagation = 0; Inherited = $false }
            })
        }
    }

    It 'accepts the protected owner and SYSTEM ACL' {
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Not -Throw
    }

    It 'accepts SYSTEM ownership with the same restricted access rules' {
        $access.Owner = 'S-1-5-18'
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Not -Throw
    }

    It 'rejects unsafe access: <Case>' -ForEach @(
        @{ Case = 'a regular file'; Field = 'Directory'; Value = $false; Error = '*regular directory*' }
        @{ Case = 'unknown directory type'; Field = 'Directory'; Value = $null; Error = '*regular directory*' }
        @{ Case = 'string directory type'; Field = 'Directory'; Value = 'True'; Error = '*regular directory*' }
        @{ Case = 'a reparse point'; Field = 'ReparsePoint'; Value = $true; Error = '*regular directory*' }
        @{ Case = 'unknown reparse point state'; Field = 'ReparsePoint'; Value = $null; Error = '*regular directory*' }
        @{ Case = 'string reparse point state'; Field = 'ReparsePoint'; Value = 'False'; Error = '*regular directory*' }
        @{ Case = 'different owner'; Field = 'Owner'; Value = 'S-1-5-21-9-9-9-1000'; Error = '*untrusted owner*' }
        @{ Case = 'differently cased owner'; Field = 'Owner'; Value = 's-1-5-21-1-2-3-1000'; Error = '*untrusted owner*' }
        @{ Case = 'inherited ACL'; Field = 'Protected'; Value = $false; Error = '*inheritance*' }
        @{ Case = 'unknown inheritance state'; Field = 'Protected'; Value = $null; Error = '*inheritance*' }
        @{ Case = 'string inheritance state'; Field = 'Protected'; Value = 'True'; Error = '*inheritance*' }
    ) {
        $access[$Field] = $Value
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Throw $Error
    }

    It 'rejects an unsafe rule: <Case>' -ForEach @(
        @{ Case = 'unknown identity'; Field = 'Sid'; Value = 'S-1-5-11'; Error = '*identity*' }
        @{ Case = 'duplicate identity'; Field = 'Sid'; Value = 'S-1-5-18'; Error = '*identity*' }
        @{ Case = 'deny rule'; Field = 'Type'; Value = 'Deny'; Error = '*access rule*' }
        @{ Case = 'differently cased rule'; Field = 'Type'; Value = 'allow'; Error = '*access rule*' }
        @{ Case = 'incomplete rights'; Field = 'Rights'; Value = 131241; Error = '*access rule*' }
        @{ Case = 'missing object inheritance'; Field = 'Inheritance'; Value = 1; Error = '*access rule*' }
        @{ Case = 'missing container inheritance'; Field = 'Inheritance'; Value = 2; Error = '*access rule*' }
        @{ Case = 'inherit-only propagation'; Field = 'Propagation'; Value = 2; Error = '*access rule*' }
        @{ Case = 'inherited rule'; Field = 'Inherited'; Value = $true; Error = '*access rule*' }
        @{ Case = 'unknown rule inheritance'; Field = 'Inherited'; Value = $null; Error = '*access rule*' }
        @{ Case = 'string rule inheritance'; Field = 'Inherited'; Value = 'False'; Error = '*access rule*' }
    ) {
        $access.Rules[0][$Field] = $Value
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Throw $Error
    }

    It 'rejects an additional writable identity' {
        $access.Rules += @{ Sid = 'S-1-5-11'; Type = 'Allow'; Rights = 2032127; Inheritance = 3; Propagation = 0; Inherited = $false }
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Throw '*unexpected access rules*'
    }

    It 'creates a protected Windows directory and refuses existing broader access' -Skip:(-not $IsWindows) {
        $path = Join-Path $TestDrive 'private-temp'
        Initialize-LocalCiPrivateTempDirectory -Path $path
        Initialize-LocalCiPrivateTempDirectory -Path $path
        $directory = [IO.DirectoryInfo]::new($path)
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($directory, [Security.AccessControl.AccessControlSections]::Access)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-11'), [Security.AccessControl.FileSystemRights]::Modify,
            [Security.AccessControl.AccessControlType]::Allow)
        $null = $acl.AddAccessRule($rule)
        [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
        { Initialize-LocalCiPrivateTempDirectory -Path $path } | Should -Throw '*Unsafe CI TEMP*'
        (Get-Acl -LiteralPath $path).Access.Count | Should -Be 3
    }

    It 'rejects a real Windows junction without following or repairing it' -Skip:(-not $IsWindows) {
        $target = Join-Path $TestDrive 'private-target'
        $junction = Join-Path $TestDrive 'temp-junction'
        Initialize-LocalCiPrivateTempDirectory -Path $target
        $null = New-Item -ItemType Junction -Path $junction -Value $target
        try {
            { Initialize-LocalCiPrivateTempDirectory -Path $junction } | Should -Throw '*regular directory*'
            ((Get-Item -LiteralPath $junction).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        }
        finally { Remove-Item -LiteralPath $junction -Force }
    }
}
