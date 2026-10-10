#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../templates/instance/.github/workflows/deploy.yml'),
    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$lines = [System.Collections.Generic.List[string]]::new()

function Add-WorkflowBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Text)

    foreach ($line in $Text.Trim("`r", "`n").Replace("`r", '').Split("`n")) { $lines.Add($line) }
}

function Add-WorkflowCheckout {
    [CmdletBinding()]
    param([switch] $Candidate)

    if ($Candidate) {
        Add-WorkflowBlock @'
      - name: Check out the immutable candidate
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
        with:
          ref: ${{ needs.authorize.outputs.revision }}
          path: candidate
          persist-credentials: false
'@
    }
    else {
        Add-WorkflowBlock @'
      - name: Check out trusted authorization tools
        uses: actions/checkout@11d5960a326750d5838078e36cf38b85af677262
        with:
          ref: ${{ github.event.pull_request.base.sha || github.sha }}
          path: trusted
          persist-credentials: false
'@
    }
}

function Add-DeploymentJob {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest,
        [Parameter(Mandatory)][ValidateSet('plan', 'apply', 'rulesetPlan')][string] $Phase
    )

    $name = $Manifest['name']
    $suffix = $name.Replace('-', '_')
    $prefix = if ($Phase -eq 'apply') { 'apply_' } elseif ($Phase -eq 'rulesetPlan') { 'ruleset_plan_' } else { 'module_' }
    $prerequisitePrefix = if ($Phase -eq 'apply') { 'apply_' } else { 'module_' }
    $needs = @('authorize', 'select')
    if ($Phase -eq 'apply') { $needs += 'approve_apply' }
    $needs += @($Manifest['prerequisites'] | ForEach-Object { $prerequisitePrefix + $_.Replace('-', '_') })
    $prerequisiteRulesetJobs = @()
    if ($Phase -ne 'apply') {
        $prerequisiteRulesetJobs = @($Manifest['prerequisites'] |
            Where-Object { $modules[$_]['permissions']['githubApp'].Contains('rulesetPlan') } |
            ForEach-Object { 'ruleset_plan_' + $_.Replace('-', '_') })
        $needs += $prerequisiteRulesetJobs
    }
    if ($Phase -eq 'rulesetPlan') { $needs += "module_$suffix" }
    $condition = "!cancelled() && needs.authorize.outputs.allowed == 'true' && needs.select.result == 'success' && contains(fromJSON(needs.select.outputs.modules), '$name')"
    if ($Phase -eq 'apply') { $condition += " && needs.approve_apply.result == 'success'" }
    foreach ($prerequisite in $Manifest['prerequisites']) {
        $condition += " && needs.$prerequisitePrefix$($prerequisite.Replace('-', '_')).result == 'success'"
    }
    foreach ($job in $prerequisiteRulesetJobs) {
        $condition += " && needs.$job.result == 'success'"
    }
    if ($Phase -eq 'rulesetPlan') { $condition += " && needs.module_$suffix.result == 'success'" }
    $environmentOutput = if ($Phase -eq 'apply') { 'applyEnvironments' } elseif ($Phase -eq 'rulesetPlan') { 'rulesetEnvironments' } else { 'environments' }
    Add-WorkflowBlock @"
  $prefix${suffix}:
    name: '$name$(if ($Phase -ne 'plan') { " ($Phase)" })'
    runs-on: ubuntu-latest
    needs: [$($needs -join ', ')]
