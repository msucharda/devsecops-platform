#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1')
Import-Module (Get-ToolDependencyPath -Name powershell-yaml -ReuseLoaded)

# security-check: github-app-owner
function Test-PlatformGitHubAppOwner {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [AllowNull()][object] $Owner,
        [Parameter(Mandatory)][string] $Enterprise
    )

    # GET /app documents owner as oneOf simple-user or enterprise. GHE.com returns simple-user with
    # type 'enterprise' for enterprise-owned Apps. Any other shape fails closed.
    if ($Owner -isnot [System.Collections.IDictionary]) { return $false }
    $id = $Owner['id']
    $identified = ($id -is [int] -or $id -is [long]) -and $id -gt 0 -and
        $Owner['node_id'] -is [string] -and -not [string]::IsNullOrWhiteSpace($Owner['node_id'])
    if (-not $identified) { return $false }
    if ($Owner.Contains('login')) {
        return $Owner['type'] -is [string] -and $Owner['type'] -ieq 'enterprise' -and
            $Owner['login'] -is [string] -and $Owner['login'] -ieq $Enterprise
    }
    return -not $Owner.Contains('type') -and $Owner['slug'] -is [string] -and $Owner['slug'] -ceq $Enterprise
}

function Get-PlatformYaml {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Yaml')][string] $Yaml
    )

    try {
        if ($PSCmdlet.ParameterSetName -eq 'Path') {
            $Yaml = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        }
        else { $Path = '<inline>' }
        $documents = @(ConvertFrom-Yaml -Yaml $Yaml -AllDocuments -ErrorAction Stop)
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
        $parameterSchemaPath = Join-Path $ModulesPath "$name/parameters.schema.json"
        if (Test-Path -LiteralPath $parameterSchemaPath -PathType Leaf) {
            try {
                $parameterSchema = Get-Content -LiteralPath $parameterSchemaPath -Raw -ErrorAction Stop |
                    ConvertFrom-Json -AsHashtable -NoEnumerate -ErrorAction Stop
            }
            catch { throw "Invalid module parameter schema '$parameterSchemaPath': $($_.Exception.Message)" }
            if ($parameterSchema -isnot [System.Collections.IDictionary]) {
                throw "Module parameter schema '$parameterSchemaPath' must be an object."
            }
            $checkSchema = {
                param($Value)
                if ($Value -is [System.Collections.IDictionary]) {
                    foreach ($keyword in @('$ref', '$id', '$anchor', '$dynamicRef', '$recursiveRef')) {
                        if ($Value.Contains($keyword)) { throw "Unsupported schema keyword '$keyword' in '$parameterSchemaPath'." }
                    }
                    foreach ($key in $Value.PSBase.Keys) { & $checkSchema $Value[$key] }
                }
                elseif ($Value -is [System.Collections.IList]) {
                    foreach ($item in $Value) { & $checkSchema $item }
                }
            }
            & $checkSchema $parameterSchema
            if ($parameterSchema['type'] -cne 'object' -or
                $parameterSchema['additionalProperties'] -isnot [bool] -or $parameterSchema['additionalProperties'] -or
                $parameterSchema['properties'] -isnot [System.Collections.IDictionary]) {
                throw "Module parameter schema '$parameterSchemaPath' must declare an object with properties and additionalProperties: false."
            }
            $manifest['parameterSchema'] = $parameterSchema
        }
        elseif (Test-Path -LiteralPath (Join-Path $ModulesPath "$name/variables.tf") -PathType Leaf) {
            throw "Module '$name' is missing parameter schema '$parameterSchemaPath'."
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
        if ($manifest.Contains('phases')) {
            [string[]] $knownPrerequisites = @(Get-PlatformManualPrerequisiteName)
            foreach ($phase in $manifest.phases.PSBase.Keys) {
                if (-not (Test-Path -LiteralPath (Join-Path $ModulesPath "$name/$phase") -PathType Container)) {
                    throw "Module '$name' has no Terraform root for phase '$phase'."
                }
                if ($manifest.phases[$phase].Contains('manualPrerequisites')) {
                    foreach ($prerequisite in $manifest.phases[$phase].manualPrerequisites) {
                        if ($prerequisite -cnotin $knownPrerequisites) {
                            throw "Module '$name' phase '$phase' references unknown manual prerequisite '$prerequisite'."
                        }
                    }
                }
                [string[]] $phasePrerequisites = @($manifest.phases[$phase].prerequisites)
                [System.Array]::Sort($phasePrerequisites, [System.StringComparer]::Ordinal)
                $manifest.phases[$phase].prerequisites = $phasePrerequisites
            }
        }
        [string[]] $prerequisites = @($manifest.prerequisites)
        [System.Array]::Sort($prerequisites, [System.StringComparer]::Ordinal)
        $manifest.prerequisites = $prerequisites
        $modules.Add($manifest.name, $manifest)
    }

    $nodes = Get-PlatformModulePhaseGraph -Modules $modules
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
        foreach ($prerequisite in $nodes[$Name].Prerequisites) {
            & $visit $prerequisite
        }
        $path.RemoveAt($path.Count - 1)
        $visited[$Name] = $true
    }
    foreach ($name in $nodes.PSBase.Keys) {
        & $visit $name
    }
    return $modules
}

