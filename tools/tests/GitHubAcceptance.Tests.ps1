BeforeAll {
    $root = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $wizard = Join-Path $root 'tools/Start-InstanceSetup.ps1'
    Import-Module (Join-Path $root 'tools/InstanceSetup.psm1') -Force
}

Describe 'GitHub acceptance through the public setup wizard' {
    BeforeEach {
        $savedTokens = @{}
        foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN')) {
            $savedTokens[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, $null)
        }
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Mock Write-Host -ModuleName InstanceSetup {}
        Mock Read-Host -ModuleName InstanceSetup { 's' }
        Mock Invoke-WebRequest -ModuleName InstanceSetup { throw 'No cloud request is authorized.' }
    }
    AfterEach {
        foreach ($name in $savedTokens.Keys) { [Environment]::SetEnvironmentVariable($name, $savedTokens[$name]) }
    }

    It 'does not accept or provision an instance without the verified issue ten inputs' {
        $result = & $wizard -WorkPath $work -GitHubAcceptance -PassThru

        $result.AcceptancePassed | Should -BeFalse
        ($result.Stages | Where-Object Id -eq 'acceptance-inputs').Status | Should -Be 'Missing'
        ($result.Stages | Where-Object Id -eq 'acceptance-azure').Status | Should -Be 'Skipped'
        Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 0 -Exactly
        Test-Path -LiteralPath $result.ReportPath | Should -BeTrue
    }

    It 'builds an isolated acceptance release but performs no provisioning when consent is declined' {
        Import-Module powershell-yaml -RequiredVersion 0.4.12
        $null = New-Item -ItemType Directory -Path $work
        $config = ConvertFrom-Yaml (Get-Content (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $config.bootstrap = @{
            tenantId = '11111111-1111-1111-1111-111111111111'
            managementSubscriptionId = '22222222-2222-2222-2222-222222222222'
            subscriptionIds = @('22222222-2222-2222-2222-222222222222')
            enterpriseApplicationObjectId = '33333333-3333-3333-3333-333333333333'
            enterprise = 'example'; githubHost = 'example.ghe.com'
        }
        $sourceConfig = ConvertTo-Yaml $config
        Set-Content (Join-Path $work 'instance.yaml') $sourceConfig
        $source = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $source
        foreach ($name in @('tools', 'schemas', 'templates')) {
            Copy-Item (Join-Path $root $name) -Destination $source -Recurse
        }
        Mock Read-Host -ModuleName InstanceSetup {
            if ($Prompt -like 'Approve*acceptance*') { return 'y' }
            if ($Prompt -like 'Create or reconcile Azure*') { return $(if ($runAzurePreparation) { 'y' } else { 'n' }) }
            return 's'
        }
        $runAzurePreparation = $false

        $staging = Join-Path $work 'github-acceptance/release-preparing'
        $null = New-Item -ItemType Directory -Path $staging -Force
        $unapproved = Join-Path $staging 'unapproved.txt'
        Set-Content $unapproved 'not part of the approved source'
        $blocked = & $wizard -WorkPath $work -GitHubAcceptance -ReleasePath $source -ReleaseVersion '0.0.0-bootstrap.11' -PassThru
        ($blocked.Stages | Where-Object Id -eq 'acceptance-release').Status | Should -Be 'Error'
        ($blocked.Stages | Where-Object Id -eq 'acceptance-azure').Status | Should -Be 'Skipped'
        Remove-Item -LiteralPath $unapproved

        $result = & $wizard -WorkPath $work -GitHubAcceptance -ReleasePath $source -ReleaseVersion '0.0.0-bootstrap.11' -PassThru

        $result.AcceptancePassed | Should -BeFalse
        ($result.Stages | Where-Object Id -eq 'acceptance-release').Status | Should -Be 'Ok' -Because (
            ($result.Stages | Where-Object Id -eq 'acceptance-release').Detail)
        ($result.Stages | Where-Object Id -eq 'acceptance-azure').Status | Should -Be 'Missing'
        foreach ($id in @('acceptance-resources', 'acceptance-apps', 'acceptance-complete', 'acceptance-repeat', 'acceptance-workflow', 'acceptance-witnesses')) {
            ($result.Stages | Where-Object Id -eq $id).Status | Should -Be 'Skipped'
        }
        Test-Path (Join-Path $work 'github-acceptance/release/modules/enterprise-baseline/module.yaml') | Should -BeTrue
        Test-Path (Join-Path $work 'github-acceptance/release/templates/instance/.github/workflows/bootstrap-acceptance.yml') | Should -BeTrue
        (Get-Content (Join-Path $work 'instance.yaml') -Raw).TrimEnd() | Should -Be $sourceConfig.TrimEnd()
        Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 0 -Exactly
        Test-Path (Join-Path $work 'github-acceptance/keys.json') | Should -BeFalse

        $runAzurePreparation = $true
        Mock gh -ModuleName InstanceSetup { $global:LASTEXITCODE = 0; 'gho_test' }
        Mock az -ModuleName InstanceSetup {
            $global:LASTEXITCODE = 0
            '{"tenant":"11111111-1111-1111-1111-111111111111","accessToken":"test-azure"}'
        }
        Mock Start-Sleep -ModuleName InstanceSetup {}
        Mock Invoke-WebRequest -ModuleName InstanceSetup { throw 'Injected API stop after provisional configuration validation' }
        $prepared = & $wizard -WorkPath $work -GitHubAcceptance -ReleasePath $source -ReleaseVersion '0.0.0-bootstrap.11' -PassThru
        ($prepared.Stages | Where-Object Id -eq 'acceptance-azure').Detail |
            Should -Match 'Injected API stop after provisional configuration validation'
        Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 1 -Exactly

        Add-Content (Join-Path $work 'github-acceptance/release/tools/Invoke-Bootstrap.ps1') '# changed after approval'
        $resumed = & $wizard -WorkPath $work -GitHubAcceptance -ReleasePath $source -ReleaseVersion '0.0.0-bootstrap.11' -PassThru
        ($resumed.Stages | Where-Object Id -eq 'acceptance-release').Status | Should -Be 'Error'
        ($resumed.Stages | Where-Object Id -eq 'acceptance-azure').Status | Should -Be 'Skipped'
        Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 1 -Exactly
    }
}
