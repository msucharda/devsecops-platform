Set-StrictMode -Version Latest

function Invoke-InstallerStub {
    [CmdletBinding()]
    param(
        [string] $StatePath,
        [string] $WorkingPath,
        [ValidateSet('None', 'Install', 'Register')]
        [string] $Failure = 'None',
        [ValidateSet('None', 'Registered', 'Installed')]
        [string] $InterruptAfter = 'None'
    )
    $installer = Join-Path $PSScriptRoot '../Install-ToolDependencies.ps1'
    $module = Join-Path $WorkingPath 'PowerShellGetStub.psm1'
    Set-Content -LiteralPath $module -Value @'
$ErrorActionPreference = 'Continue'
function Get-Module {
    [CmdletBinding()]
    param([string] $Name, [switch] $ListAvailable)
    if (Test-Path (Join-Path $env:INSTALLER_STATE 'installed')) { [pscustomobject]@{ Version = [version] '0.4.12' } }
}
function Get-PSRepository {
    [CmdletBinding()]
    param([string] $Name)
    if (Test-Path (Join-Path $env:INSTALLER_STATE 'registered')) { [pscustomobject]@{ Name = 'PSGallery' } }
}
function Register-PSRepository {
    [CmdletBinding()]
    param([switch] $Default)
    Add-Content (Join-Path $env:INSTALLER_STATE 'attempts') 'register'
    if ($env:INSTALLER_FAILURE -eq 'Register') { Write-Error 'Nonterminating registration failure'; return }
    Set-Content (Join-Path $env:INSTALLER_STATE 'registered') 'PSGallery'
    if ($env:INSTALLER_INTERRUPT -eq 'Registered') { [Environment]::Exit(17) }
}
function Install-Module {
    [CmdletBinding()]
    param([string] $Name, [string] $RequiredVersion, [string] $Repository, [string] $Scope, [switch] $Force, [switch] $AllowClobber)
    Add-Content (Join-Path $env:INSTALLER_STATE 'attempts') 'install'
    if ($env:INSTALLER_FAILURE -eq 'Install') { Write-Error 'Nonterminating installation failure'; return }
    Set-Content (Join-Path $env:INSTALLER_STATE 'installed') $RequiredVersion
    if ($env:INSTALLER_INTERRUPT -eq 'Installed') { [Environment]::Exit(17) }
}
Export-ModuleMember -Function Get-Module, Get-PSRepository, Register-PSRepository, Install-Module
'@
    $wrapper = Join-Path $WorkingPath 'Invoke-Installer.ps1'
    Set-Content -LiteralPath $wrapper -Value @'
param([string] $ModulePath, [string] $InstallerPath)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath
& $InstallerPath -MaxAttempts 2 -RetryDelaySeconds 0
'@
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $wrapper, '-ModulePath', $module, '-InstallerPath', $installer)) {
        $start.ArgumentList.Add($argument)
    }
    $start.Environment['INSTALLER_STATE'] = $StatePath
    $start.Environment['INSTALLER_FAILURE'] = $Failure
    $start.Environment['INSTALLER_INTERRUPT'] = $InterruptAfter
    $process = [Diagnostics.Process]::new()
    $process.StartInfo = $start
    try {
        $null = $process.Start()
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        if (-not $process.WaitForExit(60000)) {
            Stop-Process -Id $process.Id -Force
            throw 'The dependency installer exceeded 60 seconds.'
        }
        return @{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult(); Error = $stderr.GetAwaiter().GetResult() }
    }
    finally { $process.Dispose() }
}

Export-ModuleMember -Function Invoke-InstallerStub
