BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PlatformTools.psm1') -Force
}

Describe 'Deployment identifier' {
    It 'generates six lowercase alphanumeric characters' {
        $identifiers = 1..50 | ForEach-Object { Get-RandomPlatformDeploymentIdentifier }

        $identifiers | ForEach-Object { $_ | Should -MatchExactly '^[a-z0-9]{6}$' }
        @($identifiers | Sort-Object -Unique).Count | Should -BeGreaterThan 45
    }

    It 'composes <Kind> organization names from the instance name and deployment identifier' -TestCases @(
        @{ Kind = 'platform' }, @{ Kind = 'actions' }, @{ Kind = 'workloads' }
    ) {
        Get-PlatformOrganizationName -InstanceName 'demo' -DeploymentIdentifier 'a1b2c3' -Kind $Kind |
            Should -BeExactly "demo-a1b2c3-$Kind"
    }

    It 'keeps the longest organization name within the GitHub limit of 39 characters' {
        $name = Get-PlatformOrganizationName -InstanceName 'abcdefgh' -DeploymentIdentifier 'z9z9z9' -Kind workloads

        $name | Should -BeExactly 'abcdefgh-z9z9z9-workloads'
        $name.Length | Should -BeLessOrEqual 39
    }

    It 'rejects invalid <Case>' -TestCases @(
        @{ Case = 'short identifier'; Name = 'demo'; Identifier = 'a1b2c' }
        @{ Case = 'uppercase identifier'; Name = 'demo'; Identifier = 'A1B2C3' }
        @{ Case = 'identifier with hyphen'; Name = 'demo'; Identifier = 'a1-2c3' }
        @{ Case = 'instance name'; Name = 'Demo'; Identifier = 'a1b2c3' }
        @{ Case = 'long instance name'; Name = 'abcdefghi'; Identifier = 'a1b2c3' }
    ) {
        { Get-PlatformOrganizationName -InstanceName $Name -DeploymentIdentifier $Identifier -Kind platform } |
            Should -Throw '*deployment identifier*'
    }
}