function Get-PlatformModulePhaseGraph {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Modules)

    $nodes = [ordered]@{}
    foreach ($name in $Modules.PSBase.Keys) {
        $manifest = $Modules[$name]
        if ($manifest.Contains('phases')) {
            foreach ($phase in @($manifest.phases.PSBase.Keys | Sort-Object -CaseSensitive)) {
                $key = "${name}:$phase"
                $nodes[$key] = [pscustomobject]@{
                    Name = $key; Module = $name; Phase = $phase
                    Prerequisites = @($manifest.phases[$phase].prerequisites)
                    Manifest = $manifest
                }
            }
        }
        $nodes[$name] = [pscustomobject]@{
            Name = $name; Module = $name; Phase = $null
            Prerequisites = @($manifest.prerequisites)
            Manifest = $manifest
        }
    }
    $jobIds = @{}
    foreach ($name in $nodes.PSBase.Keys) {
        $jobId = $name.Replace('-', '_').Replace(':', '_')
        if ($jobIds.ContainsKey($jobId)) {
            throw "Deployment phases '$($jobIds[$jobId])' and '$name' produce the same workflow job ID."
        }
        $jobIds[$jobId] = $name
        foreach ($prerequisite in $nodes[$name].Prerequisites) {
            if (-not $nodes.Contains($prerequisite)) {
                throw "Deployment phase '$name' requires missing prerequisite '$prerequisite'."
            }
        }
    }
    return $nodes
}

# security-check: platform-ordinal-string
function Get-PlatformSortedString {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Value)

    foreach ($item in $Value) {
        if ($item -isnot [string]) {
            throw 'Ordinal string ordering requires only string values.'
        }
    }
    [string[]] $sorted = @($Value)
    [Array]::Sort($sorted, [StringComparer]::Ordinal)
    return $sorted
}

