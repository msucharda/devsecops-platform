BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InstallToolDependenciesStub.psm1') -Force
}

Describe 'Tool dependency installation recovery' -Tag Interruption {
    BeforeEach {
        $statePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $statePath
    }

    It 'resumes after abrupt interruption after <InterruptAfter> without reinstalling completed work' -ForEach @(
        @{ InterruptAfter = 'Registered' }
        @{ InterruptAfter = 'Installed' }
    ) {
        (Invoke-InstallerStub -StatePath $statePath -WorkingPath $TestDrive -InterruptAfter $InterruptAfter).ExitCode | Should -Be 17
        (Invoke-InstallerStub -StatePath $statePath -WorkingPath $TestDrive).ExitCode | Should -Be 0

        Get-Content (Join-Path $statePath 'installed') | Should -BeExactly '0.4.12'
        @(Get-Content (Join-Path $statePath 'attempts') | Where-Object { $_ -eq 'register' }).Count | Should -Be 1
        @(Get-Content (Join-Path $statePath 'attempts') | Where-Object { $_ -eq 'install' }).Count | Should -Be 1
    }
}
