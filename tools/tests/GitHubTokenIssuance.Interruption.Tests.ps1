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
        return ,(Get-GitHubApiFixture -Name apps/list-installations -Set @{
            '0.id' = 201; '0.account.login' = 'platform'; '0.target_type' = 'Organization'
            '0.permissions' = @{ members = 'read' }; '0.suspended_at' = $null
        })
    }
    if ($Uri -like '*/access_tokens') {
        $cloud.Posts++
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
    if ($Uri -like '*/orgs/platform/teams`?*') { return Get-GitHubApiFixture -Name teams/list-teams }
    if ($Uri -like '*/installation/token' -and $Method -ceq 'DELETE') {
        $cloud.Revoked++
        $cloud.Active--
        Save-Cloud
        return
    }
    throw "Unexpected offline request: $Method $Uri"
}
$app = @{
    appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ members = 'read' }
    resources = @{ organizations = @('platform'); repositories = @{} }
}
$supervisor = {
    param($LifecycleEvent)
    $cloud.Events += @($LifecycleEvent.Event)
    Save-Cloud
    return $true
}
$result = & (Join-Path $Tools 'New-PlatformGitHubToken.ps1') -BootstrapApp $app -Authorization `
    -PrivateKey ([IO.File]::ReadAllText($KeyPath)) -ValidateOnly -ApiUrl https://api.example.test `
    -IssuanceStatePath $StatePath -TokenLifecycle $supervisor
if ($result.Verified) { Write-Output 'Verified = true' }
'@)
}

Describe 'Installation token issuance process interruption' -Tag 'Interruption' {
    It 'blocks a fresh process after <Kind> with <Stop> until explicit disposition' -ForEach @(
        @{ Index = 0; Kind = 'BeforeApply'; Stop = 'Error'; ExpectedIssued = 0 }
        @{ Index = 1; Kind = 'BeforeApply'; Stop = 'Abrupt'; ExpectedIssued = 0 }
        @{ Index = 2; Kind = 'LoseResponse'; Stop = 'Error'; ExpectedIssued = 1 }
        @{ Index = 3; Kind = 'LoseResponse'; Stop = 'Abrupt'; ExpectedIssued = 1 }
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
        [IO.File]::WriteAllText($cloudPath, '{"Posts":0,"Issued":0,"Revoked":0,"Active":0,"Expired":0,"Events":[]}')
        $childArguments = @('-NoProfile', '-File', $driver, '-Tools', $tools, '-KeyPath', $keyPath,
            '-StatePath', $statePath, '-CloudPath', $cloudPath, '-FailureKind', $Kind, '-Stop', $Stop)

        $first = & $pwsh @childArguments -Inject 2>&1 | Out-String
        $LASTEXITCODE | Should -Be $(if ($Stop -ceq 'Abrupt') { 91 } else { 1 })
        $first | Should -Not -Match 'Verified = true'
        if ($Stop -ceq 'Error') { $first | Should -Match 'may have been created' }
        Test-Path -LiteralPath $statePath | Should -BeTrue
        $cloud = [IO.File]::ReadAllText($cloudPath) | ConvertFrom-Json -AsHashtable
        $cloud.Posts | Should -Be 1
        $cloud.Issued | Should -Be $ExpectedIssued
        $cloud.Revoked | Should -Be 0
        @($cloud.Events).Count | Should -Be 0

        $repeat = & $pwsh @childArguments 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 1
        $repeat | Should -Match 'Unresolved installation token issuance'
        $repeat | Should -Not -Match 'Verified = true'
        $cloud = [IO.File]::ReadAllText($cloudPath) | ConvertFrom-Json -AsHashtable
        $cloud.Posts | Should -Be 1
        $cloud.Active | Should -Be $ExpectedIssued

        # Model independent expiry, not a DELETE using a token the issuer never received.
        $cloud.Expired = $cloud.Active
        $cloud.Active = 0
        [IO.File]::WriteAllText($cloudPath, ($cloud | ConvertTo-Json -Compress))
        $resolution = & (Join-Path $tools 'Resolve-PlatformGitHubTokenIssuance.ps1') `
            -IssuanceStatePath $statePath -ConfirmTokenExpiredOrRevoked
        $resolution.Verified | Should -BeFalse
        $resolution.Disposition | Should -BeExactly 'OperatorConfirmedExpiredOrRevoked'

        $recovered = & $pwsh @childArguments 2>&1 | Out-String
        $LASTEXITCODE | Should -Be 0
        $recovered | Should -Match 'Verified = true'
        $cloud = [IO.File]::ReadAllText($cloudPath) | ConvertFrom-Json -AsHashtable
        $cloud.Issued | Should -Be ($ExpectedIssued + 1)
        $cloud.Expired | Should -Be $ExpectedIssued
        $cloud.Revoked | Should -Be 1
        $cloud.Active | Should -Be 0
        @($cloud.Events) | Should -Be @('Issued', 'Revoking', 'Revoked')
        Test-Path -LiteralPath $statePath | Should -BeFalse
    }
}
