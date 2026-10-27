Set-StrictMode -Version Latest

function Invoke-InstallerStub {
    [CmdletBinding()]
    param(
        [string] $StatePath,
        [string] $WorkingPath,
        [ValidateSet('None', 'Download', 'Save')]
        [string] $Failure = 'None',
        [ValidateSet('None', 'Downloaded', 'Saved', 'PackagePublished', 'Installed')]
        [string] $InterruptAfter = 'None',
        [ValidateSet('Abrupt', 'Error')]
        [string] $InterruptMode = 'Abrupt'
    )

    $tools = Join-Path $StatePath 'tools'
    if (-not (Test-Path -LiteralPath $tools)) {
        $null = New-Item -ItemType Directory -Path $tools
        $source = Split-Path $PSScriptRoot -Parent
        Copy-Item (Join-Path $source 'Install-ToolDependencies.ps1'), (Join-Path $source 'ToolDependencies.psm1') $tools
        $payload = Join-Path $StatePath 'payload'
        $null = New-Item -ItemType Directory -Path $payload
        Set-Content (Join-Path $payload 'Pester.psd1') "@{ ModuleVersion='5.7.1'; RootModule='Pester.psm1' }"
        Set-Content (Join-Path $payload 'Pester.psm1') '# Offline package fixture.'
        $package = Join-Path $StatePath 'fixture.nupkg'
        [IO.Compression.ZipFile]::CreateFromDirectory($payload, $package)
        $hash = (Get-FileHash $package).Hash
        Set-Content (Join-Path $tools 'requirements.psd1') "@{ Runtime=@{}; Development=@{ Pester='5.7.1' }; Sha256=@{ Pester='$hash' } }"
    }

    $module = Join-Path $WorkingPath 'PowerShellGetStub.psm1'
    Set-Content -LiteralPath $module -Value @'
$ErrorActionPreference = 'Continue'
function Stop-AtBoundary {
    param([string] $Name)
    if ($env:INSTALLER_INTERRUPT -ne $Name) { return }
    if ($env:INSTALLER_MODE -eq 'Error') { throw "Interrupted after $Name." }
    [Environment]::Exit(17)
}
function Invoke-WebRequest {
    [CmdletBinding()]
    param([string] $Uri, [string] $OutFile)
    Add-Content (Join-Path $env:INSTALLER_STATE 'attempts') 'download'
    if ($env:INSTALLER_FAILURE -eq 'Download') { Write-Error 'Nonterminating download failure'; return }
    Copy-Item (Join-Path $env:INSTALLER_STATE 'fixture.nupkg') $OutFile
    Stop-AtBoundary Downloaded
}
function Save-Module {
    [CmdletBinding()]
    param([string] $Name, [string] $RequiredVersion, [string] $Repository, [string] $Path, [switch] $Force)
    Add-Content (Join-Path $env:INSTALLER_STATE 'attempts') 'save'
    if ($env:INSTALLER_FAILURE -eq 'Save') { Write-Error 'Nonterminating save failure'; return }
    $destination = Join-Path $Path "$Name/$RequiredVersion"
    $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
    Copy-Item (Join-Path $env:INSTALLER_STATE 'payload') $destination -Recurse
    Stop-AtBoundary Saved
}
function Get-PSRepository {
    [CmdletBinding()]
    param([string] $Name)
    [pscustomobject]@{ Name = $Name }
}
function Move-Item {
    [CmdletBinding()]
    param([string] $LiteralPath, [string] $Destination, [switch] $Force)
    Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
    if ($Destination -like '*.nupkg') {
        Add-Content (Join-Path $env:INSTALLER_STATE 'attempts') 'package'
        Stop-AtBoundary PackagePublished
    }
    else {
        Add-Content (Join-Path $env:INSTALLER_STATE 'attempts') 'installed'
        Stop-AtBoundary Installed
    }
}
Export-ModuleMember -Function Invoke-WebRequest, Save-Module, Move-Item, Get-PSRepository
'@
    $wrapper = Join-Path $WorkingPath 'Invoke-Installer.ps1'
    Set-Content -LiteralPath $wrapper -Value @'
param([string] $ModulePath, [string] $InstallerPath)
$ErrorActionPreference = 'Stop'
Import-Module $ModulePath
& $InstallerPath -Development -MaxAttempts 2 -RetryDelaySeconds 0
'@
    $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', $wrapper, '-ModulePath', $module, '-InstallerPath', (Join-Path $tools 'Install-ToolDependencies.ps1'))) {
        $start.ArgumentList.Add($argument)
    }
    $start.Environment['INSTALLER_STATE'] = $StatePath
    $start.Environment['INSTALLER_FAILURE'] = $Failure
    $start.Environment['INSTALLER_INTERRUPT'] = $InterruptAfter
    $start.Environment['INSTALLER_MODE'] = $InterruptMode
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
