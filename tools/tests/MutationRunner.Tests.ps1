BeforeAll {
    $runner = Join-Path $PSScriptRoot '../Invoke-MutationTests.ps1'
    $sample = Join-Path $TestDrive 'sample'
    $null = New-Item -ItemType Directory -Path (Join-Path $sample 'tools/tests') -Force
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot '../requirements.psd1') -Destination (Join-Path $sample 'tools/requirements.psd1')
    @'
# security-check: sample-a
function Test-SampleA {
    param([string] $Value)
    if ($Value -cne 'yes') { return $false }
    return $true
}
# security-check: sample-b
function Test-SampleB {
    param([string] $Value)
    if ($Value -cne 'yes') { return $false }
    return $true
}
Export-ModuleMember -Function Test-SampleA, Test-SampleB
'@ | Set-Content -LiteralPath (Join-Path $sample 'tools/Sample.psm1')
    @'
BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../Sample.psm1') -Force
}
Describe 'Sample controls' {
    It 'accepts the exact allowed value and rejects other values' {
        Test-SampleA 'yes' | Should -BeTrue
        Test-SampleB 'yes' | Should -BeTrue
        foreach ($value in 'no', 'YES', '') {
            Test-SampleA $value | Should -BeFalse
            Test-SampleB $value | Should -BeFalse
        }
    }
}
'@ | Set-Content -LiteralPath (Join-Path $sample 'tools/tests/Sample.Tests.ps1')
    $configuration = Join-Path $sample 'checks.psd1'
    @'
@{
    Checks = @(
        @{ Name = 'sample-a'; Tests = @(@{ Path = 'tools/tests/Sample.Tests.ps1'; FullName = @('*') }) }
        @{ Name = 'sample-b'; Tests = @(@{ Path = 'tools/tests/Sample.Tests.ps1'; FullName = @('*') }) }
    )
    Exceptions = @()
}
'@ | Set-Content -LiteralPath $configuration
}

