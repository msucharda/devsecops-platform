BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InstallToolDependenciesStub.psm1') -Force
}

Describe 'Tool dependency installation recovery' -Tag Interruption {
    BeforeEach {
        $statePath = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $statePath
    }

    It 'resumes after <Mode> interruption after <Boundary>' -ForEach @(
        @{ Mode = 'Abrupt'; Boundary = 'Downloaded' }
        @{ Mode = 'Abrupt'; Boundary = 'Saved' }
        @{ Mode = 'Abrupt'; Boundary = 'PackagePublished' }
        @{ Mode = 'Abrupt'; Boundary = 'Installed' }
        @{ Mode = 'Error'; Boundary = 'Downloaded' }
        @{ Mode = 'Error'; Boundary = 'Saved' }
        @{ Mode = 'Error'; Boundary = 'PackagePublished' }
        @{ Mode = 'Error'; Boundary = 'Installed' }
    ) {
        $first = Invoke-InstallerStub -StatePath $statePath -WorkingPath $TestDrive -InterruptAfter $Boundary -InterruptMode $Mode
        $first.ExitCode | Should -Be $(if ($Mode -eq 'Abrupt') { 17 } else { 1 })
        $second = Invoke-InstallerStub -StatePath $statePath -WorkingPath $TestDrive
        $second.ExitCode | Should -Be 0 -Because $second.Error
        Test-Path (Join-Path $statePath 'tools/.dependencies/Pester/5.7.1/Pester.psd1') | Should -BeTrue
        @(Get-Content (Join-Path $statePath 'attempts') | Where-Object { $_ -eq 'installed' }).Count | Should -Be 1
    }
}
