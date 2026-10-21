#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module powershell-yaml -RequiredVersion 0.4.12

function Test-PlatformGitHubAppOwner {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][object] $Owner,
        [Parameter(Mandatory)][string] $Enterprise
    )

    if ($Owner -isnot [System.Collections.IDictionary]) { return $false }
    if ($Owner.Contains('login')) {
        return $Owner['type'] -ieq 'enterprise' -and $Owner['login'] -ieq $Enterprise
    }
    return -not $Owner.Contains('type') -and $Owner['slug'] -ceq $Enterprise -and
        [string] $Owner['id'] -cmatch '^[1-9][0-9]*$' -and -not [string]::IsNullOrWhiteSpace($Owner['node_id'])
}

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

function Get-PlatformJsonSchema {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][ValidateSet('instance', 'module')][string] $Name)

    $schemas = @{
        module = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/module.schema.json') -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    if ($Name -ceq 'instance') {
        $schemas['instance'] = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/instance.schema.json') -Raw -ErrorAction Stop |
            ConvertFrom-Json -AsHashtable -ErrorAction Stop
        if ($schemas['instance'].definitions.Contains('platformModuleSchema')) {
            throw 'The instance schema uses the reserved platformModuleSchema definition.'
        }
    }
    $rewrite = {
        param($Value, [string] $Source)
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($keyword in @('$id', '$anchor', '$dynamicRef', '$recursiveRef')) {
                if ($Value.Contains($keyword)) { throw "Unsupported schema keyword '$keyword' in the local $Source schema." }
            }
            if ($Value.Contains('$ref')) {
                $reference = $Value['$ref']
                if ($reference -isnot [string] -or $reference -cnotmatch '^(module\.schema\.json)?#/definitions/([A-Za-z][A-Za-z0-9]*)$') {
                    throw "Unsupported schema reference in the local $Source schema."
                }
                $target = if ($Matches[1]) { 'module' } else { $Source }
                $definition = $Matches[2]
                if (-not $schemas[$target].definitions.Contains($definition)) {
                    throw "Missing schema definition '$definition' in the local $target schema."
                }
                $prefix = if ($Name -ceq 'instance' -and $target -ceq 'module') { '#/definitions/platformModuleSchema' } else { '#' }
                $Value['$ref'] = "$prefix/definitions/$definition"
            }
            foreach ($key in @($Value.PSBase.Keys)) { & $rewrite $Value[$key] $Source }
        }
        elseif ($Value -is [System.Collections.IList]) {
            foreach ($item in $Value) { & $rewrite $item $Source }
        }
    }
    foreach ($source in @($schemas.Keys)) { & $rewrite $schemas[$source] $source }
    if ($Name -ceq 'instance') {
        # Rebase the sibling's own references as well as references from the instance schema.
        $schemas['instance'].definitions['platformModuleSchema'] = $schemas['module']
    }
    return $schemas[$Name]
}

