#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]*(-[a-z0-9]+)*$')][string] $Module,
    [Parameter(Mandatory)][ValidateSet('plan', 'apply', 'destroy', 'output', 'state')][string] $Action,
    [switch] $Rulesets,
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [ValidateSet('azurerm', 'local')][string] $Backend = 'azurerm',
    [string] $StorageAccountName = $env:PLATFORM_STATE_STORAGE_ACCOUNT,
    [string] $ResourceGroupName = $env:PLATFORM_STATE_RESOURCE_GROUP,
    [string] $StatePath,
    [string] $PrerequisiteOutputsPath,
    [string] $ArtifactsPath = (Join-Path (Get-Location) 'artifacts/module-outputs'),
    [string] $JobSummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string] $GitHubOutputPath,
    [Parameter(DontShow)][string] $Organization,
    # Owner of the instance repository; the organizations of the instance are derived from it.
    [string] $PlatformOrganization
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
$outputName = if ($Rulesets) { "$Module.rulesets" } else { $Module }
$artifactFile = [IO.Path]::GetFullPath((Join-Path $ArtifactsPath "$outputName.json"))
if ($Action -ne 'state' -and (Test-Path -LiteralPath $artifactFile -PathType Leaf)) {
    [IO.File]::Delete($artifactFile)
}
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
if ($GitHubOutputPath -and $Action -ne 'plan') {
    throw 'The workflow change output is supported only for plan.'
}

function Invoke-ModuleTerraform {
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string[]] $Arguments,
        [int[]] $AllowedExitCodes = @(0),
        [switch] $Json
    )

    $text = (& terraform "-chdir=$moduleRoot" @Arguments 2>&1 | Out-String)
    $code = $LASTEXITCODE
    if ($code -notin $AllowedExitCodes) {
        throw "Terraform $($Arguments[0]) failed for module '$Module' (exit $code): $text"
    }
    if (-not $Json) {
        Write-Information $text.TrimEnd() -InformationAction Continue
    }
    [pscustomobject]@{ ExitCode = $code; Text = $text }
}

function Assert-ModuleOutputSensitivity {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary] $Outputs,
        [System.Collections.IDictionary] $Changes = @{}
    )

    foreach ($name in $Outputs.PSBase.Keys) {
        $record = $Outputs[$name]
        if ($record -isnot [System.Collections.IDictionary] -or $record['sensitive'] -isnot [bool]) {
            throw "Output '$name' of module '$Module' has no sensitivity classification."
        }
        if ($record['sensitive']) {
            throw "Sensitive output '$name' of module '$Module' must not be published."
        }
    }
    foreach ($name in $Changes.PSBase.Keys) {
        if ($Changes[$name]['after_sensitive'] -eq $true) {
            throw "Sensitive output '$name' of module '$Module' must not be published."
        }
    }
}

function Get-ModulePublicOutput {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][System.Collections.IDictionary] $Outputs,
        [System.Collections.IDictionary] $Changes = @{},
        [switch] $Planned
    )

    $hasUnknown = {
        param($Value)
        if ($Value -is [bool]) {
            return $Value
        }
        if ($Value -is [System.Collections.IDictionary]) {
            foreach ($item in $Value.PSBase.Values) {
                if (& $hasUnknown $item) { return $true }
            }
        }
        elseif ($Value -is [System.Collections.IList]) {
            foreach ($item in $Value) {
                if (& $hasUnknown $item) { return $true }
            }
        }
        return $false
    }
    Assert-ModuleOutputSensitivity -Outputs $Outputs -Changes $Changes
    if ($Planned) {
        foreach ($name in $Changes.PSBase.Keys) {
            if (& $hasUnknown $Changes[$name]['after_unknown']) {
                throw "Unknown planned output '$name' of module '$Module' cannot be passed to dependent modules. Apply the prerequisite first."
            }
        }
    }
    $values = [ordered]@{}
    foreach ($name in $Outputs.PSBase.Keys) {
        $record = $Outputs[$name]
        if ($Planned -and -not $record.Contains('value')) {
            throw "Unknown planned output '$name' of module '$Module' cannot be passed to dependent modules. Apply the prerequisite first."
        }
        if (-not $record.Contains('value')) {
            throw "Output '$name' of module '$Module' has no value."
        }
        $values[$name] = $record['value']
    }
    return $values
}

