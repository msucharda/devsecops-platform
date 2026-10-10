#Requires -Version 7.4
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [string] $TrustedInstancePath,
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
if ($TrustedInstancePath) {
    $trusted = Get-PlatformInstance -Path $TrustedInstancePath -Modules $modules
    foreach ($field in @('credentials', 'githubApps')) {
        if ((ConvertTo-PlatformCanonicalJson $instance[$field]) -cne (ConvertTo-PlatformCanonicalJson $trusted[$field])) {
            throw "PR changes protected $field bindings. Cloud plan must run from main after review and merge."
        }
    }
}
$names = Get-PlatformModuleSelection -Instance $instance -Modules $modules
$json = ConvertTo-Json -InputObject $names -Compress
if ($GitHubOutputPath) {
    $environments = [ordered]@{}
    $applyEnvironments = [ordered]@{}
    $rulesetEnvironments = [ordered]@{}
    foreach ($name in $names) {
        $environments[$name] = $instance['credentials'][$name]['plan']['environment']
        $applyEnvironments[$name] = $instance['credentials'][$name]['apply']['environment']
        if ($instance['credentials'][$name].Contains('rulesetPlan')) {
            $rulesetEnvironments[$name] = $instance['credentials'][$name]['rulesetPlan']['environment']
        }
    }
    $environmentJson = ConvertTo-Json -InputObject $environments -Compress
    $applyJson = ConvertTo-Json -InputObject $applyEnvironments -Compress
    $rulesetJson = ConvertTo-Json -InputObject $rulesetEnvironments -Compress
    $rulesetModules = ConvertTo-Json -InputObject @($names | Where-Object { $modules[$_]['permissions']['githubApp'].Contains('rulesetPlan') }) -Compress
    [System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($GitHubOutputPath),
        "modules=$json`nenvironments=$environmentJson`napplyEnvironments=$applyJson`nrulesetEnvironments=$rulesetJson`nrulesetModules=$rulesetModules`n",
        [System.Text.UTF8Encoding]::new($false))
}
$json
