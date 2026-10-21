BeforeAll {
    $resolve = Join-Path (Split-Path $PSScriptRoot -Parent) 'Resolve-PlatformReleaseImport.ps1'
}

Describe 'Platform release import inputs' {
    BeforeEach {
        $instancePath = Join-Path $TestDrive 'instance.yaml'
        "instance:`n  name: demo`n" | Set-Content -LiteralPath $instancePath
    }

    It 'derives the attested asset and deployment actions organization for <Tag>' -ForEach @(
        @{ Tag = 'v1.2.0'; Prerelease = $false }
        @{ Tag = 'v0.1.0-rc.1'; Prerelease = $true }
        @{ Tag = 'v10.0.12-rc.0'; Prerelease = $true }
    ) {
        $result = & $resolve -Tag $Tag -InstancePath $instancePath -PlatformOrganization demo-a1b2c3-platform
        $result.SourceRepository | Should -BeExactly 'msucharda/devsecops-platform'
        $result.Asset | Should -BeExactly "platform-$Tag.zip"
        $result.Prerelease | Should -Be $Prerelease
        $result.ActionsOrganization | Should -BeExactly 'demo-a1b2c3-actions'
    }

    It 'derives the legacy actions organization and writes workflow outputs' {
        $output = Join-Path $TestDrive 'github-output'
        $null = & $resolve -Tag v1.0.0 -InstancePath $instancePath -PlatformOrganization demo-platform -SourceRepository fork/devsecops-platform -GitHubOutputPath $output
        Get-Content -LiteralPath $output | Should -Be @(
            'source-repository=fork/devsecops-platform'
            'source-asset=platform-v1.0.0.zip'
            'actions-organization=demo-actions'
        )
    }

    It 'rejects the tag <Tag>' -ForEach @(
        @{ Tag = '' }
        @{ Tag = '1.2.0' }
        @{ Tag = 'v1.2' }
        @{ Tag = 'v01.2.0' }
        @{ Tag = 'V1.2.0' }
        @{ Tag = 'v1.2.0-beta.1' }
        @{ Tag = 'v1.2.0-rc.01' }
        @{ Tag = 'v1.2.0-rc1' }
        @{ Tag = 'v1.2.0+build' }
        @{ Tag = "v1.2.0`nsource-asset=evil.zip" }
    ) {
        { & $resolve -Tag $Tag -InstancePath $instancePath -PlatformOrganization demo-a1b2c3-platform } |
            Should -Throw '*must be vMAJOR.MINOR.PATCH*'
    }

    It 'rejects the source repository <Repository>' -ForEach @(
        @{ Repository = 'devsecops-platform' }
        @{ Repository = 'owner/repo/extra' }
        @{ Repository = "owner/repo`nactions-organization=evil" }
    ) {
        { & $resolve -Tag v1.0.0 -InstancePath $instancePath -PlatformOrganization demo-platform -SourceRepository $Repository } |
            Should -Throw '*must be owner/repo*'
    }

    It 'rejects a platform organization of another instance' {
        { & $resolve -Tag v1.0.0 -InstancePath $instancePath -PlatformOrganization other-a1b2c3-platform } | Should -Throw
    }
}
