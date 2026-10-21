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
}

Describe 'Interruption harness' {
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
}
