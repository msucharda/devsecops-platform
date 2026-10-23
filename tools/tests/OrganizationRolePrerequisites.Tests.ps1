BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $tools = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $tools 'PlatformTools.psm1') -Force
    $validator = Join-Path $tools 'Test-InstanceConfiguration.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
}

Describe 'Organization security team link confirmation' {
    It 'accepts a post-bootstrap confirmation without requiring it during initial bootstrap' {
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.manualPrerequisites.organizationSecurityTeamsLinked = $true
        $path = Join-Path $TestDrive 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $path

        $validated = & $validator -InstancePath $path -ModulesPath $fixtures | ConvertFrom-Json -AsHashtable

        { Assert-PlatformManualPrerequisite -Instance $validated -Name organizationSecurityTeamsLinked -Subject 'organization-roles' } |
            Should -Not -Throw
        @(Get-PlatformManualPrerequisite -Instance $validated -Scope Bootstrap).Name |
            Should -Not -Contain 'organizationSecurityTeamsLinked'
    }

    It 'rejects a missing or unconfirmed link confirmation: <Case>' -ForEach @(
        @{ Case = 'missing'; Prerequisites = @{} }
        @{ Case = 'false'; Prerequisites = @{ organizationSecurityTeamsLinked = $false } }
        @{ Case = 'string'; Prerequisites = @{ organizationSecurityTeamsLinked = 'true' } }
        @{ Case = 'null'; Prerequisites = @{ organizationSecurityTeamsLinked = $null } }
    ) {
        $instance = @{ manualPrerequisites = $Prerequisites }

        { Assert-PlatformManualPrerequisite -Instance $instance -Name organizationSecurityTeamsLinked -Subject 'organization-roles' } |
            Should -Throw '*organization-roles*organizationSecurityTeamsLinked*'
    }
}
