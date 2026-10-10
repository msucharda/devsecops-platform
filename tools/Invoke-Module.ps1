#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9]*(-[a-z0-9]+)*$')][string] $Module,
    [Parameter(Mandatory)][ValidateSet('plan', 'apply', 'destroy')][string] $Action,
    [switch] $Rulesets,
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [ValidateSet('azurerm', 'local')][string] $Backend = 'azurerm',
    [string] $StorageAccountName = $env:PLATFORM_STATE_STORAGE_ACCOUNT,
    [string] $ResourceGroupName = $env:PLATFORM_STATE_RESOURCE_GROUP,
    [string] $StatePath,
    [string] $PrerequisiteOutputsPath,
    [string] $ArtifactsPath = (Join-Path (Get-Location) 'artifacts/module-outputs'),
    [string] $JobSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')

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

$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules
if ($Module -cnotin (Get-PlatformModuleSelection -Instance $instance -Modules $modules)) {
    throw "Module '$Module' is not selected in $.modules or required by a selected module."
}
$moduleRoot = [IO.Path]::GetFullPath((Join-Path $ModulesPath $Module))
$outputName = $Module
$stateKey = 'terraform.tfstate'
if ($Rulesets) {
    if (-not $modules[$Module]['permissions']['githubApp'].Contains('rulesetPlan')) {
        throw "Module '$Module' requires a declared ruleset exception before running its rulesets root."
    }
    $moduleRoot = Join-Path $moduleRoot 'rulesets'
    $outputName = "$Module.rulesets"
    $stateKey = 'terraform.rulesets.tfstate'
}
if (-not (Test-Path -LiteralPath $moduleRoot -PathType Container)) {
    throw "Terraform root '$moduleRoot' does not exist."
}
$artifactFile = [IO.Path]::GetFullPath((Join-Path $ArtifactsPath "$outputName.json"))
if (Test-Path -LiteralPath $artifactFile -PathType Leaf) {
    [IO.File]::Delete($artifactFile)
}
if ($Action -eq 'destroy' -and -not $instance['teardown']['allowed']) {
    throw "Destroy is denied: $.teardown.allowed must be true."
}
if ($Module -eq 'bootstrap' -and $Action -ne 'destroy') {
    Assert-PlatformManualPrerequisite -Instance $instance
}
$manualStates = [System.Collections.Generic.List[object]]::new()
$summary = [System.Collections.Generic.List[string]]::new()
$summary.Add("`n## Module ``$Module``: $Action")
if ($Module -eq 'bootstrap' -and $Action -ne 'destroy') {
    $summary.Add('Required manual prerequisite confirmations are present. Live state is not automatically verified by this runner.')
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
    [IO.Directory]::CreateDirectory($stateDirectory) | Out-Null
    $backendArguments += "-backend-config=path=$(Join-Path $stateDirectory "$outputName.tfstate")"
}
else {
    if (-not $StorageAccountName -or -not $ResourceGroupName -or $Module.Length -lt 3) {
        throw 'Azure backend requires storage account, resource group and a module name of at least 3 characters.'
    }
    $backendArguments += @(
        "-backend-config=storage_account_name=$StorageAccountName"
        "-backend-config=resource_group_name=$ResourceGroupName"
        "-backend-config=container_name=$Module"
        "-backend-config=key=$stateKey"
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
if ($instance['modules'].Contains($Module) -and $instance['modules'][$Module].Contains('parameters')) {
    foreach ($name in $instance['modules'][$Module]['parameters'].PSBase.Keys) {
        $variables[$name] = $instance['modules'][$Module]['parameters'][$name]
    }
}
foreach ($prerequisite in $modules[$Module]['prerequisites']) {
    if (-not $PrerequisiteOutputsPath) {
        throw "Missing prerequisite outputs for '$prerequisite': supply -PrerequisiteOutputsPath."
    }
    $file = Join-Path $PrerequisiteOutputsPath "$prerequisite.json"
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
    $variables['prerequisites'][$prerequisite] = $values
}

$temporaryDirectory = Join-Path ([IO.Path]::GetTempPath()) "platform-module-$([guid]::NewGuid())"
[IO.Directory]::CreateDirectory($temporaryDirectory) | Out-Null
$previousDataDirectory = $env:TF_DATA_DIR
$previousWorkspace = $env:TF_WORKSPACE
try {
    $env:TF_DATA_DIR = Join-Path $temporaryDirectory 'data'
    $env:TF_WORKSPACE = 'default'
    $variableFile = Join-Path $temporaryDirectory 'inputs.tfvars.json'
    [IO.File]::WriteAllText($variableFile, (ConvertTo-Json -InputObject $variables -Depth 100), [Text.UTF8Encoding]::new($false))
    $null = Invoke-ModuleTerraform -Arguments (@('init', '-input=false', '-no-color', '-reconfigure') + $backendArguments)
    $backendMetadataPath = Join-Path $env:TF_DATA_DIR 'terraform.tfstate'
    if (-not (Test-Path -LiteralPath $backendMetadataPath -PathType Leaf)) {
        throw "Module '$Module' must declare a '$Backend' backend in its Terraform root."
    }
    $metadata = Get-Content -LiteralPath $backendMetadataPath -Raw | ConvertFrom-Json -AsHashtable
    if ($metadata['backend']['type'] -cne $Backend) {
        throw "Module '$Module' declares a different backend than '$Backend'."
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
    [pscustomobject]@{
        Module = $Module
        Action = $Action
        HasChanges = ($plan.ExitCode -eq 2)
        OutputsPath = $artifactFile
        ManualSteps = $manualStates.ToArray()
    }
}
finally {
    $env:TF_DATA_DIR = $previousDataDirectory
    $env:TF_WORKSPACE = $previousWorkspace
    [IO.Directory]::Delete($temporaryDirectory, $true)
}
