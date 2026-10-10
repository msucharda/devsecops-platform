#Requires -Version 7.4
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
$names = Get-PlatformModuleSelection -Instance $instance -Modules $modules
$json = ConvertTo-Json -InputObject $names -Compress
if ($GitHubOutputPath) {
    $environments = [ordered]@{}
    foreach ($name in $names) {
        $environments[$name] = $instance['credentials'][$name]['plan']['environment']
    }
    $environmentJson = ConvertTo-Json -InputObject $environments -Compress
    [System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($GitHubOutputPath), "modules=$json`nenvironments=$environmentJson`n", [System.Text.UTF8Encoding]::new($false))
}
$json
