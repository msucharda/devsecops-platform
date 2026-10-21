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

Describe 'Instance organizations derived from the platform organization' {
    It 'derives the deployment identifier and all organization names' {
        $organizations = Get-PlatformInstanceOrganization -InstanceName 'demo' -PlatformOrganization 'demo-a1b2c3-platform'

        $organizations.deploymentIdentifier | Should -BeExactly 'a1b2c3'
        $organizations.platform | Should -BeExactly 'demo-a1b2c3-platform'
        $organizations.actions | Should -BeExactly 'demo-a1b2c3-actions'
        $organizations.workloads | Should -BeExactly 'demo-a1b2c3-workloads'
    }

    It 'uses legacy names without a deployment identifier for {name}-platform' {
        $organizations = Get-PlatformInstanceOrganization -InstanceName 'slzdso' -PlatformOrganization 'slzdso-platform'

        $organizations.Contains('deploymentIdentifier') | Should -BeTrue
        $organizations.deploymentIdentifier | Should -BeNullOrEmpty
        $organizations.platform | Should -BeExactly 'slzdso-platform'
        $organizations.actions | Should -BeExactly 'slzdso-actions'
        $organizations.workloads | Should -BeExactly 'slzdso-workloads'
    }

    It 'rejects <Case>' -TestCases @(
        @{ Case = 'another instance name'; Organization = 'other-a1b2c3-platform' }
        @{ Case = 'a different letter case'; Organization = 'Demo-a1b2c3-platform' }
        @{ Case = 'an uppercase identifier'; Organization = 'demo-A1B2C3-platform' }
        @{ Case = 'a short identifier'; Organization = 'demo-a1b2c-platform' }
        @{ Case = 'a long identifier'; Organization = 'demo-a1b2c3d-platform' }
        @{ Case = 'a non-platform suffix'; Organization = 'demo-a1b2c3-actions' }
        @{ Case = 'an instance name prefix only'; Organization = 'demox-a1b2c3-platform' }
        @{ Case = 'surrounding whitespace'; Organization = ' demo-a1b2c3-platform' }
        @{ Case = 'a trailing line feed'; Organization = "demo-a1b2c3-platform`n" }
        @{ Case = 'an empty value'; Organization = '' }
    ) {
        { Get-PlatformInstanceOrganization -InstanceName 'demo' -PlatformOrganization $Organization } |
            Should -Throw "*does not match instance.name 'demo'*"
    }

    It 'rejects an invalid instance name' {
        { Get-PlatformInstanceOrganization -InstanceName 'Demo' -PlatformOrganization 'Demo-platform' } |
            Should -Throw '*instance.name*'
    }
}
