BeforeAll {
    $toolRoot = Split-Path $PSScriptRoot -Parent
    $fixture = Join-Path $TestDrive 'runner'
    $null = New-Item -ItemType Directory -Path (Join-Path $fixture 'tools/tests/nested') -Force
    Copy-Item -LiteralPath (Join-Path $toolRoot 'Invoke-Tests.ps1'), (Join-Path $toolRoot 'requirements.psd1') -Destination (Join-Path $fixture 'tools')
    Set-Content -LiteralPath (Join-Path $fixture 'tools/pester-durations.psd1') -Value "@{ 'Case0.Tests.ps1' = 20; 'Case1.Tests.ps1' = 11; 'Case2.Tests.ps1' = 7; 'Case3.Tests.ps1' = 5 }"
    foreach ($index in 0..7) {
        $directory = if ($index -ge 4) { 'tools/tests/nested' } else { 'tools/tests' }
        Set-Content -LiteralPath (Join-Path $fixture "$directory/Case$index.Tests.ps1") -Value @"
Describe 'File $index' {
    It 'runs case $index' { 1 | Should -Be 1 }
    It 'excludes interruption $index' -Tag Interruption { throw 'Must not run' }
}
"@
    }

    function Invoke-FixtureTest {
        param([string[]] $ArgumentList = @())
        $output = @(& ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $fixture 'tools/Invoke-Tests.ps1') -CI @ArgumentList 2>&1)
        $code = $LASTEXITCODE
        $code | Should -Be 0 -Because ($output -join "`n")
        $resultFiles = @(Get-ChildItem -LiteralPath (Join-Path $fixture 'artifacts') -Filter 'pester*.xml')
        $resultFiles.Count | Should -Be 1
        $xml = [xml](Get-Content -LiteralPath $resultFiles[0].FullName -Raw)
        $names = @($xml.SelectNodes('//test-case[@executed="True"]') | ForEach-Object { $_.name })
        Remove-Item -LiteralPath $resultFiles[0].FullName
        return $names
    }
}

Describe 'Pester runner file sharding' {
    It 'runs every selected test exactly once across all shards, including nested and new files' {
        $baseline = @(Invoke-FixtureTest)
        $baseline.Count | Should -Be 8
        $costs = @(20, 11, 7, 5, 1, 1, 1, 1)
        $sharded = @(foreach ($index in 0..3) {
            $names = @(Invoke-FixtureTest -ArgumentList @('-Shard', "$index/4"))
            $names.Count | Should -BeGreaterThan 0
            $seconds = ($names | ForEach-Object {
                $_ | Should -Match 'case (\d+)$'
                $costs[[int] [regex]::Match($_, 'case (\d+)$').Groups[1].Value]
            } | Measure-Object -Sum).Sum
            $seconds | Should -BeLessOrEqual 20
            $names
        })
        $sharded.Count | Should -Be $baseline.Count
        @($sharded | Sort-Object -Unique).Count | Should -Be $baseline.Count
        ($sharded | Sort-Object) | Should -BeExactly ($baseline | Sort-Object)
    }

    It 'fails a shard when a selected test fails and writes its failure to XML' {
        $path = Join-Path $fixture 'Failure.Tests.ps1'
        Set-Content -LiteralPath $path -Value "Describe 'Failure' { It 'reports failure' { 1 | Should -Be 2 } }"
        $output = @(& ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $fixture 'tools/Invoke-Tests.ps1') -CI -Path $path -Shard '0/1' 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match 'Pester failed: 1 failed'
        $xml = [xml](Get-Content -LiteralPath (Join-Path $fixture 'artifacts/pester-0-of-1.xml') -Raw)
        $xml.'test-results'.failures | Should -Be '1'
    }

    It 'rejects invalid shard <Shard>' -ForEach @(
        @{ Shard = '4/4' }, @{ Shard = '0/0' }, @{ Shard = '-1/4' }, @{ Shard = '0/99' }
    ) {
        $output = @(& ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $fixture 'tools/Invoke-Tests.ps1') -Shard $Shard 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match 'Shard|nonempty shards'
    }

    It 'fails a shard on <Case> even when other tests pass' -Tag RunnerFailure -ForEach @(
        @{ Case = 'discovery failure'; Body = "throw 'Discovery failure'" }
        @{ Case = 'AfterAll failure'; Body = "Describe 'Broken cleanup' { It 'passes' { 1 | Should -Be 1 }; AfterAll { throw 'Cleanup failure' } }" }
    ) {
        $directory = Join-Path $fixture 'failure-modes'
        $null = New-Item -ItemType Directory -Force -Path $directory
        Set-Content -LiteralPath (Join-Path $directory 'Passing.Tests.ps1') -Value "Describe 'Passing' { It 'passes' { 1 | Should -Be 1 } }"
        Set-Content -LiteralPath (Join-Path $directory 'Broken.Tests.ps1') -Value $Body
        $output = @(& ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $fixture 'tools/Invoke-Tests.ps1') -CI -Path $directory -Shard '0/1' 2>&1)
        $LASTEXITCODE | Should -Not -Be 0
        ($output -join "`n") | Should -Match 'Pester failed:'
    }
}
