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

Describe 'Local CI external-program preflight' {
    It 'runs a real child pwsh with redirected stdin and a string-map response' {
        Test-LocalCiRuntime -TempPath $TestDrive -Executable ([Environment]::ProcessPath) | Should -BeTrue
    }

    It 'rejects a pwsh executable that cannot be launched before any tests run' {
        { Test-LocalCiRuntime -TempPath $TestDrive -Executable (Join-Path $TestDrive 'missing-pwsh') } |
            Should -Throw '*pwsh external-program preflight failed*'
    }

    It 'rejects a PATH executable that resolves but cannot launch through Go' {
        $name = "invalid-pwsh-$([guid]::NewGuid().ToString('N')).exe"
        $path = Join-Path $TestDrive $name
        # Deliberately invalid executable, not a simulated Windows AppExecLink.
        [IO.File]::WriteAllBytes($path, [byte[]] @())
        if (-not $IsWindows) { & chmod '+x' $path }
        $savedPath = $env:PATH
        $env:PATH = "$TestDrive$([IO.Path]::PathSeparator)$savedPath"
        try {
            { Test-LocalCiRuntime -TempPath $TestDrive -Executable $name } |
                Should -Throw '*Terraform external-program launch failed*'
        }
        finally { $env:PATH = $savedPath }
    }

    It 'rejects Windows TEMP paths that leave insufficient space for nested git refs' {
        $long = Join-Path $TestDrive ('x' * 81)
        { Assert-LocalCiTempPath -Path $long -Windows $true } | Should -Throw '*TEMP*64*TempRoot*'
    }
}

Describe 'Local CI process guards' {
    It 'rejects <Case> without publishing a result' -ForEach @(
        @{ Case = 'a HEAD change while loading workflow settings'; Command = 'Get-CiWorkflowSetting'; MissingGo = $false; InvalidFile = $false; ExpectedExit = 2; ExpectedError = 'Source changed during test selection \(Head\)' }
        @{ Case = 'a HEAD change during test selection'; Command = 'Get-LocalCiProfile'; MissingGo = $false; InvalidFile = $false; ExpectedExit = 2; ExpectedError = 'Source changed during test selection \(Head\)' }
        @{ Case = 'missing Go with preflight exit code 2'; Command = 'Test-LocalCiRuntime'; MissingGo = $true; InvalidFile = $false; ExpectedExit = 2; ExpectedError = 'Go is missing' }
        @{ Case = 'a parser error in a non-ASCII filename'; Command = ''; MissingGo = $false; InvalidFile = $true; ExpectedExit = 1; ExpectedError = 'syntax errors' }
        @{ Case = 'an intermediate TEMP directory writable by another identity'; Command = ''; MissingGo = $false; InvalidFile = $false; UnsafeTemp = 'Writable'; ExpectedExit = 1; ExpectedError = 'Unsafe CI TEMP' }
        @{ Case = 'an intermediate TEMP junction'; Command = ''; MissingGo = $false; InvalidFile = $false; UnsafeTemp = 'Junction'; ExpectedExit = 1; ExpectedError = 'Unsafe CI TEMP' }
        @{ Case = 'a junction between UserProfile and the TEMP root'; Command = ''; MissingGo = $false; InvalidFile = $false; UnsafeTemp = 'RootJunction'; ExpectedExit = 2; ExpectedError = 'direct child of UserProfile' }
        @{ Case = 'a TEMP root writable by another identity'; Command = ''; MissingGo = $false; InvalidFile = $false; UnsafeTemp = 'RootWritable'; ExpectedExit = 1; ExpectedError = 'Unsafe CI TEMP' }
        @{ Case = 'a worktree TEMP junction'; Command = ''; MissingGo = $false; InvalidFile = $false; UnsafeTemp = 'LeafJunction'; ExpectedExit = 1; ExpectedError = 'Unsafe CI TEMP' }
        @{ Case = 'a custom TEMP root outside Windows'; Command = ''; MissingGo = $false; InvalidFile = $false; UnsupportedTemp = $true; ExpectedExit = 2; ExpectedError = 'TempRoot.*only supported on Windows' }
    ) {
        param([string] $UnsafeTemp = '', [bool] $UnsupportedTemp = $false)
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
            $action = if ($MissingGo) {
                @'
    & (Get-Module LocalCiGate) {
        function script:Get-Command {
            [CmdletBinding()]
            param([string] $Name, [System.Management.Automation.CommandTypes] $CommandType)
            if ($Name -eq 'go') { return }
            Microsoft.PowerShell.Core\Get-Command @PSBoundParameters
        }
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
            @"
`$ErrorActionPreference = 'Stop'
Remove-Item Env:INVOKE_LOCAL_CI_ACTIVE -ErrorAction SilentlyContinue
$breakpoint
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
