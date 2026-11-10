BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force

    $plan = Get-InterruptionPlan
    $remote = @{ Items = [System.Collections.Generic.List[string]]::new() }
    $statePath = Join-Path $TestDrive 'state.json'
    $reset = {
        $remote.Items.Clear()
        if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
    }
    $captureLocal = { if (Test-Path -LiteralPath $statePath) { [IO.File]::ReadAllText($statePath) } }
    $restoreLocal = {
        param($Text)
        if (Test-Path -LiteralPath $statePath) { Remove-Item -LiteralPath $statePath }
        if ($null -ne $Text) { [IO.File]::WriteAllText($statePath, $Text) }
    }
    $snapshot = { @{ items = @($remote.Items) } }

    # A toy tool that creates one item; the create API does not reject duplicates. A pending intent makes the rerun
    # look the item up instead of creating it again. SaveIntentFirst decides whether the intent is saved before the
    # request or only in the finally block.
    function Invoke-ToyTool {
        param([switch] $SaveIntentFirst)

        $state = if (Test-Path -LiteralPath $statePath) { Get-Content -LiteralPath $statePath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
        try {
            if ($state['done']) { return }
            if ($state['pending'] -and $remote.Items.Contains('item')) { $state['done'] = $true; return }
            $state['pending'] = $true
            if ($SaveIntentFirst) { ConvertTo-Json $state | Set-Content -LiteralPath $statePath }
            $response = Invoke-InterruptionStep -Plan $plan -Request 'POST /items' -Identity 'item' -Apply {
                $remote.Items.Add('item')
                [pscustomobject]@{ StatusCode = 201 }
            } -Interrupt { [pscustomobject]@{ StatusCode = 503 } }
            if ($response.StatusCode -ne 201) { throw "HTTP $($response.StatusCode)" }
            $state['done'] = $true
        }
        finally {
            ConvertTo-Json $state | Set-Content -LiteralPath $statePath
        }
    }

    function Invoke-ToyPutSequence {
        param([int] $StepCount)

        for ($stepIndex = 0; $stepIndex -lt $StepCount; $stepIndex++) {
            $item = "item-$stepIndex"
            $response = Invoke-InterruptionStep -Plan $plan -Request "PUT /items/$item" -Apply {
                if (-not $remote.Items.Contains($item)) { $remote.Items.Add($item) }
                [pscustomobject]@{ StatusCode = 200 }
            } -Interrupt { [pscustomobject]@{ StatusCode = 503 } }
            if ($response.StatusCode -ne 200) { throw "HTTP $($response.StatusCode)" }
        }
    }
}

