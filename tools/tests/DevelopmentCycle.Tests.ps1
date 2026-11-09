BeforeAll {
    $tools = Split-Path $PSScriptRoot -Parent
    $validate = Join-Path $tools 'Test-DevelopmentCycle.ps1'
}

Describe 'Private development cycle evidence' {
    BeforeEach {
        $path = Join-Path $TestDrive 'cycle.json'
        $record = @{
            version = 1; state = 'completed'
            candidate = @{
                baselineRelease = 'v1.2.3'; baseRevision = 'a' * 40; revision = 'b' * 40; digest = 'c' * 64
                pullRequest = 'https://example.test/instance/pull/42'; change = 'A specified control change'
                approvalUrl = 'https://example.test/instance/pull/42#approval'; approvedBy = 'reviewer'
            }
            verificationPlan = @{
                bootstrap = $false; teardown = $false; recovery = $false; acceptanceMilestone = $false
                rationale = 'Only the changed control; destructive acceptance remains separate.'
            }
            readyAt = '2026-01-01T10:00:00.0000000+00:00'
            firstLive = @{
                at = '2026-01-01T10:10:00.0000000+00:00'; revision = 'b' * 40; digest = 'c' * 64
                result = 'passed'; evidenceUrl = 'https://example.test/instance/actions/runs/1'
            }
            standardRelease = @{
                verifiedAt = '2026-01-01T10:30:00.0000000+00:00'; tag = 'v1.2.4'
                platformRevision = 'd' * 40; instanceRevision = 'e' * 40
                sourcePullRequest = 'https://example.test/platform/pull/43'
                importPullRequest = 'https://example.test/instance/pull/44'
                evidenceUrl = 'https://example.test/instance/actions/runs/2'
                scenarios = @{
                    functional = @{ result = 'passed'; scenario = 'Changed capability'; expected = 'enabled'; actual = 'enabled'; evidenceUrl = 'https://example.test/evidence/1' }
                    forbidden = @{ result = 'passed'; scenario = 'Forbidden operation'; expected = 'denied'; actual = 'denied'; evidenceUrl = 'https://example.test/evidence/2' }
                    idempotence = @{ result = 'passed'; scenario = 'Repeated apply'; expected = 'zero changes'; actual = 'zero changes'; changes = 0; evidenceUrl = 'https://example.test/evidence/3' }
                    drift = @{ result = 'passed'; scenario = 'Compare expected state'; expected = 'no unexpected drift'; actual = 'no unexpected drift'; unexpectedDrift = $false; evidenceUrl = 'https://example.test/evidence/4' }
                }
            }
            observedUntil = '2026-01-01T10:30:00.0000000+00:00'
            dispositionEvidenceUrl = 'https://example.test/approval/adopt'
            approvalRemovedAt = '2026-01-01T10:30:00.0000000+00:00'
            intervals = @(
                @{ kind = 'work'; start = '2026-01-01T10:00:00.0000000+00:00'; end = '2026-01-01T10:03:00.0000000+00:00' }
                @{ kind = 'ci'; start = '2026-01-01T10:03:00.0000000+00:00'; end = '2026-01-01T10:07:00.0000000+00:00' }
                @{ kind = 'humanWait'; start = '2026-01-01T10:07:00.0000000+00:00'; end = '2026-01-01T10:10:00.0000000+00:00' }
                @{ kind = 'work'; start = '2026-01-01T10:10:00.0000000+00:00'; end = '2026-01-01T10:20:00.0000000+00:00' }
                @{ kind = 'ci'; start = '2026-01-01T10:20:00.0000000+00:00'; end = '2026-01-01T10:28:00.0000000+00:00' }
                @{ kind = 'humanWait'; start = '2026-01-01T10:28:00.0000000+00:00'; end = '2026-01-01T10:30:00.0000000+00:00' }
            )
        }
    }

    It 'measures both actual legs and separates work, CI and human waiting without claiming independent live verification' {
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        $result = & $validate -RecordPath $path -RequireComplete
        $result.EvidenceComplete | Should -BeTrue
        $result.ReadyToLiveSeconds | Should -Be 600
        $result.LiveToReleaseSeconds | Should -Be 1200
        $result.BreakdownSeconds.readyToLive.work | Should -Be 180
        $result.BreakdownSeconds.readyToLive.ci | Should -Be 240
        $result.BreakdownSeconds.readyToLive.humanWait | Should -Be 180
        $result.BreakdownSeconds.liveToRelease.work | Should -Be 600
        $result.BreakdownSeconds.liveToRelease.ci | Should -Be 480
        $result.BreakdownSeconds.liveToRelease.humanWait | Should -Be 120
        $result.EvidenceQualification | Should -Match 'reported, not independently verified'
    }

    It 'keeps <State> or missing release evidence incomplete' -ForEach @(
        @{ State = 'inProgress' }
        @{ State = 'interrupted' }
        @{ State = 'reverted' }
    ) {
        $record.state = $State
        if ($State -ceq 'reverted') { $record.reversionEvidenceUrl = 'https://example.test/instance/actions/runs/3' }
        $record.standardRelease = $null
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        $result = & $validate -RecordPath $path
        $result.EvidenceComplete | Should -BeFalse
        $result.LiveToReleaseSeconds | Should -BeNullOrEmpty
        { & $validate -RecordPath $path -RequireComplete } | Should -Throw '*not complete*'
    }

    It 'retains a failed first result and its measurement in an interrupted cycle' {
        $record.state = 'interrupted'
        $record.firstLive.result = 'failed'
        $record.standardRelease = $null
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        $result = & $validate -RecordPath $path
        $result.EvidenceComplete | Should -BeFalse
        $result.FirstLiveResult | Should -Be 'failed'
        $result.ReadyToLiveSeconds | Should -Be 600
        $result.Missing | Should -Contain 'successfulLive'
        { & $validate -RecordPath $path -RequireComplete } | Should -Throw '*not complete*'
    }

    It 'requires later successful verification without rewriting the first failed milestone' {
        $record.firstLive.result = 'failed'
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        { & $validate -RecordPath $path -RequireComplete } | Should -Throw '*successful live verification*'
        $record.successfulLive = $record.firstLive.Clone()
        $record.successfulLive.result = 'passed'
        $record.successfulLive.at = '2026-01-01T10:20:00.0000000+00:00'
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        $result = & $validate -RecordPath $path -RequireComplete
        $result.EvidenceComplete | Should -BeTrue
        $result.FirstLiveResult | Should -Be 'failed'
        $result.ReadyToLiveSeconds | Should -Be 600
        $result.LiveToReleaseSeconds | Should -Be 1200
        $record.successfulLive.result = 'failed'
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        { & $validate -RecordPath $path } | Should -Throw '*must be passed*'
    }

    It 'rejects <Case> rather than inventing successful measurements' -ForEach @(
        @{ Case = 'a gap'; Change = { $record.intervals[1].start = '2026-01-01T10:04:00.0000000+00:00' }; Error = '*gaps or overlaps*' }
        @{ Case = 'an overlap'; Change = { $record.intervals[1].start = '2026-01-01T10:02:00.0000000+00:00' }; Error = '*gaps or overlaps*' }
        @{ Case = 'unmeasured time'; Change = { $record.intervals = $record.intervals[0..4] }; Error = '*cover observedUntil*' }
        @{ Case = 'reversed milestones'; Change = { $record.firstLive.at = '2025-01-01T10:00:00.0000000+00:00' }; Error = '*precedes*' }
        @{ Case = 'different live candidate'; Change = { $record.firstLive.revision = 'f' * 40 }; Error = '*exact candidate*' }
        @{ Case = 'different live digest'; Change = { $record.firstLive.digest = 'f' * 64 }; Error = '*exact candidate*' }
        @{ Case = 'unknown live result'; Change = { $record.firstLive.result = 'unknown' }; Error = '*observed passed or failed*' }
        @{ Case = 'unobserved future live result'; Change = {
            $record.state = 'interrupted'; $record.standardRelease = $null
            $record.firstLive.at = '2026-01-01T10:40:00.0000000+00:00'
        }; Error = '*observedUntil precedes*' }
        @{ Case = 'baseline release relabeled as adoption'; Change = { $record.standardRelease.tag = $record.candidate.baselineRelease }; Error = '*new release and instance revision*' }
        @{ Case = 'candidate relabeled as adoption'; Change = { $record.standardRelease.instanceRevision = $record.candidate.revision }; Error = '*new release and instance revision*' }
        @{ Case = 'baseline main relabeled as adoption'; Change = { $record.standardRelease.instanceRevision = $record.candidate.baseRevision }; Error = '*new release and instance revision*' }
        @{ Case = 'premature approval removal'; Change = { $record.approvalRemovedAt = '2026-01-01T10:20:00.0000000+00:00' }; Error = '*only after standard release verification*' }
        @{ Case = 'unexpected drift'; Change = { $record.standardRelease.scenarios.drift.unexpectedDrift = $true }; Error = '*Unexpected drift*' }
        @{ Case = 'non-idempotent apply'; Change = { $record.standardRelease.scenarios.idempotence.changes = 1 }; Error = '*zero changes*' }
        @{ Case = 'unassessed teardown'; Change = { $record.verificationPlan.Remove('teardown') }; Error = '*impact decision*' }
        @{ Case = 'unapproved destructive acceptance'; Change = {
            $record.verificationPlan.teardown = $true
            $record.verificationPlan.destructiveScenario = 'Rebuild acceptance'
            $record.verificationPlan.destructiveStatus = 'passed'
        }; Error = '*destructiveApprovalUrl*' }
    ) {
        . $Change
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        { & $validate -RecordPath $path -RequireComplete } | Should -Throw $Error
    }

    It 'requires a scalar JSON integer for the zero-change result: <Case>' -ForEach @(
        foreach ($value in @($null, @(), @(0), $false, $true, '0', 0.0, @{ value = 0 })) {
            @{ Case = (ConvertTo-Json -InputObject $value -Compress); InvalidChanges = $value }
        }
    ) {
        $record.standardRelease.scenarios.idempotence.changes = $InvalidChanges
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        { & $validate -RecordPath $path -RequireComplete } | Should -Throw '*zero changes*'
    }

    It 'requires a reason for a not-applicable scenario and preserves deferred destructive verification' {
        $record.standardRelease.scenarios.forbidden = @{ result = 'notApplicable'; reason = 'No authorization control changed.' }
        $record.verificationPlan.recovery = $true
        $record.verificationPlan.destructiveScenario = 'Separate recovery milestone'
        $record.verificationPlan.destructiveStatus = 'unverified'
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        $result = & $validate -RecordPath $path -RequireComplete
        $result.DestructiveVerification | Should -Be 'unverified'
        $record.standardRelease.scenarios.forbidden.Remove('reason')
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        { & $validate -RecordPath $path } | Should -Throw '*reason*'
    }

    It 'does not finish an experiment without its prior scope, changed objects and codification or rollback' {
        $record.experiments = @(@{
            kind = 'API'; approvalUrl = 'https://example.test/approval/1'; objects = @('organization/control/1')
            originalState = 'disabled'; actual = 'enabled'; evidenceUrl = 'https://example.test/run/1'
            disposition = 'pending'
        })
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        (& $validate -RecordPath $path).EvidenceComplete | Should -BeFalse
        { & $validate -RecordPath $path -RequireComplete } | Should -Throw '*experiment.disposition*'
        $record.experiments[0].disposition = 'codified'
        $record.experiments[0].dispositionEvidenceUrl = 'https://example.test/source/pull/42'
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        (& $validate -RecordPath $path -RequireComplete).EvidenceComplete | Should -BeTrue
        $record.experiments[0].Remove('approvalUrl')
        $record | ConvertTo-Json -Depth 20 | Set-Content $path
        { & $validate -RecordPath $path } | Should -Throw '*experiment.approvalUrl*'
    }
}