function ConvertTo-PlatformCanonicalJson {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()] $Value)

    $normalize = {
        param($Item)
        if ($Item -is [System.Collections.IDictionary]) {
            $result = [ordered]@{}
            foreach ($key in @(Get-PlatformSortedString -Value @($Item.PSBase.Keys))) {
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
    if ($Declaration['resources']['installationSelection'] -ceq 'none') {
        $scope['repositories'] = @{}
    }
    $schema = Get-PlatformJsonSchema -Name module
    $resourceSchema = $schema.definitions.githubAppResources
    $resourceSchema.definitions = @{ githubOrganization = $schema.definitions.githubOrganization }
    $valid = Test-Json -Json (ConvertTo-Json -InputObject $scope -Depth 100) `
        -Schema (ConvertTo-Json -InputObject $resourceSchema -Depth 100) -ErrorAction SilentlyContinue
    if (-not $valid) {
        throw "Invalid instance configuration: $.modules.$Module.parameters has invalid GitHub App resource scope."
    }
    $scope['organizations'] = @(Get-PlatformSortedString -Value $scope['organizations'])
    if ($scope.Contains('repositories')) {
        foreach ($organization in @($scope['repositories'].PSBase.Keys)) {
            if ($organization -cnotin $scope['organizations']) {
                throw "Invalid instance configuration: $.modules.$Module.parameters references repositories outside the target organizations."
            }
            $scope['repositories'][$organization] = @(Get-PlatformSortedString -Value $scope['repositories'][$organization])
        }
    }
    return $scope
}

# security-check: platform-app-manifest-scope
function Assert-PlatformAppManifestScope {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Declaration,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Expected,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Actual,
        [Parameter(Mandatory)][string] $Context
    )

    if (-not $Declaration['resources'].Contains('installationSelection') -and
        -not $Expected.Contains('repositories') -and $Actual.Contains('repositories') -and
        $Actual['repositories'].Count -eq 0) {
        $Expected['repositories'] = @{}
    }
    if ((ConvertTo-PlatformCanonicalJson $Expected) -cne (ConvertTo-PlatformCanonicalJson $Actual)) {
        throw "$Context resources differ from the module's target resources."
    }
}

function Get-PlatformInstance {
    [CmdletBinding(DefaultParameterSetName = 'Path')]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory, ParameterSetName = 'Path')][string] $Path,
        [Parameter(Mandatory, ParameterSetName = 'Yaml')][string] $Yaml,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Modules,
        [switch] $AllowUnboundApps
    )

    $instance = if ($PSCmdlet.ParameterSetName -eq 'Yaml') {
        $Path = '<inline>'
        Get-PlatformYaml -Yaml $Yaml
    }
    else { Get-PlatformYaml -Path $Path }
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
    foreach ($name in $Modules.PSBase.Keys) {
        if (-not $Modules[$name].Contains('parameterSchema')) { continue }
        $parameterSchema = $Modules[$name]['parameterSchema']
        $entry = @{
            allOf = @(
                @{ '$ref' = '#/definitions/moduleEntry' }
                @{
                    properties = @{ parameters = $parameterSchema }
                }
            )
        }
        if ($parameterSchema.Contains('required') -and $parameterSchema['required'].Count -gt 0) {
            $entry.allOf[1]['required'] = @('parameters')
        }
        $schema.properties.modules.properties[$name] = $entry
    }
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
            $app['resources']['organizations'] = @(Get-PlatformSortedString -Value $app['resources']['organizations'])
        }
        if ($app['resources'].Contains('repositories')) {
            foreach ($organization in @($app['resources']['repositories'].PSBase.Keys)) {
                if ($organization -cnotin $app['resources']['organizations']) {
                    throw "Invalid instance configuration '$Path': $.githubApps.$alias.resources has repositories outside its organizations."
                }
                $app['resources']['repositories'][$organization] = @(Get-PlatformSortedString -Value $app['resources']['repositories'][$organization])
            }
        }
    }
    $selected = Get-PlatformModuleSelection -Instance $instance -Modules $Modules
    foreach ($name in $selected) {
        if ($Modules[$name].Contains('parameterSchema') -and
            $Modules[$name]['parameterSchema'].Contains('required') -and
            $Modules[$name]['parameterSchema']['required'].Count -gt 0 -and
            -not $instance['modules'].Contains($name)) {
            throw "Invalid instance configuration '$Path': $.modules.$name is required by the selected prerequisites and must declare its required parameters."
        }
    }
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
                    Assert-PlatformAppManifestScope -Declaration $declaration -Expected $resources -Actual $identity['resources'] `
                        -Context "Invalid instance configuration '$Path': $bindingPath.githubApp"
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

function Get-PlatformAppInstallationRequirement {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Modules,
        [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]*(-[a-z0-9]+)*\.ghe\.com$')][string] $GitHubHost
    )

    foreach ($name in (Get-PlatformModuleSelection -Instance $Instance -Modules $Modules)) {
        foreach ($phase in @('plan', 'apply', 'rulesetPlan')) {
            if (-not $Modules[$name]['permissions']['githubApp'].Contains($phase)) { continue }
            $declaration = $Modules[$name]['permissions']['githubApp'][$phase]
            if ($declaration['resources'].Contains('enterprise')) { continue }
            $resources = Get-PlatformAppScope -Instance $Instance -Module $name -Declaration $declaration
            $binding = $Instance['credentials'][$name][$phase]
            $alias = $binding['githubApp']
            $appId = if ($alias) { $Instance['githubApps'][$alias]['appId'] } else { $null }
            foreach ($organization in $resources['organizations']) {
                $selection = 'all'
                $repositories = @()
                if ($resources.Contains('repositories')) {
                    $selection = 'none'
                    if ($resources['repositories'].Contains($organization)) {
                        $repositories = @($resources['repositories'][$organization])
                        $selection = 'selected'
                    }
                }
                [pscustomobject]@{
                    module = $name
                    phase = $phase
                    organization = $organization
                    repositorySelection = $selection
                    repositories = $repositories
                    permissions = $declaration['permissions']
                    appAlias = $alias
                    appId = $appId
                    registrationRequired = -not [bool] $alias
                    organizationSettingsUrl = "https://$GitHubHost/organizations/$organization/settings/installations"
                }
            }
        }
    }
}

function Get-PlatformModuleSelection {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Modules,
        [switch] $PhaseNodes
    )

    $nodes = Get-PlatformModulePhaseGraph -Modules $Modules
    $pending = [System.Collections.Generic.Queue[string]]::new()
    foreach ($name in $Instance['modules'].PSBase.Keys) {
        $pending.Enqueue($name)
        foreach ($node in $nodes.PSBase.Values) {
            if ($node.Module -ceq $name -and $node.Phase) {
                $pending.Enqueue($node.Name)
            }
        }
    }
    $selected = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $name = $pending.Dequeue()
        if ($selected.Add($name)) {
            foreach ($prerequisite in $nodes[$name].Prerequisites) {
                $pending.Enqueue($prerequisite)
            }
        }
    }
    if ($PhaseNodes) {
        [string[]] $names = @($selected)
    }
    else {
        $moduleNames = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($name in $selected) { $null = $moduleNames.Add($nodes[$name].Module) }
        [string[]] $names = @($moduleNames)
    }
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    return ,$names
}