Describe 'Interruption harness' {
    It 'dispatches nested script requests through scoped transports without Pester call-history overhead' {
        $nested = Join-Path $TestDrive 'nested.ps1'
        Set-Content -LiteralPath $nested -Value @'
param($Address)
Invoke-RestMethod -Uri $Address -Method POST -Headers @{ test = 'rest' } -Body '{"value":1}' -ContentType application/json -MaximumRetryCount 0 -MaximumRedirection 0 -TimeoutSec 60
'@
        $entry = Join-Path $TestDrive 'entry.ps1'
        Set-Content -LiteralPath $entry -Value @'
param($Address, $Nested)
Invoke-WebRequest -Uri $Address -Method PUT -Headers @{ test = 'web' } -Body '{"value":2}' -ContentType application/json -SkipHttpErrorCheck -MaximumRetryCount 0 -MaximumRedirection 0 -TimeoutSec 60
& $Nested -Address $Address
gh fixture-argument
'@
        Mock Invoke-WebRequest { throw 'Unexpected Pester web dispatcher.' }
        Mock Invoke-RestMethod { throw 'Unexpected Pester REST dispatcher.' }
        $calls = [Collections.Generic.List[string]]::new()
        $web = {
            param($Uri, $Method, $Headers, $Body)
            $calls.Add("$Method $Uri $($Headers.test) $Body")
            'web-result'
        }
        $rest = {
            param($Uri, $Method, $Headers, $Body)
            $calls.Add("$Method $Uri $($Headers.test) $Body")
            'rest-result'
        }

        $result = @(Invoke-InterruptionScript -Path $entry -Arguments @{ Address = 'https://offline.invalid/app'; Nested = $nested } `
                -WebRequest $web -RestMethod $rest -Command @{ gh = { "cli-result:$($args -join ',')" } })

        $result | Should -BeExactly @('web-result', 'rest-result', 'cli-result:fixture-argument')
        $calls.ToArray() | Should -BeExactly @(
            'PUT https://offline.invalid/app web {"value":2}'
            'POST https://offline.invalid/app rest {"value":1}'
        )
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
        { Invoke-WebRequest -Uri 'https://offline.invalid/app' } | Should -Throw '*Unexpected Pester web dispatcher*'
        { Invoke-RestMethod -Uri 'https://offline.invalid/app' } | Should -Throw '*Unexpected Pester REST dispatcher*'
    }

    It 'propagates transport failures rather than returning a successful script result' {
        $entry = Join-Path $TestDrive 'failed-transport.ps1'
        Set-Content -LiteralPath $entry -Value "Invoke-WebRequest -Uri 'https://offline.invalid/app'; 'must not succeed'"

        { Invoke-InterruptionScript -Path $entry -Arguments @{} -WebRequest { throw 'Injected transport failure.' } `
                -RestMethod { throw 'Unexpected REST request.' } } | Should -Throw '*Injected transport failure*'
    }

    It 'preserves supplied nested script defaults without changing caller defaults' {
        $nested = Join-Path $TestDrive 'nested-default.ps1'
        Set-Content -LiteralPath $nested -Value "[CmdletBinding()] param([string] `$StatePath = 'unexpected-user-state'); `$StatePath"
        $entry = Join-Path $TestDrive 'entry-default.ps1'
        Set-Content -LiteralPath $entry -Value 'param($Nested); & $Nested'
        $defaults = @{ 'nested-default.ps1:StatePath' = (Join-Path $TestDrive 'pending.json') }
        $saved = $PSDefaultParameterValues

        $result = Invoke-InterruptionScript -Path $entry -Arguments @{ Nested = $nested } `
            -WebRequest { throw 'Unexpected web request.' } -RestMethod { throw 'Unexpected REST request.' } `
            -DefaultParameterValues $defaults

        $result | Should -BeExactly $defaults['nested-default.ps1:StatePath']
        $PSDefaultParameterValues | Should -Be $saved
        $defaults.Count | Should -Be 1
    }

    It 'rejects unsupported cmdlet parameters before dispatching a request' {
        $entry = Join-Path $TestDrive 'invalid-parameters.ps1'
        Set-Content -LiteralPath $entry -Value "Invoke-WebRequest -Uri 'https://offline.invalid/app' -UnsupportedParameter value"
        $observed = @{ Dispatched = $false }

        { Invoke-InterruptionScript -Path $entry -Arguments @{} -WebRequest { $observed.Dispatched = $true } `
                -RestMethod { throw 'Unexpected REST request.' } } | Should -Throw '*UnsupportedParameter*'
        $observed.Dispatched | Should -BeFalse
    }

    It 'reports a duplicate after an abrupt stop when the tool saves its intent only in a finally block' {
        $run = { Invoke-ToyTool }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal)

        @($result | Where-Object { $_.Stop -eq 'Error' -and -not $_.Passed }).Count | Should -Be 0
        $abrupt = @($result | Where-Object { $_.Stop -eq 'Abrupt' -and $_.Kind -eq 'LoseResponse' })
        $abrupt.Count | Should -Be 1
        $abrupt[0].Passed | Should -BeFalse
        $abrupt[0].Problem | Should -BeLike '*duplicate creations: item (2x, reference 1x)*'
    }

    It 'passes every stop when the tool saves its intent before the request' {
        $run = { Invoke-ToyTool -SaveIntentFirst }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal)

        $result.Count | Should -Be 4
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0
    }

    It 'restores the local state captured at the injection boundary after an abrupt stop' {
        $run = { Invoke-ToyTool }
        $observed = @{}

        $null = Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal -Kind BeforeApply -Stop Abrupt -Recover {
            param($InterruptedError)
            $null = $InterruptedError
            $observed.State = if (Test-Path -LiteralPath $statePath) { [IO.File]::ReadAllText($statePath) } else { '<none>' }
            Invoke-ToyTool
        }

        $observed.State | Should -BeExactly '<none>'
    }

    It 'partitions all stop/kind cases exactly once: <StepCount> steps, interruption-based <ByInterruption>' -ForEach @(
        @{ StepCount = 1; ByInterruption = $false; Counts = @(4, 0, 0, 0) }
        @{ StepCount = 1; ByInterruption = $true; Counts = @(1, 1, 1, 1) }
        @{ StepCount = 2; ByInterruption = $false; Counts = @(4, 4, 0, 0) }
        @{ StepCount = 2; ByInterruption = $true; Counts = @(2, 2, 2, 2) }
        @{ StepCount = 3; ByInterruption = $false; Counts = @(4, 4, 4, 0) }
        @{ StepCount = 3; ByInterruption = $true; Counts = @(3, 3, 3, 3) }
    ) {
        $run = { Invoke-ToyPutSequence -StepCount $StepCount }
        $reference = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal)
        $combined = [Collections.Generic.List[object]]::new()
        foreach ($shardIndex in 0..3) {
            $selection = @{ ShardIndex = $shardIndex; ShardCount = 4 }
            if ($ByInterruption) { $selection.ShardByInterruption = $true }
            $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @selection)
            $result.Count | Should -Be $Counts[$shardIndex]
            foreach ($item in $result) { $combined.Add($item) }
        }

        $combined.Count | Should -Be ($StepCount * 4)
        @($combined | Where-Object { -not $_.Passed }).Count | Should -Be 0
        @($combined | Group-Object Step, Kind, Stop | Where-Object Count -NE 1).Count | Should -Be 0
        $labels = { process { "$($_.Step):$($_.Kind):$($_.Stop)" } }
        ($combined | & $labels | Sort-Object) -join ',' | Should -BeExactly (($reference | & $labels | Sort-Object) -join ',')
    }
}
