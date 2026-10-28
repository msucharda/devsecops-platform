BeforeAll {
    $script:probeScript = Join-Path $PSScriptRoot '../Test-LocalCiRuntimeProbe.ps1'
    Import-Module (Join-Path $PSScriptRoot '../LocalCiGate.psm1') -Force
}

Describe 'Offline real-Terraform probe entry point' {
    BeforeEach {
        $providers = Join-Path $TestDrive 'providers'
        $external = Join-Path $providers 'registry.terraform.io/hashicorp/external/2.4.2/fixture'
        $null = New-Item -ItemType Directory -Force -Path $external
        Set-Content (Join-Path $external 'provider-fixture.txt') 'installed provider'
        $savedConfig = $env:TF_CLI_CONFIG_FILE
        $env:TF_CLI_CONFIG_FILE = 'original-cli-config'
        Mock Import-Module { } -ParameterFilter { $Name -like '*LocalCiGate.psm1' }
        Mock Test-LocalCiRuntime {
            $config = Get-Content -LiteralPath $env:TF_CLI_CONFIG_FILE -Raw
            $config | Should -Match 'filesystem_mirror'
            $config | Should -Match 'disable_checkpoint = true'
            $config | Should -Not -Match '\bdirect\b'
            $config | Should -Match 'registry.terraform.io/hashicorp/external'
            @(Get-ChildItem -LiteralPath $TempPath -Recurse -Filter provider-fixture.txt).Count | Should -Be 1
            if ($Executable -eq 'pwsh') { return $true }
            throw "pwsh external-program preflight failed: External Program Lookup Failed: $Executable"
        }
    }

    AfterEach { $env:TF_CLI_CONFIG_FILE = $savedConfig }

    It 'runs positive and negative probes with only the installed provider, then restores CLI configuration' {
        $output = @(& $probeScript -ProviderDirectory $providers -TempPath $TestDrive)
        $output | Should -Contain 'PASS real Terraform external probe: working pwsh'
        $output | Should -Contain 'PASS real Terraform external probe: missing pwsh rejected'
        Should -Invoke Test-LocalCiRuntime -Times 1 -Exactly -ParameterFilter { $Executable -eq 'pwsh' }
        Should -Invoke Test-LocalCiRuntime -Times 1 -Exactly -ParameterFilter { $Executable -like '*missing-local-ci-pwsh*' }
        $env:TF_CLI_CONFIG_FILE | Should -BeExactly 'original-cli-config'
        @(Get-ChildItem $TestDrive -Filter 'runtime-smoke-*') | Should -BeNullOrEmpty
    }

    It 'does not accept an unrelated negative-probe failure and can retry after interruption' {
        Mock Test-LocalCiRuntime {
            if ($Executable -eq 'pwsh') { return $true }
            throw 'Provider initialization interrupted'
        }
        { & $probeScript -ProviderDirectory $providers -TempPath $TestDrive } | Should -Throw '*initialization interrupted*'
        $env:TF_CLI_CONFIG_FILE | Should -BeExactly 'original-cli-config'
        @(Get-ChildItem $TestDrive -Filter 'runtime-smoke-*') | Should -BeNullOrEmpty
        Mock Test-LocalCiRuntime {
            if ($Executable -eq 'pwsh') { return $true }
            throw "External Program Lookup Failed: $Executable"
        }
        { & $probeScript -ProviderDirectory $providers -TempPath $TestDrive } | Should -Not -Throw
    }

    It 'rejects a negative probe that unexpectedly succeeds' {
        Mock Test-LocalCiRuntime { $true }
        { & $probeScript -ProviderDirectory $providers -TempPath $TestDrive } | Should -Throw '*missing pwsh unexpectedly succeeded*'
    }

    It 'rejects a false positive result' {
        Mock Test-LocalCiRuntime { $false }
        { & $probeScript -ProviderDirectory $providers -TempPath $TestDrive } | Should -Throw '*positive probe did not pass*'
    }

    It 'rejects a nonboolean positive result' {
        Mock Test-LocalCiRuntime { 'true' }
        { & $probeScript -ProviderDirectory $providers -TempPath $TestDrive } | Should -Throw '*positive probe did not pass*'
    }

    It 'rejects a lookup failure for a different executable' {
        Mock Test-LocalCiRuntime {
            if ($Executable -eq 'pwsh') { return $true }
            throw 'External Program Lookup Failed: other-executable'
        }
        { & $probeScript -ProviderDirectory $providers -TempPath $TestDrive } |
            Should -Throw '*External Program Lookup Failed: other-executable*'
    }

    It 'rejects a different failure for the expected executable' {
        Mock Test-LocalCiRuntime {
            if ($Executable -eq 'pwsh') { return $true }
            throw "Other Terraform failure: $Executable"
        }
        { & $probeScript -ProviderDirectory $providers -TempPath $TestDrive } |
            Should -Throw '*Other Terraform failure: missing-local-ci-pwsh-*'
    }

    It 'rejects a missing installed external provider without running a probe' {
        { & $probeScript -ProviderDirectory (Join-Path $TestDrive 'missing') -TempPath $TestDrive } |
            Should -Throw '*installed hashicorp/external provider*'
        Should -Invoke Test-LocalCiRuntime -Times 0
    }
}
