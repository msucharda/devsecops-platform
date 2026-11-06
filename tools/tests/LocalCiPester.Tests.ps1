BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiPester.psm1') -Force
    $testWorkerBudget = 64
    if ($null -ne $env:LOCAL_CI_WORKER_BUDGET) {
        if (-not [int]::TryParse($env:LOCAL_CI_WORKER_BUDGET, [ref] $testWorkerBudget) -or $testWorkerBudget -le 0) {
            throw 'LOCAL_CI_WORKER_BUDGET must be a positive integer.'
        }
    }
    $parallelSlots = [Math]::Min(2, $testWorkerBudget)
    $nestedSlots = [Math]::Min(3, $testWorkerBudget)

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
    It 'accepts the Pester Ignored root variant for passing suites with skipped tests' {
        $report = Join-Path $TestDrive 'skipped.xml'
        $output = Join-Path $TestDrive 'skipped-merged.xml'
        Write-ShardReport -Path $report -File 'A.Tests.ps1'
        $xml = [xml](Get-Content $report -Raw)
        $xml.'test-results'.SetAttribute('total', '2')
        $xml.'test-results'.SetAttribute('skipped', '1')
        # Pester 5.7.1 reports skipped cases as Ignored but keeps the ignored counter at zero.
        $xml.'test-results'.'test-suite'.SetAttribute('result', 'Ignored')
        $xml.SelectSingleNode('/test-results/test-suite/results/test-suite').SetAttribute('result', 'Ignored')
        $case = $xml.SelectSingleNode('//test-case').CloneNode($true)
        $case.SetAttribute('name', 'skipped case')
        $case.SetAttribute('executed', 'False')
        $case.SetAttribute('result', 'Ignored')
        $case.SetAttribute('success', 'False')
        $null = $xml.SelectSingleNode('//test-case').ParentNode.AppendChild($case)
        $xml.Save($report)

        $result = Merge-LocalCiPesterResult -Shard @(
            @{ ResultPath = $report; Path = @('A.Tests.ps1'); ExitCode = 0 }
        ) -RepositoryRoot $TestDrive -OutputPath $output

        $result.ExitCode | Should -Be 0 -Because ($result.Output -join "`n")
        ([xml](Get-Content $output -Raw)).'test-results'.skipped | Should -Be '1'
    }

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

    It 'rejects a hidden test with <Case> despite successful report metadata' -ForEach @(
        @{ Case = 'a failure'; Executed = 'True'; Result = 'Failure' }
        @{ Case = 'missing executed'; Executed = $null; Result = 'Failure' }
        @{ Case = 'unknown executed'; Executed = 'Unknown'; Result = 'Failure' }
        @{ Case = 'lowercase executed'; Executed = 'true'; Result = 'Success' }
        @{ Case = 'missing result'; Executed = 'True'; Result = $null }
        @{ Case = 'unknown result'; Executed = 'True'; Result = 'Unknown' }
        @{ Case = 'lowercase result'; Executed = 'True'; Result = 'success' }
        @{ Case = 'unexecuted success'; Executed = 'False'; Result = 'Success' }
        @{ Case = 'unexecuted failure'; Executed = 'False'; Result = 'Failure' }
        @{ Case = 'executed ignored'; Executed = 'True'; Result = 'Ignored' }
        @{ Case = 'lowercase unexecuted'; Executed = 'false'; Result = 'Ignored' }
        @{ Case = 'lowercase ignored'; Executed = 'False'; Result = 'ignored' }
        @{ Case = 'unexecuted unknown'; Executed = 'False'; Result = 'Unknown' }
    ) {
        $report = Join-Path $TestDrive 'inconsistent.xml'
        $output = Join-Path $TestDrive 'inconsistent-merged.xml'
        Write-ShardReport -Path $report -File 'A.Tests.ps1'
        $xml = [xml](Get-Content $report -Raw)
        $case = $xml.SelectSingleNode('//test-case').CloneNode($true)
        $case.SetAttribute('result', $Result)
        if ($null -eq $Result) { $case.RemoveAttribute('result') }
        $case.SetAttribute('executed', $Executed)
        if ($null -eq $Executed) { $case.RemoveAttribute('executed') }
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

    It 'accepts an executed inconclusive case alongside a passing case' {
        $report = Join-Path $TestDrive 'inconclusive.xml'
        Write-ShardReport -Path $report -File 'A.Tests.ps1'
        $xml = [xml](Get-Content $report -Raw)
        $case = $xml.SelectSingleNode('//test-case').CloneNode($true)
        $case.SetAttribute('result', 'Inconclusive')
        $case.SetAttribute('success', 'False')
        $null = $xml.SelectSingleNode('//test-case').ParentNode.AppendChild($case)
        $xml.'test-results'.SetAttribute('total', '2')
        $xml.'test-results'.SetAttribute('inconclusive', '1')
        # Pester 5.7.1 Get-GroupResult emits Inconclusive when no tests failed or skipped.
        $xml.SelectSingleNode('/test-results/test-suite').SetAttribute('result', 'Inconclusive')
        $xml.SelectSingleNode('/test-results/test-suite/results/test-suite').SetAttribute('result', 'Inconclusive')
        $xml.Save($report)

        $result = Merge-LocalCiPesterResult -Shard @(
            @{ ResultPath = $report; Path = @('A.Tests.ps1'); ExitCode = 0 }
        ) -RepositoryRoot $TestDrive -OutputPath (Join-Path $TestDrive 'inconclusive-merged.xml')

        $result.ExitCode | Should -Be 0 -Because ($result.Output -join "`n")
        ([xml](Get-Content (Join-Path $TestDrive 'inconclusive-merged.xml') -Raw)).'test-results'.'test-suite'.result |
            Should -BeExactly 'Inconclusive'
    }

    It 'rejects invalid shard metadata <Case> by its own condition' -ForEach @(
        @{ Case = 'no shards'; Change = 'shards'; Message = 'No Pester shard results' }
        @{ Case = 'no suite'; Change = 'suite'; Message = 'Invalid Pester shard XML' }
        @{ Case = 'no root'; Change = 'root'; Message = 'Invalid Pester shard XML' }
        @{ Case = 'empty selection'; Change = 'selection'; Message = 'coverage.*empty' }
        @{ Case = 'negative counter'; Change = 'counter'; Field = 'total'; Value = '-1'; Message = "Invalid Pester shard counter 'total'" }
        @{ Case = 'nonnumeric counter'; Change = 'counter'; Field = 'total'; Value = 'unknown'; Message = "Invalid Pester shard counter 'total'" }
        @{ Case = 'zero total'; Change = 'counter'; Field = 'total'; Value = '0'; Message = 'counters report failure' }
        @{ Case = 'total exceeding case count'; Change = 'counter'; Field = 'total'; Value = '2'; Message = "counter 'total'.*test cases" }
        @{ Case = 'inconclusive count mismatch'; Change = 'counter'; Field = 'inconclusive'; Value = '1'; Message = "counter 'inconclusive'.*test cases" }
        @{ Case = 'skipped count mismatch'; Change = 'counter'; Field = 'skipped'; Value = '1'; Message = "counter 'skipped'.*test cases" }
        @{ Case = 'ignored count mismatch'; Change = 'counter'; Field = 'ignored'; Value = '1'; Message = "counter 'ignored'.*zero" }
        @{ Case = 'errors'; Change = 'counter'; Field = 'errors'; Value = '1'; Message = 'counters report failure' }
        @{ Case = 'failures'; Change = 'counter'; Field = 'failures'; Value = '1'; Message = 'counters report failure' }
        @{ Case = 'invalid tests'; Change = 'counter'; Field = 'invalid'; Value = '1'; Message = 'counters report failure' }
        @{ Case = 'negative duration'; Change = 'attribute'; Field = 'time'; Value = '-1'; Message = 'Invalid Pester shard duration' }
        @{ Case = 'unknown duration'; Change = 'attribute'; Field = 'time'; Value = 'unknown'; Message = 'Invalid Pester shard duration' }
        @{ Case = 'NaN duration'; Change = 'attribute'; Field = 'time'; Value = 'NaN'; Message = 'Invalid Pester shard duration' }
        @{ Case = 'unknown suite result'; Change = 'attribute'; Field = 'result'; Value = 'Unknown'; Message = 'suite outcome' }
        @{ Case = 'suite result casing'; Change = 'attribute'; Field = 'result'; Value = 'success'; Message = 'suite outcome' }
        @{ Case = 'suite success casing'; Change = 'attribute'; Field = 'success'; Value = 'true'; Message = 'suite outcome' }
        @{ Case = 'no passing tests'; Change = 'cases'; Message = 'no passing executed tests' }
    ) {
        $report = Join-Path $TestDrive 'metadata.xml'
        Write-ShardReport -Path $report -File 'A.Tests.ps1'
        $xml = [xml](Get-Content $report -Raw)
        $shards = @(@{ ResultPath = $report; Path = @('A.Tests.ps1'); ExitCode = 0 })
        switch ($Change) {
            'shards' { $shards = @() }
            'suite' { $null = $xml.DocumentElement.RemoveChild($xml.SelectSingleNode('/test-results/test-suite')) }
            'root' { $xml = [xml] '<unexpected />' }
            'selection' { $shards[0].Path = @() }
            'counter' { $xml.DocumentElement.SetAttribute($Field, $Value) }
            'attribute' { $xml.SelectSingleNode('/test-results/test-suite').SetAttribute($Field, $Value) }
            'cases' {
                $xml.SelectSingleNode('//test-case').SetAttribute('result', 'Inconclusive')
                $xml.DocumentElement.SetAttribute('inconclusive', '1')
            }
        }
        $xml.Save($report)

        $result = Merge-LocalCiPesterResult -Shard $shards -RepositoryRoot $TestDrive -OutputPath (Join-Path $TestDrive 'metadata-merged.xml')

        $result.ExitCode | Should -Be 1
        ($result.Output -join "`n") | Should -Match $Message
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

    It 'rejects a selected file suite without cases even when total covers both files' {
        $report = Join-Path $TestDrive 'empty-file.xml'
        Write-ShardReport -Path $report -File 'A.Tests.ps1'
        $xml = [xml](Get-Content $report -Raw)
        $fileSuite = $xml.SelectSingleNode('/test-results/test-suite/results/test-suite')
        $null = $fileSuite.SelectSingleNode('results').AppendChild($fileSuite.SelectSingleNode('.//test-case').CloneNode($true))
        $empty = $fileSuite.CloneNode($true)
        $empty.SetAttribute('name', 'B.Tests.ps1')
        $empty.SelectSingleNode('results').RemoveAll()
        $null = $fileSuite.ParentNode.AppendChild($empty)
        $xml.DocumentElement.SetAttribute('total', '2')
        $xml.Save($report)

        $result = Merge-LocalCiPesterResult -Shard @(
            @{ ResultPath = $report; Path = @('A.Tests.ps1', 'B.Tests.ps1'); ExitCode = 0 }
        ) -RepositoryRoot $TestDrive -OutputPath (Join-Path $TestDrive 'empty-file-merged.xml')

        $result.ExitCode | Should -Be 1
        ($result.Output -join "`n") | Should -Match 'file coverage.*no test cases.*B.Tests.ps1'
    }

    It 'recovers XML publication interrupted <Boundary> with <Termination>' -ForEach @(
        @{ Boundary = 'BeforeApply'; Termination = 'Error' }
        @{ Boundary = 'BeforeApply'; Termination = 'Abrupt' }
        @{ Boundary = 'LoseResponse'; Termination = 'Error' }
        @{ Boundary = 'LoseResponse'; Termination = 'Abrupt' }
    ) {
        $report = Join-Path $TestDrive "$Boundary-$Termination.xml"
        $output = Join-Path $TestDrive "$Boundary-$Termination-merged.xml"
        Write-ShardReport -Path $report -File 'A.Tests.ps1'
        Set-Content -LiteralPath $output -Value 'Stale successful result'
        $shards = @(@{ ResultPath = $report; Path = @('A.Tests.ps1'); ExitCode = 0 })
        $boundaryState = @{ Interrupt = $true; Staging = $null; Final = $null; Boundary = $Boundary }
        Mock Move-LocalCiPesterArtifact -ModuleName LocalCiPester {
            param($Source, $Destination)
            if (-not $boundaryState.Interrupt) { [IO.File]::Move($Source, $Destination, $true); return }
            if ($boundaryState.Boundary -eq 'LoseResponse') { [IO.File]::Move($Source, $Destination, $true) }
            $boundaryState.Staging = if (Test-Path $Source) { [IO.File]::ReadAllText($Source) } else { $null }
            $boundaryState.Final = if (Test-Path $Destination) { [IO.File]::ReadAllText($Destination) } else { $null }
            throw 'Publication interrupted'
        }

        $result = Merge-LocalCiPesterResult -Shard $shards -RepositoryRoot $TestDrive -OutputPath $output

        $result.ExitCode | Should -Be 1
        ($result.Output -join "`n") | Should -Match 'Publication interrupted'
        Test-Path -LiteralPath "$output.new" | Should -BeFalse
        if ($Boundary -eq 'BeforeApply') {
            Test-Path -LiteralPath $output | Should -BeFalse
            ([xml] $boundaryState.Staging).'test-results'.'test-suite'.success | Should -BeExactly 'True'
        }
        else { ([xml](Get-Content $output -Raw)).'test-results'.'test-suite'.success | Should -BeExactly 'True' }
        if ($Termination -eq 'Abrupt') {
            # Restore the filesystem snapshot from the boundary, discarding finally's cleanup.
            if ($null -ne $boundaryState.Staging) { [IO.File]::WriteAllText("$output.new", $boundaryState.Staging) }
            if ($null -ne $boundaryState.Final) { [IO.File]::WriteAllText($output, $boundaryState.Final) }
        }
        $boundaryState.Interrupt = $false

        $retry = Merge-LocalCiPesterResult -Shard $shards -RepositoryRoot $TestDrive -OutputPath $output

        $retry.ExitCode | Should -Be 0 -Because ($retry.Output -join "`n")
        ([xml](Get-Content $output -Raw)).'test-results'.total | Should -BeExactly '1'
        Test-Path -LiteralPath "$output.new" | Should -BeFalse
    }

    Describe 'Local Pester parallel execution' {
        BeforeEach {
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N').Substring(0, 8))
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'tools/tests'), (Join-Path $root 'arrivals')
            foreach ($name in 'A', 'B', 'C', 'D') { Set-Content (Join-Path $root "tools/tests/$name.Tests.ps1") '# Process fixture' }
            Set-Content (Join-Path $root 'tools/pester-durations.psd1') '@{}'
            Set-Content (Join-Path $root 'parallel-slots') $parallelSlots
            # The child process is the boundary; this fixture writes the NUnit shape emitted by Pester 5.7.1.
            Set-Content (Join-Path $root 'tools/Invoke-Tests.ps1') @'
param([switch] $CI, [string[]] $Path, [string] $ResultPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
@{ Path = $Path; Temp = $env:TEMP; Tmp = $env:TMP; TmpDir = $env:TMPDIR; Budget = $env:LOCAL_CI_WORKER_BUDGET } |
    ConvertTo-Json | Set-Content (Join-Path $root "arrivals/$PID.json")
$watch = [Diagnostics.Stopwatch]::StartNew()
$expected = [int](Get-Content (Join-Path $root 'parallel-slots'))
while (@(Get-ChildItem (Join-Path $root 'arrivals') -Filter '*.json').Count -lt $expected) {
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
            $sidecar = Join-Path $root 'shards.json'
            $group = Get-LocalCiPesterStepGroup -RepositoryRoot $root -Path $files -GrantedShardCount $parallelSlots -TimingPath $sidecar
            $group.Slots | Should -Be $parallelSlots
            $savedTemp = $env:TEMP
            try {
                $env:TEMP = Join-Path $root 'scratch'
                $output = @(& ([scriptblock]::Create($group.Steps[0].Script)))
                $result = [pscustomobject]@{
                    ExitCode = $LASTEXITCODE; Output = $output
                    Shards = @(Get-Content $sidecar -Raw | ConvertFrom-Json)
                }
            }
            finally { $env:TEMP = $savedTemp }

            $result.ExitCode | Should -Be 0 -Because ($result.Output -join "`n")
            $arrivals = @(Get-ChildItem (Join-Path $root 'arrivals') | ForEach-Object { Get-Content $_.FullName -Raw | ConvertFrom-Json })
            $arrivals.Count | Should -Be $parallelSlots
            @($arrivals.Path | Sort-Object) | Should -BeExactly ($files | Sort-Object)
            @($arrivals.Temp | Sort-Object -Unique).Count | Should -Be $parallelSlots
            foreach ($arrival in $arrivals) {
                $arrival.Temp | Should -BeExactly $arrival.Tmp
                $arrival.Temp | Should -BeExactly $arrival.TmpDir
                $arrival.Budget | Should -Be '1'
            }
            $xml = [xml](Get-Content (Join-Path $root 'artifacts/pester.xml') -Raw)
            $xml.'test-results'.total | Should -Be '4'
            @($result.Shards).Count | Should -Be $parallelSlots
            foreach ($shard in $result.Shards) {
                Test-Path -LiteralPath $shard.ResultPath | Should -BeTrue
                Test-Path -LiteralPath $shard.LogPath | Should -BeTrue
                $shard.FileCount | Should -Be (4 / $parallelSlots)
                $shard.Seconds | Should -BeGreaterThan 0
                $shard.Files.Count | Should -Be (4 / $parallelSlots)
                $shard.Files.Seconds | Should -BeExactly @(1..(4 / $parallelSlots) | ForEach-Object { 1 })
            }
            ($result.Output -join "`n") | Should -Match 'Pester shard 0 completed:.*wall'
            ($result.Output -join "`n") | Should -Match 'Pester file.*A.Tests.ps1.*1.000'
        }

        It 'reserves nested child capacity without overlapping peer shards for <Suite> with <Case>' -ForEach @(
            @{ Suite = 'InstanceSetupManualSteps'; Case = 'one file'; Peers = @() }
            @{ Suite = 'InstanceSetupManualSteps'; Case = 'multiple files'; Peers = @('tools/tests/A.Tests.ps1', 'tools/tests/B.Tests.ps1') }
            @{ Suite = 'LocalCiPester'; Case = 'one file'; Peers = @() }
            @{ Suite = 'LocalCiPester'; Case = 'multiple files'; Peers = @('tools/tests/A.Tests.ps1', 'tools/tests/B.Tests.ps1') }
            @{ Suite = 'LocalCiGate.Unit'; Case = 'one file'; Peers = @() }
            @{ Suite = 'LocalCiGate.Unit'; Case = 'multiple files'; Peers = @('tools/tests/A.Tests.ps1', 'tools/tests/B.Tests.ps1') }
        ) {
            $nested = "tools/tests/$Suite.Tests.ps1"
            Set-Content (Join-Path $root $nested) '# Nested-process fixture'
            Set-Content (Join-Path $root 'tools/pester-durations.psd1') "@{ '$Suite.Tests.ps1'=100 }"
            Set-Content (Join-Path $root 'nested-slots') $nestedSlots
            Set-Content (Join-Path $root 'tools/Invoke-Tests.ps1') @'
param([switch] $CI, [string[]] $Path, [string] $ResultPath)
$ErrorActionPreference = 'Stop'
$root = Split-Path $PSScriptRoot -Parent
if (@($Path | Where-Object { [IO.Path]::GetFileName($_) -in @('InstanceSetupManualSteps.Tests.ps1', 'LocalCiPester.Tests.ps1', 'LocalCiGate.Unit.Tests.ps1') }).Count) {
    if ($env:LOCAL_CI_WORKER_BUDGET -ne (Get-Content (Join-Path $root 'nested-slots'))) { throw 'Nested suite did not receive its reserved slots.' }
    Start-Sleep -Milliseconds 100
    [IO.File]::WriteAllText((Join-Path $root 'nested-done'), '')
}
else {
    if ($env:LOCAL_CI_WORKER_BUDGET -ne '1') { throw 'Peer shard received unreserved slots.' }
    if (-not (Test-Path (Join-Path $root 'nested-done'))) { throw 'Peer shard exceeded the reserved capacity.' }
}
$suites = foreach ($file in $Path) {
    "<test-suite name=`"$file`" time=`"1`"><results><test-case executed=`"True`" result=`"Success`" /></results></test-suite>"
}
@"
<test-results total="$($Path.Count)" errors="0" failures="0" not-run="0" inconclusive="0" ignored="0" skipped="0" invalid="0">
<test-suite result="Success" success="True" time="1"><results>$($suites -join '')</results></test-suite></test-results>
"@ | Set-Content -LiteralPath $ResultPath
'@
            $sidecar = Join-Path $root 'nested-shards.json'
            $group = Get-LocalCiPesterStepGroup -RepositoryRoot $root -Path (@($nested) + $Peers) -GrantedShardCount $nestedSlots -TimingPath $sidecar
            $group.Slots | Should -Be $nestedSlots
            $savedTemp = $env:TEMP
            try {
                $env:TEMP = Join-Path $root 'scratch'
                $output = @(& ([scriptblock]::Create($group.Steps[0].Script)))
                $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
            }
            finally { $env:TEMP = $savedTemp }
            $shards = @(Get-Content $sidecar -Raw | ConvertFrom-Json)
            $shards.Count | Should -Be ([Math]::Min($nestedSlots, 1 + $Peers.Count))
            ($shards | Where-Object { $_.Path -contains $nested }).Slots | Should -Be $nestedSlots
            @($shards | Where-Object { $_.Path -notcontains $nested } | Select-Object -ExpandProperty Slots) |
                Should -BeExactly @(1..$shards.Count | Select-Object -Skip 1 | ForEach-Object { 1 })
        }

        It 'fails the combined result on a shard <Case>, waits for peers, and can rerun safely' -ForEach @(
            @{ Case = 'nonzero exit'; Message = 'exit 7' }
            @{ Case = 'crash'; Message = 'exit 8' }
            @{ Case = 'missing XML'; Message = 'Missing Pester shard XML' }
            @{ Case = 'timeout after XML'; Message = 'timed out' }
            @{ Case = 'completed after deadline'; Message = 'timed out' }
        ) {
            $behavior = @{ Mode = $Case }
            # Stub the operating-system process boundary; the merge and fail-closed paths stay real.
            Mock Invoke-LocalCiPesterProcess -ModuleName LocalCiPester {
                param($Path, $ResultPath)
                $target = if ($behavior.Mode -eq 'completed after deadline') { 'tools/tests/B.Tests.ps1' } else { 'tools/tests/A.Tests.ps1' }
                $mode = if ($Path -contains $target) { $behavior.Mode } else { 'success' }
                if ($mode -notin @('missing XML', 'crash')) { Write-ShardReport -Path $ResultPath -File $Path[0] }
                $stream = [pscustomobject]@{}
                $stream | Add-Member ScriptMethod ReadToEndAsync { [Threading.Tasks.Task]::FromResult[string]('Stub child output') }
                $end = [datetime]::UtcNow
                $process = [pscustomobject]@{
                    HasExited = $mode -ne 'timeout after XML'; EnableRaisingEvents = $false
                    ExitCode = if ($mode -eq 'nonzero exit') { 7 } elseif ($mode -eq 'crash') { 8 } else { 0 }
                    StandardOutput = $stream; StandardError = $stream
                    StartTime = $end.AddSeconds($(if ($mode -eq 'completed after deadline') { -901 } else { -1.5 })); ExitTime = $end
                }
                $process | Add-Member ScriptMethod WaitForExit { param($Milliseconds) if ($null -ne $Milliseconds) { return $false } }
                $process | Add-Member ScriptMethod Kill { $this.HasExited = $true }
                $process | Add-Member ScriptMethod Dispose {}
                return $process
            }
            $files = @('tools/tests/A.Tests.ps1', 'tools/tests/B.Tests.ps1')
            $result = Invoke-LocalCiPester -RepositoryRoot $root -Path $files -ShardCount 2 -WorkerSlots $parallelSlots -TempPath (Join-Path $root 'scratch')

            $result.ExitCode | Should -Be 1
            $result.Shards.Seconds | Should -BeExactly @(1.5, $(if ($Case -eq 'completed after deadline') { 901 } else { 1.5 }))
            ($result.Output -join "`n") | Should -Match $Message
            @($result.Shards | Where-Object ExitCode -EQ 0).Count | Should -Be $(if ($Case -eq 'missing XML') { 2 } else { 1 })
            foreach ($shard in $result.Shards) { Test-Path $shard.LogPath | Should -BeTrue }
            $behavior.Mode = 'success'

            $retry = Invoke-LocalCiPester -RepositoryRoot $root -Path $files -ShardCount 2 -WorkerSlots $parallelSlots -TempPath (Join-Path $root 'scratch')
            $retry.ExitCode | Should -Be 0 -Because ($retry.Output -join "`n")
            $retry.Shards.OverheadSeconds | Should -BeExactly @(0.25, 0.25)
            $retry.Shards[0].ResultPath | Should -Not -Be $result.Shards[0].ResultPath
        }

        It 'terminates a real sleeping child at the timeout boundary' {
            Set-Content (Join-Path $root 'tools/Invoke-Tests.ps1') 'param([switch] $CI, [string[]] $Path, [string] $ResultPath); Start-Sleep -Seconds 30'

            $result = Invoke-LocalCiPester -RepositoryRoot $root -Path 'tools/tests/A.Tests.ps1' -ShardCount 1 -TempPath (Join-Path $root 'scratch') -TimeoutSeconds 1

            $result.ExitCode | Should -Be 1
            ($result.Output -join "`n") | Should -Match 'timed out'
            $result.Shards[0].Seconds | Should -BeGreaterThan 0
            Test-Path (Join-Path $root 'artifacts/pester.xml') | Should -BeFalse
        }

            It 'clears an older success even if selection fails before a child starts' {
                $null = New-Item -ItemType Directory -Force -Path (Join-Path $root 'artifacts')
                $old = Join-Path $root 'artifacts/pester.xml'
                Set-Content $old 'Stale success'

                $result = Invoke-LocalCiPester -RepositoryRoot $root -Path 'tools/tests/Missing.Tests.ps1' -ShardCount 2 -WorkerSlots $parallelSlots -TempPath (Join-Path $root 'scratch')

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
