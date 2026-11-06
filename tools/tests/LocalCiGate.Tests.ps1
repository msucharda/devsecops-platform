BeforeDiscovery {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiGate.psm1') -Force
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiGate.psm1') -Force
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
}

Describe 'Local CI content-bound result' {
    BeforeEach {
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $repo | Out-Null
        git -C $repo init --quiet
        git -C $repo config user.email 'tests@example.invalid'
        git -C $repo config user.name 'Local CI tests'
        Set-Content (Join-Path $repo 'source.ps1') "'initial'" -NoNewline
        git -C $repo add .
        git -C $repo -c commit.gpgsign=false commit --quiet -m initial
        git -C $repo branch baseline
    }

    It 'accepts the exact pushed HEAD and stored base for the <GateProfile> profile' -ForEach @(
        @{ GateProfile = 'Local' }, @{ GateProfile = 'Full' }
    ) {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile $GateProfile
        Test-LocalCiGateResult -RepositoryRoot $repo -ExpectedHead $state.Head | Should -BeTrue
        { Test-LocalCiGateResult -RepositoryRoot $repo -ExpectedHead ('a' * 40) } | Should -Throw '*stale*'
        { Test-LocalCiGateResult -RepositoryRoot $repo -ExpectedHead $state.Head.ToUpperInvariant() } | Should -Throw '*stale*'
    }

    It 'preserves the canonical fingerprint for literal Unicode paths, empty and binary files' {
        [IO.File]::WriteAllText((Join-Path $repo 'source.ps1'), 'abc', [Text.UTF8Encoding]::new($false))
        $nested = Join-Path $repo 'nested'
        $null = New-Item -ItemType Directory -Path $nested
        [IO.File]::WriteAllBytes((Join-Path $nested 'ž [literal]=.txt'), [byte[]] @())
        git -C $repo add -- 'nested'
        $LASTEXITCODE | Should -Be 0
        $binary = Join-Path $repo 'binary.bin'
        [IO.File]::WriteAllBytes($binary, [byte[]] @(0, 1, 128, 255, 13, 10))
        $binaryHash = (Get-FileHash -LiteralPath $binary -Algorithm SHA256).Hash
        $emptyHash = 'E3B0C44298FC1C149AFBF4C8996FB92427AE41E4649B934CA495991B7852B855'
        $abcHash = 'BA7816BF8F01CFEA414140DE5DAE2223B00361A396177A9CB410FF61F20015AD'
        $reference = Join-Path $TestDrive 'fingerprint-reference'
        [IO.File]::WriteAllText($reference,
            "10:binary.bin=$binaryHash`n23:nested/ž [literal]=.txt=$emptyHash`n10:source.ps1=$abcHash`n",
            [Text.UTF8Encoding]::new($false))

        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline

        $state.Fingerprint | Should -BeExactly (Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash.ToLowerInvariant()
        $state.Clean | Should -BeFalse
    }

    It 'invalidates the receipt for same-size <Kind> byte edits with the original timestamp' -ForEach @(
        @{ Kind = 'tracked'; Name = 'source.ps1' }
        @{ Kind = 'untracked'; Name = 'new [literal].bin' }
    ) {
        $file = Join-Path $repo $Name
        if ($Kind -eq 'untracked') { [IO.File]::WriteAllBytes($file, [byte[]] @(0, 1, 128, 255)) }
        $before = [IO.File]::ReadAllBytes($file)
        $timestamp = [IO.File]::GetLastWriteTimeUtc($file)
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $before[0] = $before[0] -bxor 1
        [IO.File]::WriteAllBytes($file, $before)
        [IO.File]::SetLastWriteTimeUtc($file, $timestamp)

        $current = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline

        (Get-Item -LiteralPath $file).Length | Should -Be $before.Length
        [IO.File]::GetLastWriteTimeUtc($file) | Should -Be $timestamp
        $current.Head | Should -BeExactly $state.Head
        $current.BaseSha | Should -BeExactly $state.BaseSha
        $current.Fingerprint | Should -Not -BeExactly $state.Fingerprint
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*stale*Fingerprint*'
    }

    It 'preserves the deleted sentinel for <Case>' -ForEach @(
        @{ Case = 'a missing file'; MissingParent = $false }
        @{ Case = 'a missing parent directory'; MissingParent = $true }
    ) {
        $reference = Join-Path $TestDrive 'deleted-reference'
        if ($MissingParent) {
            $nested = Join-Path $repo 'nested'
            $null = New-Item -ItemType Directory -Path $nested
            [IO.File]::WriteAllText((Join-Path $nested 'source.ps1'), 'abc')
            git -C $repo add -- 'nested'
            $LASTEXITCODE | Should -Be 0
            Remove-Item -LiteralPath $nested -Recurse -Force
            $sourceHash = (Get-FileHash -LiteralPath (Join-Path $repo 'source.ps1') -Algorithm SHA256).Hash
            $expected = "17:nested/source.ps1=deleted`n10:source.ps1=$sourceHash`n"
        }
        else {
            Remove-Item -LiteralPath (Join-Path $repo 'source.ps1')
            $expected = "10:source.ps1=deleted`n"
        }
        [IO.File]::WriteAllText($reference, $expected, [Text.UTF8Encoding]::new($false))

        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline

        $state.Fingerprint | Should -BeExactly (Get-FileHash -LiteralPath $reference -Algorithm SHA256).Hash.ToLowerInvariant()
        $state.Clean | Should -BeFalse
    }

    It 'excludes Git-ignored untracked bytes but includes other untracked bytes' {
        [IO.File]::WriteAllText((Join-Path $repo '.gitignore'), 'ignored.bin')
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        [IO.File]::WriteAllBytes((Join-Path $repo 'ignored.bin'), [byte[]] @(0, 255))

        (Get-LocalCiContentState -RepositoryRoot $repo -Base baseline).Fingerprint | Should -BeExactly $state.Fingerprint
        [IO.File]::WriteAllBytes((Join-Path $repo 'included.bin'), [byte[]] @(0, 255))
        (Get-LocalCiContentState -RepositoryRoot $repo -Base baseline).Fingerprint | Should -Not -BeExactly $state.Fingerprint
    }

    It 'rejects a tracked file replaced by a directory' {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        Remove-Item -LiteralPath (Join-Path $repo 'source.ps1')
        $null = New-Item -ItemType Directory -Path (Join-Path $repo 'source.ps1')

        { Get-LocalCiContentState -RepositoryRoot $repo -Base baseline } | Should -Throw '*Cannot fingerprint non-file Git entry: source.ps1*'
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*Cannot fingerprint non-file Git entry: source.ps1*'
    }

    It 'rejects unreadable bytes without treating them as empty or deleted' -Skip:(-not $IsWindows) {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $stream = [IO.File]::Open((Join-Path $repo 'source.ps1'), [IO.FileMode]::Open, [IO.FileAccess]::Read, [IO.FileShare]::None)
        try {
            { Get-LocalCiContentState -RepositoryRoot $repo -Base baseline } | Should -Throw '*source.ps1*'
            { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*source.ps1*'
        }
        finally { $stream.Dispose() }

        Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline | Should -BeTrue
    }

    It 'rejects a malformed receipt with <Field> changed independently' -ForEach @(
        @{ Field = 'Schema'; Value = 2 }
        @{ Field = 'Schema'; Value = '1' }
        @{ Field = 'Status'; Value = '' }
        @{ Field = 'Status'; Value = @('selected-local-gate-passed') }
        @{ Field = 'Status'; Value = 'SELECTED-LOCAL-GATE-PASSED' }
        @{ Field = 'Profile'; Value = 'Unknown' }
        @{ Field = 'Profile'; Value = @('Local') }
        @{ Field = 'Profile'; Value = 'local' }
        @{ Field = 'State'; Value = 'not-an-object' }
    ) {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $path = (git -C $repo rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        $receipt = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $receipt[$Field] = $Value
        $receipt | ConvertTo-Json -Depth 5 | Set-Content $path
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*Invalid local gate result*'
    }

    It 'rejects an incomplete content binding' {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $path = (git -C $repo rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        $receipt = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $receipt.State.Remove('Fingerprint')
        $receipt | ConvertTo-Json -Depth 5 | Set-Content $path
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*stale*Fingerprint*'
    }

    It 'rejects an invalid stored base with <Case>' -ForEach @(
        @{ Case = 'an empty value'; Value = '' }
        @{ Case = 'an array'; Value = @('baseline') }
    ) {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $path = (git -C $repo rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        $receipt = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $receipt.State['Base'] = $Value
        $receipt | ConvertTo-Json -Depth 5 | Set-Content $path
        { Test-LocalCiGateResult -RepositoryRoot $repo } | Should -Throw '*missing base reference*'
    }

    It 'rejects an unreadable JSON result' {
        $path = (git -C $repo rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        Set-Content $path '{'
        { Test-LocalCiGateResult -RepositoryRoot $repo } | Should -Throw
    }

    It 'rejects an array instead of a result object' {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $path = (git -C $repo rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        $receipt = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        ConvertTo-Json -InputObject @($receipt) -Depth 5 | Set-Content $path
        { Test-LocalCiGateResult -RepositoryRoot $repo } | Should -Throw '*Invalid local gate result*'
    }

    It 'rejects a differently cased binding' {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $path = (git -C $repo rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        $receipt = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $receipt.State['Head'] = $state.Head.ToUpperInvariant()
        $receipt | ConvertTo-Json -Depth 5 | Set-Content $path
        { Test-LocalCiGateResult -RepositoryRoot $repo } | Should -Throw '*stale*Head*'
    }

    It 'rejects a non-string binding even when string comparison would coerce it' {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $path = (git -C $repo rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        $receipt = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        $receipt.State['Head'] = @($state.Head)
        $receipt | ConvertTo-Json -Depth 5 | Set-Content $path
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*stale*Head*'
    }

    It 'invalidates a successful result when <Change> changes' -ForEach @(
        @{ Change = 'tracked content' }
        @{ Change = 'untracked content' }
        @{ Change = 'deleted file' }
        @{ Change = 'HEAD' }
        @{ Change = 'base' }
    ) {
        $start = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $start -GateProfile Local
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Not -Throw
        switch ($Change) {
            'tracked content' { Set-Content (Join-Path $repo 'source.ps1') "'changed'" -NoNewline }
            'untracked content' { Set-Content (Join-Path $repo 'new.ps1') "'new'" -NoNewline }
            'deleted file' { Remove-Item (Join-Path $repo 'source.ps1') }
            'HEAD' { git -C $repo -c commit.gpgsign=false commit --quiet --allow-empty -m next }
            'base' {
                git -C $repo -c commit.gpgsign=false commit --quiet --allow-empty -m next
                git -C $repo branch --force baseline HEAD
                git -C $repo switch --quiet --detach HEAD~1
            }
        }
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*stale*'
    }

    It 'rejects a missing result and a result left by an interrupted rerun' {
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*No successful*'
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        Clear-LocalCiGateResult -RepositoryRoot $repo
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*No successful*'
    }

    It 'refuses a receipt for uncommitted code even when nothing changes after the gate' {
        Set-Content (Join-Path $repo 'source.ps1') "'fix-not-in-HEAD'"
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } |
            Should -Throw '*Commit*before*gate*'
    }

    It 'rejects hidden index flags <Flag> even when Git status reports a clean worktree' -ForEach @(
        @{ Flag = '--assume-unchanged' }, @{ Flag = '--skip-worktree' }
    ) {
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        git -C $repo update-index $Flag source.ps1
        $LASTEXITCODE | Should -Be 0
        Set-Content (Join-Path $repo 'source.ps1') "'hidden-from-status'" -NoNewline
        @(git -C $repo status --porcelain=v1).Count | Should -Be 0
        { Get-LocalCiContentState -RepositoryRoot $repo -Base baseline } | Should -Throw '*index flags*'
        { Test-LocalCiGateResult -RepositoryRoot $repo -Base baseline } | Should -Throw '*index flags*'
    }

    It 'enforces the receipt in a real pre-push hook against an isolated bare remote' {
        $tools = Join-Path $repo 'tools'
        $hooks = Join-Path $repo '.githooks'
        New-Item -ItemType Directory $tools, $hooks | Out-Null
        Copy-Item (Join-Path $repository 'tools/LocalCiGate.psm1'), (Join-Path $repository 'tools/Test-LocalCiResult.ps1') $tools
        Copy-Item (Join-Path $repository '.githooks/pre-push') $hooks
        if (-not $IsWindows) { & chmod '+x' (Join-Path $hooks 'pre-push') }
        git -C $repo add .
        git -C $repo -c commit.gpgsign=false commit --quiet -m 'Include the hook and validator in HEAD'
        $remote = Join-Path $TestDrive 'remote.git'
        git init --quiet --bare $remote
        $state = Get-LocalCiContentState -RepositoryRoot $repo -Base baseline
        Save-LocalCiGateResult -RepositoryRoot $repo -State $state -GateProfile Local
        $output = git -C $repo -c core.hooksPath=.githooks push --quiet $remote HEAD:refs/heads/accepted 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output

        Set-Content (Join-Path $repo 'source.ps1') "'after-gate'"
        $output = git -C $repo -c core.hooksPath=.githooks push --quiet $remote HEAD:refs/heads/rejected 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0
        $output | Should -Match 'stale'
        git --git-dir=$remote show-ref --verify --quiet refs/heads/rejected
        $LASTEXITCODE | Should -Be 1
    }
}

Describe 'Local CI external-program preflight' -Tag LocalCiRuntime {
    InModuleScope LocalCiGate {
        BeforeEach {
            $fixturePath = Join-Path (Split-Path (Get-Module LocalCiGate).Path -Parent) 'tests/fixtures/terraform/plan-runtime.json'
            $script:runtimePlan = (Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable).body
            Mock Invoke-LocalCiTerraform {
                if ($Arguments[0] -eq 'show') {
                    $script:runtimePlan | ConvertTo-Json -Depth 10
                }
            }
        }

        It 'checks the external string map from a Terraform plan using the committed provider lock' {
            Mock Invoke-LocalCiTerraform {
                if ($Arguments[0] -eq 'init') {
                    $configuration = Get-Content (Join-Path $Directory 'main.tf.json') -Raw | ConvertFrom-Json -AsHashtable
                    $configuration.data.external.runtime.program[0] | Should -BeExactly 'probe-pwsh'
                    $configuration.data.external.runtime.query.probe | Should -BeExactly 'local-ci'
                    $configuration.terraform.required_providers.external.version | Should -BeExactly '2.4.2'
                    $Arguments | Should -Contain '-lockfile=readonly'
                    Get-Content (Join-Path $Directory '.terraform.lock.hcl') -Raw | Should -Match 'zh:0b51793'
                }
                if ($Arguments[0] -eq 'show') {
                    $script:runtimePlan | ConvertTo-Json -Depth 10
                }
            }
            Test-LocalCiRuntime -TempPath $TestDrive -Executable 'probe-pwsh' | Should -BeTrue
            Should -Invoke Invoke-LocalCiTerraform -Times 1 -Exactly -ParameterFilter { $Arguments[0] -eq 'plan' }
            @(Get-ChildItem $TestDrive -Filter 'external-probe-*') | Should -BeNullOrEmpty
        }

        It 'rejects <Case> and removes the interrupted probe directory' -ForEach @(
            @{ Case = 'a missing executable'; Detail = 'External Program Lookup Failed: exec: "pwsh": executable file not found' }
            @{ Case = 'a non-launchable Store alias'; Detail = 'External Program Execution Failed: fork/exec pwsh.exe: The file cannot be accessed by the system.' }
            @{ Case = 'a failed provider initialization'; Detail = 'Provider checksum mismatch' }
        ) {
            Mock Invoke-LocalCiTerraform { throw $Detail }
            { Test-LocalCiRuntime -TempPath $TestDrive } | Should -Throw "*$Detail*working PowerShell*Microsoft Store*"
            @(Get-ChildItem $TestDrive -Filter 'external-probe-*') | Should -BeNullOrEmpty
        }

        It 'rejects <Case> in the external response' -ForEach @(
            @{ Case = 'a wrong probe'; Value = '{"probe":"other","version":"7.4.0"}' }
            @{ Case = 'an old version'; Value = '{"probe":"local-ci","version":"7.3.9"}' }
            @{ Case = 'a missing version'; Value = '{"probe":"local-ci"}' }
            @{ Case = 'a non-string version'; Value = '{"probe":"local-ci","version":7.4}' }
            @{ Case = 'an extra field'; Value = '{"probe":"local-ci","version":"7.4.0","extra":"value"}' }
            @{ Case = 'an empty version'; Value = '{"probe":"local-ci","version":""}' }
            @{ Case = 'an array'; Value = '[]' }
        ) {
            Mock Invoke-LocalCiTerraform {
                if ($Arguments[0] -eq 'show') {
                    $script:runtimePlan.planned_values.outputs.runtime.value = $Value | ConvertFrom-Json -AsHashtable -NoEnumerate
                    $script:runtimePlan | ConvertTo-Json -Depth 10
                }
            }
            { Test-LocalCiRuntime -TempPath $TestDrive } | Should -Throw '*expected external-program string map*'
        }

        It 'rejects plan format_version <Case>' -ForEach @(
            @{ Case = 'unsupported major'; Format = '2.0' }
            @{ Case = 'empty'; Format = '' }
            @{ Case = 'null'; Format = $null }
            @{ Case = 'non-string'; Format = 1.2 }
            @{ Case = 'array'; Format = @('1.2') }
        ) {
            $script:runtimePlan.format_version = $Format
            { Test-LocalCiRuntime -TempPath $TestDrive } | Should -Throw '*Unsupported Terraform plan format_version*'
        }

        It 'rejects a missing plan format_version' {
            $script:runtimePlan.Remove('format_version')
            { Test-LocalCiRuntime -TempPath $TestDrive } | Should -Throw '*Unsupported Terraform plan format_version*'
        }

        It 'accepts a newer minor plan format version' {
            $script:runtimePlan.format_version = '1.99'
            Test-LocalCiRuntime -TempPath $TestDrive | Should -BeTrue
        }
    }

    It 'rejects Windows TEMP paths that leave insufficient space for nested git refs' {
        $long = Join-Path $TestDrive ('x' * 81)
        { Assert-LocalCiTempPath -Path $long -Windows $true } | Should -Throw '*TEMP*64*TempRoot*'
    }
}

Describe 'Local CI process guards' -Tag LocalCiProcess {
    It 'rejects <Case> without publishing a result' -ForEach @(
        @{ Case = 'a HEAD change while loading workflow settings'; Command = 'Get-CiWorkflowSetting'; RuntimeFailure = $false; InvalidFile = $false; ExpectedExit = 2; ExpectedError = 'Source changed during test selection \(Head\)' }
        @{ Case = 'a HEAD change during test selection'; Command = 'Get-LocalCiProfile'; RuntimeFailure = $false; InvalidFile = $false; ExpectedExit = 2; ExpectedError = 'Source changed during test selection \(Head\)' }
        @{ Case = 'missing pwsh in Full with preflight exit code 2'; Command = 'Test-LocalCiRuntime'; RuntimeFailure = $true; InvalidFile = $false; ExpectedExit = 2; ExpectedError = 'pwsh not found.*working PowerShell' }
        @{ Case = 'Changed reaching actionlint without a Terraform probe'; Command = 'Clear-LocalCiTemp'; RuntimeFailure = $false; InvalidFile = $false; ProbeSkipped = $true; ExpectedExit = 2; ExpectedError = 'Actionlint.*archive is missing' }
        @{ Case = 'Full without roots reaching actionlint without a Terraform probe'; Command = 'Clear-LocalCiTemp'; RuntimeFailure = $false; InvalidFile = $false; ProbeSkipped = $true; NoRoots = $true; ExpectedExit = 2; ExpectedError = 'Actionlint.*archive is missing' }
        @{ Case = 'a parser error in a non-ASCII filename'; Command = ''; RuntimeFailure = $false; InvalidFile = $true; ExpectedExit = 1; ExpectedError = 'syntax errors' }
        @{ Case = 'an intermediate TEMP directory writable by another identity'; Command = ''; RuntimeFailure = $false; InvalidFile = $false; UnsafeTemp = 'Writable'; ExpectedExit = 1; ExpectedError = 'Unsafe CI TEMP' }
        @{ Case = 'an intermediate TEMP junction'; Command = ''; RuntimeFailure = $false; InvalidFile = $false; UnsafeTemp = 'Junction'; ExpectedExit = 1; ExpectedError = 'Unsafe CI TEMP' }
        @{ Case = 'a junction between UserProfile and the TEMP root'; Command = ''; RuntimeFailure = $false; InvalidFile = $false; UnsafeTemp = 'RootJunction'; ExpectedExit = 2; ExpectedError = 'direct child of UserProfile' }
        @{ Case = 'a TEMP root writable by another identity'; Command = ''; RuntimeFailure = $false; InvalidFile = $false; UnsafeTemp = 'RootWritable'; ExpectedExit = 1; ExpectedError = 'Unsafe CI TEMP' }
        @{ Case = 'a worktree TEMP junction'; Command = ''; RuntimeFailure = $false; InvalidFile = $false; UnsafeTemp = 'LeafJunction'; ExpectedExit = 1; ExpectedError = 'Unsafe CI TEMP' }
        @{ Case = 'a custom TEMP root outside Windows'; Command = ''; RuntimeFailure = $false; InvalidFile = $false; UnsupportedTemp = $true; ExpectedExit = 2; ExpectedError = 'TempRoot.*only supported on Windows' }
    ) {
        param([string] $UnsafeTemp = '', [bool] $UnsupportedTemp = $false, [bool] $ProbeSkipped = $false, [bool] $NoRoots = $false)
        if ($UnsafeTemp -and -not $IsWindows) {
            Set-ItResult -Skipped -Because 'Windows ACL and junction regression.'
            return
        }
        if ($UnsupportedTemp -and $IsWindows) {
            Set-ItResult -Skipped -Because 'Non-Windows parameter rejection.'
            return
        }
        $fixture = Join-Path $TestDrive ("guard-$([guid]::NewGuid().ToString('N').Substring(0, 8))")
        $null = New-Item -ItemType Directory -Path $fixture
        foreach ($file in @(git -C $repository ls-files)) {
            $source = Join-Path $repository $file
            if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { continue }
            $destination = Join-Path $fixture $file
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $destination -Parent)
            Copy-Item -LiteralPath $source -Destination $destination
        }
        if ($NoRoots) {
            Get-ChildItem -LiteralPath $fixture -Recurse -File | Where-Object { $_.Name -match '\.tf(\.json)?$' } |
                Remove-Item -Force
        }
        $requirements = Import-PowerShellDataFile (Join-Path $repository 'tools/requirements.psd1')
        $cache = Join-Path $fixture 'tools/.dependencies'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $cache 'packages')
        foreach ($name in $requirements.Development.Keys) {
            $version = $requirements.Development[$name]
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $cache $name)
            Copy-Item -LiteralPath (Join-Path $repository "tools/.dependencies/$name/$version") -Destination (Join-Path $cache "$name/$version") -Recurse
            Copy-Item -LiteralPath (Join-Path $repository "tools/.dependencies/packages/$name.$version.nupkg") -Destination (Join-Path $cache 'packages')
        }
        if ($InvalidFile) {
            # Keep this parser regression from recursively running its own fixture suite.
            $names = @(Get-ChildItem (Join-Path $fixture 'tools/tests') -Filter '*.Tests.ps1' |
                    ForEach-Object { "'$($_.Name)'" })
            Set-Content -LiteralPath (Join-Path $fixture 'tools/test-profiles.psd1') (
                "@{ Unit=@(); Contract=@(); Integration=@($($names -join ',')); Interruption=@() }")
        }
        git -C $fixture init --quiet
        git -C $fixture config user.email 'tests@example.invalid'
        git -C $fixture config user.name 'Local CI selection tests'
        git -C $fixture config commit.gpgsign false
        git -C $fixture add .
        git -C $fixture commit --quiet -m initial
        git -C $fixture branch baseline
        $tempRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) ".t$([guid]::NewGuid().ToString('N').Substring(0, 6))"
        if (Test-Path -LiteralPath $tempRoot) { throw 'Fixture TEMP root already exists.' }
        $fixtureTempRoot = $tempRoot
        $rootJunction = Join-Path $fixtureTempRoot 'alias'
        $leafJunction = $null
        $container = Join-Path $tempRoot 'devsecops-local-ci'
        try {
            if ($UnsafeTemp) {
                Initialize-LocalCiPrivateTempDirectory -Path $tempRoot
                if ($UnsafeTemp -cin @('Junction', 'RootJunction', 'LeafJunction')) {
                    $target = Join-Path $tempRoot 'target'
                    Initialize-LocalCiPrivateTempDirectory -Path $target
                    if ($UnsafeTemp -ceq 'RootJunction') {
                        $null = New-Item -ItemType Junction -Path $rootJunction -Value $target
                        $tempRoot = Join-Path $rootJunction 'temp'
                    }
                    elseif ($UnsafeTemp -ceq 'LeafJunction') {
                        Import-Module (Join-Path $repository 'tools/LocalCi.psm1') -Force
                        Initialize-LocalCiPrivateTempDirectory -Path $container
                        $leafJunction = Get-LocalCiTempPath -RepoPath $fixture -DataRoot $tempRoot
                        Set-Content -LiteralPath (Join-Path $target 'preserve.txt') 'untouched'
                        $null = New-Item -ItemType Junction -Path $leafJunction -Value $target
                    }
                    else { $null = New-Item -ItemType Junction -Path $container -Value $target }
                }
                else {
                    $unsafeDirectory = if ($UnsafeTemp -ceq 'RootWritable') { $tempRoot } else { $container }
                    Initialize-LocalCiPrivateTempDirectory -Path $unsafeDirectory
                    $directory = [IO.DirectoryInfo]::new($unsafeDirectory)
                    $acl = [IO.FileSystemAclExtensions]::GetAccessControl($directory, [Security.AccessControl.AccessControlSections]::Access)
                    $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                        [Security.Principal.SecurityIdentifier]::new('S-1-5-11'), [Security.AccessControl.FileSystemRights]::Modify,
                        [Security.AccessControl.AccessControlType]::Allow)
                    $null = $acl.AddAccessRule($rule)
                    [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
                }
            }
            if ($InvalidFile) {
                git -C $fixture config core.quotepath true
                Set-Content -LiteralPath (Join-Path $fixture "tools/$([char]0xE9).ps1") 'function {'
                git -C $fixture add .
                git -C $fixture commit --quiet -m 'Include an invalid non-ASCII source file'
            }
            $wrapper = Join-Path $TestDrive 'selection-race.ps1'
            $escaped = $fixture.Replace("'", "''")
            $action = if ($RuntimeFailure) {
                @'
    & (Get-Module LocalCiGate) {
        function script:Invoke-LocalCiTerraform { throw 'pwsh not found' }
    }
'@
            }
            elseif ($ProbeSkipped) {
                @'
    & (Get-Module LocalCiGate) {
        function script:Invoke-LocalCiTerraform { throw 'Unexpected Terraform probe' }
    }
'@
            }
            else {
                @"
    'function {' | Set-Content '$escaped/bad.ps1'
    git -C '$escaped' add bad.ps1
    git -C '$escaped' commit --quiet -m 'Change HEAD during selection'
"@
            }
            $breakpoint = if ($InvalidFile -or $UnsafeTemp -or $UnsupportedTemp) { '' } else { @"
Set-PSBreakpoint -Command '$Command' -Action {
$action
    Get-PSBreakpoint | Remove-PSBreakpoint
} | Out-Null
"@ }
            $tempArgument = if ($IsWindows -or $UnsupportedTemp) { " -TempRoot '$($tempRoot.Replace("'", "''"))'" } else { '' }
            if ($RuntimeFailure -or $NoRoots) { $tempArgument += ' -Full' }
            $parserStub = if ($InvalidFile) {
                @"
Set-PSBreakpoint -Command Get-ToolBinaryPath -Action {
    `$package = Get-ToolBinaryPackage -Name Actionlint
    New-Item -ItemType Directory -Force -Path (Split-Path `$package.CachePath -Parent) | Out-Null
    'offline archive stub' | Set-Content `$package.CachePath
    Get-Module -All ToolDependencies | ForEach-Object {
        & `$_ { function script:Expand-ToolBinary { '$escaped/fake-actionlint.ps1' } }
    }
    Get-PSBreakpoint | Remove-PSBreakpoint
} | Out-Null
"@
            } else { '' }
            if ($InvalidFile) {
                Set-Content -LiteralPath (Join-Path $fixture 'fake-actionlint.ps1') "'1.7.7'"
                git -C $fixture add .
                git -C $fixture commit --quiet -m 'Add offline actionlint stub'
            }
            @"
`$ErrorActionPreference = 'Stop'
Remove-Item Env:INVOKE_LOCAL_CI_ACTIVE -ErrorAction SilentlyContinue
$breakpoint
$parserStub
& '$escaped/tools/Invoke-LocalCi.ps1' -WorkerProcess -Base baseline$tempArgument -LogPath '$escaped/../selection.log' -StateRoot '$escaped/../machine-state'
exit `$LASTEXITCODE
"@ | Set-Content $wrapper
            $output = & ([Environment]::ProcessPath) -NoProfile -File $wrapper 2>&1 | Out-String
            $LASTEXITCODE | Should -Be $ExpectedExit -Because $output
            $output | Should -Match $ExpectedError
            $receipt = (git -C $fixture rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
            Test-Path -LiteralPath $receipt | Should -BeFalse
            if ($UnsafeTemp -ceq 'LeafJunction') {
                Get-Content -LiteralPath (Join-Path $target 'preserve.txt') | Should -BeExactly 'untouched'
            }
        }
        finally {
            if ($leafJunction -and (Test-Path -LiteralPath $leafJunction)) { Remove-Item -LiteralPath $leafJunction -Force }
            if ($UnsafeTemp -ceq 'Junction' -and (Test-Path -LiteralPath $container)) {
                Remove-Item -LiteralPath $container -Force
            }
            if ($UnsafeTemp -ceq 'RootJunction' -and (Test-Path -LiteralPath $rootJunction)) {
                Remove-Item -LiteralPath $rootJunction -Force
            }
            if (Test-Path -LiteralPath $fixtureTempRoot) { Remove-Item -LiteralPath $fixtureTempRoot -Recurse -Force }
        }
    }
}

Describe 'Changed-only PowerShell analysis' {
    It 'analyzes the explicit file and rejects its parser error' {
        $valid = Join-Path $TestDrive 'valid.ps1'
        $invalid = Join-Path $TestDrive 'invalid.ps1'
        Set-Content $valid "'valid'"
        Set-Content $invalid 'function {'
        & (Join-Path $repository 'tools/Test-PowerShell.ps1') -Path @($valid)
        { & (Join-Path $repository 'tools/Test-PowerShell.ps1') -Path @($invalid) } | Should -Throw '*syntax errors*'
    }
}

Describe 'Local CI gate timing output' -Tag LocalCiTimingOutput {
    It 'writes timings beside a plan log without leaving gaps in the run' {
        $runner = Join-Path $PSScriptRoot '../Invoke-LocalCi.ps1'
        $log = Join-Path $TestDrive 'plan.log'
        $watch = [Diagnostics.Stopwatch]::StartNew()
        $startedTimestamp = [Diagnostics.Stopwatch]::GetTimestamp()
        $output = & ([Environment]::ProcessPath) -NoProfile -File $runner -Plan -Base HEAD -LogPath $log `
            -StartedTimestamp $startedTimestamp 2>&1 | Out-String
        $watch.Stop()
        $LASTEXITCODE | Should -Be 0 -Because $output

        $summary = Get-Content -LiteralPath (Join-Path $TestDrive 'plan.timings.json') -Raw | ConvertFrom-Json
        $summary.Mode | Should -BeExactly 'Plan'
        $summary.Phases.Name | Should -Contain 'Test selection'
        $summary.TotalSeconds | Should -BeLessOrEqual $watch.Elapsed.TotalSeconds
        ($watch.Elapsed.TotalSeconds - $summary.TotalSeconds) | Should -BeLessThan 1
        [Math]::Abs(($summary.Phases | Measure-Object Seconds -Sum).Sum - $summary.TotalSeconds) | Should -BeLessThan 0.001
        $output | Should -Match 'TIMING Test selection'
    }

    It 'writes a failed timing artifact when usage validation exits before selection' {
        $runner = Join-Path $PSScriptRoot '../Invoke-LocalCi.ps1'
        $log = Join-Path $TestDrive 'failed.log'
        $output = & ([Environment]::ProcessPath) -NoProfile -File $runner -Changed -Full -LogPath $log 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 2 -Because $output

        $summary = Get-Content -LiteralPath (Join-Path $TestDrive 'failed.timings.json') -Raw | ConvertFrom-Json
        $summary.ExitCode | Should -Be 2
        $summary.Status | Should -BeExactly 'failed'
        @($summary.Phases).Count | Should -Be 1
        $summary.Phases[0].Name | Should -BeExactly 'Startup'
        $output | Should -Match 'TIMING Startup'
    }
}

Describe 'Local CI run-all gate' -Tag LocalCiSchedule {
    BeforeAll {
        $fixture = Join-Path $TestDrive 'schedule'
        $tools = Join-Path $fixture 'tools'
        $null = New-Item -ItemType Directory -Force -Path $tools, (Join-Path $tools 'tests'), (Join-Path $fixture '.github/workflows')
        foreach ($name in 'Invoke-LocalCi.ps1', 'LocalCi.psm1', 'LocalCiGate.psm1', 'LocalCiConcurrency.psm1',
            'LocalCiTiming.psm1', 'LocalCiSteps.psm1', 'LocalCiPester.psm1', 'pester-durations.psd1', 'requirements.psd1') {
            Copy-Item -LiteralPath (Join-Path $repository "tools/$name") -Destination $tools
        }
        Copy-Item -LiteralPath (Join-Path $repository '.github/workflows/ci.yml') -Destination (Join-Path $fixture '.github/workflows/ci.yml')
        $instanceWorkflows = Join-Path $fixture 'templates/instance/.github/workflows'
        $null = New-Item -ItemType Directory -Force -Path $instanceWorkflows
        foreach ($name in 'import-release.yml', 'import-action.yml', 'vendor.yml') {
            Set-Content -LiteralPath (Join-Path $instanceWorkflows $name) -Value '# CLI fixture'
        }
        # Executables and dependency lookup are the system boundary; the scheduler and result binding remain real.
        $dependencyRoot = (Join-Path $repository 'tools/.dependencies').Replace("'", "''")
        $yamlManifest = (Get-ToolDependencyPath -Name powershell-yaml).Replace("'", "''")
        @"
function Get-ToolDependencyPath {
    param([string] `$Name, [switch] `$ReuseLoaded)
    if (`$Name -eq 'powershell-yaml') { return '$yamlManifest' }
    `$requirements = Import-PowerShellDataFile (Join-Path `$PSScriptRoot 'requirements.psd1')
    `$version = if (`$Name -eq 'powershell-yaml') { `$requirements.Runtime[`$Name] } else { `$requirements.Development[`$Name] }
    return Join-Path '$dependencyRoot' "`$Name/`$version/`$Name.psd1"
}
function Get-ToolBinaryPath { param(`$Name, `$DestinationPath); Join-Path `$PSScriptRoot 'actionlint.ps1' }
"@ | Set-Content -LiteralPath (Join-Path $tools 'ToolDependencies.psm1')
        @'
param([switch] $version, [Parameter(ValueFromRemainingArguments)][object[]] $ArgumentList)
if ($version) { '1.7.7'; return }
$name = if ($ArgumentList -contains '.github/workflows/ci.yml') { 'Validate deployment workflow syntax' }
else { 'Validate instance workflows that call local reusable workflows' }
"output: $name"
if ($env:LOCAL_CI_FAILED_STEP -in @($name, 'all')) { throw "failure: $name" }
'@ | Set-Content -LiteralPath (Join-Path $tools 'actionlint.ps1')
        $stub = @'
param(
    $Path, $CacheDirectory, $ModulesPath, $InstancePath, $OutputPath, $ResultPath,
    [switch] $Check, [switch] $CI
)
$name = '%%STEP%%'
if ($name -eq 'Validate module manifests' -and $ModulesPath -like '*runner-modules') { $name = 'Validate instance examples' }
"output: $name"
if ($env:LOCAL_CI_FAILED_STEP -in @($name, 'all')) { throw "failure: $name" }
if ($name -eq 'Run Pester') {
    $suites = foreach ($file in $Path) {
        $escaped = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath($file))
        '<test-suite name="{0}" result="Success" success="True" time="1"><results><test-case name="{0}" executed="True" result="Success" success="True" time="1" /></results></test-suite>' -f $escaped
    }
    $count = @($Path).Count
    $xml = '<test-results total="{0}" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0" result="Success" success="True" time="1"><test-suite name="Pester" result="Success" success="True" time="1"><results>{1}</results></test-suite></test-results>' -f $count, ($suites -join '')
    Set-Content -LiteralPath $ResultPath -Value $xml
    "Tests Passed: $count, Failed: 0, Skipped: 0, NotRun: 0"
}
'@
        foreach ($entry in @{
            'Test-PowerShell.ps1' = 'Check PowerShell'
            'Test-ModuleManifests.ps1' = 'Validate module manifests'
            'Test-InstanceConfiguration.ps1' = 'Validate instance examples'
            'Generate-DeploymentWorkflow.ps1' = 'Check generated workflows'
            'Generate-TeardownWorkflow.ps1' = 'Check generated workflows'
            'Invoke-Tests.ps1' = 'Run Pester'
        }.GetEnumerator()) {
            Set-Content -LiteralPath (Join-Path $tools $entry.Key) -Value $stub.Replace('%%STEP%%', $entry.Value)
        }
        @'
param($RepositoryPath, $GitHubOutputPath)
if ($GitHubOutputPath) {
    'output: Discover Terraform roots'
    if ($env:LOCAL_CI_FAILED_STEP -in @('Discover Terraform roots', 'all')) { throw 'failure: Discover Terraform roots' }
} else { '[]' }
'@ | Set-Content -LiteralPath (Join-Path $tools 'Get-TerraformRoots.ps1')
        Set-Content -LiteralPath (Join-Path $tools 'test-profiles.psd1') "@{ Unit=@('Fixture.Tests.ps1', 'Second.Tests.ps1'); Contract=@(); Integration=@(); Interruption=@() }"
        Set-Content -LiteralPath (Join-Path $tools 'tests/Fixture.Tests.ps1') ''
        Set-Content -LiteralPath (Join-Path $tools 'tests/Second.Tests.ps1') ''
        Set-Content -LiteralPath (Join-Path $fixture '.gitignore') 'artifacts/'
        git -C $fixture init --quiet
        git -C $fixture config user.email 'tests@example.invalid'
        git -C $fixture config user.name 'Local CI scheduler tests'
        git -C $fixture add .
        git -C $fixture -c commit.gpgsign=false commit --quiet -m initial
        git -C $fixture branch baseline
        Add-Content -LiteralPath (Join-Path $tools 'Test-PowerShell.ps1') '# Changed analysis target'
        git -C $fixture add .
        git -C $fixture -c commit.gpgsign=false commit --quiet -m changed
        $stepNames = @(
            'Check PowerShell', 'Validate module manifests', 'Validate instance examples', 'Check generated workflows',
            'Discover Terraform roots', 'Validate deployment workflow syntax',
            'Validate instance workflows that call local reusable workflows', 'Run Pester'
        )
    }

    It 'reports every selected step with failure=<Failure> and budget=<Budget>' -ForEach @(
        @{ Failure = 'none'; Budget = 4 }
        @{ Failure = 'Check PowerShell'; Budget = 4 }
        @{ Failure = 'Validate module manifests'; Budget = 4 }
        @{ Failure = 'Validate instance examples'; Budget = 4 }
        @{ Failure = 'Check generated workflows'; Budget = 4 }
        @{ Failure = 'Discover Terraform roots'; Budget = 4 }
        @{ Failure = 'Validate deployment workflow syntax'; Budget = 4 }
        @{ Failure = 'Validate instance workflows that call local reusable workflows'; Budget = 4 }
        @{ Failure = 'Run Pester'; Budget = 4 }
        @{ Failure = 'all'; Budget = 4 }
        @{ Failure = 'none'; Budget = 1 }
    ) {
        $log = Join-Path $fixture 'artifacts/schedule.log'
        $savedActive = $env:INVOKE_LOCAL_CI_ACTIVE
        $env:LOCAL_CI_FAILED_STEP = $Failure
        Remove-Item Env:INVOKE_LOCAL_CI_ACTIVE -ErrorAction SilentlyContinue
        try {
            $output = & ([Environment]::ProcessPath) -NoProfile -File (Join-Path $tools 'Invoke-LocalCi.ps1') `
                -Base baseline -LogPath $log -WorkerBudget $Budget -StateRoot (Join-Path $TestDrive 'scheduler-machine') 2>&1 | Out-String
            $code = $LASTEXITCODE
        }
        finally {
            $env:INVOKE_LOCAL_CI_ACTIVE = $savedActive
            Remove-Item Env:LOCAL_CI_FAILED_STEP
        }

        $code | Should -Be $(if ($Failure -eq 'none') { 0 } else { 1 }) -Because $output
        $content = Get-Content -LiteralPath $log -Raw
        foreach ($name in $stepNames) {
            $content | Should -Match "=== $([regex]::Escape($name))\r?\n"
            $status = if ($Failure -in @($name, 'all')) { 'FAIL' } else { 'PASS' }
            $content | Should -Match "$status\s+$([regex]::Escape($name)) \["
        }
        $blocks = [regex]::Split($content, '(?m)^=== ')
        foreach ($block in $blocks | Select-Object -Skip 1) {
            $name = ($block -split '\r?\n')[0]
            foreach ($line in ($block -split '\r?\n' | Where-Object { $_ -like 'output: *' })) {
                $line | Should -BeExactly "output: $name" -Because 'child output must stay inside its own step block'
            }
        }
        $content | Should -Not -Match 'fail-fast'
        $receipt = (git -C $fixture rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        Test-Path -LiteralPath $receipt | Should -Be ($Failure -eq 'none')
        $summary = Get-Content -LiteralPath ([IO.Path]::ChangeExtension($log, '.timings.json')) -Raw | ConvertFrom-Json
        $summary.MachineQueue.Slots | Should -Be $Budget
        @($summary.PesterShards).Count | Should -Be $(if ($Budget -eq 1) { 1 } else { 2 })
        ($summary.PesterShards | Measure-Object FileCount -Sum).Sum | Should -Be 2
        foreach ($shard in $summary.PesterShards) { $shard.Seconds | Should -BeGreaterThan 0 }
        if ($Failure -notin @('Run Pester', 'all')) {
            ($summary.PesterShards.Files | Measure-Object).Count | Should -Be 2
            $summary.PesterShards.Files.Seconds | Should -BeExactly @(1, 1)
            Test-Path (Join-Path $fixture 'artifacts/pester.xml') | Should -BeTrue
        }
        @($summary.Steps.Name | Sort-Object) | Should -BeExactly @($stepNames | Sort-Object)
        $phase = $summary.Phases | Where-Object Name -EQ 'Concurrent checks'
        foreach ($step in $summary.Steps) {
            $step.StartSeconds | Should -BeGreaterOrEqual $phase.StartSeconds
            ($step.StartSeconds + $step.Seconds) | Should -BeLessOrEqual ($phase.StartSeconds + $phase.Seconds)
        }
        [Math]::Abs(($summary.Phases | Measure-Object Seconds -Sum).Sum - $summary.TotalSeconds) | Should -BeLessThan 0.001
    }

    It 'never accepts a pass receipt when timing finalization ends at <Boundary> and recovers on retry' -Tag LocalCiFinalization -ForEach @(
        @{ Boundary = 'staging write' }
        @{ Boundary = 'rename' }
        @{ Boundary = 'abrupt before timings' }
    ) {
        $log = Join-Path $fixture 'artifacts/finalization.log'
        $timingPath = [IO.Path]::ChangeExtension($log, '.timings.json')
        $blocked = if ($Boundary -eq 'staging write') { "$timingPath.new" } else { $timingPath }
        $receipt = (git -C $fixture rev-parse --path-format=absolute --git-path local-ci-pass.json).Trim()
        $runner = Join-Path $tools 'Invoke-LocalCi.ps1'
        $stateRoot = Join-Path $TestDrive 'finalization-machine'
        $savedActive = $env:INVOKE_LOCAL_CI_ACTIVE
        Remove-Item Env:INVOKE_LOCAL_CI_ACTIVE -ErrorAction SilentlyContinue
        try {
            Save-LocalCiGateResult -RepositoryRoot $fixture -State (Get-LocalCiContentState -RepositoryRoot $fixture -Base baseline) -GateProfile Local
            Test-LocalCiGateResult -RepositoryRoot $fixture -Base baseline | Should -BeTrue
            Remove-Item -LiteralPath $timingPath, "$timingPath.new" -Force -ErrorAction SilentlyContinue
            if ($Boundary -eq 'abrupt before timings') {
                $wrapper = Join-Path $fixture 'artifacts/interrupt-finalization.ps1'
                $null = New-Item -ItemType Directory -Force -Path (Split-Path $wrapper -Parent)
                @'
param($Runner, $Log, $StateRoot)
Set-PSBreakpoint -Command Save-LocalCiTiming -Action { [Environment]::Exit(9) } | Out-Null
& $Runner -Base baseline -LogPath $Log -WorkerBudget 1 -StateRoot $StateRoot -WorkerProcess
'@ | Set-Content -LiteralPath $wrapper
                $output = & ([Environment]::ProcessPath) -NoProfile -File $wrapper -Runner $runner -Log $log -StateRoot $stateRoot 2>&1 | Out-String
            }
            else {
                $null = New-Item -ItemType Directory -Force -Path $blocked
                Set-Content -LiteralPath (Join-Path $blocked 'blocker') 'Prevent removal of the directory'
                $output = & ([Environment]::ProcessPath) -NoProfile -File $runner `
                    -Base baseline -LogPath $log -WorkerBudget 1 -StateRoot $stateRoot 2>&1 | Out-String
            }
            $LASTEXITCODE | Should -Not -Be 0 -Because $output
            { Test-LocalCiGateResult -RepositoryRoot $fixture -Base baseline } | Should -Throw '*No successful*'
            Test-Path -LiteralPath $receipt | Should -BeFalse
            if (Test-Path -LiteralPath $blocked -PathType Container) { Remove-Item -LiteralPath $blocked -Recurse -Force }

            $retry = & ([Environment]::ProcessPath) -NoProfile -File $runner `
                -Base baseline -LogPath $log -WorkerBudget 1 -StateRoot $stateRoot 2>&1 | Out-String

            $LASTEXITCODE | Should -Be 0 -Because $retry
            Test-LocalCiGateResult -RepositoryRoot $fixture -Base baseline | Should -BeTrue
            (Get-Content -LiteralPath $timingPath -Raw | ConvertFrom-Json).Status | Should -BeExactly 'passed'
        }
        finally {
            $env:INVOKE_LOCAL_CI_ACTIVE = $savedActive
            if (Test-Path -LiteralPath $blocked -PathType Container) { Remove-Item -LiteralPath $blocked -Recurse -Force }
        }
    }
}

Describe 'Local CI profiles' {
    It 'keeps the complete Pester, interruption, mutation and Terraform selection in the full plan' {
        $log = Join-Path $TestDrive 'full-plan.log'
        $output = & ([Environment]::ProcessPath) -NoProfile -File (Join-Path $repository 'tools/Invoke-LocalCi.ps1') -Full -Base HEAD -Plan -LogPath $log 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output
        $output | Should -Match 'Mode: Full'
        $output | Should -Match 'Pester: all'
        $output | Should -Match 'Interruption: all'
        $output | Should -Match 'Mutation: all'
        $output | Should -Not -Match 'Terraform roots: none'
    }
}

Describe 'Local CI changed paths' {
    BeforeEach {
        $repo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        New-Item -ItemType Directory $repo | Out-Null
        git -C $repo init --quiet
        git -C $repo config user.email 'tests@example.invalid'
        git -C $repo config user.name 'Local CI tests'
        Set-Content (Join-Path $repo 'source.ps1') "'initial'" -NoNewline
        git -C $repo add .
        git -C $repo -c commit.gpgsign=false commit --quiet -m initial
        git -C $repo branch baseline
    }

    It 'preserves literal changed, added and untracked paths even when Git quotes names by default' {
        git -C $repo config core.quotepath true
        $changed = "changed-$([char]0xE9) file.ps1"
        $added = "added-$([char]0xE9) file.ps1"
        $untracked = "untracked-$([char]0xE9) file.ps1"
        Set-Content -LiteralPath (Join-Path $repo $changed) "'before'"
        git -C $repo add .
        git -C $repo -c commit.gpgsign=false commit --quiet -m 'Track a non-ASCII path'
        git -C $repo branch path-baseline
        Set-Content -LiteralPath (Join-Path $repo $changed) "'after'"
        Set-Content -LiteralPath (Join-Path $repo $added) "'added'"
        git -C $repo add .
        git -C $repo -c commit.gpgsign=false commit --quiet -m 'Change non-ASCII paths'
        Set-Content -LiteralPath (Join-Path $repo $untracked) "'untracked'"

        $paths = Get-LocalCiChangedFile -RepositoryRoot $repo -MergeBase path-baseline -Head HEAD

        $paths.Changed.Count | Should -Be 3
        $paths.Changed | Should -Contain $changed
        $paths.Changed | Should -Contain $added
        $paths.Changed | Should -Contain $untracked
        $paths.Added.Count | Should -Be 2
        $paths.Added | Should -Contain $added
        $paths.Added | Should -Contain $untracked
        (Get-LocalCiChangedFile -RepositoryRoot $repo -MergeBase path-baseline).Changed | Should -Contain $changed
    }

    It 'preserves distinct Unicode-normalization paths without culture-based deduplication' {
        $composed = "$([char]0xE9).ps1"
        $decomposed = "e$([char]0x301).ps1"
        Set-Content -LiteralPath (Join-Path $repo $composed) "'composed'"
        Set-Content -LiteralPath (Join-Path $repo $decomposed) "'decomposed'"

        $paths = Get-LocalCiChangedFile -RepositoryRoot $repo -MergeBase baseline

        $paths.Changed.Count | Should -Be 2
        $paths.Added.Count | Should -Be 2
        $paths.Changed | Should -Contain $composed
        $paths.Changed | Should -Contain $decomposed
    }

    It 'preserves an embedded newline in a Unix filename' -Skip:$IsWindows {
        $name = "line`nbreak.ps1"
        Set-Content -LiteralPath (Join-Path $repo $name) "'source'"

        $paths = Get-LocalCiChangedFile -RepositoryRoot $repo -MergeBase baseline

        $paths.Changed | Should -BeExactly @($name)
        $paths.Added | Should -BeExactly @($name)
    }
}