function Test-ModuleStateEmpty {
    [CmdletBinding()]
    [OutputType([bool])]
    param()

    $state = ConvertFrom-Json -InputObject (Invoke-ModuleTerraform -Arguments @('show', '-json') -Json).Text -AsHashtable
    if (-not $state.Contains('values') -or $null -eq $state['values']) {
        return $true
    }
    if ($state['values'].Contains('outputs') -and @($state['values']['outputs'].PSBase.Keys).Count -gt 0) {
        return $false
    }
    $pending = [System.Collections.Generic.Stack[object]]::new()
    if ($state['values'].Contains('root_module')) {
        $pending.Push($state['values']['root_module'])
    }
    while ($pending.Count -gt 0) {
        $node = $pending.Pop()
        if ($node.Contains('resources') -and @($node['resources']).Count -gt 0) {
            return $false
        }
        if ($node.Contains('child_modules')) {
            foreach ($child in $node['child_modules']) { $pending.Push($child) }
        }
    }
    return $true
}

$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
if ($Module -cnotin (Get-PlatformModuleSelection -Instance $instance -Modules $modules)) {
    throw "Module '$Module' is not selected in $.modules or required by a selected module."
}
$organizationScoped = $modules[$Module].Contains('organizationScoped') -and $modules[$Module]['organizationScoped']
if ($Organization -and -not $organizationScoped) {
    throw "Module '$Module' does not declare organizationScoped execution."
}
$moduleRoot = [IO.Path]::GetFullPath((Join-Path $ModulesPath $Module))
$stateKey = 'terraform.tfstate'
if ($Rulesets) {
    if (-not $modules[$Module]['permissions']['githubApp'].Contains('rulesetPlan')) {
        throw "Module '$Module' requires a declared ruleset exception before running its rulesets root."
    }
    $moduleRoot = Join-Path $moduleRoot 'rulesets'
    $stateKey = 'terraform.rulesets.tfstate'
}
if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
    throw "Terraform root '$moduleRoot' does not exist."
}
$executionOrganizations = @()
if ($organizationScoped) {
    $executionOrganizations = Get-PlatformModuleOrganization -Instance $instance -Manifest $modules[$Module] `
        -PlatformOrganization $PlatformOrganization -Organization $Organization
}
$organizations = $null
if ($PSBoundParameters.ContainsKey('PlatformOrganization')) {
    $organizations = Get-PlatformInstanceOrganization -InstanceName $instance['instance']['name'] -PlatformOrganization $PlatformOrganization
}
if ($Action -eq 'destroy' -and -not $instance['teardown']['allowed']) {
    throw "Destroy is denied: $.teardown.allowed must be true."
}
if ($Module -eq 'bootstrap' -and $Action -ne 'destroy') {
    Assert-PlatformManualPrerequisite -Instance $instance
}
[string[]] $declaredPrerequisites = @()
if ($modules[$Module].Contains('manualPrerequisites')) {
    $declaredPrerequisites = @($modules[$Module]['manualPrerequisites'])
}
if ($declaredPrerequisites.Count -gt 0 -and $Action -notin @('destroy', 'state')) {
    Assert-PlatformManualPrerequisite -Instance $instance -Name $declaredPrerequisites -Subject "Module '$Module'"
}
$manualStates = [System.Collections.Generic.List[object]]::new()
$prerequisiteStates = [System.Collections.Generic.List[object]]::new()
$summary = [System.Collections.Generic.List[string]]::new()
$organizationLabel = if ($Organization) { ' / `{0}`' -f $Organization } else { '' }
$summary.Add("`n## Module ``$Module``${organizationLabel}: $Action")
if ($Module -eq 'bootstrap' -and $Action -ne 'destroy') {
    $summary.Add('Required manual prerequisite confirmations are present. Live state is not automatically verified by this runner.')
}
if ($declaredPrerequisites.Count -gt 0) {
    foreach ($prerequisite in @(Get-PlatformManualPrerequisite -Instance $instance -Name $declaredPrerequisites)) {
        $prerequisiteStates.Add([pscustomobject]@{
            Name = $prerequisite.Name
            Confirmed = [bool] $prerequisite.Confirmed
            Verified = $false
        })
        $status = if ($prerequisite.Confirmed) { 'CONFIRMED (manual declaration only)' } else { 'WARNING (unconfirmed)' }
        $summary.Add("- **$status**: enterprise prerequisite ``$.manualPrerequisites.$($prerequisite.Name)``.")
        if (-not $prerequisite.Confirmed) {
            Write-Warning "Manual prerequisite '$($prerequisite.Name)' of module '$Module' is unconfirmed."
        }
    }
    $summary.Add('Enterprise prerequisites are not read by plan or drift detection and are not changed by teardown.')
}
foreach ($step in $modules[$Module]['manualSteps']) {
    $confirmed = $instance['manualSteps'].Contains($Module) -and
        $instance['manualSteps'][$Module].Contains($step['id']) -and $instance['manualSteps'][$Module][$step['id']]
    $owner = 'platform'
    if ($step.Contains('owner')) { $owner = $step['owner'] }
    $limitations = @{
        plan = 'Manual state is not automatically verified.'
        drift = 'Manual changes are not automatically detected.'
        teardown = 'Manual state is not automatically reversed.'
    }
    if ($step.Contains('limitations')) { $limitations = $step['limitations'] }
    $state = [pscustomobject]@{
        Id = $step['id']
        Confirmed = [bool] $confirmed
        Verified = $false
        Owner = $owner
        Limitations = $limitations
    }
    $manualStates.Add($state)
    $status = if ($confirmed) { 'CONFIRMED (manual declaration only)' } else { 'WARNING (unconfirmed)' }
    $summary.Add("- **$status**: ``$($step['id'])`` - $($step['description']) Owner: $owner team.")
    $summary.Add("  Plan: $($limitations['plan']) Drift: $($limitations['drift']) Teardown: $($limitations['teardown'])")
    if (-not $confirmed) {
        Write-Warning "Manual step '$($step['id'])' of module '$Module' is unconfirmed; owner: $owner team."
    }
}
$summary.Add('Manual confirmations are declarations, not automatically verified checks. Terraform only covers automated resources.')
if ($JobSummaryPath) {
    $summaryFile = [IO.Path]::GetFullPath($JobSummaryPath)
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($summaryFile)) | Out-Null
    [IO.File]::AppendAllText($summaryFile, ($summary -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}
else {
    Write-Information ($summary -join "`n") -InformationAction Continue
}
$backendArguments = @()
if ($Backend -eq 'local') {
    if (-not $StatePath) {
        throw 'Local backend requires -StatePath.'
    }
    $stateDirectory = [IO.Path]::GetFullPath($StatePath)
    if ($Organization) {
        $stateDirectory = Join-Path $stateDirectory "$Module/organizations/$Organization"
    }
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    $localStateName = if ($Organization) { $stateKey } else { "$outputName.tfstate" }
    $backendArguments += "-backend-config=path=$(Join-Path $stateDirectory $localStateName)"
}
else {
    if (-not $StorageAccountName -or -not $ResourceGroupName -or $Module.Length -lt 3) {
        throw 'Azure backend requires storage account, resource group and a module name of at least 3 characters.'
    }
    $backendArguments += @(
        "-backend-config=storage_account_name=$StorageAccountName"
        "-backend-config=resource_group_name=$ResourceGroupName"
        "-backend-config=container_name=$Module"
        "-backend-config=key=$(if ($Organization) { "organizations/$Organization/$stateKey" } else { $stateKey })"
        '-backend-config=use_azuread_auth=true'
    )
}

$variables = @{
    instance = @{
        name = $instance['instance']['name']
        regions = $instance['regions']
        teams = $instance['teams']
        customPatterns = $instance['customPatterns']
    }
    prerequisites = @{}
}
if ($instance.Contains('bootstrap')) {
    $variables.instance.entra = @{
        tenantId = $instance['bootstrap']['tenantId']
        enterpriseApplicationObjectId = $instance['bootstrap']['enterpriseApplicationObjectId']
    }
    $variables.instance.github = @{
        host = $instance['bootstrap']['githubHost']
        enterprise = $instance['bootstrap']['enterprise']
    }
}
if ($organizations) {
    $variables.instance.organizations = $organizations
}
if ($instance['modules'].Contains($Module) -and $instance['modules'][$Module].Contains('parameters')) {
    foreach ($name in $instance['modules'][$Module]['parameters'].PSBase.Keys) {
        $variables[$name] = $instance['modules'][$Module]['parameters'][$name]
    }
    if ($organizationScoped -and -not $Organization) {
        $results = [ordered]@{}
        foreach ($name in $executionOrganizations) {
            $results[$name] = [ordered]@{ result = 'pending'; changes = $null }
        }
        $tokens = @{}
        if ($Action -in @('plan', 'apply') -or ($Action -eq 'destroy' -and $env:PLATFORM_GITHUB_TOKENS)) {
            $tokens = Get-PlatformOrganizationToken -Organization $executionOrganizations -Json $env:PLATFORM_GITHUB_TOKENS
        }
        $public = [ordered]@{ organizations = @($executionOrganizations); organization_outputs = [ordered]@{} }
        $savedEnvironment = @{}
        foreach ($name in @('GITHUB_TOKEN', 'GH_TOKEN', 'PLATFORM_GITHUB_TOKENS', 'TF_VAR_github_tokens', 'REST_API_BEARER')) {
            $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $empty = $true
        try {
            foreach ($name in $executionOrganizations) {
                $selectedTokens = @{}
                if ($tokens.Contains($name)) { $selectedTokens[$name] = $tokens[$name] }
                $env:PLATFORM_GITHUB_TOKENS = ConvertTo-Json -InputObject $selectedTokens -Compress
                $env:TF_VAR_github_tokens = $env:PLATFORM_GITHUB_TOKENS
                $env:GITHUB_TOKEN = $selectedTokens[$name]
                $env:GH_TOKEN = $selectedTokens[$name]
                $env:REST_API_BEARER = $null
                $childArguments = @{} + $PSBoundParameters
                $childArguments.Remove('GitHubOutputPath')
                $childArguments['Organization'] = $name
                $childArguments['ArtifactsPath'] = Join-Path $ArtifactsPath "organizations/$name"
                try {
                    $result = & $PSCommandPath @childArguments
                    if ($Action -eq 'state') { $empty = $empty -and $result.Empty }
                    else {
                        $public.organization_outputs[$name] = Get-Content -LiteralPath $result.OutputsPath -Raw | ConvertFrom-Json -AsHashtable
                        $results[$name].changes = $result.HasChanges
                    }
                    $results[$name].result = 'success'
                }
                catch {
                    $results[$name].result = 'failure'
                    throw
                }
            }
            if ($Action -eq 'state') {
                return [pscustomobject]@{ Module = $Module; Action = $Action; Empty = $empty; OrganizationResults = $results }
            }
            [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($artifactFile)) | Out-Null
            [IO.File]::WriteAllText($artifactFile, (ConvertTo-Json -InputObject $public -Depth 100), [Text.UTF8Encoding]::new($false))
            return [pscustomobject]@{
                Module = $Module; Action = $Action
                HasChanges = @($results.PSBase.Values | Where-Object { $_.changes -eq $true }).Count -gt 0
                OutputsPath = $artifactFile; OrganizationResults = $results
                ManualSteps = $manualStates.ToArray(); ManualPrerequisites = $prerequisiteStates.ToArray()
            }
        }
        finally {
            foreach ($name in $savedEnvironment.Keys) {
                [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name])
            }
            if ($GitHubOutputPath) {
                $content = "organizations=$(ConvertTo-Json -InputObject $results -Depth 10 -Compress)`n"
                $hasChanges = @($results.PSBase.Values | Where-Object { $_.changes -eq $true }).Count -gt 0
                if ($hasChanges -or @($results.PSBase.Values | Where-Object { $_.result -cne 'success' }).Count -eq 0) {
                    $content += "changes=$($hasChanges.ToString().ToLowerInvariant())`n"
                }
                [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath), $content, [Text.UTF8Encoding]::new($false))
            }
        }
    }
    if ($Organization) {
        $variables['target_organizations'] = @($Organization)
        if ($modules[$Module].Contains('organizationParameters')) {
            foreach ($parameter in $modules[$Module]['organizationParameters']) {
                $variables[$parameter] = $variables[$parameter][$Organization]
            }
        }
    }
}
$prerequisites = @($modules[$Module]['prerequisites'])
if ($Action -in @('output', 'state')) {
    $prerequisites = @()
}
function Import-ModulePrerequisiteOutput {
    param([string[]] $Name, [string] $Path, [System.Collections.IDictionary] $Target)

    foreach ($prerequisite in $Name) {
        if (-not $Path) {
            throw "Missing prerequisite outputs for '$prerequisite': supply -PrerequisiteOutputsPath."
        }
        $file = Join-Path $Path "$prerequisite.json"
        if (-not (Test-Path -LiteralPath $file -PathType Leaf)) {
            throw "Missing prerequisite outputs for '$prerequisite': '$file'."
        }
        try {
            $values = Get-Content -LiteralPath $file -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
        }
        catch {
            throw "Invalid prerequisite outputs for '$prerequisite' in '$file': expected a JSON object."
        }
        if ($values -isnot [System.Collections.IDictionary]) {
            throw "Invalid prerequisite outputs for '$prerequisite' in '$file': expected a JSON object."
        }
        $Target[$prerequisite] = $values
    }
}
# A destroy of an empty state needs no prerequisite outputs; it loads them only after the state check.
if ($Action -ne 'destroy') { Import-ModulePrerequisiteOutput -Name $prerequisites -Path $PrerequisiteOutputsPath -Target $variables['prerequisites'] }

$usesRestProvider = @(Get-ChildItem -LiteralPath $moduleRoot -Filter '*.tf' -File |
    Select-String -Pattern 'source\s*=\s*"(registry\.terraform\.io/)?mastercard/restapi"').Count -gt 0
if ($usesRestProvider -and $modules[$Module]['permissions'].Contains('githubApp')) {
    # Organization tokens are issued per organization, but the REST provider accepts a single bearer per run.
    foreach ($phase in $modules[$Module]['permissions']['githubApp'].PSBase.Values) {
        if (-not $phase['resources'].Contains('organizations')) { continue }
        $parameter = [string] $phase['resources']['organizations']
        $count = @($variables[$parameter] | Where-Object { $null -ne $_ }).Count
        if ($count -ne 1) {
            throw "Module '$Module' uses the REST provider and supports exactly one organization in '$parameter' per run; got $count. Declare organizationScoped for isolated execution across the instance organizations."
        }
    }
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "platform-module-$([guid]::NewGuid())"
[IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
$previousDataDirectory = $env:TF_DATA_DIR
$previousWorkspace = $env:TF_WORKSPACE
$previousRestBearer = $env:REST_API_BEARER
$organizationEnvironment = @{}
if ($Organization) {
    foreach ($name in @('GITHUB_TOKEN', 'GH_TOKEN', 'PLATFORM_GITHUB_TOKENS', 'TF_VAR_github_tokens')) {
        $organizationEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
    }
}
function Initialize-ModuleOrganizationEnvironment {
    param([System.Collections.IDictionary] $Tokens)

    $env:GITHUB_TOKEN = $Tokens[$Organization]
    $env:GH_TOKEN = $Tokens[$Organization]
    $env:PLATFORM_GITHUB_TOKENS = ConvertTo-Json -InputObject $Tokens -Compress
    $env:TF_VAR_github_tokens = $env:PLATFORM_GITHUB_TOKENS
    $env:REST_API_BEARER = $Tokens[$Organization]
}
try {
    $env:TF_DATA_DIR = Join-Path $temporaryDirectory 'data'
    $env:TF_WORKSPACE = 'default'
    if ($Organization) {
        $selectedTokens = @{}
        if ($Action -in @('plan', 'apply')) {
            $selectedTokens = Get-PlatformOrganizationToken -Organization @($Organization) -Json $organizationEnvironment['PLATFORM_GITHUB_TOKENS']
        }
        Initialize-ModuleOrganizationEnvironment -Tokens $selectedTokens
    }
    # The REST provider reads its bearer from the environment; only the job's installation token may reach it.
    $env:REST_API_BEARER = $env:GITHUB_TOKEN
    $null = Invoke-ModuleTerraform -Arguments (@('init', '-input=false', '-no-color', '-reconfigure') + $backendArguments)
    $backendMetadataPath = Join-Path $env:TF_DATA_DIR 'terraform.tfstate'
    if (-not (Test-Path -LiteralPath $backendMetadataPath -PathType Leaf)) {
        throw "Module '$Module' must declare a '$Backend' backend in its Terraform root."
    }
    $metadata = Get-Content -LiteralPath $backendMetadataPath -Raw | ConvertFrom-Json -AsHashtable
    if ($metadata['backend']['type'] -cne $Backend) {
        throw "Module '$Module' declares a different backend than '$Backend'."
    }
    if ($Action -eq 'state') {
        # Teardown reads this before issuing GitHub tokens; only an empty state lets it skip the module.
        return [pscustomobject]@{
            Module = $Module
            Action = $Action
            Empty = [bool] (Test-ModuleStateEmpty)
        }
    }
    $readOnly = $Action -eq 'output'
    if ($Action -eq 'destroy' -and (Test-ModuleStateEmpty)) {
        # A repeated teardown after an interruption finds nothing left; planning would need outputs of destroyed prerequisites.
        Write-Information "Module '$Module' has no resources or outputs in state; nothing to destroy." -InformationAction Continue
        $readOnly = $true
    }
    if ($readOnly) {
        $output = Invoke-ModuleTerraform -Arguments @('output', '-json') -Json
        $outputs = Get-ModulePublicOutput -Outputs (ConvertFrom-Json -InputObject $output.Text -AsHashtable)
        [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($artifactFile)) | Out-Null
        [IO.File]::WriteAllText($artifactFile, (ConvertTo-Json -InputObject $outputs -Depth 100), [Text.UTF8Encoding]::new($false))
        return [pscustomobject]@{
            Module = $Module
            Action = $Action
            HasChanges = $false
            OutputsPath = $artifactFile
            ManualSteps = $manualStates.ToArray()
            ManualPrerequisites = $prerequisiteStates.ToArray()
        }
    }
    if ($Organization -and $Action -eq 'destroy') {
        $selectedTokens = Get-PlatformOrganizationToken -Organization @($Organization) -Json $organizationEnvironment['PLATFORM_GITHUB_TOKENS']
        Initialize-ModuleOrganizationEnvironment -Tokens $selectedTokens
    }
    if ($Action -eq 'destroy') { Import-ModulePrerequisiteOutput -Name $prerequisites -Path $PrerequisiteOutputsPath -Target $variables['prerequisites'] }
    $variableFile = Join-Path $temporaryDirectory 'inputs.tfvars.json'
    [IO.File]::WriteAllText($variableFile, (ConvertTo-Json -InputObject $variables -Depth 100), [Text.UTF8Encoding]::new($false))
    if ($Rulesets -and $Module -ceq 'organization-rulesets' -and $Action -ceq 'destroy') {
        & (Join-Path $PSScriptRoot 'Restore-RulesetState.ps1') -TerraformRoot $moduleRoot -VariableFile $variableFile
    }
    $planFile = Join-Path $temporaryDirectory 'module.tfplan'
    $planArguments = @('plan', '-input=false', '-no-color', '-detailed-exitcode', "-var-file=$variableFile", "-out=$planFile")
    if ($Action -eq 'plan') {
        $planArguments += '-lock=false'
    }
    if ($Action -eq 'destroy') {
        $planArguments += '-destroy'
    }
    $plan = Invoke-ModuleTerraform -Arguments $planArguments -AllowedExitCodes @(0, 2)
    $output = Invoke-ModuleTerraform -Arguments @('show', '-json', $planFile) -Json
    $planData = ConvertFrom-Json -InputObject $output.Text -AsHashtable
    $terraformOutputs = @{}
    if ($planData['planned_values'].Contains('outputs')) {
        $terraformOutputs = $planData['planned_values']['outputs']
    }
    $changes = @{}
    if ($planData.Contains('output_changes')) {
        $changes = $planData['output_changes']
    }
    if ($Action -eq 'plan') {
        $outputs = Get-ModulePublicOutput -Outputs $terraformOutputs -Changes $changes -Planned
    }
    else {
        Assert-ModuleOutputSensitivity -Outputs $terraformOutputs -Changes $changes
        $null = Invoke-ModuleTerraform -Arguments @('apply', '-input=false', '-no-color', '-auto-approve', $planFile)
        $output = Invoke-ModuleTerraform -Arguments @('output', '-json') -Json
        $terraformOutputs = ConvertFrom-Json -InputObject $output.Text -AsHashtable
        $outputs = Get-ModulePublicOutput -Outputs $terraformOutputs
    }
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($artifactFile)) | Out-Null
    [IO.File]::WriteAllText($artifactFile, (ConvertTo-Json -InputObject $outputs -Depth 100), [Text.UTF8Encoding]::new($false))
    if ($GitHubOutputPath) {
        [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath),
            "changes=$(($plan.ExitCode -eq 2).ToString().ToLowerInvariant())`n", [Text.UTF8Encoding]::new($false))
    }
    [pscustomobject]@{
        Module = $Module
        Action = $Action
        HasChanges = ($plan.ExitCode -eq 2)
        OutputsPath = $artifactFile
        ManualSteps = $manualStates.ToArray()
        ManualPrerequisites = $prerequisiteStates.ToArray()
    }
}
finally {
    $env:TF_DATA_DIR = $previousDataDirectory
    $env:TF_WORKSPACE = $previousWorkspace
    $env:REST_API_BEARER = $previousRestBearer
    foreach ($name in $organizationEnvironment.Keys) {
        [Environment]::SetEnvironmentVariable($name, $organizationEnvironment[$name])
    }
    [IO.Directory]::Delete($temporaryDirectory, $true)
}
