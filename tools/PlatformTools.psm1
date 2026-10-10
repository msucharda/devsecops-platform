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
        foreach ($phase in $manifest.permissions.githubApp.PSBase.Keys) {
            $declaration = $manifest.permissions.githubApp[$phase]
            if ($phase -eq 'plan' -and 'write' -cin @($declaration.permissions.PSBase.Values)) {
                throw "Module '$name': ordinary plan permissions must be read-only."
            }
            if ($phase -eq 'rulesetPlan') {
                if (-not $declaration.Contains('purpose') -or
                    $declaration.permissions.Count -ne 1 -or
                    $declaration.permissions['organization_administration'] -cne 'write' -or
                    $declaration.resources.Contains('repositories')) {
                    throw "Module '$name': rulesetPlan must declare the organization-rulesets-full-read exception with only organization_administration: write for target organizations."
                }
            }
            elseif ($declaration.Contains('purpose')) {
                throw "Module '$name': the ruleset exception is only valid in rulesetPlan."
            }
        }
        if ($manifest.permissions.githubApp.Contains('rulesetPlan') -and
            $manifest.permissions.githubApp['apply']['permissions']['organization_administration'] -cne 'write') {
            throw "Module '$name': apply must declare organization_administration: write to apply its rulesets root."
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

function ConvertTo-PlatformCanonicalJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()] $Value)

    $normalize = {
        param($Item)
        if ($Item -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in @($Item.PSBase.Keys | Sort-Object -CaseSensitive)) {
                $result[$key] = & $normalize $Item[$key]
            }
            return $result
        }
        if ($Item -is [System.Collections.IList]) {
            return ,@($Item | ForEach-Object { & $normalize $_ })
        }
        return $Item
    }
    ConvertTo-Json -InputObject (& $normalize $Value) -Depth 100 -Compress
}

