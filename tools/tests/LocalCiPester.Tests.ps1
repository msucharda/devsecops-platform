BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiPester.psm1') -Force

    function Write-ShardReport {
        param([string] $Path, [string] $File, [switch] $Failed)
        $result = if ($Failed) { 'Failure' } else { 'Success' }
        $success = if ($Failed) { 'False' } else { 'True' }
        $failures = [int] $Failed.IsPresent
        Set-Content -LiteralPath $Path -Value @"
<test-results name="Pester" total="1" errors="0" failures="$failures" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0">
<test-suite type="TestFixture" name="Pester" executed="True" result="$result" success="$success" time="1.25" asserts="0"><results>
<test-suite type="TestFixture" name="$File" executed="True" result="$result" success="$success" time="1.25" asserts="0"><results>
<test-case name="test $File" executed="True" result="$result" success="$success" time="1.25" />
</results></test-suite></results></test-suite></test-results>
"@
    }
}

Describe 'Local Pester result merging' {
    It 'fails closed for <Case> without reusing an older merged success' -ForEach @(
        @{ Case = 'missing XML'; Change = 'missing'; Message = 'Missing Pester shard XML' }
        @{ Case = 'malformed XML'; Change = 'malformed'; Message = 'unexpected|parse|root|Data|invalid' }
        @{ Case = 'missing counter'; Change = 'counter'; Message = 'counter' }
        @{ Case = 'empty result'; Change = 'empty'; Message = 'no passing' }
        @{ Case = 'unselected file'; Change = 'file'; Message = 'coverage' }
        @{ Case = 'duplicate file'; Change = 'duplicate'; Message = 'more than one shard' }
        @{ Case = 'failed process with successful XML'; Change = 'exit'; Message = 'exit 9' }
        @{ Case = 'failed test'; Change = 'failure'; Message = 'Failed: 1' }
        @{ Case = 'unknown success state'; Change = 'success'; Message = 'Failed: 0' }
    ) {
        $report = Join-Path $TestDrive "$Change.xml"
        $output = Join-Path $TestDrive "$Change-merged.xml"
        Write-ShardReport -Path $report -File 'A.Tests.ps1' -Failed:($Change -eq 'failure')
        $shards = @(@{ ResultPath = $report; Path = @('A.Tests.ps1'); ExitCode = 0 })
        switch ($Change) {
            'missing' { Remove-Item $report }
            'malformed' { Set-Content $report '<not-xml' }
            'counter' {
                $xml = [xml](Get-Content $report -Raw)
                $xml.'test-results'.RemoveAttribute('total')
                $xml.Save($report)
            }
            'empty' {
                $xml = [xml](Get-Content $report -Raw)
                $xml.SelectSingleNode('//test-case').SetAttribute('executed', 'False')
                $xml.Save($report)
            }
            'file' { $shards[0].Path = @('B.Tests.ps1') }
            'duplicate' { $shards += $shards[0] }
            'exit' { $shards[0].ExitCode = 9 }
            'success' {
                $xml = [xml](Get-Content $report -Raw)
                $xml.SelectSingleNode('/test-results/test-suite').SetAttribute('success', '')
                $xml.Save($report)
            }
        }
        Set-Content $output 'Stale successful result'

        $result = Merge-LocalCiPesterResult -Shard $shards -RepositoryRoot $TestDrive -OutputPath $output

        $result.ExitCode | Should -Be 1
        ($result.Output -join "`n") | Should -Match $Message
        if (Test-Path $output) {
            ([xml](Get-Content $output -Raw)).'test-results'.'test-suite'.success | Should -Be 'False'
        }
    }

    It 'rejects a failing test hidden by successful report metadata' {
        $report = Join-Path $TestDrive 'inconsistent.xml'
        $output = Join-Path $TestDrive 'inconsistent-merged.xml'
        Write-ShardReport -Path $report -File 'A.Tests.ps1'
        $xml = [xml](Get-Content $report -Raw)
        $case = $xml.SelectSingleNode('//test-case').CloneNode($true)
        $case.SetAttribute('result', 'Failure')
        $case.SetAttribute('name', 'hidden failure')
        $null = $xml.SelectSingleNode('//test-case').ParentNode.AppendChild($case)
        $xml.'test-results'.SetAttribute('total', '2')
        $xml.Save($report)
        $result = Merge-LocalCiPesterResult -Shard @(
            @{ ResultPath = $report; Path = @('A.Tests.ps1'); ExitCode = 0 }
        ) -RepositoryRoot $TestDrive -OutputPath $output

        $result.ExitCode | Should -Be 1
        ($result.Output -join "`n") | Should -Match 'inconsistent|no passing'
    }

    It 'preserves all file suites and adds counters and duration into one NUnit report' {
        $first = Join-Path $TestDrive 'one.xml'
        $second = Join-Path $TestDrive 'two.xml'
        $output = Join-Path $TestDrive 'merged.xml'
        Write-ShardReport -Path $first -File 'A.Tests.ps1'
        Write-ShardReport -Path $second -File 'B.Tests.ps1'

        $result = Merge-LocalCiPesterResult -Shard @(
            @{ ResultPath = $first; Path = @('A.Tests.ps1'); ExitCode = 0 }
            @{ ResultPath = $second; Path = @('B.Tests.ps1'); ExitCode = 0 }
        ) -RepositoryRoot $TestDrive -OutputPath $output

        $result.ExitCode | Should -Be 0
        $xml = [xml](Get-Content -LiteralPath $output -Raw)
        $xml.'test-results'.total | Should -Be '2'
        $xml.'test-results'.'test-suite'.time | Should -Be '2.5'
        @($xml.SelectNodes('//test-case')).Count | Should -Be 2
        @($xml.SelectNodes('/test-results/test-suite/results/test-suite').name) |
            Should -BeExactly @('A.Tests.ps1', 'B.Tests.ps1')
    }

    Describe 'Local Pester parallel execution' {
        BeforeEach {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'tools/tests'), (Join-Path $root 'arrivals')
            foreach ($name in 'A', 'B', 'C', 'D') { Set-Content (Join-Path $root "tools/tests/$name.Tests.ps1") '# Process fixture' }
            Set-Content (Join-Path $root 'tools/pester-durations.psd1') '@{}'
            # The child process is the boundary; this fixture writes the NUnit shape emitted by Pester 5.7.1.
            Set-Content (Join-Path $root 'tools/Invoke-Tests.ps1') @'
param([switch] $CI, [string[]] $Path, [string] $ResultPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
@{ Path = $Path; Temp = $env:TEMP; Tmp = $env:TMP; TmpDir = $env:TMPDIR; Budget = $env:LOCAL_CI_WORKER_BUDGET } |
    ConvertTo-Json | Set-Content (Join-Path $root "arrivals/$PID.json")
$watch = [Diagnostics.Stopwatch]::StartNew()
while (@(Get-ChildItem (Join-Path $root 'arrivals') -Filter '*.json').Count -lt 2) {
    if ($watch.Elapsed.TotalSeconds -gt 10) { throw 'Shards were not concurrent.' }
    Start-Sleep -Milliseconds 20
}
$suites = foreach ($file in $Path) {
    $name = [Security.SecurityElement]::Escape([IO.Path]::GetFullPath((Join-Path $root $file)))
    "<test-suite name=`"$name`" time=`"1`"><results><test-case name=`"$name`" executed=`"True`" result=`"Success`" /></results></test-suite>"
}
@"
<test-results total="$($Path.Count)" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0">
<test-suite name="Pester" result="Success" success="True" time="1"><results>$($suites -join '')</results></test-suite></test-results>
"@ | Set-Content -LiteralPath $ResultPath
'Fixture tests finished'
'@
        }

        It 'runs all selected files once concurrently, isolates shard TEMP and publishes one merged result' {
            $files = @('tools/tests/A.Tests.ps1', 'tools/tests/B.Tests.ps1', 'tools/tests/C.Tests.ps1', 'tools/tests/D.Tests.ps1')
            $result = Invoke-LocalCiPester -RepositoryRoot $root -Path $files -ShardCount 2 -TempPath (Join-Path $root 'scratch')

            $result.ExitCode | Should -Be 0 -Because ($result.Output -join "`n")
            $arrivals = @(Get-ChildItem (Join-Path $root 'arrivals') | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
            $arrivals.Count | Should -Be 2
            @($arrivals.Path | Sort-Object) | Should -BeExactly ($files | Sort-Object)
            @($arrivals.Temp | Sort-Object -Unique).Count | Should -Be 2
            foreach ($arrival in $arrivals) {
                $arrival.Temp | Should -BeExactly $arrival.Tmp
                $arrival.Temp | Should -BeExactly $arrival.TmpDir
                $arrival.Budget | Should -Be '1'
            }
            $xml = [xml](Get-Content (Join-Path $root 'artifacts/pester.xml') -Raw)
            $xml.'test-results'.total | Should -Be '4'
            @($result.Shards).Count | Should -Be 2
            foreach ($shard in $result.Shards) {
                Test-Path -LiteralPath $shard.ResultPath | Should -BeTrue
                Test-Path -LiteralPath $shard.LogPath | Should -BeTrue
            }
        }

        It 'fails the combined result on a shard <Case>, waits for peers, and can rerun safely' -ForEach @(
                @{ Case = 'nonzero exit'; Tail = 'exit 7'; Message = 'exit 7'; Timeout = 15 }
                @{ Case = 'crash'; Tail = '[Environment]::Exit(8)'; Message = 'exit 8'; Timeout = 15 }
                @{ Case = 'missing XML'; Tail = 'Remove-Item -LiteralPath $ResultPath'; Message = 'Missing Pester shard XML'; Timeout = 15 }
                @{ Case = 'timeout after XML'; Tail = 'Start-Sleep -Seconds 30'; Message = 'timed out'; Timeout = 3 }
            ) {
                $runner = Join-Path $root 'tools/Invoke-Tests.ps1'
                $body = Get-Content $runner -Raw
                Add-Content $runner "`nif (`$Path -contains 'tools/tests/A.Tests.ps1') { $Tail }"
                $files = @('tools/tests/A.Tests.ps1', 'tools/tests/B.Tests.ps1')
                $result = Invoke-LocalCiPester -RepositoryRoot $root -Path $files -ShardCount 2 -TempPath (Join-Path $root 'scratch') -TimeoutSeconds $Timeout

                $result.ExitCode | Should -Be 1
                ($result.Output -join "`n") | Should -Match $Message
                @($result.Shards | Where-Object ExitCode -EQ 0).Count | Should -Be $(if ($Case -eq 'missing XML') { 2 } else { 1 })
                foreach ($shard in $result.Shards) { Test-Path $shard.LogPath | Should -BeTrue }
                Set-Content $runner $body

                $retry = Invoke-LocalCiPester -RepositoryRoot $root -Path $files -ShardCount 2 -TempPath (Join-Path $root 'scratch')
                $retry.ExitCode | Should -Be 0 -Because ($retry.Output -join "`n")
                $retry.Shards[0].ResultPath | Should -Not -Be $result.Shards[0].ResultPath
            }

            It 'clears an older success even if selection fails before a child starts' {
                $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'artifacts')
                $old = Join-Path $root 'artifacts/pester.xml'
                Set-Content $old 'Stale success'

                $result = Invoke-LocalCiPester -RepositoryRoot $root -Path 'tools/tests/Missing.Tests.ps1' -ShardCount 2 -TempPath (Join-Path $root 'scratch')

                $result.ExitCode | Should -Be 1
                ($result.Output -join "`n") | Should -Match 'existing test files'
                Test-Path $old | Should -BeFalse
            }
    }
}

