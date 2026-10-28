#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $ProviderDirectory,
    [Parameter(Mandatory)][string] $TempPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'LocalCiGate.psm1')

$provider = Join-Path $ProviderDirectory 'registry.terraform.io/hashicorp/external'
if (-not (Test-Path -LiteralPath $provider -PathType Container)) {
    throw 'The installed hashicorp/external provider is missing; initialize modules/organizations first.'
}
$directory = Join-Path ([IO.Path]::GetFullPath($TempPath)) "runtime-smoke-$([guid]::NewGuid().ToString('N'))"
$savedConfig = $env:TF_CLI_CONFIG_FILE
try {
    $mirror = Join-Path $directory 'mirror'
    $namespace = Join-Path $mirror 'registry.terraform.io/hashicorp'
    $null = New-Item -ItemType Directory -Force -Path $namespace
    Copy-Item -LiteralPath $provider -Destination $namespace -Recurse
    $configuration = Join-Path $directory 'offline.tfrc'
    $mirrorLiteral = ConvertTo-Json -InputObject $mirror -Compress
    [IO.File]::WriteAllText($configuration, @"
disable_checkpoint = true
provider_installation {
  filesystem_mirror {
    path = $mirrorLiteral
    include = ["registry.terraform.io/hashicorp/external"]
  }
}
"@)
    $env:TF_CLI_CONFIG_FILE = $configuration
    $positive = Test-LocalCiRuntime -TempPath $directory -Executable 'pwsh'
    if ($positive -isnot [bool] -or -not $positive) { throw 'Real Terraform positive probe did not pass.' }
    Write-Output 'PASS real Terraform external probe: working pwsh'

    $missing = "missing-local-ci-pwsh-$([guid]::NewGuid().ToString('N'))"
    $rejected = $false
    try { $null = Test-LocalCiRuntime -TempPath $directory -Executable $missing }
    catch {
        if ($_.Exception.Message -notmatch 'External Program Lookup Failed' -or
            $_.Exception.Message -notmatch [regex]::Escape($missing)) { throw }
        $rejected = $true
    }
    if (-not $rejected) { throw 'Real Terraform probe with missing pwsh unexpectedly succeeded.' }
    Write-Output 'PASS real Terraform external probe: missing pwsh rejected'
}
finally {
    $env:TF_CLI_CONFIG_FILE = $savedConfig
    if (Test-Path -LiteralPath $directory) { Remove-Item -LiteralPath $directory -Recurse -Force }
}
