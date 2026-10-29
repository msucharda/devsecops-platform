BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $tools = Split-Path $PSScriptRoot -Parent
    $issuer = Join-Path $tools 'New-PlatformGitHubToken.ps1'
    $resolver = Join-Path $tools 'Resolve-PlatformGitHubTokenIssuance.ps1'
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()
}

Describe 'Installation token issuance recovery' {
    BeforeEach {
        $statePath = Join-Path $TestDrive "issuance-$([guid]::NewGuid())/pending.json"
        $app = @{
            appId = '101'; installationId = '201'; enterprise = 'example'
            permissions = @{ members = 'read' }
            resources = @{ organizations = @('platform'); repositories = @{} }
        }
        $arguments = @{
            BootstrapApp = $app; Authorization = $true; PrivateKey = $privateKey
            ValidateOnly = $true; ApiUrl = 'https://api.example.test'; IssuanceStatePath = $statePath
        }
        $cloud = @{ Issued = 0; Revoked = 0; LoseResponse = $false }
        Mock Invoke-RestMethod {
            param($Uri, $Method)
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
                $cloud.Issued++
                if ($cloud.LoseResponse) { throw 'Injected token response loss.' }
                return Get-GitHubApiFixture -Name apps/create-installation-access-token -Set @{
                    token = "fake-installation-token-$($cloud.Issued)"; permissions = @{ members = 'read' }
                }
            }
            if ($Uri -like '*/installation/repositories`?*') {
                return Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{ total_count = 0; repositories = @() }
            }
            if ($Uri -like '*/orgs/platform/teams`?*') { return Get-GitHubApiFixture -Name teams/list-teams }
            if ($Uri -like '*/installation/token' -and $Method -eq 'DELETE') { $cloud.Revoked++; return }
            throw "Unexpected offline request: $Method $Uri"
        }
    }

    It 'publishes a secret-free private intent before POST and clears it after known cleanup' {
        Mock Invoke-RestMethod {
            Test-Path -LiteralPath $statePath | Should -BeTrue
            $content = [IO.File]::ReadAllText($statePath)
            $record = $content | ConvertFrom-Json -AsHashtable
            $record.apiUrl | Should -BeExactly 'https://api.example.test'
            $record.appId | Should -BeExactly '101'
            @($record.installationIds) | Should -Be @('201')
            $record.intentId | Should -Match '^[0-9a-f-]{36}$'
            $content | Should -Match '"createdAtUtc":"[^"]+\+00:00"'
            $content | Should -Not -Match 'fake-installation-token|PRIVATE KEY|eyJ'
            Get-GitHubApiFixture -Name apps/create-installation-access-token -Set @{
                token = 'fake-installation-token'; permissions = @{ members = 'read' }
            }
        } -ParameterFilter { $Uri -like '*/access_tokens' }

        $result = & $issuer @arguments

        $result.Verified | Should -BeTrue
        Test-Path -LiteralPath $statePath | Should -BeFalse
        $directory = Split-Path $statePath -Parent
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $directory
            $acl.AreAccessRulesProtected | Should -BeTrue
            $rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]))
            $rules.Count | Should -Be 1
            $rules[0].IdentityReference.Value | Should -BeExactly ([Security.Principal.WindowsIdentity]::GetCurrent().User.Value)
        }
        else { [int] [IO.File]::GetUnixFileMode($directory) | Should -Be 448 }
    }

    It 'retains uncertainty without a blind retry or a fabricated revocation' {
        $cloud.LoseResponse = $true
        { & $issuer @arguments } | Should -Throw '*may have been created*cannot be revoked*201*recorded UTC*Injected token response loss*'
        $pending = [IO.File]::ReadAllText($statePath)

        { & $issuer @arguments } | Should -Throw '*Unresolved*issuance*201*recorded UTC*Use Resolve-PlatformGitHubTokenIssuance.ps1*'

        [IO.File]::ReadAllText($statePath) | Should -BeExactly $pending
        $cloud.Issued | Should -Be 1
        $cloud.Revoked | Should -Be 0
    }

    It 'blocks a <Case> pending record rather than treating it as success' -ForEach @(
        @{ Case = 'empty'; Content = '' }
        @{ Case = 'corrupt'; Content = '{invalid' }
    ) {
        $cloud.LoseResponse = $true
        { & $issuer @arguments } | Should -Throw '*Injected token response loss*'
        [IO.File]::WriteAllText($statePath, $Content)

        { & $issuer @arguments } | Should -Throw '*Unresolved*issuance*'

        $cloud.Issued | Should -Be 1
        $cloud.Revoked | Should -Be 0
    }

    It 'refuses a concurrent issuer and resolver while the process lock is held' {
        $null = & $issuer @arguments
        $held = [IO.File]::Open("$statePath.lock", [IO.FileMode]::Open, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            { & $issuer @arguments } | Should -Throw '*exclusively lock*'
            { & $resolver -IssuanceStatePath $statePath -ConfirmTokenExpiredOrRevoked } | Should -Throw '*exclusively lock*'
            $cloud.Issued | Should -Be 1
        }
        finally { $held.Dispose() }
        (& $issuer @arguments).Verified | Should -BeTrue
    }

    It 'retains pending state after an uncertain revocation and never retries it' {
        Mock Invoke-RestMethod { throw 'Injected revocation response loss.' } -ParameterFilter { $Method -eq 'DELETE' }

        { & $issuer @arguments } | Should -Throw '*Injected revocation response loss*'
        { & $issuer @arguments } | Should -Throw '*Unresolved*issuance*'

        Test-Path -LiteralPath $statePath | Should -BeTrue
        $cloud.Issued | Should -Be 1
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'DELETE' }
    }

    It 'clears pending state after known cleanup when the supervisor rejects registration' {
        $arguments.TokenLifecycle = { param($LifecycleEvent) if ($LifecycleEvent.Event -ceq 'Issued') { throw 'Registration rejected.' }; return $true }
        { & $issuer @arguments } | Should -Throw '*Registration rejected*'
        Test-Path -LiteralPath $statePath | Should -BeFalse
        $cloud.Revoked | Should -Be 1
        $arguments.Remove('TokenLifecycle')
        (& $issuer @arguments).Verified | Should -BeTrue
    }

    It 'does not issue when the existing state directory grants broader access' {
        $null = & $issuer @arguments
        $directory = Split-Path $statePath -Parent
        if ($IsWindows) {
            $acl = Get-Acl -LiteralPath $directory
            $acl.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new('S-1-1-0'),
                [Security.AccessControl.FileSystemRights]::Read,
                [Security.AccessControl.AccessControlType]::Allow))
            [IO.FileSystemAclExtensions]::SetAccessControl([IO.DirectoryInfo]::new($directory), $acl)
        }
        else { [IO.File]::SetUnixFileMode($directory, [IO.UnixFileMode] 511) }

        { & $issuer @arguments } | Should -Throw '*accessible only to that user*'
        $cloud.Issued | Should -Be 1
    }

    It 'refuses to store issuance state inside the checkout' {
        $arguments.IssuanceStatePath = Join-Path (Split-Path $tools -Parent) ".issuance-test-$([guid]::NewGuid())/pending.json"
        try {
            { & $issuer @arguments } | Should -Throw '*outside the checkout*'
            $cloud.Issued | Should -Be 0
        }
        finally {
            $directory = Split-Path $arguments.IssuanceStatePath -Parent
            if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
        }
    }

    It 'does not discard a pending record changed after its publication: <Change>' -ForEach @(
        @{ Change = 'whitespace' }
        @{ Change = 'case' }
    ) {
        Mock Invoke-RestMethod {
            if ($Change -ceq 'case') {
                [IO.File]::WriteAllText($statePath, [IO.File]::ReadAllText($statePath).Replace('"apiUrl"', '"apiURL"'))
            }
            else { [IO.File]::AppendAllText($statePath, ' ') }
            Get-GitHubApiFixture -Name apps/create-installation-access-token -Set @{
                token = 'fake-installation-token'; permissions = @{ members = 'read' }
            }

        } -ParameterFilter { $Uri -like '*/access_tokens' }

        { & $issuer @arguments } | Should -Throw '*pending state changed*'

        Test-Path -LiteralPath $statePath | Should -BeTrue
        $cloud.Revoked | Should -Be 1
    }

    It 'refuses to store issuance state at the checkout root' {
        $arguments.IssuanceStatePath = Split-Path $tools -Parent
        { & $issuer @arguments } | Should -Throw '*outside the checkout*'
        $cloud.Issued | Should -Be 0
    }

    It 'refuses a reparse-point ancestor without issuing a token' {
        $target = Join-Path $TestDrive "target-$([guid]::NewGuid())"
        $null = [IO.Directory]::CreateDirectory($target)
        $link = Join-Path $TestDrive "link-$([guid]::NewGuid())"
        $null = New-Item -ItemType $(if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }) -Path $link -Target $target
        $arguments.IssuanceStatePath = Join-Path $link 'private/pending.json'
        { & $issuer @arguments } | Should -Throw '*reparse-point ancestor*'
        $cloud.Issued | Should -Be 0
    }

    It 'requires explicit operator confirmation for a <Case> pending timestamp' -ForEach @(
        @{ Case = 'recent'; Change = 'recent' }
        @{ Case = 'sixty-nine-minute-old'; Change = 'sixty-nine' }
        @{ Case = 'future'; Change = 'future' }
        @{ Case = 'missing'; Change = 'missing' }
        @{ Case = 'non-UTC'; Change = 'offset' }
        @{ Case = 'corrupt'; Change = 'corrupt' }
        @{ Case = 'empty'; Change = 'empty' }
    ) {
        $cloud.LoseResponse = $true
        { & $issuer @arguments } | Should -Throw '*Injected token response loss*'
        $record = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -AsHashtable
        switch ($Change) {
            'sixty-nine' { $record.createdAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-69).ToString('o') }
            'future' { $record.createdAtUtc = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o') }
            'missing' { $record.Remove('createdAtUtc') }
            'offset' { $record.createdAtUtc = [DateTimeOffset]::UtcNow.AddHours(-2).ToOffset([TimeSpan]::FromHours(1)).ToString('o') }
        }
        $content = $record | ConvertTo-Json -Depth 5 -Compress
        if ($Change -ceq 'corrupt') { $content = '{invalid' }
        if ($Change -ceq 'empty') { $content = '' }
        [IO.File]::WriteAllText($statePath, $content)

        { & $resolver -IssuanceStatePath $statePath } | Should -Throw '*70 minutes*explicit operator confirmation*'
        Test-Path -LiteralPath $statePath | Should -BeTrue
        $resolved = & $resolver -IssuanceStatePath $statePath -ConfirmTokenExpiredOrRevoked

        $resolved.Resolved | Should -BeTrue
        $resolved.Verified | Should -BeFalse
        $resolved.Disposition | Should -BeExactly 'OperatorConfirmedExpiredOrRevoked'
        $resolved.Message | Should -Match 'No token was revoked'
        Test-Path -LiteralPath $statePath | Should -BeFalse
        $cloud.Issued | Should -Be 1
        $cloud.Revoked | Should -Be 0
    }

    It 'allows manual resolution after the seventy-minute wait without claiming revocation' {
        $cloud.LoseResponse = $true
        { & $issuer @arguments } | Should -Throw '*Injected token response loss*'
        $record = [IO.File]::ReadAllText($statePath) | ConvertFrom-Json -AsHashtable
        $record.createdAtUtc = [DateTimeOffset]::UtcNow.AddMinutes(-70).ToString('o')
        [IO.File]::WriteAllText($statePath, ($record | ConvertTo-Json -Depth 5 -Compress))

        $resolved = & $resolver -IssuanceStatePath $statePath

        $resolved.Verified | Should -BeFalse
        $resolved.Disposition | Should -BeExactly 'SeventyMinuteWaitElapsed'
        $cloud.Revoked | Should -Be 0
        $cloud.LoseResponse = $false
        (& $issuer @arguments).Verified | Should -BeTrue
        $cloud.Issued | Should -Be 2
        $cloud.Revoked | Should -Be 1
    }
}
