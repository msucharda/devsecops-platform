BeforeAll {
    $benchmark = Join-Path $PSScriptRoot '../Measure-LocalCi.ps1'
}

Describe 'Local CI benchmark CLI' {
    BeforeEach {
        $fixture = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
        $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'tools') -Force
        git -C $fixture init --quiet
        git -C $fixture config user.email 'tests@example.invalid'
        git -C $fixture config user.name 'Local CI benchmark tests'
        Set-Content (Join-Path $fixture '.gitignore') 'artifacts/'
        Set-Content (Join-Path $fixture 'README.md') '# Fixture'
        Set-Content (Join-Path $fixture 'tools/Select-InstanceModules.ps1') '# Fixture'
        Set-Content (Join-Path $fixture 'tools/Invoke-Tests.ps1') '# Fixture'
        # The child process is the system boundary: no real CI steps run in this isolated repository.
        Set-Content (Join-Path $fixture 'tools/Invoke-LocalCi.ps1') @'
param([string] $Base, [string] $LogPath)
Set-Content -LiteralPath $LogPath "Measured fixture gate; base $Base"
Start-Sleep -Milliseconds 25
exit 0
'@
        git -C $fixture add .
        git -C $fixture -c commit.gpgsign=false commit --quiet -m initial
        git -C $fixture branch baseline
        $head = (git -C $fixture rev-parse HEAD).Trim()
        $report = Join-Path $fixture 'artifacts/benchmark.json'
    }

    It 'repeats all three scenarios <Runs> times without changing the source checkout' -ForEach @(
        @{ Runs = 3 }, @{ Runs = 2 }
    ) {
        # A dirty caller checkout must also remain untouched; only the pinned commit is benchmarked.
        Set-Content (Join-Path $fixture 'README.md') 'uncommitted source draft'
        $status = @(git -C $fixture status --porcelain)
        $output = & ([Environment]::ProcessPath) -NoProfile -File $benchmark -RepositoryRoot $fixture -Revision baseline -Repeat $Runs -OutputPath $report 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output

        $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        $result.Schema | Should -Be 1
        $result.Revision | Should -BeExactly $head
        $result.Status | Should -BeExactly 'passed'
        @($result.Scenarios.Name) | Should -BeExactly @('Documentation', 'Small change', 'Fan-out')
        foreach ($scenario in $result.Scenarios) {
            @($scenario.Samples).Count | Should -Be $Runs
            @($scenario.Samples | Where-Object ExitCode -NE 0).Count | Should -Be 0
            $scenario.MedianSeconds | Should -BeGreaterThan 0
            $ordered = @($scenario.Samples.Seconds | Sort-Object)
            $expected = if ($Runs -eq 3) { $ordered[1] } else { ($ordered[0] + $ordered[1]) / 2 }
            $scenario.MedianSeconds | Should -Be $expected
        }
        @(git -C $fixture status --porcelain) | Should -BeExactly $status
        (git -C $fixture rev-parse HEAD).Trim() | Should -BeExactly $head
        Get-Content -LiteralPath (Join-Path $fixture 'README.md') | Should -BeExactly 'uncommitted source draft'
        @(git -C $fixture worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count | Should -Be 1
    }

    It 'keeps failed samples as failures and removes its detached worktree' {
        Set-Content (Join-Path $fixture 'tools/Invoke-LocalCi.ps1') 'exit 1'
        git -C $fixture add .
        git -C $fixture -c commit.gpgsign=false commit --quiet -m 'Fail the fixture gate'
        git -C $fixture branch --force baseline HEAD

        $output = & ([Environment]::ProcessPath) -NoProfile -File $benchmark -RepositoryRoot $fixture -Revision baseline -Repeat 3 -OutputPath $report 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0 -Because $output
        $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        $result.Status | Should -BeExactly 'failed'
        $result.Scenarios[0].Samples[0].ExitCode | Should -Be 1
        $result.Scenarios[0].MedianSeconds | Should -BeNullOrEmpty
        @(git -C $fixture status --porcelain).Count | Should -Be 0
        @(git -C $fixture worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count | Should -Be 1
    }

    It 'measures only the documentation scenario when explicitly selected' {
        $output = & ([Environment]::ProcessPath) -NoProfile -File $benchmark -RepositoryRoot $fixture `
            -Revision baseline -Scenario Documentation -Repeat 1 -OutputPath $report 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $output

        $result = Get-Content -LiteralPath $report -Raw | ConvertFrom-Json
        $result.Status | Should -BeExactly 'passed'
        @($result.Scenarios.Name) | Should -BeExactly @('Documentation')
        @($result.Scenarios[0].Samples).Count | Should -Be 1
        @(git -C $fixture status --porcelain).Count | Should -Be 0
        @(git -C $fixture worktree list --porcelain | Where-Object { $_ -like 'worktree *' }).Count | Should -Be 1
    }

    It 'refuses a report path that would overwrite a tracked source file' -Tag BenchmarkReportSafety {
        $readme = Join-Path $fixture 'README.md'
        $output = & ([Environment]::ProcessPath) -NoProfile -File $benchmark -RepositoryRoot $fixture -Revision baseline -Repeat 1 -OutputPath $readme 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0 -Because $output
        $output | Should -Match 'tracked'
        Get-Content -LiteralPath $readme | Should -BeExactly '# Fixture'
        @(git -C $fixture status --porcelain).Count | Should -Be 0
    }

    It 'refuses a report path outside artifacts without changing Git metadata' -Tag BenchmarkReportSafety {
        $metadata = Join-Path $fixture '.git/HEAD'
        $before = Get-Content -LiteralPath $metadata -Raw
        $output = & ([Environment]::ProcessPath) -NoProfile -File $benchmark -RepositoryRoot $fixture -Revision baseline -Repeat 1 -OutputPath $metadata 2>&1 | Out-String
        $LASTEXITCODE | Should -Not -Be 0 -Because $output
        Get-Content -LiteralPath $metadata -Raw | Should -BeExactly $before
    }
}
