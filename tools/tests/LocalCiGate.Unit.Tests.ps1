BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../LocalCiGate.psm1') -Force
    $repository = [IO.Path]::GetFullPath((Join-Path $PSScriptRoot '../..'))
}

Describe 'Local CI profiles' {
    It 'keeps every discovered test in the full profile and only isolated suites in the local profile' {
        $testProfile = Get-LocalCiProfile -RepositoryRoot $repository -AllPester
        $discovered = @(Get-ChildItem (Join-Path $repository 'tools/tests') -Filter '*.Tests.ps1' |
            ForEach-Object Name | Sort-Object)

        @($testProfile.Full | ForEach-Object { Split-Path $_ -Leaf } | Sort-Object) | Should -BeExactly $discovered
        $testProfile.Local | Should -Contain 'tools/tests/DeploymentIdentifier.Tests.ps1'
        $testProfile.Local | Should -Contain 'tools/tests/LocalCiGate.Unit.Tests.ps1'
        $testProfile.Local | Should -Contain 'tools/tests/CanonicalConfiguration.Tests.ps1'
        $testProfile.Local | Should -Contain 'tools/tests/ActionUpdates.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/MutationRunner.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/LocalCiGate.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/EnterpriseBaseline.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/GitHubBootstrap.Tests.ps1'
        $testProfile.Local | Should -Not -Contain 'tools/tests/VendoringPullRequest.Tests.ps1'
        @($testProfile.Local | Where-Object { $_ -notin $testProfile.Full }).Count | Should -Be 0
    }

    It 'selects only affected isolated suites and reports the rest as remote work' {
        $testProfile = Get-LocalCiProfile -RepositoryRoot $repository -PesterPath @(
            'tools/tests/DeploymentIdentifier.Tests.ps1', 'tools/tests/EnterpriseBaseline.Tests.ps1'
        )
        @($testProfile.Selected) | Should -BeExactly @('tools/tests/DeploymentIdentifier.Tests.ps1')
        $testProfile.Remote | Should -Contain 'tools/tests/EnterpriseBaseline.Tests.ps1'
    }

    It 'rejects a newly discovered test without an explicit category' {
        $fixture = Join-Path $TestDrive 'profile'
        $tests = Join-Path $fixture 'tools/tests'
        New-Item -ItemType Directory -Force $tests | Out-Null
        Set-Content (Join-Path $tests 'Known.Tests.ps1') ''
        Set-Content (Join-Path $tests 'Unknown.Tests.ps1') ''
        Set-Content (Join-Path $fixture 'tools/test-profiles.psd1') "@{ Unit=@('Known.Tests.ps1'); Contract=@(); Integration=@(); Interruption=@() }"
        { Get-LocalCiProfile -RepositoryRoot $fixture -AllPester } | Should -Throw '*missing*Unknown.Tests.ps1*'
    }

}

Describe 'Local CI index visibility' {
    It 'accepts visible cached entries' {
        InModuleScope LocalCiGate {
            { Assert-LocalCiIndexVisibility -Entry @('H source.ps1', 'H file with spaces.ps1') } | Should -Not -Throw
        }
    }

    It 'rejects a hidden or unsupported index tag <Tag>' -ForEach @(
        @{ Tag = 'h' }, @{ Tag = 'S' }, @{ Tag = 's' }, @{ Tag = 'M' }, @{ Tag = 'Z' }
    ) {
        InModuleScope LocalCiGate -Parameters @{ Tag = $Tag } {
            param($Tag)
            # Z deliberately models invalid Git output.
            $entries = @('H visible.ps1', "$Tag source.ps1")
            { Assert-LocalCiIndexVisibility -Entry $entries } | Should -Throw '*index flags*'
        }
    }
}

