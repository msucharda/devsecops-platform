#Requires -Version 7.4
[CmdletBinding()]
param([ValidateSet('TFLint')][string] $Name = 'TFLint')

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1')
if (-not $IsLinux -or [Runtime.InteropServices.RuntimeInformation]::OSArchitecture -ne [Runtime.InteropServices.Architecture]::X64) {
    throw 'CI binary installation supports Linux amd64 only.'
}
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
$pin = $requirements.Binaries[$Name]
$directory = Join-Path $env:RUNNER_TEMP "platform-tflint-$([guid]::NewGuid().ToString('N'))"
$null = New-Item -ItemType Directory -Path $directory
$published = $false
try {
    $archive = Join-Path $directory 'tflint_linux_amd64.zip'
    Invoke-WebRequest -Uri "https://github.com/terraform-linters/tflint/releases/download/v$($pin.Version)/tflint_linux_amd64.zip" -OutFile $archive -ErrorAction Stop
    Assert-ToolPackage -Path $archive -Sha256 $pin.LinuxAmd64ArchiveSha256 -Name $Name
    [IO.Compression.ZipFile]::ExtractToDirectory($archive, $directory)
    $executable = Join-Path $directory 'tflint'
    if (-not (Test-Path -LiteralPath $executable -PathType Leaf)) { throw 'TFLint archive does not contain tflint.' }
    & chmod '+x' $executable
    if ($LASTEXITCODE -ne 0) { throw 'Cannot mark TFLint executable.' }
    Add-Content -LiteralPath $env:GITHUB_PATH -Value $directory
    $published = $true
}
finally {
    if (-not $published) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