function Get-PlatformAppScope {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [Parameter(Mandatory)][string] $Module,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Declaration
    )

    $parameters = @{}
    if ($Instance['modules'].Contains($Module) -and $Instance['modules'][$Module].Contains('parameters')) {
        $parameters = $Instance['modules'][$Module]['parameters']
    }
    $scope = [ordered]@{}
    foreach ($kind in @('organizations', 'repositories')) {
        if ($Declaration['resources'].Contains($kind)) {
            $parameter = $Declaration['resources'][$kind]
            if (-not $parameters.Contains($parameter)) {
                throw "Invalid instance configuration: $.modules.$Module.parameters.$parameter must declare GitHub App resources."
            }
            $scope[$kind] = $parameters[$parameter]
        }
    }
    $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/module.schema.json') -Raw | ConvertFrom-Json -AsHashtable
    $resourceSchema = $schema.definitions.githubAppResources
    $resourceSchema.definitions = @{ githubOrganization = $schema.definitions.githubOrganization }
    $valid = Test-Json -Json (ConvertTo-Json -InputObject $scope -Depth 100) `
        -Schema (ConvertTo-Json -InputObject $resourceSchema -Depth 100) -ErrorAction SilentlyContinue
    if (-not $valid) {
        throw "Invalid instance configuration: $.modules.$Module.parameters has invalid GitHub App resource scope."
    }
    $scope['organizations'] = @($scope['organizations'] | Sort-Object -CaseSensitive)
    if ($scope.Contains('repositories')) {
        foreach ($organization in @($scope['repositories'].PSBase.Keys)) {
            if ($organization -cnotin $scope['organizations']) {
                throw "Invalid instance configuration: $.modules.$Module.parameters references repositories outside the target organizations."
            }
            $scope['repositories'][$organization] = @($scope['repositories'][$organization] | Sort-Object -CaseSensitive)
        }
    }
    return $scope
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
    $appContracts = @{}
    foreach ($alias in $instance['githubApps'].PSBase.Keys) {
        $app = $instance['githubApps'][$alias]
        $app['resources']['organizations'] = @($app['resources']['organizations'] | Sort-Object -CaseSensitive)
        if ($app['resources'].Contains('repositories')) {
            foreach ($organization in @($app['resources']['repositories'].PSBase.Keys)) {
                if ($organization -cnotin $app['resources']['organizations']) {
                    throw "Invalid instance configuration '$Path': $.githubApps.$alias.resources has repositories outside its organizations."
                }
                $app['resources']['repositories'][$organization] = @($app['resources']['repositories'][$organization] | Sort-Object -CaseSensitive)
            }
        }
    }
    $selected = Get-PlatformModuleSelection -Instance $instance -Modules $Modules
    foreach ($name in $Modules.PSBase.Keys) {
        if (-not $instance['credentials'].Contains($name)) {
            $instance['credentials'][$name] = @{
                plan = @{ environment = "$name-plan" }
                apply = @{ environment = "$name-apply" }
            }
        }
        if ($Modules[$name].permissions.githubApp.Contains('rulesetPlan') -and -not $instance['credentials'][$name].Contains('rulesetPlan')) {
            $instance['credentials'][$name]['rulesetPlan'] = @{ environment = "$name-ruleset-plan" }
        }
        foreach ($phase in @('plan', 'apply', 'rulesetPlan')) {
            if (-not $instance['credentials'][$name].Contains($phase)) {
                continue
            }
            $binding = $instance['credentials'][$name][$phase]
            $bindingPath = "$.credentials.$name.$phase"
            $environment = $binding['environment']
            if ($environment -in @('approve-apply', 'pr-authorization')) {
                throw "Invalid instance configuration '$Path': $bindingPath.environment is reserved for a workflow gate."
            }
            $explicit = $name -cin $configuredModules
            if ($environmentBindings.ContainsKey($environment)) {
                $previous = $environmentBindings[$environment]
                $invalidPath = if ($explicit -or -not $previous['explicit']) { $bindingPath } else { $previous['path'] }
                throw "Invalid instance configuration '$Path': $invalidPath.environment shares an environment with another module or phase."
            }
            $environmentBindings[$environment] = @{ path = $bindingPath; explicit = $explicit }
            $declaration = $Modules[$name].permissions.githubApp[$phase]
            if ($phase -eq 'rulesetPlan' -and -not $declaration) {
                throw "Invalid instance configuration '$Path': $bindingPath requires a declared ruleset exception."
            }
            if ($declaration -and $name -cin $selected -and -not $binding.Contains('githubApp')) {
                throw "Invalid instance configuration '$Path': $bindingPath.githubApp is required by the module manifest."
            }
            if ($binding.Contains('githubApp')) {
                $app = $binding['githubApp']
                if (-not $instance['githubApps'].Contains($app)) {
                    throw "Invalid instance configuration '$Path': $bindingPath.githubApp references unknown App '$app'."
                }
                $identity = $instance['githubApps'][$app]
                if ($phase -eq 'plan' -and 'write' -cin @($identity['permissions'].PSBase.Values)) {
                    throw "Invalid instance configuration '$Path': $bindingPath.githubApp must use a read-only App, not a narrowed token from a write-capable key."
                }
                $expectedPermissions = if ($declaration) { $declaration['permissions'] } else { @{} }
                if ((ConvertTo-PlatformCanonicalJson $identity['permissions']) -cne (ConvertTo-PlatformCanonicalJson $expectedPermissions)) {
                    throw "Invalid instance configuration '$Path': $bindingPath.githubApp permissions differ from the manifest."
                }
                if ($declaration -and $name -cin $selected) {
                    $resources = Get-PlatformAppScope -Instance $instance -Module $name -Declaration $declaration
                    if ((ConvertTo-PlatformCanonicalJson $resources) -cne (ConvertTo-PlatformCanonicalJson $identity['resources'])) {
                        throw "Invalid instance configuration '$Path': $bindingPath.githubApp resources differ from the module's target resources."
                    }
                }
                $appId = $identity['appId']
                $contract = ConvertTo-PlatformCanonicalJson @{
                    phase = $phase
                    enterprise = $identity['enterprise']
                    permissions = $identity['permissions']
                    resources = $identity['resources']
                }
                if ($appContracts.ContainsKey($appId) -and $appContracts[$appId] -cne $contract) {
                    throw "Invalid instance configuration '$Path': $bindingPath.githubApp shares a private-key identity across different phases, permissions or resources."
                }
                $appContracts[$appId] = $contract
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

Export-ModuleMember -Function Get-PlatformYaml, Get-PlatformModuleGraph, Get-PlatformInstance, Get-PlatformModuleSelection, ConvertTo-PlatformCanonicalJson