function Get-PlatformModuleGraph {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $ModulesPath)

    $schema = ConvertTo-Json -InputObject (Get-PlatformJsonSchema -Name module) -Depth 100
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
                -Schema $schema -ErrorAction Stop
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
                    -not $declaration.resources.Contains('organizations') -or
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
        if ($manifest.Contains('manualPrerequisites')) {
            [string[]] $knownPrerequisites = @(Get-PlatformManualPrerequisiteName)
            foreach ($prerequisite in $manifest.manualPrerequisites) {
                if ($prerequisite -cnotin $knownPrerequisites) {
                    throw "Module '$name' references unknown manual prerequisite '$prerequisite'."
                }
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

    if ($Declaration['resources'].Contains('enterprise')) {
        return @{ enterprise = $true }
    }
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
    $schema = Get-PlatformJsonSchema -Name module
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
        [Parameter(Mandatory)][System.Collections.IDictionary] $Modules,
        [switch] $AllowUnboundApps
    )

    $instance = Get-PlatformYaml -Path $Path
    foreach ($field in @('instance', 'regions', 'teams', 'modules')) {
        if (-not $instance.Contains($field)) {
            throw "Invalid instance configuration '$Path': $.$field is required."
        }
    }
    if ($instance['modules'] -is [System.Collections.IDictionary]) {
        $manifestSchema = Get-PlatformJsonSchema -Name module
        $nameSchema = ConvertTo-Json -InputObject $manifestSchema['definitions']['moduleName'] -Compress
        foreach ($name in $instance['modules'].PSBase.Keys) {
            if (-not (Test-Json -Json (ConvertTo-Json -InputObject $name -Compress) -Schema $nameSchema -ErrorAction SilentlyContinue)) {
                throw "Invalid instance configuration '$Path': $.modules.$name has an invalid module name."
            }
        }
    }
    $schema = Get-PlatformJsonSchema -Name instance
    $schemaJson = ConvertTo-Json -InputObject $schema -Depth 100
    $instanceJson = ConvertTo-Json -InputObject $instance -Depth 100 -Compress
    $validationErrors = @()
    $valid = Test-Json -Json $instanceJson -Schema $schemaJson `
        -ErrorAction SilentlyContinue -ErrorVariable validationErrors
    if (-not $valid) {
        $messages = @(foreach ($errorRecord in $validationErrors) {
            $errorRecord.Exception.Message -replace "at '(/[^']*)'", {
                "at '$" + $_.Groups[1].Value.TrimEnd('/').Replace('/', '.') + "'"
            }
        })
        if ($messages.Count -eq 0) {
            # PowerShell 7.6 can reject nested data without emitting its validation errors.
            $options = [Json.Schema.EvaluationOptions]::new()
            $options.OutputFormat = [Json.Schema.OutputFormat]::List
            $evaluation = [Json.Schema.JsonSchema]::FromText($schemaJson).Evaluate(
                [System.Text.Json.Nodes.JsonNode]::Parse($instanceJson), $options)
            $messages = @(foreach ($result in @($evaluation) + @($evaluation.Details)) {
                if ($result.HasErrors) {
                    $location = '$' + $result.InstanceLocation.ToString().Replace('/', '.')
                    foreach ($message in $result.Errors.Values) { "$message at '$location'" }
                }
            })
            if ($messages.Count -eq 0) {
                throw "Invalid instance configuration '$Path': Test-Json rejected the data without diagnostic details."
            }
        }
        throw "Invalid instance configuration '$Path': $($messages -join '; ')"
    }
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
        if ($app['resources'].Contains('organizations')) {
            $app['resources']['organizations'] = @($app['resources']['organizations'] | Sort-Object -CaseSensitive)
        }
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
            if ($environment -in @('approve-apply', 'pr-authorization', 'approve-teardown-platform', 'teardown', 'drift-report')) {
                throw "Invalid instance configuration '$Path': $bindingPath.environment is reserved for a workflow gate."
            }
            $explicit = $name -cin $configuredModules
            $environmentNames = @($environment)
            if ($phase -ne 'apply') { $environmentNames += "$environment-drift" }
            foreach ($environmentName in $environmentNames) {
                if ($environmentName.Length -gt 255) {
                    throw "Invalid instance configuration '$Path': $bindingPath.environment exceeds 255 characters including the drift suffix."
                }
                if ($environmentBindings.ContainsKey($environmentName)) {
                    $previous = $environmentBindings[$environmentName]
                    $invalidPath = if ($explicit -or -not $previous['explicit']) { $bindingPath } else { $previous['path'] }
                    throw "Invalid instance configuration '$Path': $invalidPath.environment shares an environment with another module or phase."
                }
                $environmentBindings[$environmentName] = @{ path = $bindingPath; explicit = $explicit }
            }
            $declaration = $Modules[$name].permissions.githubApp[$phase]
            if ($phase -eq 'rulesetPlan' -and -not $declaration) {
                throw "Invalid instance configuration '$Path': $bindingPath requires a declared ruleset exception."
            }
            if ($declaration -and $name -cin $selected -and -not $binding.Contains('githubApp') -and -not $AllowUnboundApps) {
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
                    if (-not $resources.Contains('repositories') -and $identity['resources'].Contains('repositories') -and
                        $identity['resources']['repositories'].Count -eq 0) {
                        $resources['repositories'] = @{}
                    }
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

function Get-PlatformManualPrerequisiteName {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/instance.schema.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $schema['properties']['manualPrerequisites']['properties'].PSBase.Keys
}

function Get-PlatformManualPrerequisite {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [string[]] $Name
    )

    $names = if ($PSBoundParameters.ContainsKey('Name')) { $Name } else { Get-PlatformManualPrerequisiteName }
    foreach ($prerequisite in $names) {
        [pscustomobject]@{
            Name = $prerequisite
            Confirmed = $Instance['manualPrerequisites'].Contains($prerequisite) -and $Instance['manualPrerequisites'][$prerequisite] -is [bool] -and $Instance['manualPrerequisites'][$prerequisite]
        }
    }
}

function Assert-PlatformManualPrerequisite {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [string[]] $Name,
        [string] $Subject = 'Bootstrap'
    )

    $arguments = @{ Instance = $Instance }
    if ($PSBoundParameters.ContainsKey('Name')) { $arguments.Name = $Name }
    $missing = @(Get-PlatformManualPrerequisite @arguments | Where-Object { -not $_.Confirmed } | ForEach-Object { $_.Name })
    if ($missing.Count -gt 0) {
        throw "$Subject requires manual prerequisite confirmations: $(($missing | ForEach-Object { '$.manualPrerequisites.' + $_ }) -join ', ')."
    }
}

function Assert-PlatformBootstrapRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Uri,
        [Parameter(Mandatory)][string] $Method,
        [System.Collections.IDictionary] $Body,
        [switch] $NoChanges,
        [switch] $ReadOnlyPost,
        [ValidateSet('Read', 'Reconcile', 'TokenIssue', 'TokenRevoke')][string] $Kind = 'Read',
        [scriptblock] $RequestPolicy
    )

    if ($NoChanges -and $Method -cne 'GET' -and -not ($Method -ceq 'POST' -and $ReadOnlyPost)) {
        throw "NoChanges refuses $Method '$Uri' before sending the request."
    }
    if ($RequestPolicy) {
        $decision = @(& $RequestPolicy ([pscustomobject]@{ Uri = $Uri; Method = $Method; Body = $Body; Kind = $Kind }))
        if ($decision.Count -ne 1 -or $decision[0] -isnot [bool] -or -not $decision[0]) {
            throw "The bootstrap request policy did not authorize $Method '$Uri'."
        }
    }
}

function Get-RandomPlatformDeploymentIdentifier {
    [CmdletBinding()]
    [OutputType([string])]
    param()

    $alphabet = 'abcdefghijklmnopqrstuvwxyz0123456789'
    -join (1..6 | ForEach-Object { $alphabet[[Security.Cryptography.RandomNumberGenerator]::GetInt32($alphabet.Length)] })
}

function Get-PlatformOrganizationName {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $InstanceName,
        [Parameter(Mandatory)][string] $DeploymentIdentifier,
        [Parameter(Mandatory)][ValidateSet('platform', 'actions', 'workloads')][string] $Kind
    )

    if ($InstanceName -cnotmatch '^[a-z][a-z0-9]{1,7}$' -or $DeploymentIdentifier -cnotmatch '^[a-z0-9]{6}$') {
        throw 'Organization names require instance.name with 2-8 lowercase alphanumeric characters and a deployment identifier with 6 lowercase alphanumeric characters.'
    }
    "$InstanceName-$DeploymentIdentifier-$Kind"
}

Export-ModuleMember -Function Get-PlatformYaml, Get-PlatformModuleGraph, Get-PlatformInstance, Get-PlatformModuleSelection, ConvertTo-PlatformCanonicalJson, Get-PlatformManualPrerequisite, Assert-PlatformManualPrerequisite, Test-PlatformGitHubAppOwner, Assert-PlatformBootstrapRequest, Get-RandomPlatformDeploymentIdentifier, Get-PlatformOrganizationName
