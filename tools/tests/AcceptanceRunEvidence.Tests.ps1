BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    Import-Module (Join-Path $repoRoot 'tools/InstanceSetup.psm1') -Force

    function New-TestEvidence {
        param([Parameter(Mandatory)][string] $Phase)

        $alias = @{ plan = 'reader'; apply = 'writer'; rulesetPlan = 'rulesets'; wrongSubject = $null }[$Phase]
        $checks = switch ($Phase) {
            wrongSubject { @{ wrongSubjectRejected = $true } }
            rulesetPlan { @{ rulesetBypassRead = $true; phaseIdentityVerified = $true; otherModuleStateDenied = $true } }
            default { @{ organizationApisRead = $true; phaseIdentityVerified = $true; otherModuleStateDenied = $true } }
        }
        $record = @{
            version = 1; passed = $true; phase = $Phase; revision = 'abc123def'; runId = '123'; runAttempt = '2'
            authorizationFingerprint = 'SHA256:authorizationKey'; checks = $checks
        }
        if ($alias) { $record.keyFingerprint = "SHA256:${alias}Key" }
        return $record
    }

    function Invoke-TestEvidence {
        param([string[]] $Phases = @('plan', 'rulesetPlan', 'wrongSubject', 'apply'))

        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory
        @{
            reader = @{ fingerprint = 'SHA256:readerKey' }; writer = @{ fingerprint = 'SHA256:writerKey' }
            rulesets = @{ fingerprint = 'SHA256:rulesetsKey' }; authorization = @{ fingerprint = 'SHA256:authorizationKey' }
        } | ConvertTo-Json -Depth 5 | Set-Content -LiteralPath (Join-Path $directory 'keys.json')
        $setup = @{
            Acceptance = @{ directory = $directory; repository = 'acceptance-org/acceptance' }
            Settings = @{ githubHost = 'example.ghe.com' }
        }
        $run = @{ id = 123; run_attempt = 2; head_sha = 'abc123def' }
        InModuleScope InstanceSetup -Parameters @{ Setup = $setup; Run = $run; Phases = $Phases } {
            param($Setup, $Run, $Phases)
            Test-SetupAcceptanceRunEvidence -Setup $Setup -Run $Run -Phases $Phases
        }
        return $directory
    }
}

