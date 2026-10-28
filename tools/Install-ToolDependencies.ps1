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
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1') -Force

function Invoke-DependencyTransfer {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][scriptblock] $Action,
        [Parameter(Mandatory)][int] $MaxAttempts,
        [Parameter(Mandatory)][int] $RetryDelaySeconds,
        [Parameter(Mandatory)][string] $Dependency
    )

    for ($attempt = 1; $attempt -le $MaxAttempts; $attempt++) {
        try {
            & $Action
            return
        }
        catch {
            if ($attempt -eq $MaxAttempts) { throw }
            $delay = $RetryDelaySeconds * $attempt
            Write-Warning "Failed to download $Dependency (attempt $attempt/$MaxAttempts): $($_.Exception.Message). Retrying in $delay seconds."
            Start-Sleep -Seconds $delay
        }
    }
}

$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
foreach ($name in $requirements.Runtime.Keys) {
    $null = Get-ToolDependencyPath -Name $name
}
if (-not $Development) { return }

$cache = Join-Path $PSScriptRoot '.dependencies'
$null = New-Item -ItemType Directory -Path $cache -Force
foreach ($name in ($requirements.Development.Keys | Sort-Object)) {
    $version = $requirements.Development[$name]
    $transfer = @{ MaxAttempts = $MaxAttempts; RetryDelaySeconds = $RetryDelaySeconds; Dependency = "$name $version" }
    $directory = Join-Path $cache "$name/$version"
    if (Test-Path -LiteralPath $directory) {
        $null = Get-ToolDependencyPath -Name $name
        continue
    }
    $staging = Join-Path $cache ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $staging
    try {
        $package = Join-Path $staging "$name.$version.nupkg"
        Invoke-DependencyTransfer @transfer -Action {
            Invoke-WebRequest -Uri "https://www.powershellgallery.com/api/v2/package/$name/$version" -OutFile $package -ErrorAction Stop
        }
        Assert-ToolPackage -Path $package -Sha256 $requirements.Sha256[$name] -Name $name
        Invoke-DependencyTransfer @transfer -Action {
            if (-not (Get-PSRepository -Name PSGallery -ErrorAction SilentlyContinue)) {
                Register-PSRepository -Default -ErrorAction Stop
            }
            Save-Module -Name $name -RequiredVersion $version -Repository PSGallery -Path $staging -Force -ErrorAction Stop
        }
        $saved = Join-Path $staging "$name/$version"
        Assert-ToolModulePayload -PackagePath $package -ModulePath $saved
        $packages = Join-Path $cache 'packages'
        $null = New-Item -ItemType Directory -Path $packages -Force
        Move-Item -LiteralPath $package -Destination (Join-Path $packages "$name.$version.nupkg") -Force
        $null = New-Item -ItemType Directory -Path (Split-Path $directory -Parent) -Force
        Move-Item -LiteralPath $saved -Destination $directory
    }
    finally {
        Remove-Item -LiteralPath $staging -Recurse -Force
    }
}
