BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'GitHubHost.psm1') -Force
}

Describe 'Deadline-bounded GitHub CLI credentials' {
    It 'cancels a slow credential tree when <Case> and returns pending within the waiter deadline' -ForEach @(
        @{ Case = 'the parent remains alive'; ParentExits = 'false' }
        @{ Case = 'the parent exits before its child'; ParentExits = 'true' }
    ) {
        $worker = Join-Path $TestDrive 'gh-deadline.ps1'
        $pidFile = Join-Path $TestDrive 'credential.pid'
        @'
param([Parameter(ValueFromRemainingArguments)][string[]] $Remaining)
$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
$start.UseShellExecute = $false
$start.CreateNoWindow = $true
foreach ($argument in @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 30')) { $start.ArgumentList.Add($argument) }
$child = [Diagnostics.Process]::Start($start)
[IO.File]::WriteAllLines($env:GH_TEST_PID_FILE, [string[]] @($PID, $child.Id))
if ($env:GH_TEST_PARENT_EXITS -eq 'true') { exit 0 }
Start-Sleep -Seconds 30
'@ | Set-Content -LiteralPath $worker
        $savedPidFile = $env:GH_TEST_PID_FILE
        $savedParentExits = $env:GH_TEST_PARENT_EXITS
        $env:GH_TEST_PID_FILE = $pidFile
        $env:GH_TEST_PARENT_EXITS = $ParentExits
        $names = @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')
        $saved = @{}
        foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, "original-$name") }
        Mock Get-Command -ModuleName GitHubHost {
            [pscustomobject]@{ Source = $worker; CommandType = 'ExternalScript' }
        } -ParameterFilter { $Name -eq 'gh' }
        Mock gh -ModuleName GitHubHost {
            [Threading.Thread]::Sleep(6500)
            $global:LASTEXITCODE = 0
            'slow-credential'
        }
        $watch = [Diagnostics.Stopwatch]::StartNew()
        try {
            $waiter = Join-Path (Split-Path $PSScriptRoot -Parent) 'Wait-PullRequestChecks.ps1'

            $output = & $waiter -Pr 1 -Repository example.ghe.com/demo/source -GitHubUser pilot-owner -MaxSeconds 15

            $cleanupGraceSeconds = 3
            $watch.Elapsed.TotalSeconds | Should -BeLessThan (15 + $cleanupGraceSeconds)
            $output | Should -BeExactly 'pending; copilot: unknown (credential deadline reached)'
            $LASTEXITCODE | Should -Be 2
            $childIds = @(Get-Content -LiteralPath $pidFile)
            do {
                $remaining = @($childIds | ForEach-Object { Get-Process -Id ([int] $_) -ErrorAction SilentlyContinue })
                if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 25 }
            } while ($remaining.Count -gt 0 -and $watch.Elapsed.TotalSeconds -lt (15 + $cleanupGraceSeconds))
            $remaining | Should -BeNullOrEmpty
            $watch.Elapsed.TotalSeconds | Should -BeLessThan (15 + $cleanupGraceSeconds)
            foreach ($name in $names) { [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "original-$name" }
        }
        finally {
            if (Test-Path -LiteralPath $pidFile) {
                foreach ($childId in (Get-Content -LiteralPath $pidFile)) {
                    $child = Get-Process -Id ([int] $childId) -ErrorAction SilentlyContinue
                    if ($null -ne $child) { $child.Kill($true); $child.WaitForExit() }
                }
            }
            $env:GH_TEST_PID_FILE = $savedPidFile
            $env:GH_TEST_PARENT_EXITS = $savedParentExits
            foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
        }
    }

    It 'stops the credential tree when the adapter process is killed without running its finally' {
        $pidFile = Join-Path $TestDrive 'abandoned-credential-pids.txt'
        $native = Join-Path $PSHOME 'pwsh'
        $command = Join-Path $TestDrive 'abandoned-gh.ps1'
        @'
$child = [Diagnostics.Process]::Start((Join-Path $PSHOME 'pwsh'), '-NoProfile -Command "Start-Sleep -Seconds 30"')
@($PID, $child.Id) | Set-Content -LiteralPath $env:GH_TEST_PID_FILE
Start-Sleep -Seconds 30
'@ | Set-Content -LiteralPath $command
        $adapter = Join-Path $TestDrive 'abandoned-adapter.ps1'
        @'
param($Module, $Command)
Import-Module $Module
Set-Alias gh $Command
Invoke-GitHubHostGh -Hostname example.ghe.com -User pilot-owner -Arguments @('auth', 'token') -Deadline ([datetime]::UtcNow.AddSeconds(120))
'@ | Set-Content -LiteralPath $adapter
        $savedPidFile = $env:GH_TEST_PID_FILE
        $env:GH_TEST_PID_FILE = $pidFile
        $parent = [Diagnostics.Process]::new()
        try {
            $parent.StartInfo.FileName = $native
            $parent.StartInfo.UseShellExecute = $false
            $parent.StartInfo.CreateNoWindow = $true
            foreach ($argument in @('-NoLogo', '-NoProfile', '-File', $adapter, '-Module', (Join-Path (Split-Path $PSScriptRoot -Parent) 'GitHubHost.psm1'), '-Command', $command)) {
                $parent.StartInfo.ArgumentList.Add($argument)
            }
            $parent.Start() | Should -BeTrue
            $ready = [Diagnostics.Stopwatch]::StartNew()
            while (-not (Test-Path -LiteralPath $pidFile) -and $ready.Elapsed.TotalSeconds -lt 60) { Start-Sleep -Milliseconds 25 }
            Test-Path -LiteralPath $pidFile | Should -BeTrue
            $children = @(Get-Content -LiteralPath $pidFile)
            $children.Count | Should -Be 2
            $parent.Kill()
            $parent.WaitForExit()
            $cleanup = [Diagnostics.Stopwatch]::StartNew()
            do {
                $remaining = @($children | ForEach-Object { Get-Process -Id ([int] $_) -ErrorAction SilentlyContinue })
                if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 25 }
            } while ($remaining.Count -gt 0 -and $cleanup.Elapsed.TotalSeconds -lt 3)
            $remaining | Should -BeNullOrEmpty
        }
        finally {
            if (-not $parent.HasExited) { $parent.Kill($true); $parent.WaitForExit() }
            if (Test-Path -LiteralPath $pidFile) {
                foreach ($id in (Get-Content -LiteralPath $pidFile)) {
                    $child = Get-Process -Id ([int] $id) -ErrorAction SilentlyContinue
                    if ($null -ne $child) { $child.Kill($true); $child.WaitForExit() }
                }
            }
            $parent.Dispose()
            $env:GH_TEST_PID_FILE = $savedPidFile
        }
    }

    It 'keeps native stdout separate from stderr and uses the named credential before the deadline' {
        $worker = Join-Path $TestDrive 'gh-output.ps1'
        @'
param([Parameter(ValueFromRemainingArguments)][string[]] $Remaining)
if ($Remaining -contains '--user') {
    foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
        if ([Environment]::GetEnvironmentVariable($name)) { [Console]::Error.WriteLine('inherited override'); exit 1 }
    }
    [Console]::Error.WriteLine('Credential expires soon')
    'named-account-token'
}
elseif ($env:GH_TOKEN -eq 'named-account-token') { 'selected-account-result' }
else { [Console]::Error.WriteLine('wrong identity'); exit 1 }
'@ | Set-Content -LiteralPath $worker
        Mock Get-Command -ModuleName GitHubHost {
            [pscustomobject]@{ Source = $worker; CommandType = 'ExternalScript' }
        } -ParameterFilter { $Name -eq 'gh' }

        $output = Invoke-GitHubHostGh -Hostname example.ghe.com -User pilot-owner -Arguments @('auth', 'token', '--hostname', 'example.ghe.com') -Deadline ([datetime]::UtcNow.AddSeconds(60))

        $output.Trim() | Should -BeExactly 'selected-account-result'
    }

    It 'does not launch gh after the absolute deadline' {
        Mock Get-Command -ModuleName GitHubHost { throw 'must not resolve or launch gh' } -ParameterFilter { $Name -eq 'gh' }

        { Invoke-GitHubHostGh -Hostname example.ghe.com -User pilot-owner -Arguments @('auth', 'token') -Deadline ([datetime]::UtcNow.AddSeconds(-1)) } |
            Should -Throw '*deadline reached*'

        Should -Invoke -ModuleName GitHubHost Get-Command -Times 0
    }

    It 'reports native stderr and the exact nonzero exit code instead of success' {
        $worker = Join-Path $TestDrive 'gh-failure.ps1'
        "[Console]::Error.WriteLine('native-request-rejected'); exit 23" | Set-Content -LiteralPath $worker
        Mock Get-Command -ModuleName GitHubHost {
            [pscustomobject]@{ Source = $worker; CommandType = 'ExternalScript' }
        } -ParameterFilter { $Name -eq 'gh' }

        { Invoke-GitHubHostGh -Hostname example.ghe.com -Arguments @('api', 'user') -Deadline ([datetime]::UtcNow.AddSeconds(30)) } |
            Should -Throw '*failed with exit code 23: native-request-rejected*'
    }

    It 'cleans descendants with independent output streams before the command worker exits' -Tag ProcessLifetime {
        $pidFile = Join-Path $TestDrive 'completed-command-child.pid'
        $command = Join-Path $TestDrive 'completed-gh.ps1'
        @'
if ($IsWindows) {
    Add-Type 'using System; using System.Runtime.InteropServices; public static class CompletionHandles { [DllImport("kernel32.dll", SetLastError=true)] public static extern IntPtr GetStdHandle(int which); [DllImport("kernel32.dll", SetLastError=true)] public static extern bool SetHandleInformation(IntPtr handle, uint mask, uint flags); }'
    foreach ($stream in @(-11, -12)) {
        if (-not [CompletionHandles]::SetHandleInformation([CompletionHandles]::GetStdHandle($stream), 1, 0)) {
            throw [ComponentModel.Win32Exception]::new()
        }
    }
}
$start = [Diagnostics.ProcessStartInfo]::new((Join-Path $PSHOME 'pwsh'))
$start.UseShellExecute = $false
$start.RedirectStandardOutput = $true
$start.RedirectStandardError = $true
foreach ($arg in @('-NoLogo', '-NoProfile', '-Command', 'Start-Sleep -Seconds 30')) { $start.ArgumentList.Add($arg) }
$child = [Diagnostics.Process]::Start($start)
[IO.File]::WriteAllText($env:GH_TEST_PID_FILE, [string] $child.Id)
'completed-command'
'@ | Set-Content -LiteralPath $command
        $savedPidFile = $env:GH_TEST_PID_FILE
        $env:GH_TEST_PID_FILE = $pidFile
        $worker = [Diagnostics.Process]::new()
        try {
            $native = (Get-Command (Join-Path $PSHOME 'pwsh') -CommandType Application).Source
            $argumentsJson = ConvertTo-Json -InputObject @('-NoLogo', '-NoProfile', '-File', $command) -Compress
            $worker.StartInfo.FileName = $native
            $worker.StartInfo.UseShellExecute = $false
            $worker.StartInfo.RedirectStandardOutput = $true
            $worker.StartInfo.RedirectStandardError = $true
            foreach ($arg in @('-NoLogo', '-NoProfile', '-File', (Join-Path $PSScriptRoot '..\GitHubHost.Worker.ps1'),
                    '-FilePath', $native, '-ArgumentsJson', $argumentsJson,
                    '-DeadlineUtcTicks', ([datetime]::UtcNow.AddSeconds(30).Ticks), '-ParentProcessId', $PID)) {
                $worker.StartInfo.ArgumentList.Add($arg)
            }
            $worker.Start() | Should -BeTrue
            $stdout = $worker.StandardOutput.ReadToEndAsync()
            $stderr = $worker.StandardError.ReadToEndAsync()
            $worker.WaitForExit(60000) | Should -BeTrue
            $errorOutput = $stderr.GetAwaiter().GetResult()
            $worker.ExitCode | Should -Be 0 -Because $errorOutput
            $stdout.GetAwaiter().GetResult().Trim() | Should -BeExactly 'completed-command'
            $childId = [int] (Get-Content -LiteralPath $pidFile)
            $cleanup = [Diagnostics.Stopwatch]::StartNew()
            do {
                $remaining = @(Get-Process -Id $childId -ErrorAction SilentlyContinue)
                if ($remaining.Count -gt 0) { Start-Sleep -Milliseconds 25 }
            } while ($remaining.Count -gt 0 -and $cleanup.Elapsed.TotalSeconds -lt 3)
            $remaining | Should -BeNullOrEmpty
        }
        finally {
            if (-not $worker.HasExited) { $worker.Kill($true); $worker.WaitForExit() }
            if (Test-Path -LiteralPath $pidFile) {
                $child = Get-Process -Id ([int] (Get-Content -LiteralPath $pidFile)) -ErrorAction SilentlyContinue
                if ($null -ne $child) { $child.Kill($true); $child.WaitForExit(); $child.Dispose() }
            }
            $worker.Dispose()
            $env:GH_TEST_PID_FILE = $savedPidFile
        }
    }

    It 'rejects a shell function instead of bypassing it for a different configured gh' {
        Mock Get-Command -ModuleName GitHubHost {
            [pscustomobject]@{ CommandType = 'Function' }
        } -ParameterFilter { $Name -eq 'gh' }

        { Invoke-GitHubHostGh -Hostname example.ghe.com -User pilot-owner -Arguments @('auth', 'token') -Deadline ([datetime]::UtcNow.AddSeconds(15)) } |
            Should -Throw '*requires an executable or PowerShell script*'
    }

    It 'runs a native executable alias with the same bounded process adapter' {
        $native = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
        Mock Get-Command -ModuleName GitHubHost {
            [pscustomobject]@{ CommandType = 'Alias'; ResolvedCommand = [pscustomobject]@{ CommandType = 'Application'; Source = $native } }
        } -ParameterFilter { $Name -eq 'gh' }

        $output = Invoke-GitHubHostGh -Hostname example.ghe.com -Arguments @('-NoLogo', '-NoProfile', '-Command', "'native-result'") -Deadline ([datetime]::UtcNow.AddSeconds(15))

        $output.Trim() | Should -BeExactly 'native-result'
    }

    It 'preserves quoted, multiline, trailing-slash and timestamp native arguments' {
        $echo = Join-Path $TestDrive 'echo-arguments.ps1'
        @'
param([Parameter(ValueFromRemainingArguments)][AllowEmptyString()][string[]] $Remaining)
ConvertTo-Json -InputObject @($Remaining) -Compress
'@ | Set-Content -LiteralPath $echo
        $native = (Get-Command (Join-Path $PSHOME 'pwsh') -CommandType Application).Source
        Mock Get-Command -ModuleName GitHubHost {
            [pscustomobject]@{ CommandType = 'Application'; Source = $native }
        } -ParameterFilter { $Name -eq 'gh' }
        $expected = @('space value', 'quote"value', 'trailing\', '2026-03-10T11:12:13Z', "line`nbreak")

        $output = Invoke-GitHubHostGh -Hostname example.ghe.com -Arguments (@('-NoLogo', '-NoProfile', '-File', $echo) + $expected) -Deadline ([datetime]::UtcNow.AddSeconds(15))

        $document = [System.Text.Json.JsonDocument]::Parse($output)
        try {
            $actual = @($document.RootElement.EnumerateArray() | ForEach-Object { $_.GetString() })
            $actual.Count | Should -Be $expected.Count
            for ($index = 0; $index -lt $expected.Count; $index++) { $actual[$index] | Should -BeExactly $expected[$index] }
        }
        finally { $document.Dispose() }
    }
}

