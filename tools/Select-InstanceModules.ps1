#Requires -Version 7.4
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [string] $TrustedInstancePath,
    [string] $GitHubOutputPath,
    [ValidateSet('full', 'code-security')][string] $DeploymentScope = 'full'
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
$phaseNodes = Get-PlatformModulePhaseGraph -Modules $modules
if ($DeploymentScope -ceq 'code-security') {
    if (-not $instance['modules'].Contains('enterprise-baseline') -or
        -not $phaseNodes.Contains('enterprise-baseline:code-security')) {
        throw 'Code Security deployment requires a configured enterprise-baseline module and its declared code-security phase.'
    }
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $pending.Enqueue('enterprise-baseline:code-security')
    $selectedNodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $nodeName = $pending.Dequeue()
        if ($selectedNodes.Add($nodeName)) {
            foreach ($prerequisite in $phaseNodes[$nodeName].Prerequisites) {
                $pending.Enqueue($prerequisite)
            }
        }
    }
    [string[]] $names = @($selectedNodes | ForEach-Object { $_.Split(':')[0] } | Sort-Object -Unique -CaseSensitive)
}
else {
    $selectedNodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($node in $phaseNodes.PSBase.Values) {
        if ($node.Module -cin $names) { $null = $selectedNodes.Add($node.Name) }
    }
}
[string[]] $nodeNames = @($selectedNodes)
[Array]::Sort($nodeNames, [StringComparer]::Ordinal)
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
    if ($DeploymentScope -ceq 'code-security') { $rulesetModules = '[]' }
    $nodeOutput = if ($PSBoundParameters.ContainsKey('DeploymentScope')) {
        'phaseNodes=' + (ConvertTo-Json -InputObject @($nodeNames) -Compress) + "`n"
    } else { '' }
    [System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($GitHubOutputPath),
        "modules=$json`n${nodeOutput}environments=$environmentJson`napplyEnvironments=$applyJson`nrulesetEnvironments=$rulesetJson`nrulesetModules=$rulesetModules`n",
        [System.Text.UTF8Encoding]::new($false))
}
$json