Describe 'Local CI Windows TEMP root scope' {
    BeforeEach {
        $userProfile = Join-Path $TestDrive 'profile'
    }

    It 'accepts the default root omission outside Windows' {
        { Assert-LocalCiWindowsTempRoot -Path '' -UserProfile $userProfile -Windows $false } | Should -Not -Throw
    }

    It 'rejects a custom root outside Windows: <Root>' -ForEach @(
        @{ Root = '/tmp' }, @{ Root = 'relative' }, @{ Root = ' ' }
    ) {
        { Assert-LocalCiWindowsTempRoot -Path $Root -UserProfile $userProfile -Windows $false } |
            Should -Throw '*TempRoot*only supported on Windows*'
    }

    It 'accepts a direct profile child with <Case>' -ForEach @(
        @{ Case = 'the default name'; Leaf = '.dci'; UpperCase = $false; TrailingSeparator = $false }
        @{ Case = 'a custom name'; Leaf = 'custom'; UpperCase = $false; TrailingSeparator = $false }
        @{ Case = 'different Windows casing'; Leaf = 'custom'; UpperCase = $true; TrailingSeparator = $false }
        @{ Case = 'a trailing separator'; Leaf = 'custom'; UpperCase = $false; TrailingSeparator = $true }
    ) {
        $path = Join-Path $userProfile $Leaf
        if ($UpperCase) { $path = $path.ToUpperInvariant() }
        if ($TrailingSeparator) { $path += [IO.Path]::DirectorySeparatorChar }
        { Assert-LocalCiWindowsTempRoot -Path $path -UserProfile $userProfile -Windows $true } | Should -Not -Throw
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'the profile itself'; Kind = 'Profile' }
        @{ Case = 'a nested directory'; Kind = 'Nested' }
        @{ Case = 'a profile-prefix sibling'; Kind = 'Sibling' }
        @{ Case = 'a volume-root child'; Kind = 'Volume' }
        @{ Case = 'the public C:\t directory'; Kind = 'Public' }
    ) {
        $path = switch ($Kind) {
            Profile { $userProfile }
            Nested { Join-Path $userProfile 'nested/temp' }
            Sibling { Join-Path "$userProfile-other" 'temp' }
            Volume { Join-Path ([IO.Path]::GetPathRoot($userProfile)) 'temp' }
            Public { 'C:\t' }
        }
        { Assert-LocalCiWindowsTempRoot -Path $path -UserProfile $userProfile -Windows $true } | Should -Throw '*direct child*UserProfile*'
    }

    It 'rejects a junction between the profile and root without accessing its target' -Skip:(-not $IsWindows) {
        $target = Join-Path $TestDrive 'outside-profile'
        $junction = Join-Path $userProfile 'alias'
        New-Item -ItemType Directory -Path $userProfile, $target | Out-Null
        $null = New-Item -ItemType Junction -Path $junction -Value $target
        try {
            { Assert-LocalCiWindowsTempRoot -Path (Join-Path $junction 'temp') -UserProfile $userProfile -Windows $true } |
                Should -Throw '*direct child*UserProfile*'
            Test-Path -LiteralPath (Join-Path $target 'temp') | Should -BeFalse
        }
        finally { Remove-Item -LiteralPath $junction -Force }
    }
}