Describe 'GitHub cloud repository targets' {
    It 'resolves <Repository> to its exact API origin' -ForEach @(
        @{ Repository = 'demo/source'; ApiUrl = ''; Hostname = 'github.com'; ExpectedApi = 'https://api.github.com' }
        @{ Repository = 'example.ghe.com/demo/source'; ApiUrl = ''; Hostname = 'example.ghe.com'; ExpectedApi = 'https://api.example.ghe.com' }
        @{ Repository = 'EXAMPLE.GHE.COM/demo/source'; ApiUrl = ''; Hostname = 'example.ghe.com'; ExpectedApi = 'https://api.example.ghe.com' }
        @{ Repository = 'demo/source'; ApiUrl = 'https://api.example.ghe.com/'; Hostname = 'example.ghe.com'; ExpectedApi = 'https://api.example.ghe.com' }
        @{ Repository = 'example.ghe.com/demo/source'; ApiUrl = 'https://api.example.ghe.com'; Hostname = 'example.ghe.com'; ExpectedApi = 'https://api.example.ghe.com' }
    ) {
        $target = Resolve-GitHubCloudTarget -Repository $Repository -ApiUrl $ApiUrl
        $target.Host | Should -BeExactly $Hostname
        $target.Slug | Should -BeExactly 'demo/source'
        $target.ApiUrl | Should -BeExactly $ExpectedApi
    }

    It 'rejects an API override with <Case> before retrieving credentials' -ForEach @(
        @{ Case = 'HTTP'; ApiUrl = 'http://api.example.ghe.com' }
        @{ Case = 'userinfo'; ApiUrl = 'https://user@api.example.ghe.com' }
        @{ Case = 'a port'; ApiUrl = 'https://api.example.ghe.com:444' }
        @{ Case = 'a path'; ApiUrl = 'https://api.example.ghe.com/other' }
        @{ Case = 'a query'; ApiUrl = 'https://api.example.ghe.com?x=1' }
        @{ Case = 'a fragment'; ApiUrl = 'https://api.example.ghe.com#x' }
        @{ Case = 'a foreign host'; ApiUrl = 'https://api.example.net' }
        @{ Case = 'a suffix lookalike'; ApiUrl = 'https://api.example.ghe.com.attacker.test' }
        @{ Case = 'an empty enterprise label'; ApiUrl = 'https://api..ghe.com' }
    ) {
        { Resolve-GitHubCloudTarget -Repository demo/source -ApiUrl $ApiUrl } |
            Should -Throw '*HTTPS API origin*'
    }

    It 'rejects an explicit repository on a different API host' {
        { Resolve-GitHubCloudTarget -Repository github.com/demo/source -ApiUrl https://api.example.ghe.com } |
            Should -Throw '*different GitHub hosts*'
    }

    It 'rejects a non-cloud repository host' {
        { Resolve-GitHubCloudTarget -Repository github.example.net/demo/source } |
            Should -Throw '*only github.com and GHE.com*'
    }

    It 'rejects an invalid repository: <Repository>' -ForEach @(
        @{ Repository = '' }
        @{ Repository = 'source' }
        @{ Repository = 'demo/source extra' }
        @{ Repository = 'demo/.' }
        @{ Repository = 'demo/..' }
        @{ Repository = 'example.ghe.com/demo/source/extra' }
    ) {
        { ConvertTo-GitHubRepositoryTarget -Repository $Repository } | Should -Throw "*must be 'owner/repo'*"
    }
}

Describe 'GitHub worker process lifetime' {
    BeforeAll {
        Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'GitHubProcessLifetime.psm1')
    }

    BeforeEach {
        Mock Invoke-GitHubWindowsWorkerLifetime {} -ModuleName GitHubProcessLifetime
        Mock Invoke-GitHubUnixProcessGroupCreate { $true } -ModuleName GitHubProcessLifetime
        Mock Invoke-GitHubUnixProcessGroupKill {} -ModuleName GitHubProcessLifetime
    }

    It 'initializes the Windows lifetime adapter before starting a command' {
        Mock Invoke-GitHubWindowsWorkerLifetime {} -ModuleName GitHubProcessLifetime

        Initialize-GitHubHostWorkerLifetime -Windows $true

        Should -Invoke -ModuleName GitHubProcessLifetime Invoke-GitHubWindowsWorkerLifetime -Times 1 -Exactly
    }

    It 'does not swallow a failed Windows lifetime initialization' {
        Mock Invoke-GitHubWindowsWorkerLifetime { throw 'lifetime initialization failed' } -ModuleName GitHubProcessLifetime

        { Initialize-GitHubHostWorkerLifetime -Windows $true } | Should -Throw '*lifetime initialization failed*'
    }

    It 'creates an owned Unix process group before starting a command' {
        Mock Invoke-GitHubUnixProcessGroupCreate { $true } -ModuleName GitHubProcessLifetime

        Initialize-GitHubHostWorkerLifetime -Windows $false

        Should -Invoke -ModuleName GitHubProcessLifetime Invoke-GitHubUnixProcessGroupCreate -Times 1 -Exactly
    }

    It 'refuses a command when its Unix process group cannot be created' {
        Mock Invoke-GitHubUnixProcessGroupCreate { $false } -ModuleName GitHubProcessLifetime

        { Initialize-GitHubHostWorkerLifetime -Windows $false } | Should -Throw '*Cannot create*worker process group*'
    }

    It 'signals the exact owned Unix process group' {
        Mock Invoke-GitHubUnixProcessGroupKill { $ProcessId | Should -Be 12345 } -ModuleName GitHubProcessLifetime

        Stop-GitHubHostProcessGroup -ProcessId 12345 -Windows $false

        Should -Invoke -ModuleName GitHubProcessLifetime Invoke-GitHubUnixProcessGroupKill -Times 1 -Exactly
    }

    It 'rejects a nonpositive group ID before signaling processes: <Id>' -ForEach @(
        @{ Id = 0 }
        @{ Id = -1 }
    ) {
        Mock Invoke-GitHubUnixProcessGroupKill { throw 'must not signal processes' } -ModuleName GitHubProcessLifetime

        { Stop-GitHubHostProcessGroup -ProcessId $Id -Windows $false } | Should -Throw '*Cannot validate argument*'

        Should -Invoke -ModuleName GitHubProcessLifetime Invoke-GitHubUnixProcessGroupKill -Times 0
    }
}