Describe 'Local Pester shard planning' {
    It 'caps shards at the number of unique files and falls back on invalid or absent local history' {
        $root = Join-Path $TestDrive 'fallback'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'tools/tests'), (Join-Path $root 'artifacts')
        foreach ($name in 'A', 'B', 'C') { Set-Content (Join-Path $root "tools/tests/$name.Tests.ps1") '# Fixture' }
        Set-Content (Join-Path $root 'tools/pester-durations.psd1') "@{ 'B.Tests.ps1'=8; 'C.Tests.ps1'=3 }"
        Set-Content (Join-Path $root 'artifacts/pester.xml') '<broken'
        $files = @('tools/tests/A.Tests.ps1', 'tools/tests/B.Tests.ps1', 'tools/tests/C.Tests.ps1', 'tools/tests/A.Tests.ps1')

        $plan = @(Get-LocalCiPesterShard -RepositoryRoot $root -Path $files -ShardCount 8)

        $plan.Count | Should -Be 3
        $plan.Seconds | Should -BeExactly @(8, 3, 1)
        @($plan.Path).Count | Should -Be 3
        $again = @(Get-LocalCiPesterShard -RepositoryRoot $root -Path $files -ShardCount 1)
        $again.Count | Should -Be 1
        $again[0].Path.Count | Should -Be 3
    }

    It 'uses recent local file durations and assigns every selected file once within the granted count' {
        $root = Join-Path $TestDrive 'planning'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'tools/tests'), (Join-Path $root 'artifacts')
        foreach ($name in 'A', 'B', 'C', 'D') {
            Set-Content (Join-Path $root "tools/tests/$name.Tests.ps1") "Describe '$name' {}"
        }
        Set-Content (Join-Path $root 'tools/pester-durations.psd1') "@{ 'A.Tests.ps1'=1; 'B.Tests.ps1'=9; 'C.Tests.ps1'=8; 'D.Tests.ps1'=7 }"
        Set-Content (Join-Path $root 'artifacts/pester.xml') @"
<test-results><test-suite type="TestFixture" name="Pester"><results>
<test-suite type="TestFixture" name="$root/tools/tests/A.Tests.ps1" time="20" />
<test-suite type="TestFixture" name="$root/tools/tests/B.Tests.ps1" time="3" />
</results></test-suite></test-results>
"@
        $plan = @(Get-LocalCiPesterShard -RepositoryRoot $root -Path @(
            'tools/tests/D.Tests.ps1', 'tools/tests/B.Tests.ps1', 'tools/tests/A.Tests.ps1', 'tools/tests/C.Tests.ps1'
        ) -ShardCount 2)

        $plan.Count | Should -Be 2
        $plan[0].Path | Should -BeExactly @('tools/tests/A.Tests.ps1')
        $plan[1].Path | Should -BeExactly @('tools/tests/C.Tests.ps1', 'tools/tests/D.Tests.ps1', 'tools/tests/B.Tests.ps1')
        $plan[0].Seconds | Should -Be 20
        $plan[1].Seconds | Should -Be 18
        @($plan.Path | Sort-Object -Unique).Count | Should -Be 4
    }
}