"@
    $lines.Add('    if: ${{ ' + $condition + ' }}')
    $lines.Add('    environment: ${{ fromJSON(needs.select.outputs.' + $environmentOutput + ')[''' + $name + '''] }}')
    Add-WorkflowBlock @'
    permissions:
      contents: read
      id-token: write
    env:
      TF_IN_AUTOMATION: 'true'
      ARM_USE_OIDC: 'true'
      ARM_USE_AZUREAD: 'true'
      ARM_CLIENT_ID: ${{ vars.AZURE_CLIENT_ID }}
      ARM_TENANT_ID: ${{ vars.AZURE_TENANT_ID }}
      ARM_SUBSCRIPTION_ID: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      PLATFORM_STATE_STORAGE_ACCOUNT: ${{ vars.PLATFORM_STATE_STORAGE_ACCOUNT }}
      PLATFORM_STATE_RESOURCE_GROUP: ${{ vars.PLATFORM_STATE_RESOURCE_GROUP }}
    steps:
'@
    Add-WorkflowCheckout
    Add-WorkflowCheckout -Candidate
    Add-WorkflowBlock @'
      - name: Install runtime dependencies
        shell: pwsh
        run: ./trusted/platform/tools/Install-ToolDependencies.ps1
      - uses: hashicorp/setup-terraform@b9cd54a3c349d3f38e8881555d616ced269862dd
        with:
          terraform_version: 1.16.5
          terraform_wrapper: false
      - name: Sign in to Azure with the phase managed identity
        uses: Azure/login@7184910d9eb2b1c5e48f7073824a90609bb9b6d6
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
      - name: Issue a phase-scoped enterprise App installation token
        shell: pwsh
        env:
          PLATFORM_APP_ID: ${{ vars.PLATFORM_APP_ID }}
          PLATFORM_APP_INSTALLATION_ID: ${{ vars.PLATFORM_APP_INSTALLATION_ID }}
          PLATFORM_APP_ENTERPRISE: ${{ vars.PLATFORM_APP_ENTERPRISE }}
          PLATFORM_APP_PRIVATE_KEY: ${{ secrets.PLATFORM_APP_PRIVATE_KEY }}
'@
    $lines.Add("        run: ./trusted/platform/tools/New-PlatformGitHubToken.ps1 -Module '$name' -Phase $Phase -InstancePath ./candidate/instance.yaml -ModulesPath ./candidate/platform/modules")
    $artifactPhase = if ($Phase -eq 'apply') { 'apply' } else { 'plan' }
    foreach ($prerequisite in $Manifest['prerequisites']) {
        Add-WorkflowBlock @"
      - name: Download outputs of $prerequisite
        uses: actions/download-artifact@d3f86a106a0bac45b974a628896c90dbdf5c8093
        with:
          name: $artifactPhase-outputs-$prerequisite
          path: ./artifacts/prerequisites
"@
    }
    $action = if ($Phase -eq 'apply') { 'apply' } else { 'plan' }
    $runner = "./candidate/platform/tools/Invoke-Module.ps1 -Module '$name' -Action $action -InstancePath ./candidate/instance.yaml -ModulesPath ./candidate/platform/modules -PrerequisiteOutputsPath ./artifacts/prerequisites -ArtifactsPath ./artifacts/module-outputs"
    $rulesetArgument = if ($Phase -eq 'rulesetPlan') { ' -Rulesets' } else { '' }
    Add-WorkflowBlock @"
      - name: Run module
        shell: pwsh
        env:
          GITHUB_TOKEN: `${{ env.GH_TOKEN }}
        run: $runner$rulesetArgument
"@
    if ($Phase -eq 'apply' -and $Manifest['permissions']['githubApp'].Contains('rulesetPlan')) {
        Add-WorkflowBlock @"
      - name: Apply the complete rulesets root including bypass configuration
        shell: pwsh
        env:
          GITHUB_TOKEN: `${{ env.GH_TOKEN }}
        run: $runner -Rulesets
"@
    }
    $artifactName = if ($Phase -eq 'rulesetPlan') { "plan-ruleset-outputs-$name" } else { "$artifactPhase-outputs-$name" }
    $outputName = if ($Phase -eq 'rulesetPlan') { "$name.rulesets" } else { $name }
    Add-WorkflowBlock @"
      - name: Upload public module outputs
        uses: actions/upload-artifact@ea165f8d65b6e75b540449e92b4886f43607fa02
        with:
          name: $artifactName
          path: ./artifacts/module-outputs/$outputName.json
          if-no-files-found: error
          retention-days: 1
"@
    Add-WorkflowBlock @'
      - name: Revoke the job installation tokens
        if: ${{ always() && env.PLATFORM_GITHUB_TOKENS != '' }}
        shell: pwsh
        run: ./trusted/platform/tools/Remove-PlatformGitHubToken.ps1
'@
}

Add-WorkflowBlock @'
# Generated by tools/Generate-DeploymentWorkflow.ps1. Do not edit.
name: Deploy instance
on:
  pull_request_target:
    branches: [main]
    types: [opened, synchronize, reopened, ready_for_review]
  push:
    branches: [main]
  workflow_dispatch:
permissions:
  contents: read
concurrency:
  group: deploy-instance-${{ github.event.pull_request.number || 'main' }}
  cancel-in-progress: false
jobs:
  authorize:
    name: Authorize deployment from trusted main
    runs-on: ubuntu-latest
    environment: pr-authorization
    outputs:
      allowed: ${{ steps.authorize.outputs.allowed }}
      revision: ${{ steps.preflight.outputs.revision }}
    steps:
'@
Add-WorkflowCheckout
Add-WorkflowBlock @'
      - name: Check PR origin before loading any App key
        id: preflight
        shell: pwsh
        run: ./trusted/platform/tools/Test-DeploymentAuthorization.ps1 -Preflight -GitHubOutputPath $env:GITHUB_OUTPUT
      - name: Install trusted runtime dependencies
        if: ${{ steps.preflight.outputs.eligible == 'true' }}
        shell: pwsh
        run: ./trusted/platform/tools/Install-ToolDependencies.ps1
      - name: Issue the isolated membership-reader token
        if: ${{ steps.preflight.outputs.eligible == 'true' }}
        shell: pwsh
        env:
          PLATFORM_APP_ID: ${{ vars.PLATFORM_APP_ID }}
          PLATFORM_APP_INSTALLATION_ID: ${{ vars.PLATFORM_APP_INSTALLATION_ID }}
          PLATFORM_APP_ENTERPRISE: ${{ vars.PLATFORM_APP_ENTERPRISE }}
          PLATFORM_APP_PRIVATE_KEY: ${{ secrets.PLATFORM_APP_PRIVATE_KEY }}
        run: ./trusted/platform/tools/New-PlatformGitHubToken.ps1 -Authorization
      - name: Verify active platform-team membership
        id: authorize
        shell: pwsh
        env:
          PLATFORM_TEAM_SLUG: ${{ vars.PLATFORM_TEAM_SLUG }}
        run: ./trusted/platform/tools/Test-DeploymentAuthorization.ps1 -GitHubOutputPath $env:GITHUB_OUTPUT
      - name: Revoke the membership-reader token
        if: ${{ always() && env.PLATFORM_GITHUB_TOKENS != '' }}
        shell: pwsh
        run: ./trusted/platform/tools/Remove-PlatformGitHubToken.ps1
  validate:
    name: Validate configuration against the vendored release
    needs: authorize
    runs-on: ubuntu-latest
    steps:
'@
Add-WorkflowCheckout -Candidate
Add-WorkflowBlock @'
      - name: Install candidate runtime dependencies without cloud credentials
        shell: pwsh
        run: ./candidate/platform/tools/Install-ToolDependencies.ps1
      - name: Validate instance configuration
        shell: pwsh
        run: ./candidate/platform/tools/Test-InstanceConfiguration.ps1 -InstancePath ./candidate/instance.yaml
  select:
    name: Select instance modules with trusted tools
    needs: [authorize, validate]
    if: ${{ needs.authorize.outputs.allowed == 'true' }}
    runs-on: ubuntu-latest
    outputs:
      modules: ${{ steps.modules.outputs.modules }}
      environments: ${{ steps.modules.outputs.environments }}
      applyEnvironments: ${{ steps.modules.outputs.applyEnvironments }}
      rulesetEnvironments: ${{ steps.modules.outputs.rulesetEnvironments }}
      rulesetModules: ${{ steps.modules.outputs.rulesetModules }}
    steps:
'@
Add-WorkflowCheckout
Add-WorkflowCheckout -Candidate
Add-WorkflowBlock @'
      - name: Install trusted runtime dependencies
        shell: pwsh
        run: ./trusted/platform/tools/Install-ToolDependencies.ps1
      - name: Select modules and validate protected credential bindings
        id: modules
        shell: pwsh
        run: |
          $arguments = @{
            InstancePath = './candidate/instance.yaml'
            ModulesPath = './candidate/platform/modules'
            GitHubOutputPath = $env:GITHUB_OUTPUT
          }
          if ($env:GITHUB_EVENT_NAME -eq 'pull_request_target') {
            $arguments.TrustedInstancePath = './trusted/instance.yaml'
          }
          ./trusted/platform/tools/Select-InstanceModules.ps1 @arguments
'@
foreach ($manifest in $modules.PSBase.Values) {
    Add-DeploymentJob -Manifest $manifest -Phase plan
    if ($manifest['permissions']['githubApp'].Contains('rulesetPlan')) {
        Add-DeploymentJob -Manifest $manifest -Phase rulesetPlan
    }
}
$planNeeds = @('authorize', 'validate', 'select')
foreach ($name in $modules.PSBase.Keys) {
    $planNeeds += 'module_' + $name.Replace('-', '_')
    if ($modules[$name]['permissions']['githubApp'].Contains('rulesetPlan')) {
        $planNeeds += 'ruleset_plan_' + $name.Replace('-', '_')
    }
}
Add-WorkflowBlock @"
  plan_complete:
    name: Report complete or explicitly unperformed cloud plan
    needs: [$($planNeeds -join ', ')]
"@
Add-WorkflowBlock @'
    if: ${{ !cancelled() }}
    runs-on: ubuntu-latest
    steps:
'@
Add-WorkflowCheckout
Add-WorkflowBlock @'
      - name: Report plan status without deployment credentials
        shell: pwsh
        env:
          DEPLOYMENT_NEEDS: ${{ toJSON(needs) }}
        run: ./trusted/platform/tools/Write-DeploymentSummary.ps1 -NeedsJson $env:DEPLOYMENT_NEEDS
  approve_apply:
    name: Platform-team approval for the entire apply
    needs: [authorize, select, plan_complete]
    if: ${{ github.ref == 'refs/heads/main' && github.event_name != 'pull_request_target' && needs.authorize.outputs.allowed == 'true' && needs.select.outputs.modules != '[]' }}
    runs-on: ubuntu-latest
    environment: approve-apply
    steps:
      - name: Record the shared apply approval
        shell: pwsh
        run: '"Platform-team approval granted for this immutable main deployment." >> $env:GITHUB_STEP_SUMMARY'
'@
foreach ($manifest in $modules.PSBase.Values) { Add-DeploymentJob -Manifest $manifest -Phase apply }

$fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$content = ($lines -join "`n") + "`n"
$encoding = [System.Text.UTF8Encoding]::new($false)
if ($Check) {
    if (-not (Test-Path -LiteralPath $fullOutputPath -PathType Leaf) -or
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fullOutputPath)) -cne
        [Convert]::ToBase64String($encoding.GetBytes($content))) {
        throw "Generated workflow differs from '$OutputPath'. Run tools/Generate-DeploymentWorkflow.ps1 to regenerate it."
    }
    return
}
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($fullOutputPath)) | Out-Null
[System.IO.File]::WriteAllText($fullOutputPath, $content, $encoding)