Describe 'Acceptance run evidence' {
    BeforeEach {
        $global:TestEvidence = @{}
        foreach ($name in @('plan', 'rulesetPlan', 'wrongSubject', 'apply')) { $global:TestEvidence[$name] = New-TestEvidence -Phase $name }
        $global:TestDownloadExitCode = 0
        Mock gh -ModuleName InstanceSetup {
            $target = $args[[array]::IndexOf($args, '--dir') + 1]
            foreach ($phase in $global:TestEvidence.Keys) {
                if ($null -eq $global:TestEvidence[$phase]) { continue }
                $folder = Join-Path $target "bootstrap-acceptance-$phase"
                $null = New-Item -ItemType Directory -Path $folder -Force
                ConvertTo-Json -InputObject $global:TestEvidence[$phase] -Depth 10 | Set-Content -LiteralPath (Join-Path $folder 'result.json')
            }
            $global:LASTEXITCODE = $global:TestDownloadExitCode
        }
    }

    AfterAll {
        Remove-Variable -Name TestEvidence, TestDownloadExitCode -Scope Global -ErrorAction SilentlyContinue
    }

    It 'stores the evidence of every phase of the successful run' {
        $directory = Invoke-TestEvidence

        foreach ($phase in @('plan', 'rulesetPlan', 'wrongSubject', 'apply')) {
            $stored = Get-Content (Join-Path $directory "evidence/123-2/bootstrap-acceptance-$phase/result.json") -Raw | ConvertFrom-Json -AsHashtable
            $stored.phase | Should -BeExactly $phase
        }
        Should -Invoke gh -ModuleName InstanceSetup -Times 1 -Exactly -ParameterFilter {
            $args -contains 'https://example.ghe.com/acceptance-org/acceptance' -and $args -contains '123'
        }
    }

    It 'accepts the requested subset of phases' {
        $global:TestEvidence.apply = $null

        $directory = Invoke-TestEvidence -Phases plan, rulesetPlan, wrongSubject

        Test-Path (Join-Path $directory 'evidence/123-2/bootstrap-acceptance-apply') | Should -BeFalse
    }

    It 'rejects a failed evidence download' {
        $global:TestDownloadExitCode = 1

        { Invoke-TestEvidence } | Should -Throw '*Downloading acceptance evidence failed*'
    }

    It 'rejects missing evidence of a phase' {
        $global:TestEvidence.rulesetPlan = $null

        { Invoke-TestEvidence } | Should -Throw '*no evidence for rulesetPlan*'
    }

    It 'rejects <Phase> evidence with <Case>' -ForEach @(
        @{ Phase = 'plan'; Case = 'another version'; Field = 'version'; Value = 2 }
        @{ Phase = 'plan'; Case = 'a string passed flag'; Field = 'passed'; Value = 'true' }
        @{ Phase = 'plan'; Case = 'a false passed flag'; Field = 'passed'; Value = $false }
        @{ Phase = 'plan'; Case = 'no passed flag'; Field = 'passed'; Value = $null }
        @{ Phase = 'plan'; Case = 'another phase'; Field = 'phase'; Value = 'apply' }
        @{ Phase = 'plan'; Case = 'a phase in another case'; Field = 'phase'; Value = 'PLAN' }
        @{ Phase = 'plan'; Case = 'another revision'; Field = 'revision'; Value = 'fff123def' }
        @{ Phase = 'plan'; Case = 'a revision in another case'; Field = 'revision'; Value = 'ABC123DEF' }
        @{ Phase = 'plan'; Case = 'another run'; Field = 'runId'; Value = '124' }
        @{ Phase = 'plan'; Case = 'another run attempt'; Field = 'runAttempt'; Value = '1' }
        @{ Phase = 'wrongSubject'; Case = 'another version'; Field = 'version'; Value = 2 }
    ) {
        $global:TestEvidence[$Phase][$Field] = $Value

        { Invoke-TestEvidence } | Should -Throw "*$Phase evidence does not belong to this successful immutable run*"
    }

    It 'rejects <Phase> evidence with <Case>' -ForEach @(
        @{ Phase = 'plan'; Case = 'another phase key'; Field = 'keyFingerprint'; Value = 'SHA256:writerKey' }
        @{ Phase = 'apply'; Case = 'a phase key in another case'; Field = 'keyFingerprint'; Value = 'SHA256:WRITERKEY' }
        @{ Phase = 'rulesetPlan'; Case = 'another authorization key'; Field = 'authorizationFingerprint'; Value = 'SHA256:otherKey' }
        @{ Phase = 'plan'; Case = 'an authorization key in another case'; Field = 'authorizationFingerprint'; Value = 'SHA256:AUTHORIZATIONKEY' }
    ) {
        $global:TestEvidence[$Phase][$Field] = $Value

        { Invoke-TestEvidence } | Should -Throw "*$Phase evidence tested another App key*"
    }

    It 'rejects <Phase> evidence when <Check> is <Case>' -ForEach @(
        @{ Phase = 'plan'; Check = 'organizationApisRead'; Case = 'false'; Value = $false }
        @{ Phase = 'apply'; Check = 'phaseIdentityVerified'; Case = 'a string'; Value = 'true' }
        @{ Phase = 'rulesetPlan'; Check = 'rulesetBypassRead'; Case = 'missing'; Value = $null }
        @{ Phase = 'rulesetPlan'; Check = 'otherModuleStateDenied'; Case = 'false'; Value = $false }
        @{ Phase = 'wrongSubject'; Check = 'wrongSubjectRejected'; Case = 'false'; Value = $false }
    ) {
        if ($null -eq $Value) { $global:TestEvidence[$Phase].checks.Remove($Check) }
        else { $global:TestEvidence[$Phase].checks[$Check] = $Value }

        { Invoke-TestEvidence } | Should -Throw "*$Phase evidence did not verify $Check*"
    }
}