Describe 'Local CI private TEMP access' {
    BeforeEach {
        $userSid = 'S-1-5-21-1-2-3-1000'
        $access = @{
            Directory = $true; ReparsePoint = $false; Owner = $userSid; Protected = $true
            Rules = @($userSid, 'S-1-5-18' | ForEach-Object {
                @{ Sid = $_; Type = 'Allow'; Rights = 2032127; Inheritance = 3; Propagation = 0; Inherited = $false }
            })
        }
    }

    It 'accepts the protected owner and SYSTEM ACL' {
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Not -Throw
    }

    It 'accepts SYSTEM ownership with the same restricted access rules' {
        $access.Owner = 'S-1-5-18'
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Not -Throw
    }

    It 'rejects unsafe access: <Case>' -ForEach @(
        @{ Case = 'a regular file'; Field = 'Directory'; Value = $false; Error = '*regular directory*' }
        @{ Case = 'unknown directory type'; Field = 'Directory'; Value = $null; Error = '*regular directory*' }
        @{ Case = 'string directory type'; Field = 'Directory'; Value = 'True'; Error = '*regular directory*' }
        @{ Case = 'a reparse point'; Field = 'ReparsePoint'; Value = $true; Error = '*regular directory*' }
        @{ Case = 'unknown reparse point state'; Field = 'ReparsePoint'; Value = $null; Error = '*regular directory*' }
        @{ Case = 'string reparse point state'; Field = 'ReparsePoint'; Value = 'False'; Error = '*regular directory*' }
        @{ Case = 'different owner'; Field = 'Owner'; Value = 'S-1-5-21-9-9-9-1000'; Error = '*untrusted owner*' }
        @{ Case = 'differently cased owner'; Field = 'Owner'; Value = 's-1-5-21-1-2-3-1000'; Error = '*untrusted owner*' }
        @{ Case = 'inherited ACL'; Field = 'Protected'; Value = $false; Error = '*inheritance*' }
        @{ Case = 'unknown inheritance state'; Field = 'Protected'; Value = $null; Error = '*inheritance*' }
        @{ Case = 'string inheritance state'; Field = 'Protected'; Value = 'True'; Error = '*inheritance*' }
    ) {
        $access[$Field] = $Value
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Throw $Error
    }

    It 'rejects an unsafe rule: <Case>' -ForEach @(
        @{ Case = 'unknown identity'; Field = 'Sid'; Value = 'S-1-5-11'; Error = '*identity*' }
        @{ Case = 'duplicate identity'; Field = 'Sid'; Value = 'S-1-5-18'; Error = '*identity*' }
        @{ Case = 'deny rule'; Field = 'Type'; Value = 'Deny'; Error = '*access rule*' }
        @{ Case = 'differently cased rule'; Field = 'Type'; Value = 'allow'; Error = '*access rule*' }
        @{ Case = 'incomplete rights'; Field = 'Rights'; Value = 131241; Error = '*access rule*' }
        @{ Case = 'missing object inheritance'; Field = 'Inheritance'; Value = 1; Error = '*access rule*' }
        @{ Case = 'missing container inheritance'; Field = 'Inheritance'; Value = 2; Error = '*access rule*' }
        @{ Case = 'inherit-only propagation'; Field = 'Propagation'; Value = 2; Error = '*access rule*' }
        @{ Case = 'inherited rule'; Field = 'Inherited'; Value = $true; Error = '*access rule*' }
        @{ Case = 'unknown rule inheritance'; Field = 'Inherited'; Value = $null; Error = '*access rule*' }
        @{ Case = 'string rule inheritance'; Field = 'Inherited'; Value = 'False'; Error = '*access rule*' }
    ) {
        $access.Rules[0][$Field] = $Value
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Throw $Error
    }

    It 'rejects an additional writable identity' {
        $access.Rules += @{ Sid = 'S-1-5-11'; Type = 'Allow'; Rights = 2032127; Inheritance = 3; Propagation = 0; Inherited = $false }
        { Assert-LocalCiTempAccess -Access $access -UserSid $userSid } | Should -Throw '*unexpected access rules*'
    }

    It 'creates a protected Windows directory and refuses existing broader access' -Skip:(-not $IsWindows) {
        $path = Join-Path $TestDrive 'private-temp'
        Initialize-LocalCiPrivateTempDirectory -Path $path
        Initialize-LocalCiPrivateTempDirectory -Path $path
        $directory = [IO.DirectoryInfo]::new($path)
        $acl = [IO.FileSystemAclExtensions]::GetAccessControl($directory, [Security.AccessControl.AccessControlSections]::Access)
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-11'), [Security.AccessControl.FileSystemRights]::Modify,
            [Security.AccessControl.AccessControlType]::Allow)
        $null = $acl.AddAccessRule($rule)
        [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
        { Initialize-LocalCiPrivateTempDirectory -Path $path } | Should -Throw '*Unsafe CI TEMP*'
        (Get-Acl -LiteralPath $path).Access.Count | Should -Be 3
    }

    It 'rejects a real Windows junction without following or repairing it' -Skip:(-not $IsWindows) {
        $target = Join-Path $TestDrive 'private-target'
        $junction = Join-Path $TestDrive 'temp-junction'
        Initialize-LocalCiPrivateTempDirectory -Path $target
        $null = New-Item -ItemType Junction -Path $junction -Value $target
        try {
            { Initialize-LocalCiPrivateTempDirectory -Path $junction } | Should -Throw '*regular directory*'
            ((Get-Item -LiteralPath $junction).Attributes -band [IO.FileAttributes]::ReparsePoint) | Should -Not -Be 0
        }
        finally { Remove-Item -LiteralPath $junction -Force }
    }
}
