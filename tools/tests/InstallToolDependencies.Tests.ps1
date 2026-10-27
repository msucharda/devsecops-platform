BeforeAll {
    $installer = Join-Path $PSScriptRoot '../Install-ToolDependencies.ps1'
    function Get-PSRepository {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Offline stub prevents PowerShellGet discovery and network access.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signature must match the mocked public command.')]
        [CmdletBinding()]
        param([string] $Name)
        throw 'Unexpected repository lookup outside the offline stub.'
    }
    function Register-PSRepository {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Offline stub prevents PowerShellGet dynamic parameter execution.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signature must match the mocked public command.')]
        [CmdletBinding()]
        param([switch] $Default)
        throw 'Unexpected repository registration outside the offline stub.'
    }
    function Install-Module {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Offline stub prevents PowerShellGet discovery and network access.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Stub signature must match the mocked public command.')]
        [CmdletBinding()]
        param([string] $Name, [string] $RequiredVersion, [string] $Repository, [string] $Scope, [switch] $Force, [switch] $AllowClobber)
        throw 'Unexpected module installation outside the offline stub.'
    }
}

Describe 'Tool dependency installation' {
    BeforeEach {
        $installState = @{ Attempts = 0 }
        Mock Get-Module { } -ParameterFilter { $ListAvailable -and $Name -eq 'powershell-yaml' }
        Mock Get-PSRepository { [pscustomobject]@{ Name = 'PSGallery' } }
        Mock Register-PSRepository { }
        Mock Start-Sleep { }
        Mock Install-Module {
            $installState.Attempts++
            if ($installState.Attempts -lt 3) { throw 'Transient download failure' }
        }
    }

    It 'retries transient downloads using the hotfix defaults and linear delays' {
        & $installer

        Should -Invoke Install-Module -Times 3 -Exactly -ParameterFilter {
            $Name -eq 'powershell-yaml' -and $RequiredVersion -eq '0.4.12' -and
            $Repository -eq 'PSGallery' -and $Scope -eq 'CurrentUser' -and $Force -and $AllowClobber -and $ErrorAction -eq 'Stop'
        }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 15 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
        Should -Invoke Register-PSRepository -Times 0
    }

    It 'restores PSGallery before each attempt when registration is missing' {
        Mock Get-PSRepository { } -ParameterFilter { $Name -eq 'PSGallery' -and $ErrorAction -eq 'SilentlyContinue' }

        & $installer -MaxAttempts 3 -RetryDelaySeconds 0

        Should -Invoke Register-PSRepository -Times 3 -Exactly -ParameterFilter { $Default -and $ErrorAction -eq 'Stop' }
        Should -Invoke Install-Module -Times 3 -Exactly
    }

    It 'retries a failed repository registration before installing' {
        $registrationState = @{ Attempts = 0 }
        Mock Get-PSRepository { }
        Mock Register-PSRepository {
            $registrationState.Attempts++
            if ($registrationState.Attempts -eq 1) { throw 'Registration failed' }
        }
        Mock Install-Module { }

        & $installer -MaxAttempts 2 -RetryDelaySeconds 2

        Should -Invoke Register-PSRepository -Times 2 -Exactly
        Should -Invoke Install-Module -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 2 }
    }

    It 'stops after the configured attempt limit without a final delay' {
        Mock Install-Module { throw 'Persistent download failure' }

        { & $installer -MaxAttempts 2 -RetryDelaySeconds 3 } | Should -Throw '*Persistent download failure*'

        Should -Invoke Install-Module -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 3 }
    }

    It 'exhausts exactly four attempts and three linear delays by default' {
        Mock Install-Module { throw 'Persistent download failure' }

        { & $installer } | Should -Throw '*Persistent download failure*'

        Should -Invoke Install-Module -Times 4 -Exactly
        Should -Invoke Start-Sleep -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 15 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 45 }
    }

    It 'does not contact PSGallery when the exact version is already installed' {
        Mock Get-Module { [pscustomobject]@{ Version = [version] '0.4.12' } } -ParameterFilter { $ListAvailable -and $Name -eq 'powershell-yaml' }

        & $installer

        Should -Invoke Install-Module -Times 0
        Should -Invoke Get-PSRepository -Times 0
        Should -Invoke Register-PSRepository -Times 0
        Should -Invoke Start-Sleep -Times 0
    }

    It 'installs the required version even when another version is available' {
        Mock Get-Module { [pscustomobject]@{ Version = [version] '0.4.11' } } -ParameterFilter { $ListAvailable -and $Name -eq 'powershell-yaml' }
        Mock Install-Module { }

        & $installer

        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'powershell-yaml' -and $RequiredVersion -eq '0.4.12' }
    }

    It 'installs the pinned runtime and development versions' {
        Mock Get-Module { } -ParameterFilter { $ListAvailable -and $Name -in @('powershell-yaml', 'Pester', 'PSScriptAnalyzer') }
        Mock Install-Module { }

        & $installer -Development

        Should -Invoke Install-Module -Times 3 -Exactly
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'Pester' -and $RequiredVersion -eq '5.7.1' }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'PSScriptAnalyzer' -and $RequiredVersion -eq '1.24.0' }
        Should -Invoke Install-Module -Times 1 -Exactly -ParameterFilter { $Name -eq 'powershell-yaml' -and $RequiredVersion -eq '0.4.12' }
    }

    It 'rejects invalid retry parameters before contacting PSGallery' -ForEach @(
        @{ Arguments = @{ MaxAttempts = 0 } }
        @{ Arguments = @{ RetryDelaySeconds = -1 } }
    ) {
        { & $installer @Arguments } | Should -Throw '*Cannot validate argument*'

        Should -Invoke Install-Module -Times 0
        Should -Invoke Register-PSRepository -Times 0
    }
}

Describe 'Tool dependency installation process errors and recovery' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'InstallToolDependenciesStub.psm1') -Force
    }

    BeforeEach {
        $statePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $statePath
    }

    It 'exits nonzero after nonterminating module-function <Failure> errors' -ForEach @(
        @{ Failure = 'Install'; Message = 'Nonterminating installation failure'; Operation = 'install' }
        @{ Failure = 'Register'; Message = 'Nonterminating registration failure'; Operation = 'register' }
    ) {
        $result = Invoke-InstallerStub -StatePath $statePath -WorkingPath $TestDrive -Failure $Failure

        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match $Message
        @(Get-Content (Join-Path $statePath 'attempts') | Where-Object { $_ -eq $Operation }).Count | Should -Be 2
        Test-Path (Join-Path $statePath 'installed') | Should -BeFalse
    }

}