Describe 'Mutation runner public interface' {
    BeforeAll {
        $shardPaths = @(0..1 | ForEach-Object { Join-Path $TestDrive "shard-$_.json" })
        $reports = @(foreach ($index in 0..1) {
            $path = $shardPaths[$index]
            & $runner -RepoPath $sample -ConfigurationPath $configuration -ThrottleLimit 1 -Shard "$index/2" -ReportPath $path 6>$null
            Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        })
    }

    It 'partitions all checks deterministically without losing or duplicating mutants' {
        @($reports[0].summary.Check) | Should -BeExactly @('sample-a')
        @($reports[1].summary.Check) | Should -BeExactly @('sample-b')
        $ids = @($reports.mutants.Id)
        @($ids | Select-Object -Unique).Count | Should -Be $ids.Count
        $reports.mutants.Status | Select-Object -Unique | Should -BeExactly 'Killed'
        $markers = @(Get-SecurityCheckMarker -RepoPath $sample)
        $expected = @(Get-SecurityCheckMutant -RepoPath $sample -Marker $markers)
        @($ids | Sort-Object) | Should -BeExactly @($expected.Id | Sort-Object)
    }

    It 'merges every shard into the same complete mutation inventory' {
        $path = Join-Path $TestDrive 'merged.json'
        & $runner -RepoPath $sample -ConfigurationPath $configuration -MergeReport $shardPaths -ShardCount 2 -ReportPath $path 6>$null
        $merged = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        @($merged.mutants.Id | Sort-Object) | Should -BeExactly @($reports.mutants.Id | Sort-Object)
        $merged.mutants.Status | Select-Object -Unique | Should -BeExactly 'Killed'
    }

    It 'rejects incomplete or untrustworthy shard reports: <Case>' -ForEach @(
        @{ Case = 'missing shard'; Message = '*Expected 2 mutation shard reports*' }
        @{ Case = 'duplicate shard'; Message = '*Invalid or duplicate mutation shard*' }
        @{ Case = 'missing mutant'; Message = '*Incomplete mutation reports*' }
        @{ Case = 'duplicate mutant'; Message = '*Duplicate mutant*' }
        @{ Case = 'unknown status'; Message = '*unknown status*' }
        @{ Case = 'changed inventory'; Message = '*inventory differs*' }
        @{ Case = 'failed shard'; Message = '*contains problems*' }
        @{ Case = 'timeout'; Message = '*Mutation testing failed*' }
        @{ Case = 'unapproved exception'; Message = '*Mutation testing failed*' }
    ) {
        $inputs = @($shardPaths | ForEach-Object { Get-Content -LiteralPath $_ -Raw | ConvertFrom-Json -AsHashtable })
        switch ($Case) {
            'missing shard' { $inputs = @($inputs[0]) }
            'duplicate shard' { $inputs[1]['shard'] = '0/2' }
            'missing mutant' { $inputs[0]['mutants'] = @($inputs[0]['mutants'] | Select-Object -Skip 1) }
            'duplicate mutant' { $inputs[0]['mutants'] += @($inputs[0]['mutants'][0]) }
            'unknown status' { $inputs[0]['mutants'][0]['Status'] = 'Unknown' }
            'changed inventory' { $inputs[0]['inventoryHash'] = 'different' }
            'failed shard' { $inputs[0]['problems'] = @('worker failed') }
            'timeout' { $inputs[0]['mutants'][0]['Status'] = 'Error'; $inputs[0]['mutants'][0]['Detail'] = 'The worker did not finish the job before the timeout.' }
            'unapproved exception' { $inputs[0]['mutants'][0]['Status'] = 'Excepted' }
        }
        $paths = @(for ($index = 0; $index -lt $inputs.Count; $index++) {
            $path = Join-Path $TestDrive "input-$index.json"
            ConvertTo-Json -InputObject $inputs[$index] -Depth 8 | Set-Content -LiteralPath $path
            $path
        })
        $output = Join-Path $TestDrive 'invalid-merge.json'
        'stale success' | Set-Content -LiteralPath $output
        { & $runner -RepoPath $sample -ConfigurationPath $configuration -MergeReport $paths -ShardCount 2 -ReportPath $output 6>$null } |
            Should -Throw $Message
        if (Test-Path -LiteralPath $output) {
            $failed = Get-Content -LiteralPath $output -Raw | ConvertFrom-Json
            $failed.problems.Count | Should -BeGreaterThan 0
        }
    }

    It 'shares identical green baselines and reports the separate phase costs' {
        $path = Join-Path $TestDrive 'unsharded.json'
        & $runner -RepoPath $sample -ConfigurationPath $configuration -ThrottleLimit 2 -ReportPath $path 6>$null
        $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $report.phases.baseline.jobs | Should -Be 1
        $report.phases.baseline.completed | Should -Be 1
        $report.phases.baseline.queued | Should -Be 0
        $report.phases.mutant.jobs | Should -Be $report.mutants.Count
        $report.phases.mutant.unfinished | Should -Be 0
        $report.phases.preparation.seconds | Should -BeGreaterOrEqual 0
        $report.phases.baseline.seconds | Should -BeGreaterThan 0
        $report.phases.mutant.seconds | Should -BeGreaterThan 0
        $report.phases.cleanup.seconds | Should -BeGreaterOrEqual 0
    }

    It 'gives mutants a fresh budget and never counts unfinished work as killed' {
        $path = Join-Path $TestDrive 'timed-out.json'
        { & $runner -RepoPath $sample -ConfigurationPath $configuration -ThrottleLimit 1 -BaselineTimeoutSeconds 60 -TimeoutSeconds 1 -ReportPath $path 6>$null } |
            Should -Throw '*Mutation testing failed*'
        $report = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json
        $report.phases.baseline.completed | Should -Be 1
        $report.phases.baseline.unfinished | Should -Be 0
        $report.phases.baseline.budgetSeconds | Should -Be 60
        $report.phases.mutant.budgetSeconds | Should -Be 1
        $report.phases.mutant.unfinished | Should -BeGreaterThan 0
        @($report.mutants | Where-Object Status -eq 'Error').Count | Should -Be $report.phases.mutant.unfinished
        @($report.mutants | Where-Object Status -eq 'Killed').Count | Should -Be $report.phases.mutant.completed
    }

    It 'rejects invalid shard selection <Shard>' -ForEach @(
        @{ Shard = '2/2'; Message = '*index must be smaller*' }
        @{ Shard = '0/3'; Message = '*nonempty shards*' }
    ) {
        { & $runner -RepoPath $sample -ConfigurationPath $configuration -Shard $Shard -ReportPath (Join-Path $TestDrive 'invalid-shard.json') 6>$null } |
            Should -Throw $Message
    }
}
