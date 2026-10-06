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
$instance = Get-PlatformYaml -Path $InstancePath
if (-not $instance.Contains('modules') -or $instance.modules -isnot [System.Collections.IDictionary]) {
    throw "Invalid instance configuration '$InstancePath': $.modules must be a mapping of selected module names to their configuration."
}

$pending = [System.Collections.Generic.Queue[string]]::new()
foreach ($name in $instance.modules.PSBase.Keys) {
    if ($name -isnot [string] -or $name -cnotmatch '^[a-z][a-z0-9]*(-[a-z0-9]+)*$' -or
        $instance.modules[$name] -isnot [System.Collections.IDictionary]) {
        throw "Invalid instance configuration '$InstancePath': $.modules.$name must be a module name with a configuration mapping."
    }
    if (-not $modules.Contains($name)) {
        throw "Invalid instance configuration '$InstancePath': $.modules.$name selects unknown module '$name'."
    }
    $pending.Enqueue($name)
}

$selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
while ($pending.Count -gt 0) {
    $name = $pending.Dequeue()
    if ($selected.Add($name)) {
        foreach ($prerequisite in $modules[$name].prerequisites) {
            $pending.Enqueue($prerequisite)
        }
    }
}
[string[]] $names = @($selected)
[System.Array]::Sort($names, [System.StringComparer]::Ordinal)
$json = ConvertTo-Json -InputObject $names -Compress
if ($GitHubOutputPath) {
    [System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($GitHubOutputPath), "modules=$json`n", [System.Text.UTF8Encoding]::new($false))
}
$json
