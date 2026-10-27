#Requires -Version 7.4
[CmdletBinding()]
param(
    [switch] $Development,
    [ValidateRange('Positive')]
    [int] $MaxAttempts = 4,
    [ValidateRange('NonNegative')]
    [int] $RetryDelaySeconds = 15
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
$dependencies = @{} + $requirements.Runtime
if ($Development) {
    $dependencies += $requirements.Development
}
foreach ($name in ($dependencies.Keys | Sort-Object)) {
    $version = $dependencies[$name]
    $installed = Get-Module -ListAvailable -Name $name | Where-Object { $_.Version -eq [version] $version }
    if (-not $installed) {
        for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
            try {
                if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
                    Register-PSRepository -Default -ErrorAction Stop
                }
                Install-Module -Name $name -RequiredVersion $version -Repository PSGallery -Scope CurrentUser -Force -AllowClobber -ErrorAction Stop
                break
            }
            catch {
                if ($attempt -eq $MaxAttempts) { throw }
                $delay = $RetryDelaySeconds * $attempt
                Write-Warning "Failed to install $name $version (attempt $attempt/$MaxAttempts): $($_.Exception.Message). Retrying in $delay seconds."
                Start-Sleep -Seconds $delay
            }
        }
    }
}
