#Requires -Version 7.4
[CmdletBinding()]
[OutputType([string])]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [string] $TrustedInstancePath,
    [string] $TrustedModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [string] $GitHubOutputPath,
    [string] $DeploymentScope = 'full'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
if ($DeploymentScope -cnotin @('full', 'code-security', 'catalog')) {
    throw "Invalid DeploymentScope '$DeploymentScope': expected 'full', 'code-security' or 'catalog'."
}
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
if ($TrustedInstancePath) {
    $trustedModules = Get-PlatformModuleGraph -ModulesPath $TrustedModulesPath
    $trusted = Get-PlatformInstance -Path $TrustedInstancePath -Modules $trustedModules
    # Compare common implicit defaults without changing either validated instance.
    $comparisonCredentials = @(foreach ($configuration in @($instance, $trusted)) {
        $credentials = ConvertFrom-Json -InputObject (ConvertTo-PlatformCanonicalJson $configuration['credentials']) `
            -AsHashtable -Depth 100 -NoEnumerate
        Add-PlatformCredentialDefault -Credentials $credentials -Modules $modules
        Add-PlatformCredentialDefault -Credentials $credentials -Modules $trustedModules
        $credentials
    })
    foreach ($field in @('credentials', 'githubApps')) {
        $candidateValue = if ($field -ceq 'credentials') { $comparisonCredentials[0] } else { $instance[$field] }
        $trustedValue = if ($field -ceq 'credentials') { $comparisonCredentials[1] } else { $trusted[$field] }
        if ((ConvertTo-PlatformCanonicalJson $candidateValue) -cne (ConvertTo-PlatformCanonicalJson $trustedValue)) {
            throw "PR changes protected $field bindings. Cloud plan must run from main after review and merge."
        }
    }
}
$phaseNodes = Get-PlatformModulePhaseGraph -Modules $modules
if ($DeploymentScope -cin @('code-security', 'catalog')) {
    if (-not $instance['modules'].Contains('enterprise-baseline') -or
        -not $phaseNodes.Contains('enterprise-baseline:code-security')) {
        throw 'Code Security deployment requires a configured enterprise-baseline module and its declared code-security phase.'
    }
    if ($DeploymentScope -ceq 'catalog' -and
        (-not $instance['modules'].Contains('actions-catalog') -or -not $phaseNodes.Contains('actions-catalog'))) {
        throw 'Catalog deployment requires a configured actions-catalog module.'
    }
    $pending = [System.Collections.Generic.Queue[string]]::new()
    $seed = if ($DeploymentScope -ceq 'catalog') { 'actions-catalog' } else { 'enterprise-baseline:code-security' }
    $pending.Enqueue($seed)
    $selectedNodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $nodeName = $pending.Dequeue()
        if ($selectedNodes.Add($nodeName)) {
            foreach ($prerequisite in $phaseNodes[$nodeName].Prerequisites) {
                $pending.Enqueue($prerequisite)
            }
        }
    }
    if ($DeploymentScope -ceq 'catalog' -and
        (-not $selectedNodes.Contains('enterprise-baseline:code-security') -or
            -not $selectedNodes.Contains('organization-rulesets') -or
            $selectedNodes.Contains('enterprise-baseline'))) {
        throw 'Catalog deployment requires the early Code Security and organization-rulesets prerequisites without the late enterprise-baseline root.'
    }
}
else {
    $selectedNodes = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($nodeName in (Get-PlatformModuleSelection -Instance $instance -Modules $modules -PhaseNodes)) {
        $null = $selectedNodes.Add($nodeName)
    }
}
$moduleNames = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($nodeName in $selectedNodes) { $null = $moduleNames.Add($phaseNodes[$nodeName].Module) }
[string[]] $names = @($moduleNames)
[Array]::Sort($names, [StringComparer]::Ordinal)
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
    $rulesetModules = ConvertTo-Json -InputObject @($names | Where-Object {
        $selectedNodes.Contains($_) -and $modules[$_]['permissions']['githubApp'].Contains('rulesetPlan')
    }) -Compress
    $nodeOutput = if ($PSBoundParameters.ContainsKey('DeploymentScope')) {
        'phaseNodes=' + (ConvertTo-Json -InputObject @($nodeNames) -Compress) + "`n"
    } else { '' }
    [System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($GitHubOutputPath),
        "modules=$json`n${nodeOutput}environments=$environmentJson`napplyEnvironments=$applyJson`nrulesetEnvironments=$rulesetJson`nrulesetModules=$rulesetModules`n",
        [System.Text.UTF8Encoding]::new($false))
}
$json