# Confirmed only after the instance repository exists, so bootstrap cannot require them.
$script:PostBootstrapManualPrerequisite = @('liveWorkflowsPromoted', 'organizationSecurityTeamsLinked')

function Get-PlatformManualPrerequisiteName {
    [CmdletBinding()]
    [OutputType([string])]
    param([ValidateSet('All', 'Bootstrap')][string] $Scope = 'All')

    $schema = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../schemas/instance.schema.json') -Raw |
        ConvertFrom-Json -AsHashtable
    $names = $schema['properties']['manualPrerequisites']['properties'].PSBase.Keys
    if ($Scope -eq 'Bootstrap') { $names = $names | Where-Object { $_ -cnotin $script:PostBootstrapManualPrerequisite } }
    $names
}

function Get-PlatformManualPrerequisite {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [string[]] $Name,
        [ValidateSet('All', 'Bootstrap')][string] $Scope = 'All'
    )

    $names = if ($PSBoundParameters.ContainsKey('Name')) { $Name } else { Get-PlatformManualPrerequisiteName -Scope $Scope }
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

    $arguments = @{ Instance = $Instance; Scope = 'Bootstrap' }
    if ($PSBoundParameters.ContainsKey('Name')) { $arguments.Name = $Name }
    $missing = @(Get-PlatformManualPrerequisite @arguments | Where-Object { -not $_.Confirmed } | ForEach-Object { $_.Name })
    if ($missing.Count -gt 0) {
        throw "$Subject requires manual prerequisite confirmations: $(($missing | ForEach-Object { '$.manualPrerequisites.' + $_ }) -join ', ')."
    }
}

# security-check: bootstrap-request-policy
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

function Get-PlatformInstanceOrganization {
    <#
    .SYNOPSIS
    Derives the deployment identifier and organization names from the platform organization that owns the instance repository.
    .DESCRIPTION
    {name}-{deployment}-platform yields the identifier; the legacy {name}-platform has none and keeps {name}-actions and {name}-workloads.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param(
        [Parameter(Mandatory)][string] $InstanceName,
        [Parameter(Mandatory)][AllowEmptyString()][string] $PlatformOrganization
    )

    if ($InstanceName -cnotmatch '^[a-z][a-z0-9]{1,7}$') {
        throw 'Organization names require instance.name with 2-8 lowercase alphanumeric characters.'
    }
    if ($PlatformOrganization -ceq "$InstanceName-platform") {
        return [ordered]@{
            deploymentIdentifier = $null
            platform = $PlatformOrganization
            actions = "$InstanceName-actions"
            workloads = "$InstanceName-workloads"
        }
    }
    $match = [regex]::Match($PlatformOrganization, "^$InstanceName-([a-z0-9]{6})-platform\z")
    if (-not $match.Success) {
        throw "Platform organization '$PlatformOrganization' does not match instance.name '$InstanceName': expected '$InstanceName-{deployment}-platform' with a 6-character lowercase alphanumeric deployment identifier, or the legacy '$InstanceName-platform'."
    }
    $identifier = $match.Groups[1].Value
    [ordered]@{
        deploymentIdentifier = $identifier
        platform = $PlatformOrganization
        actions = Get-PlatformOrganizationName -InstanceName $InstanceName -DeploymentIdentifier $identifier -Kind actions
        workloads = Get-PlatformOrganizationName -InstanceName $InstanceName -DeploymentIdentifier $identifier -Kind workloads
    }
}

