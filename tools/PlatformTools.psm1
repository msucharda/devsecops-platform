#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module powershell-yaml -RequiredVersion 0.4.12

function Get-PlatformYaml {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path)

    try {
        $documents = @(ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -AllDocuments -ErrorAction Stop)
    }
    catch {
        throw "Invalid YAML '$Path': $($_.Exception.Message)"
    }
    if ($documents.Count -ne 1 -or $documents[0] -isnot [System.Collections.IDictionary]) {
        throw "Expected one YAML mapping in '$Path'."
    }
    return $documents[0]
}

function Get-PlatformModuleGraph {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $ModulesPath)

    $modules = [ordered]@{}
    $directories = @(Get-ChildItem -LiteralPath $ModulesPath -Directory -ErrorAction Stop)
    [string[]] $names = @($directories | ForEach-Object { $_.Name })
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    foreach ($name in $names) {
        $manifestPath = Join-Path $ModulesPath "$name/module.yaml"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            continue
        }
        $manifest = Get-PlatformYaml -Path $manifestPath
        try {
            $valid = Test-Json -Json (ConvertTo-Json -InputObject $manifest -Depth 100 -Compress) `
                -SchemaFile (Join-Path $PSScriptRoot '../schemas/module.schema.json') -ErrorAction Stop
        }
        catch {
            throw "Invalid module manifest '$manifestPath': $($_.Exception.Message)"
        }
        if (-not $valid) {
            throw "Invalid module manifest '$manifestPath'."
        }
        if ($modules.Contains($manifest.name)) {
            throw "Duplicate module name '$($manifest.name)'."
        }
        if ($manifest.name -cne $name) {
            throw "Module '$($manifest.name)' must match directory '$name' in '$manifestPath'."
        }
        $manualStepIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($step in $manifest.manualSteps) {
            if (-not $manualStepIds.Add($step.id)) {
                throw "Module '$name' has duplicate manual step '$($step.id)'."
            }
        }
        [string[]] $prerequisites = @($manifest.prerequisites)
        [System.Array]::Sort($prerequisites, [System.StringComparer]::Ordinal)
        $manifest.prerequisites = $prerequisites
        $modules.Add($manifest.name, $manifest)
    }

    foreach ($name in $modules.PSBase.Keys) {
        foreach ($prerequisite in $modules[$name].prerequisites) {
            if (-not $modules.Contains($prerequisite)) {
                throw "Module '$name' requires missing prerequisite '$prerequisite'."
            }
        }
    }

    $visited = @{}
    $path = [System.Collections.Generic.List[string]]::new()
    $visit = {
        param([string] $Name)
        if ($path.Contains($Name)) {
            $cycle = @($path.GetRange($path.IndexOf($Name), $path.Count - $path.IndexOf($Name))) + $Name
            throw "Prerequisite cycle: $($cycle -join ' -> ')."
        }
        if ($visited.ContainsKey($Name)) {
            return
        }
        $path.Add($Name)
        foreach ($prerequisite in $modules[$Name].prerequisites) {
            & $visit $prerequisite
        }
        $path.RemoveAt($path.Count - 1)
        $visited[$Name] = $true
    }
    foreach ($name in $modules.PSBase.Keys) {
        & $visit $name
    }
    return $modules
}

function Get-PlatformInstance {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $Path,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Modules
    )

    $instance = Get-PlatformYaml -Path $Path
    foreach ($field in @('instance', 'regions', 'teams', 'modules')) {
        if (-not $instance.Contains($field)) {
            throw "Invalid instance configuration '$Path': $.$field is required."
        }
    }
    if ($instance['modules'] -is [System.Collections.IDictionary]) {
        $manifestSchema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/module.schema.json') -Raw |
            ConvertFrom-Json -AsHashtable
        $nameSchema = ConvertTo-Json -InputObject $manifestSchema['definitions']['moduleName'] -Compress
        foreach ($name in $instance['modules'].PSBase.Keys) {
            if (-not (Test-Json -Json (ConvertTo-Json -InputObject $name -Compress) -Schema $nameSchema -ErrorAction SilentlyContinue)) {
                throw "Invalid instance configuration '$Path': $.modules.$name has an invalid module name."
            }
        }
    }
    $validationErrors = @()
    $valid = Test-Json -Json (ConvertTo-Json -InputObject $instance -Depth 100 -Compress) `
        -SchemaFile (Join-Path $PSScriptRoot '../schemas/instance.schema.json') `
        -ErrorAction SilentlyContinue -ErrorVariable validationErrors
    if (-not $valid) {
        $messages = foreach ($errorRecord in $validationErrors) {
            $errorRecord.Exception.Message -replace "at '(/[^']*)'", {
                "at '$" + $_.Groups[1].Value.TrimEnd('/').Replace('/', '.') + "'"
            }
        }
        throw "Invalid instance configuration '$Path': $($messages -join '; ')"
    }
    $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/instance.schema.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $checkParameter = {
        param($Value, [string] $ParameterPath)
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($key in $Value.PSBase.Keys) {
                if ($key -cmatch $schema.definitions.parameterName.not.pattern) {
                    throw "Invalid instance configuration '$Path': $ParameterPath.$key must not contain credentials."
                }
                & $checkParameter $Value[$key] "$ParameterPath.$key"
            }
        }
        elseif ($Value -is [System.Collections.IList]) {
            for ($index = 0; $index -lt $Value.Count; $index++) {
                & $checkParameter $Value[$index] "$ParameterPath[$index]"
            }
        }
        elseif ($Value -is [string] -and $Value -cmatch $schema.definitions.parameterString.not.pattern) {
            throw "Invalid instance configuration '$Path': $ParameterPath must not contain private keys or tokens."
        }
    }
    foreach ($name in $instance['modules'].PSBase.Keys) {
        if (-not $Modules.Contains($name)) {
            throw "Invalid instance configuration '$Path': $.modules.$name selects unknown module '$name'."
        }
        if ($instance['modules'][$name].Contains('parameters')) {
            & $checkParameter $instance['modules'][$name]['parameters'] "$.modules.$name.parameters"
        }
    }
    foreach ($field in @('manualPrerequisites', 'manualSteps', 'githubApps', 'credentials')) {
        if (-not $instance.Contains($field)) {
            $instance[$field] = @{}
        }
    }
    if (-not $instance.Contains('customPatterns')) {
        $instance['customPatterns'] = @()
    }
    if (-not $instance.Contains('teardown')) {
        $instance['teardown'] = @{}
    }
    if (-not $instance['teardown'].Contains('allowed')) {
        $instance['teardown']['allowed'] = $false
    }
    $configuredModules = @($instance['credentials'].PSBase.Keys)
    foreach ($name in $configuredModules) {
        if (-not $Modules.Contains($name)) {
            throw "Invalid instance configuration '$Path': $.credentials.$name references an unknown module."
        }
    }
    $environmentBindings = @{}
    $appPhases = @{}
    foreach ($name in $Modules.PSBase.Keys) {
        if (-not $instance['credentials'].Contains($name)) {
            $instance['credentials'][$name] = @{
                plan = @{ environment = "$name-plan" }
                apply = @{ environment = "$name-apply" }
            }
        }
        foreach ($phase in @('plan', 'apply', 'rulesetPlan')) {
            if (-not $instance['credentials'][$name].Contains($phase)) {
                continue
            }
            $binding = $instance['credentials'][$name][$phase]
            $bindingPath = "$.credentials.$name.$phase"
            $environment = $binding['environment']
            $explicit = $name -cin $configuredModules
            if ($environmentBindings.ContainsKey($environment)) {
                $previous = $environmentBindings[$environment]
                $invalidPath = if ($explicit -or -not $previous['explicit']) { $bindingPath } else { $previous['path'] }
                throw "Invalid instance configuration '$Path': $invalidPath.environment shares an environment with another module or phase."
            }
            $environmentBindings[$environment] = @{ path = $bindingPath; explicit = $explicit }
            if ($binding.Contains('githubApp')) {
                $app = $binding['githubApp']
                if (-not $instance['githubApps'].Contains($app)) {
                    throw "Invalid instance configuration '$Path': $bindingPath.githubApp references unknown App '$app'."
                }
                $appId = $instance['githubApps'][$app]['appId']
                if ($appPhases.ContainsKey($appId) -and $appPhases[$appId] -cne $phase) {
                    throw "Invalid instance configuration '$Path': $bindingPath.githubApp shares a private-key identity across phases."
                }
                $appPhases[$appId] = $phase
            }
        }
    }
    foreach ($name in $instance['manualSteps'].PSBase.Keys) {
        if (-not $Modules.Contains($name)) {
            throw "Invalid instance configuration '$Path': $.manualSteps.$name references an unknown module."
        }
        foreach ($id in $instance['manualSteps'][$name].PSBase.Keys) {
            if ($id -cnotin @($Modules[$name]['manualSteps'] | ForEach-Object { $_['id'] })) {
                throw "Invalid instance configuration '$Path': $.manualSteps.$name.$id references an unknown manual step."
            }
        }
    }
    return $instance
}

function Get-PlatformModuleSelection {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Modules
    )

    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($name in $Instance['modules'].PSBase.Keys) {
        $pending.Enqueue($name)
    }
    $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $name = $pending.Dequeue()
        if ($selected.Add($name)) {
            foreach ($prerequisite in $Modules[$name]['prerequisites']) {
                $pending.Enqueue($prerequisite)
            }
        }
    }
    [string[]] $names = @($selected)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    return ,$names
}

Export-ModuleMember -Function Get-PlatformYaml, Get-PlatformModuleGraph, Get-PlatformInstance, Get-PlatformModuleSelection