Describe 'Host-scoped GitHub CLI credentials' {
    It 'uses the stored GHE login without either cloud token override and restores the caller environment' {
        InModuleScope GitHubHost {
            $savedGh = $env:GH_TOKEN
            $savedGitHub = $env:GITHUB_TOKEN
            try {
                $env:GH_TOKEN = 'public-gh-token'
                $env:GITHUB_TOKEN = 'public-actions-token'
                Mock gh {
                    $env:GH_TOKEN | Should -BeNullOrEmpty
                    $env:GITHUB_TOKEN | Should -BeNullOrEmpty
                    $args | Should -Contain 'example.ghe.com'
                    $global:LASTEXITCODE = 0
                    'host-scoped-result'
                }

                Invoke-GitHubHostGh -Hostname example.ghe.com -Arguments @('auth', 'token', '--hostname', 'example.ghe.com') |
                    Should -BeExactly 'host-scoped-result'

                $env:GH_TOKEN | Should -BeExactly 'public-gh-token'
                $env:GITHUB_TOKEN | Should -BeExactly 'public-actions-token'
            }
            finally {
                $env:GH_TOKEN = $savedGh
                $env:GITHUB_TOKEN = $savedGitHub
            }
        }
    }

    It 'selects a named stored account on <Hostname> with the <Variant> response without changing the globally active account' -ForEach @(
        @{ Hostname = 'github.com'; TokenVariable = 'GH_TOKEN'; Variant = 'private-user' }
        @{ Hostname = 'github.com'; TokenVariable = 'GH_TOKEN'; Variant = 'public-user' }
        @{ Hostname = 'example.ghe.com'; TokenVariable = 'GH_TOKEN'; Variant = 'private-user' }
        @{ Hostname = 'example.ghe.com'; TokenVariable = 'GH_TOKEN'; Variant = 'public-user' }
        @{ Hostname = 'github.example.net'; TokenVariable = 'GH_ENTERPRISE_TOKEN'; Variant = 'private-user' }
        @{ Hostname = 'github.example.net'; TokenVariable = 'GH_ENTERPRISE_TOKEN'; Variant = 'public-user' }
    ) {
        $response = Get-GitHubApiFixture -Name "users/get-authenticated-user.$Variant" -Set @{ login = 'pilot-owner' } |
            ConvertTo-Json -Depth 100 -Compress
        InModuleScope GitHubHost -Parameters @{ Hostname = $Hostname; TokenVariable = $TokenVariable; Response = $response } {
            $saved = $env:GH_TOKEN
            try {
                $env:GH_TOKEN = 'public-gh-token'
                Mock gh {
                    if ($args[0] -eq 'auth') {
                        $args | Should -Be @('auth', 'token', '--hostname', $Hostname, '--user', 'pilot-owner')
                        $env:GH_TOKEN | Should -BeNullOrEmpty
                        $global:LASTEXITCODE = 0
                        return 'named-account-token'
                    }
                    $args | Should -Be @('api', '--hostname', $Hostname, 'user')
                    [Environment]::GetEnvironmentVariable($TokenVariable) | Should -BeExactly 'named-account-token'
                    $global:LASTEXITCODE = 0
                    $Response
                }

                Invoke-GitHubHostGh -Hostname $Hostname -User pilot-owner -Arguments @('api', '--hostname', $Hostname, 'user') |
                    Should -BeExactly $Response

                $env:GH_TOKEN | Should -BeExactly 'public-gh-token'
            }
            finally { $env:GH_TOKEN = $saved }
        }
    }

    It 'preserves public-cloud environment credentials with the <Variant> response' -ForEach @(
        @{ Variant = 'private-user' }
        @{ Variant = 'public-user' }
    ) {
        $response = Get-GitHubApiFixture -Name "users/get-authenticated-user.$Variant" -Set @{ login = 'pilot-owner' } |
            ConvertTo-Json -Depth 100 -Compress
        InModuleScope GitHubHost -Parameters @{ Response = $response } {
            $saved = $env:GH_TOKEN
            try {
                $env:GH_TOKEN = 'public-gh-token'
                Mock gh {
                    $env:GH_TOKEN | Should -BeExactly 'public-gh-token'
                    $global:LASTEXITCODE = 0
                    $Response
                }
                Invoke-GitHubHostGh -Hostname github.com -Arguments @('api', '--hostname', 'github.com', 'user') |
                    Should -BeExactly $Response
            }
            finally { $env:GH_TOKEN = $saved }
        }
    }

    It 'uses only stdout with a stderr warning and the <Variant> response' -ForEach @(
        @{ Variant = 'private-user' }
        @{ Variant = 'public-user' }
    ) {
        $response = Get-GitHubApiFixture -Name "users/get-authenticated-user.$Variant" -Set @{ login = 'pilot-owner' } |
            ConvertTo-Json -Depth 100 -Compress
        InModuleScope GitHubHost -Parameters @{ Response = $response } {
            Mock gh {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'auth') {
                    [System.Management.Automation.ErrorRecord]::new([Exception]::new('Credential expires soon'), 'warning', 'NotSpecified', $null)
                    return 'named-account-token'
                }
                $env:GH_TOKEN | Should -BeExactly 'named-account-token'
                $Response
            }

            Invoke-GitHubHostGh -Hostname example.ghe.com -User pilot-owner -Arguments @('api', '--hostname', 'example.ghe.com', 'user') |
                Should -BeExactly $Response
        }
    }

    It 'restores all overrides after <Case> without running the requested API call' -ForEach @(
        @{ Case = 'a missing named account'; Code = 1; Value = 'authentication failed'; ExpectedError = '*No stored GitHub credential*' }
        @{ Case = 'an empty named credential'; Code = 0; Value = ' '; ExpectedError = '*credential*is empty*' }
    ) {
        InModuleScope GitHubHost -Parameters $_ {
            $names = @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')
            $saved = @{}
            foreach ($name in $names) { $saved[$name] = [Environment]::GetEnvironmentVariable($name); [Environment]::SetEnvironmentVariable($name, "original-$name") }
            try {
                Mock gh {
                    $args[0] | Should -BeExactly 'auth'
                    foreach ($name in $names) { [Environment]::GetEnvironmentVariable($name) | Should -BeNullOrEmpty }
                    $global:LASTEXITCODE = $Code
                    $Value
                }
                { Invoke-GitHubHostGh -Hostname example.ghe.com -User pilot-owner -Arguments @('api', '--hostname', 'example.ghe.com', 'user') } |
                    Should -Throw $ExpectedError
                foreach ($name in $names) { [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "original-$name" }
                Should -Invoke gh -Times 1 -Exactly
            }
            finally { foreach ($name in $names) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) } }
        }
    }

    It 'restores the environment when gh throws or exits unsuccessfully: <Case>' -ForEach @(
        @{ Case = 'exception'; Throws = $true }
        @{ Case = 'nonzero exit'; Throws = $false }
    ) {
        InModuleScope GitHubHost -Parameters $_ {
            $saved = $env:GH_TOKEN
            try {
                $env:GH_TOKEN = 'public-gh-token'
                Mock gh {
                    if ($Throws) { throw 'native launch failed' }
                    $global:LASTEXITCODE = 1
                    [System.Management.Automation.ErrorRecord]::new([Exception]::new('HTTP 403'), 'gh', 'NotSpecified', $null)
                }
                { Invoke-GitHubHostGh -Hostname example.ghe.com -Arguments @('api', '--hostname', 'example.ghe.com', 'user') } |
                    Should -Throw
                $env:GH_TOKEN | Should -BeExactly 'public-gh-token'
            }
            finally { $env:GH_TOKEN = $saved }
        }
    }
}
