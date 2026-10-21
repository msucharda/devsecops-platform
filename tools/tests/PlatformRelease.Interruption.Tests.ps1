BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    # The stub of Publish-PlatformRelease.ps1 lives in PlatformRelease.Tests.ps1. The harness reuses its
    # BeforeAll and first BeforeEach blocks, so stub changes for new API calls apply here too.
    $stubFile = Join-Path $PSScriptRoot 'PlatformRelease.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlocks = @{}
    foreach ($command in $stubAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -cin @('BeforeAll', 'BeforeEach') -and -not $stubBlocks.ContainsKey($name) -and
            $command.CommandElements.Count -eq 2 -and $command.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
            $stubBlocks[$name] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
    }
    foreach ($name in @('BeforeAll', 'BeforeEach')) {
        if (-not $stubBlocks.ContainsKey($name)) { throw "$stubFile has no $name block for the release stub." }
    }
    . $stubBlocks.BeforeAll
}

Describe 'Platform release interruption harness' -Tag 'Interruption' {
    BeforeEach {
        . $stubBlocks.BeforeEach
        $plan = Get-InterruptionPlan
        Mock Invoke-WebRequest {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            $Method = $Method.ToUpperInvariant()
            if ($Method -eq 'GET') { return & $cloudTransport -Uri $Uri -Method $Method -Body $Body }
            # Draft releases of one tag do not conflict, so a repeated creation is a duplicate. A repeated asset
            # upload with the same name is rejected with 422 by the stub as by the documented API.
            $identity = if ($Method -eq 'POST' -and $Uri.AbsolutePath -like '*/releases') { 'release v1.2.0' }
            elseif ($Method -eq 'POST') { "asset $([Web.HttpUtility]::ParseQueryString($Uri.Query)['name'])" }
            else { '' }
            Invoke-InterruptionStep -Plan $plan -Request "$Method $($Uri.AbsolutePath)" -Identity $identity -Apply {
                & $cloudTransport -Uri $Uri -Method $Method -Body $Body
            } -Interrupt {
                [pscustomobject] @{ StatusCode = 503; Content = '{"message":"Injected interruption."}' }
            }
        }
        $reset = {
            $cloud.releases.Clear()
            $cloud.nextId = 10
        }
        # The tool keeps no local state; recovery relies only on the release list of the repository.
        $captureLocal = { $null }
        $restoreLocal = { param($Text) $null = $Text }
        $snapshot = {
            @{
                releases = @(foreach ($release in $cloud.releases) {
                        @{
                            tag = $release.tag_name; draft = $release.draft; prerelease = $release.prerelease; commit = $release.target_commitish
                            latest = if ($release.Contains('make_latest')) { $release.make_latest } else { $null }
                            assets = @(foreach ($item in $release.assets) { @{ name = $item.name; state = $item.state; digest = $item.digest } })
                        }
                    })
            }
        }
        $run = { $null = & $publish @arguments 6>$null }
    }

    It 'recovers from an interruption at every mutating step of a new release' {
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Publish-PlatformRelease.ps1' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'recovers from an interruption at every mutating step of a resumed draft with a stale asset' {
        $reset = {
            $cloud.releases.Clear()
            $cloud.nextId = 10
            $release = & $newRelease @{ tag_name = 'v1.2.0'; draft = $true; prerelease = $false; target_commitish = $commit; name = 'v1.2.0' }
            $release.assets.Add((& $newAsset 'platform-v1.2.0.zip' ('sha256:' + '0' * 64)))
            $cloud.releases.Add($release)
        }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Publish-PlatformRelease.ps1 (resumed draft)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