# security-check: module-organization-scope
function Get-PlatformModuleOrganization {
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][AllowEmptyString()][string] $PlatformOrganization,
        [string] $Organization
    )

    $names = Get-PlatformInstanceOrganization -InstanceName $Instance['instance']['name'] -PlatformOrganization $PlatformOrganization
    [string[]] $expected = @($names.platform, $names.actions, $names.workloads)
    $parameters = $Instance['modules'][$Manifest.name]['parameters']
    if ($parameters -isnot [System.Collections.IDictionary]) {
        throw "Organization-scoped module '$($Manifest.name)' requires module parameters."
    }
    $targets = $parameters['target_organizations']
    if ($targets -isnot [System.Collections.IList]) {
        throw "Organization-scoped module '$($Manifest.name)' requires a target_organizations list."
    }
    $expectedJson = ConvertTo-PlatformCanonicalJson @(Get-PlatformSortedString -Value $expected)
    if ((ConvertTo-PlatformCanonicalJson @(Get-PlatformSortedString -Value $targets)) -cne $expectedJson) {
        throw "Organization-scoped module '$($Manifest.name)' target_organizations must contain exactly all instance organizations: $($expected -join ', ')."
    }
    if ($Manifest.Contains('organizationParameters')) {
        foreach ($parameter in $Manifest['organizationParameters']) {
            $values = $parameters[$parameter]
            if ($values -isnot [System.Collections.IDictionary]) {
                throw "Organization parameter '$parameter' must be a mapping keyed by organization; a shared value cannot be copied across organizations."
            }
            if ((ConvertTo-PlatformCanonicalJson @(Get-PlatformSortedString -Value @($values.PSBase.Keys))) -cne $expectedJson) {
                throw "Organization parameter '$parameter' must contain exactly all instance organization keys."
            }
        }
    }
    if ($Organization -and $Organization -cnotin $expected) {
        throw "Organization '$Organization' is not an instance organization."
    }
    return $expected
}

# security-check: module-organization-token
function Get-PlatformOrganizationToken {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string[]] $Organization,
        [AllowNull()][AllowEmptyString()][string] $Json
    )

    if ([string]::IsNullOrWhiteSpace($Json)) {
        throw 'Organization-scoped execution requires a readable PLATFORM_GITHUB_TOKENS object.'
    }
    try { $tokens = ConvertFrom-Json -InputObject $Json -AsHashtable -NoEnumerate -ErrorAction Stop }
    catch { throw 'Organization-scoped execution requires a readable PLATFORM_GITHUB_TOKENS object.' }
    if ($tokens -isnot [System.Collections.IDictionary]) {
        throw 'Organization-scoped execution requires a PLATFORM_GITHUB_TOKENS object.'
    }
    if ((ConvertTo-PlatformCanonicalJson @(Get-PlatformSortedString -Value @($tokens.PSBase.Keys))) -cne
        (ConvertTo-PlatformCanonicalJson @(Get-PlatformSortedString -Value $Organization))) {
        throw 'Organization token keys must match exactly the execution organizations.'
    }
    foreach ($name in $Organization) {
        if ($tokens[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($tokens[$name])) {
            throw "Organization '$name' requires a non-blank installation token."
        }
    }
    return $tokens
}

Export-ModuleMember -Function Get-PlatformYaml, Get-PlatformModuleGraph, Get-PlatformModulePhaseGraph, Get-PlatformInstance, Get-PlatformModuleSelection, Get-PlatformAppInstallationRequirement, ConvertTo-PlatformCanonicalJson, Get-PlatformSortedString, Get-PlatformManualPrerequisite, Assert-PlatformManualPrerequisite, Test-PlatformGitHubAppOwner, Assert-PlatformBootstrapRequest, Get-RandomPlatformDeploymentIdentifier, Get-PlatformOrganizationName, Get-PlatformInstanceOrganization, Get-PlatformModuleOrganization, Get-PlatformOrganizationToken, Test-PlatformReleaseFile
