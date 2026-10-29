BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $tools = Split-Path $PSScriptRoot -Parent
    $pwsh = Join-Path $PSHOME $(if ($IsWindows) { 'pwsh.exe' } else { 'pwsh' })
    $driver = Join-Path $TestDrive 'issuer-process.ps1'
    $keyPath = Join-Path $TestDrive 'offline-test-key.pem'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    [IO.File]::WriteAllText($keyPath, $rsa.ExportRSAPrivateKeyPem())
    $rsa.Dispose()
    [IO.File]::WriteAllText($driver, @'
param($Tools, $KeyPath, $StatePath, $CloudPath, $FailureKind, $Stop, [switch] $Inject)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $Tools 'tests/GitHubApiFixture.psm1')
$cloud = [IO.File]::ReadAllText($CloudPath) | ConvertFrom-Json -AsHashtable
$multiple = $FailureKind -in @('BeforeIntentReplacement', 'AfterIntentReplacement')
function Save-Cloud { [IO.File]::WriteAllText($CloudPath, ($cloud | ConvertTo-Json -Compress)) }
function Stop-Issuance {
    if ($Stop -ceq 'Abrupt') { [Environment]::Exit(91) }
    throw 'Injected token issuance interruption.'
}
function Invoke-RestMethod {
    param($Uri, $Method, $Headers, $Body, $MaximumRedirection, $TimeoutSec, $MaximumRetryCount, $ContentType)
    if ($Uri -eq 'https://api.example.test/app') {
        return Get-GitHubApiFixture -Name apps/get-app.owner-enterprise -Set @{
            id = 101; 'owner.slug' = 'example'; permissions = @{ members = 'read' }
        }
    }
    if ($Uri -like '*/app/installations`?*') {
        $first = Get-GitHubApiFixture -Name apps/list-installations -Set @{
            '0.id' = 201; '0.account.login' = 'platform'; '0.target_type' = 'Organization'
            '0.permissions' = @{ members = 'read' }; '0.suspended_at' = $null
        }
        if ($multiple) {
            $second = Get-GitHubApiFixture -Name apps/list-installations -Set @{
                '0.id' = 202; '0.account.login' = 'platform-two'; '0.target_type' = 'Organization'
                '0.permissions' = @{ members = 'read' }; '0.suspended_at' = $null
            }
            return ,@($first[0], $second[0])
        }
        return ,$first
    }
    if ($Uri -like '*/access_tokens') {
        if ($Inject -and $FailureKind -ceq 'AfterIntentReplacement' -and $cloud.Posts -eq 1) { Stop-Issuance }
        $cloud.Posts++
        $cloud.IntentIds += @(([IO.File]::ReadAllText($StatePath) | ConvertFrom-Json -AsHashtable).intentId)
        Save-Cloud
        if ($Inject -and $FailureKind -ceq 'BeforeApply') { Stop-Issuance }
        $cloud.Issued++
        $cloud.Active++
        Save-Cloud
        if ($Inject -and $FailureKind -ceq 'LoseResponse') { Stop-Issuance }
        return Get-GitHubApiFixture -Name apps/create-installation-access-token -Set @{
            token = "offline-token-$($cloud.Issued)"; permissions = @{ members = 'read' }
        }
    }
    if ($Uri -like '*/installation/repositories`?*') {
        return Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{ total_count = 0; repositories = @() }
    }
    if ($Uri -like '*/orgs/*/teams`?*') { return Get-GitHubApiFixture -Name teams/list-teams }
    if ($Uri -like '*/installation/token' -and $Method -ceq 'DELETE') {
        if ($Inject -and $FailureKind -ceq 'RevocationBeforeApply') { Stop-Issuance }
        $cloud.Revoked++
        $cloud.Active--
        Save-Cloud
        if ($Inject -and $FailureKind -ceq 'RevocationLoseResponse') { Stop-Issuance }
        return
    }
    throw "Unexpected offline request: $Method $Uri"
}
function Invoke-WebRequest {
    param($Uri, $Method, $Headers, $MaximumRedirection, $TimeoutSec, $MaximumRetryCount, [switch] $SkipHttpErrorCheck)
    $null = Invoke-RestMethod -Uri $Uri -Method $Method -Headers $Headers -MaximumRedirection $MaximumRedirection `
        -TimeoutSec $TimeoutSec -MaximumRetryCount $MaximumRetryCount
    [pscustomobject]@{ StatusCode = 204 }
}
$app = @{
    appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ members = 'read' }
    resources = @{ organizations = @('platform'); repositories = @{} }
}
if ($multiple) { $app.resources.organizations += @('platform-two') }
$supervisor = {
    param($LifecycleEvent)
    $cloud.Events += @($LifecycleEvent.Event)
    Save-Cloud
    if ($Inject -and $FailureKind -ceq 'AfterRevocation' -and $LifecycleEvent.Event -ceq 'Revoked') { Stop-Issuance }
    return $true
}
$issuer = Join-Path $Tools 'New-PlatformGitHubToken.ps1'
if ($Inject -and $FailureKind -ceq 'BeforeIntentReplacement') {
    $line = (Select-String -LiteralPath $issuer -SimpleMatch 'Save-PlatformGitHubTokenIssuance -Context').LineNumber
    $null = Set-PSBreakpoint -Script $issuer -Line $line -Action { if ($issuanceContext.Started) { [Environment]::Exit(91) } }
}
if ($Inject -and $FailureKind -ceq 'AfterExport') {
    $line = (Select-String -LiteralPath $issuer -SimpleMatch '[IO.File]::AppendAllText').LineNumber + 1
    $null = Set-PSBreakpoint -Script $issuer -Line $line -Action { [Environment]::Exit(91) }
}
if ($Inject -and $FailureKind -ceq 'AfterCleanup') {
    $line = (Select-String -LiteralPath $issuer -SimpleMatch 'return [pscustomobject]@{').LineNumber
    $null = Set-PSBreakpoint -Script $issuer -Line $line -Action { [Environment]::Exit(91) }
}
$arguments = @{
    BootstrapApp = $app; Authorization = $true; PrivateKey = [IO.File]::ReadAllText($KeyPath)
    ApiUrl = 'https://api.example.test'; IssuanceStatePath = $StatePath
    ValidateOnly = -not ($Inject -and $FailureKind -ceq 'AfterExport')
    EnvironmentPath = "$CloudPath.env"
}
if ($arguments.ValidateOnly) { $arguments.TokenLifecycle = $supervisor }
else {
    $arguments.Remove('BootstrapApp')
    $env:GITHUB_REPOSITORY = 'platform/instance'
    $env:PLATFORM_APP_ID = '101'
    $env:PLATFORM_APP_INSTALLATION_ID = '201'
    $env:PLATFORM_APP_ENTERPRISE = 'example'
}
$result = & $issuer @arguments
if ($result.Verified) { Write-Output 'Verified = true' }
'@)
}

Describe 'Installation token issuance process interruption' -Tag 'Interruption' {
    It 'blocks a fresh process after <Kind> with <Stop> until explicit disposition' -ForEach @(
        @{ Index = 0; Kind = 'BeforeApply'; Stop = 'Error'; ExpectedIssued = 0; ExpectedRevoked = 0; Events = @() }
        @{ Index = 1; Kind = 'BeforeApply'; Stop = 'Abrupt'; ExpectedIssued = 0; ExpectedRevoked = 0; Events = @() }
        @{ Index = 2; Kind = 'LoseResponse'; Stop = 'Error'; ExpectedIssued = 1; ExpectedRevoked = 0; Events = @() }
        @{ Index = 3; Kind = 'LoseResponse'; Stop = 'Abrupt'; ExpectedIssued = 1; ExpectedRevoked = 0; Events = @() }
        @{ Index = 4; Kind = 'RevocationBeforeApply'; Stop = 'Error'; ExpectedIssued = 1; ExpectedRevoked = 0; Events = @('Issued', 'Revoking') }
        @{ Index = 5; Kind = 'RevocationBeforeApply'; Stop = 'Abrupt'; ExpectedIssued = 1; ExpectedRevoked = 0; Events = @('Issued', 'Revoking') }
        @{ Index = 6; Kind = 'RevocationLoseResponse'; Stop = 'Error'; ExpectedIssued = 1; ExpectedRevoked = 1; Events = @('Issued', 'Revoking') }
        @{ Index = 7; Kind = 'RevocationLoseResponse'; Stop = 'Abrupt'; ExpectedIssued = 1; ExpectedRevoked = 1; Events = @('Issued', 'Revoking') }
        @{ Index = 8; Kind = 'AfterRevocation'; Stop = 'Error'; ExpectedIssued = 1; ExpectedRevoked = 1; Events = @('Issued', 'Revoking', 'Revoked') }
        @{ Index = 9; Kind = 'AfterRevocation'; Stop = 'Abrupt'; ExpectedIssued = 1; ExpectedRevoked = 1; Events = @('Issued', 'Revoking', 'Revoked') }
        @{ Index = 10; Kind = 'AfterExport'; Stop = 'Abrupt'; ExpectedIssued = 1; ExpectedRevoked = 0; Events = @() }
        @{ Index = 11; Kind = 'BeforeIntentReplacement'; Stop = 'Abrupt'; ExpectedIssued = 1; ExpectedRevoked = 0; Events = @('Issued') }
        @{ Index = 12; Kind = 'AfterIntentReplacement'; Stop = 'Abrupt'; ExpectedIssued = 1; ExpectedRevoked = 0; Events = @('Issued') }
    ) {
        $shard = Get-InterruptionShard
        if ($Index % $shard.ShardCount -ne $shard.ShardIndex) {
            Set-ItResult -Skipped -Because 'Scenario belongs to another interruption shard.'
            return
        }
        $casePath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = [IO.Directory]::CreateDirectory($casePath)
        $statePath = Join-Path $casePath 'private/pending.json'
        $cloudPath = Join-Path $casePath 'cloud.json'
        [IO.File]::WriteAllText($cloudPath, '{"Posts":0,"Issued":0,"Revoked":0,"Active":0,"Expired":0,"Events":[],"IntentIds":[]}')
        $childArguments = @('-NoProfile', '-File', $driver, '-Tools', $tools, '-KeyPath', $keyPath,
            '-StatePath', $statePath, '-CloudPath', $cloudPath, '-FailureKind', $Kind, '-Stop', $Stop)

        $first = & $pwsh @childArguments -Inject 2>&1 | Out-String
        $LASTEXITCODE | Should -Be $(if ($Stop -ceq 'Abrupt') { 91 } else { 1 }) -Because $first
        $first | Should -Not -Match 'Verified = true'
        if ($Stop -ceq 'Error' -and $Kind -in @('BeforeApply', 'LoseResponse')) { $first | Should -Match 'may have been created' }
        Test-Path -LiteralPath $statePath | Should -BeTrue
        $cloud = [IO.File]::ReadAllText($cloudPath) | ConvertFrom-Json -AsHashtable
        $cloud.Posts | Should -Be 1
        $cloud.Issued | Should -Be $ExpectedIssued
        $cloud.Revoked | Should -Be $ExpectedRevoked
        @($cloud.Events) | Should -Be $Events
        if ($Kind -ceq 'AfterExport') {
            [IO.File]::ReadAllText("$cloudPath.env") | Should -Match 'PLATFORM_GITHUB_TOKENS=.*offline-token-1'
        }
        if ($Kind -in @('BeforeIntentReplacement', 'AfterIntentReplacement')) {
            $intent = ([IO.File]::ReadAllText($statePath) | ConvertFrom-Json -AsHashtable).intentId
            if ($Kind -ceq 'BeforeIntentReplacement') { $intent | Should -BeExactly $cloud.IntentIds[0] }
            else { $intent | Should -Not -BeExactly $cloud.IntentIds[0] }
        }

        $repeat = & $pwsh @childArguments 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $repeat | Should -Match 'Unresolved installation token issuance'
        $repeat | Should -Not -Match 'Verified = true'
        $cloud = [IO.File]::ReadAllText($cloudPath) | ConvertFrom-Json -AsHashtable
        $cloud.Posts | Should -Be 1
        $cloud.Active | Should -Be ($ExpectedIssued - $ExpectedRevoked)

        # Model independent expiry, not a DELETE using a token the issuer never received.
        $cloud.Expired = $cloud.Active
        $cloud.Active = 0
        [IO.File]::WriteAllText($cloudPath, ($cloud | ConvertTo-Json -Compress))
        $resolution = & (Join-Path $tools 'Resolve-PlatformGitHubTokenIssuance.ps1') `
            -IssuanceStatePath $statePath -ConfirmTokenExpiredOrRevoked
        $resolution.Verified | Should -BeFalse
        $resolution.Disposition | Should -BeExactly 'OperatorConfirmedExpiredOrRevoked'

        $recovered = & $pwsh @childArguments 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $recovered
        $recovered | Should -Match 'Verified = true'
        $cloud = [IO.File]::ReadAllText($cloudPath) | ConvertFrom-Json -AsHashtable
        $count = if ($Kind -in @('BeforeIntentReplacement', 'AfterIntentReplacement')) { 2 } else { 1 }
        $cloud.Issued | Should -Be ($ExpectedIssued + $count)
        $cloud.Expired | Should -Be ($ExpectedIssued - $ExpectedRevoked)
        $cloud.Revoked | Should -Be ($ExpectedRevoked + $count)
        $cloud.Active | Should -Be 0
        $recoveredEvents = @(for ($i = 0; $i -lt $count; $i++) { 'Issued' }; for ($i = 0; $i -lt $count; $i++) { 'Revoking'; 'Revoked' })
        @($cloud.Events | Select-Object -Skip $Events.Count) | Should -Be $recoveredEvents
        Test-Path -LiteralPath $statePath | Should -BeFalse
    }

    It 'allows a fresh process after confirmed cleanup even if the success result was lost' {
        $shard = Get-InterruptionShard
        if (13 % $shard.ShardCount -ne $shard.ShardIndex) {
            Set-ItResult -Skipped -Because 'Scenario belongs to another interruption shard.'
            return
        }
        $casePath = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = [IO.Directory]::CreateDirectory($casePath)
        $statePath = Join-Path $casePath 'private/pending.json'
        $cloudPath = Join-Path $casePath 'cloud.json'
        [IO.File]::WriteAllText($cloudPath, '{"Posts":0,"Issued":0,"Revoked":0,"Active":0,"Expired":0,"Events":[],"IntentIds":[]}')
        $childArguments = @('-NoProfile', '-File', $driver, '-Tools', $tools, '-KeyPath', $keyPath,
            '-StatePath', $statePath, '-CloudPath', $cloudPath, '-FailureKind', 'AfterCleanup', '-Stop', 'Abrupt')
        $first = & $pwsh @childArguments -Inject 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 91 -Because $first
        $first | Should -Not -Match 'Verified = true'
        Test-Path -LiteralPath $statePath | Should -BeFalse
        $cloud = [IO.File]::ReadAllText($cloudPath) | ConvertFrom-Json -AsHashtable
        $cloud.Issued | Should -Be 1
        $cloud.Revoked | Should -Be 1
        $cloud.Active | Should -Be 0
        $repeat = & $pwsh @childArguments 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0 -Because $repeat
        $repeat | Should -Match 'Verified = true'
        $cloud = [IO.File]::ReadAllText($cloudPath) | ConvertFrom-Json -AsHashtable
        $cloud.Issued | Should -Be 2
        $cloud.Revoked | Should -Be 2
        $cloud.Active | Should -Be 0
    }
}
