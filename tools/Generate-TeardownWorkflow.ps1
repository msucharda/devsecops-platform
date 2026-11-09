#Requires -Version 7.4
[CmdletBinding()]
param(
    [string] $ModulesPath = (Join-Path $PSScriptRoot '../modules'),
    [string] $OutputPath = (Join-Path $PSScriptRoot '../templates/instance/.github/workflows/teardown.yml'),
    [switch] $Check
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$phaseGraph = Get-PlatformModulePhaseGraph -Modules $modules

function Get-WorkflowToolSourceSha256 {
    param([Parameter(Mandatory)][string] $ToolRoot)

    $root = [IO.Path]::GetFullPath($ToolRoot)
    $paths = [Collections.Generic.List[string]]::new()
    foreach ($entry in Get-ChildItem -LiteralPath $root -Recurse -Force) {
        $relative = [IO.Path]::GetRelativePath($root, $entry.FullName).Replace('\', '/')
        if ($relative -eq '.dependencies' -and $entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'The local tool dependency cache must not be a symbolic link.'
        }
        if ($relative.StartsWith('tests/', [StringComparison]::Ordinal) -or
            $relative.StartsWith('.dependencies/', [StringComparison]::Ordinal)) { continue }
        if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw "Platform tool source '$relative' must not be a symbolic link."
        }
        if ($entry -isnot [IO.FileInfo]) { continue }
        $paths.Add($relative)
    }
    $paths.Sort([StringComparer]::Ordinal)
    $manifest = [Collections.Generic.List[string]]::new()
    foreach ($relative in $paths) {
        $path = Join-Path $root $relative
        $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()
        $manifest.Add($relative + [char] 0 + $digest)
    }
    $bytes = [Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $manifest))
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
}

$platformToolsSha256 = Get-WorkflowToolSourceSha256 -ToolRoot $PSScriptRoot
$lines = [System.Collections.Generic.List[string]]::new()
$nodesExpression = 'fromJSON(needs.select.outputs.phaseNodes)'

function Add-WorkflowBlock {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Text)

    foreach ($line in $Text.Trim("`r", "`n").Replace("`r", '').Split("`n")) { $lines.Add($line) }
}

function Add-WorkflowCheckout {
    [CmdletBinding()]
    param()

    Add-WorkflowBlock @'
      - name: Check out the dispatched main commit
        uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
        with:
          ref: ${{ github.sha }}
          path: instance
          persist-credentials: false
'@
    Add-WorkflowToolsIntegrityCheck -ToolRoot './instance/platform/tools'
}

function Add-WorkflowToolsIntegrityCheck {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ToolRoot)

    $lines.Add('      - name: Verify platform tools integrity')
    $lines.Add('        shell: pwsh')
    $lines.Add('        env:')
    $lines.Add("          EXPECTED_PLATFORM_TOOLS_SHA256: $platformToolsSha256")
    $lines.Add('        run: |')
    $lines.Add("          `$toolRoot = [IO.Path]::GetFullPath('$ToolRoot')")
    $lines.Add('          $relativePaths = [Collections.Generic.List[string]]::new()')
    $lines.Add('          foreach ($entry in Get-ChildItem -LiteralPath $toolRoot -Recurse -Force) {')
    $lines.Add('            $relative = [IO.Path]::GetRelativePath($toolRoot, $entry.FullName).Replace(''\'', ''/'')')
    $lines.Add('            if ($relative -ceq ''.dependencies'' -and $entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ''The local tool dependency cache must not be a symbolic link.'' }')
    $lines.Add('            if ($relative.StartsWith(''tests/'', [StringComparison]::Ordinal) -or $relative.StartsWith(''.dependencies/'', [StringComparison]::Ordinal)) { continue }')
    $lines.Add('            if ($entry.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw ''Platform tool source must not be a symbolic link.'' }')
    $lines.Add('            if ($entry -isnot [IO.FileInfo]) { continue }')
    $lines.Add('            $relativePaths.Add($relative)')
    $lines.Add('          }')
    $lines.Add('          $relativePaths.Sort([StringComparer]::Ordinal)')
    $lines.Add('          $manifest = [Collections.Generic.List[string]]::new()')
    $lines.Add('          foreach ($relative in $relativePaths) {')
    $lines.Add('            $path = Join-Path $toolRoot $relative')
    $lines.Add('            $digest = (Get-FileHash -LiteralPath $path -Algorithm SHA256).Hash.ToLowerInvariant()')
    $lines.Add('            $manifest.Add($relative + [char] 0 + $digest)')
    $lines.Add('          }')
    $lines.Add('          $bytes = [Text.Encoding]::UTF8.GetBytes([string]::Join("`n", $manifest))')
    $lines.Add('          $actual = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()')
    $lines.Add('          if ($actual -cne $env:EXPECTED_PLATFORM_TOOLS_SHA256) {')
    $lines.Add("            throw 'Platform tools differ from the generated workflow pin.'")
    $lines.Add('          }')
}

function Add-TeardownMainCheck {
    [CmdletBinding()]
    param()

    # Approvals can wait for a long time; the gate decision is valid only while main still points to the dispatched commit.
    Add-WorkflowBlock @'
      - name: Require main to still point to the dispatched commit
        shell: pwsh
        env:
          TEARDOWN_MAIN_TOKEN: ${{ github.token }}
        run: ./instance/platform/tools/Assert-TeardownMainCommit.ps1
'@
}

function Add-ModuleJobPreamble {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Job,
        [Parameter(Mandatory)][string] $Title,
        [Parameter(Mandatory)][string[]] $Needs,
        [Parameter(Mandatory)][string] $Condition,
        [Parameter(Mandatory)][string] $Environment
    )

    Add-WorkflowBlock @"
  ${Job}:
    name: '$Title'
    runs-on: ubuntu-latest
    needs: [$($Needs -join ', ')]
"@
    $lines.Add('    if: ${{ ' + $Condition + ' }}')
    $lines.Add('    environment: ${{ ' + $Environment + ' }}')
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
    Add-WorkflowBlock @'
      - name: Install runtime dependencies
        shell: pwsh
        run: ./instance/platform/tools/Install-ToolDependencies.ps1
      - uses: hashicorp/setup-terraform@dfe3c3f87815947d99a8997f908cb6525fc44e9e # v4.0.1
        with:
          terraform_version: 1.16.5
          terraform_wrapper: false
      - name: Verify Terraform checksum
        shell: pwsh
        run: ./instance/platform/tools/Test-ToolBinary.ps1 -Name Terraform
      - name: Sign in to Azure with the phase managed identity
        uses: Azure/login@a641126d1b8aa4d1fa005f4f92df94a3a4c4c906 # v3.1.0
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          subscription-id: ${{ vars.AZURE_SUBSCRIPTION_ID }}
'@
}

$gateCondition = "needs.select.result == 'success' && needs.approve_teardown.result == 'success' && needs.enterprise_owner.result == 'success'"
$runnerArguments = '-InstancePath ./instance/instance.yaml -ModulesPath ./instance/platform/modules'
$prerequisiteModules = [System.Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
foreach ($node in $phaseGraph.PSBase.Values) {
    foreach ($prerequisite in $node.Prerequisites) { $null = $prerequisiteModules.Add($prerequisite) }
}

Add-WorkflowBlock @'
# Generated by tools/Generate-TeardownWorkflow.ps1. Do not edit.
name: Tear down instance
on:
  workflow_dispatch:
    inputs:
      instance:
        description: Instance name from instance.yaml, typed to confirm the destructive teardown
        required: true
        type: string
permissions:
  contents: read
concurrency:
  group: deploy-instance-main
  cancel-in-progress: false
jobs:
  select:
    name: Check teardown configuration and select modules
    if: ${{ github.ref == 'refs/heads/main' }}
    runs-on: ubuntu-latest
    permissions:
      contents: read
    outputs:
      modules: ${{ steps.modules.outputs.modules }}
      phaseNodes: ${{ steps.modules.outputs.phaseNodes }}
      environments: ${{ steps.modules.outputs.environments }}
      applyEnvironments: ${{ steps.modules.outputs.applyEnvironments }}
    steps:
'@
Add-WorkflowCheckout
Add-WorkflowBlock @'
      - name: Install runtime dependencies without cloud credentials
        shell: pwsh
        run: ./instance/platform/tools/Install-ToolDependencies.ps1
'@
Add-WorkflowBlock @'
      - name: Verify release marker and provenance before teardown credentials
        shell: pwsh
        env:
          PLATFORM_SOURCE_REPOSITORY: ${{ vars.PLATFORM_SOURCE_REPOSITORY }}
        run: ./instance/platform/tools/Test-DeploymentRelease.ps1 -CandidatePath ./instance -WorkPath ./release-preflight -PlatformOrganization $env:GITHUB_REPOSITORY_OWNER -SourceRepository $env:PLATFORM_SOURCE_REPOSITORY
      - name: Require an enabled and confirmed teardown
        shell: pwsh
        env:
          TEARDOWN_CONFIRMATION: ${{ inputs.instance }}
        run: ./instance/platform/tools/Test-TeardownConfiguration.ps1 -InstancePath ./instance/instance.yaml -ModulesPath ./instance/platform/modules -ConfirmInstanceName $env:TEARDOWN_CONFIRMATION
      - name: Select modules and validate protected credential bindings
        id: modules
        shell: pwsh
        run: ./instance/platform/tools/Select-InstanceModules.ps1 -InstancePath ./instance/instance.yaml -ModulesPath ./instance/platform/modules -GitHubOutputPath $env:GITHUB_OUTPUT -DeploymentScope full
  approve_teardown_platform:
    name: Platform-team approval for the teardown
    needs: [select]
    if: ${{ needs.select.result == 'success' }}
    runs-on: ubuntu-latest
    environment: approve-teardown-platform
    permissions: {}
    steps:
      - name: Record the platform-team teardown approval
        shell: pwsh
        run: '"Platform-team approval granted for the teardown of this main commit." >> $env:GITHUB_STEP_SUMMARY'
  approve_teardown:
    name: Security-team approval for the teardown
    needs: [select, approve_teardown_platform]
    if: ${{ needs.select.result == 'success' && needs.approve_teardown_platform.result == 'success' }}
    runs-on: ubuntu-latest
    environment: teardown
    permissions: {}
    steps:
      - name: Record the security-team teardown approval
        shell: pwsh
        run: '"Security-team approval granted for the teardown of this main commit." >> $env:GITHUB_STEP_SUMMARY'
  enterprise_owner:
    name: Verify a direct Enterprise Owner assignment before any destroy
    needs: [select, approve_teardown]
    if: ${{ needs.select.result == 'success' && needs.approve_teardown.result == 'success' }}
    runs-on: ubuntu-latest
    environment: ${{ fromJSON(needs.select.outputs.environments)['emu-identity'] }}
    permissions:
      contents: read
      id-token: write
    steps:
'@
Add-WorkflowCheckout
Add-WorkflowBlock @'
      - name: Install runtime dependencies
        shell: pwsh
        run: ./instance/platform/tools/Install-ToolDependencies.ps1
      - name: Sign in to Azure with the emu-identity plan identity
        uses: Azure/login@a641126d1b8aa4d1fa005f4f92df94a3a4c4c906 # v3.1.0
        with:
          client-id: ${{ vars.AZURE_CLIENT_ID }}
          tenant-id: ${{ vars.AZURE_TENANT_ID }}
          allow-no-subscriptions: true
      - name: Require a platform-team member with a direct Enterprise Owner assignment
        shell: pwsh
        run: ./instance/platform/tools/Test-TeardownEnterpriseOwner.ps1 -InstancePath ./instance/instance.yaml -ModulesPath ./instance/platform/modules
'@

foreach ($node in $phaseGraph.PSBase.Values) {
    $name = $node.Module
    $key = $node.Name
    if (-not $prerequisiteModules.Contains($key)) { continue }
    $suffix = $key.Replace('-', '_').Replace(':', '_')
    $phaseArgument = if ($node.Phase) { " -DeploymentPhase $($node.Phase)" } else { '' }
    Add-ModuleJobPreamble -Job "outputs_$suffix" -Title "$key (read outputs before teardown)" -Needs @('select', 'enterprise_owner') `
        -Condition "!cancelled() && needs.select.result == 'success' && needs.enterprise_owner.result == 'success' && contains($nodesExpression, '$key')" `
        -Environment "fromJSON(needs.select.outputs.environments)['$name']"
    Add-WorkflowBlock @"
      - name: Read public outputs from state without planning
        shell: pwsh
        run: ./instance/platform/tools/Invoke-Module.ps1 -Module '$name' -Action output $runnerArguments -ArtifactsPath ./artifacts/module-outputs -PlatformOrganization `$env:GITHUB_REPOSITORY_OWNER$phaseArgument
      - name: Upload public module outputs
        uses: actions/upload-artifact@cf430e030ddbb5b0abf93d22962f4752f3646cd9 # v7.0.2
        with:
          name: teardown-outputs-$($key.Replace(':', '-'))
          path: ./artifacts/module-outputs/$($key.Replace(':', '.')).json
          if-no-files-found: error
          retention-days: 1
"@
}

$reversed = [System.Collections.Generic.List[object]]::new()
$remaining = [System.Collections.Generic.List[string]]::new([string[]] @($phaseGraph.PSBase.Keys | Sort-Object -CaseSensitive))
# The identity module owns the teams whose approvals the apply environments of every other module require.
$identityModule = 'emu-identity'
while ($remaining.Count -gt 0) {
    # Emit a module only after every module that needs it, so destroy jobs appear in reverse prerequisite order.
    $next = $remaining | Where-Object {
        $candidate = $_
        ($candidate -cne $identityModule -or $remaining.Count -eq 1) -and
        -not ($remaining | Where-Object { $phaseGraph[$_].Prerequisites -contains $candidate })
    } | Select-Object -First 1
    if (-not $next) { throw 'Module prerequisites contain a cycle.' }
    $reversed.Add($phaseGraph[$next])
    $null = $remaining.Remove($next)
}
foreach ($node in $reversed) {
    $name = $node.Module
    $key = $node.Name
    $manifest = $node.Manifest
    $suffix = $key.Replace('-', '_').Replace(':', '_')
    $phaseArgument = if ($node.Phase) { " -DeploymentPhase $($node.Phase)" } else { '' }
    $dependents = @($phaseGraph.PSBase.Values | Where-Object { $_.Prerequisites -contains $key } | ForEach-Object { $_.Name })
    if ($key -ceq $identityModule) {
        $dependents = @($phaseGraph.PSBase.Keys | Where-Object { $_ -cne $identityModule } | Sort-Object -CaseSensitive)
    }
    $needs = @('select', 'approve_teardown', 'enterprise_owner')
    $needs += @($node.Prerequisites | ForEach-Object { 'outputs_' + $_.Replace('-', '_').Replace(':', '_') })
    $needs += @($dependents | ForEach-Object { 'destroy_' + $_.Replace('-', '_').Replace(':', '_') })
    $condition = "!cancelled() && $gateCondition && contains($nodesExpression, '$key')"
    foreach ($prerequisite in $node.Prerequisites) {
        $condition += " && needs.outputs_$($prerequisite.Replace('-', '_').Replace(':', '_')).result == 'success'"
    }
    foreach ($dependent in $dependents) {
        $job = 'destroy_' + $dependent.Replace('-', '_').Replace(':', '_')
        $condition += " && (needs.$job.result == 'success' || (needs.$job.result == 'skipped' && !contains($nodesExpression, '$dependent')))"
    }
    Add-ModuleJobPreamble -Job "destroy_$suffix" -Title "$key (destroy)" -Needs $needs -Condition $condition `
        -Environment "fromJSON(needs.select.outputs.applyEnvironments)['$name']"
    $hasRulesets = -not $node.Phase -and $manifest['permissions']['githubApp'].Contains('rulesetPlan')
    # Organization-scoped tokens fail once the organizations are deleted; a repeated teardown must still pass an already destroyed module.
    $organizationScoped = @($manifest['permissions']['githubApp'].PSBase.Values |
        Where-Object { $_['resources'].Contains('organizations') }).Count -gt 0
    if ($organizationScoped) {
        $stateRunner = "./instance/platform/tools/Invoke-Module.ps1 -Module '$name' -Action state $runnerArguments -PlatformOrganization `$env:GITHUB_REPOSITORY_OWNER$phaseArgument"
        $stateCalls = @($stateRunner)
        if ($hasRulesets) { $stateCalls += "$stateRunner -Rulesets" }
        Add-WorkflowBlock @"
      - name: Read whether every module state is empty before issuing GitHub tokens
        id: state
        shell: pwsh
        run: |
          `$results = @(
$(($stateCalls | ForEach-Object { "            $_" }) -join "`n")
          )
          `$empty = `$results.Count -eq $($stateCalls.Count) -and @(`$results | Where-Object { `$_.Empty -isnot [bool] -or -not `$_.Empty }).Count -eq 0
          "empty=`$(`$empty.ToString().ToLowerInvariant())" >> `$env:GITHUB_OUTPUT
"@
    }
    $firstGuardedLine = $lines.Count
    Add-WorkflowBlock @"
      - name: Issue an apply-scoped enterprise App installation token
        shell: pwsh
        env:
          PLATFORM_APP_ID: `${{ vars.PLATFORM_APP_ID }}
          PLATFORM_APP_INSTALLATION_ID: `${{ vars.PLATFORM_APP_INSTALLATION_ID }}
          PLATFORM_APP_ENTERPRISE: `${{ vars.PLATFORM_APP_ENTERPRISE }}
          PLATFORM_APP_PRIVATE_KEY: `${{ secrets.PLATFORM_APP_PRIVATE_KEY }}
        run: ./instance/platform/tools/New-PlatformGitHubToken.ps1 -Module '$name' -Phase apply $runnerArguments
"@
    foreach ($prerequisite in $node.Prerequisites) {
        Add-WorkflowBlock @"
      - name: Download outputs of $prerequisite
        uses: actions/download-artifact@9000827ccba6bdab643e8b6fd33ac0654aef8333 # v8.0.2
        with:
          name: teardown-outputs-$($prerequisite.Replace(':', '-'))
          path: ./artifacts/prerequisites
"@
    }
    $runner = "./instance/platform/tools/Invoke-Module.ps1 -Module '$name' -Action destroy $runnerArguments -PrerequisiteOutputsPath ./artifacts/prerequisites -ArtifactsPath ./artifacts/module-outputs -PlatformOrganization `$env:GITHUB_REPOSITORY_OWNER$phaseArgument"
    if ($hasRulesets) {
        Add-TeardownMainCheck
        Add-WorkflowBlock @"
      - name: Destroy the isolated rulesets root first
        shell: pwsh
        env:
          GITHUB_TOKEN: `${{ env.GH_TOKEN }}
        run: $runner -Rulesets
"@
    }
    Add-TeardownMainCheck
    Add-WorkflowBlock @"
      - name: Destroy module
        shell: pwsh
        env:
          GITHUB_TOKEN: `${{ env.GH_TOKEN }}
        run: $runner
"@
    if ($organizationScoped) {
        # Only the explicit result 'true' skips the token and destroy steps; a missing or other value runs them.
        for ($index = $lines.Count - 1; $index -ge $firstGuardedLine; $index--) {
            if ($lines[$index] -like '      - name: *') {
                $lines.Insert($index + 1, "        if: `${{ steps.state.outputs.empty != 'true' }}")
            }
        }
    }
    Add-WorkflowBlock @"
      - name: Revoke the job installation tokens
        if: `${{ always() && env.PLATFORM_GITHUB_TOKENS != '' }}
        shell: pwsh
        run: ./instance/platform/tools/Remove-PlatformGitHubToken.ps1
"@
}

$fullOutputPath = [System.IO.Path]::GetFullPath($OutputPath)
$content = ($lines -join "`n") + "`n"
$encoding = [System.Text.UTF8Encoding]::new($false)
if ($Check) {
    if (-not (Test-Path -LiteralPath $fullOutputPath -PathType Leaf) -or
        [Convert]::ToBase64String([System.IO.File]::ReadAllBytes($fullOutputPath)) -cne
        [Convert]::ToBase64String($encoding.GetBytes($content))) {
        throw "Generated workflow differs from '$OutputPath'. Run tools/Generate-TeardownWorkflow.ps1 to regenerate it."
    }
    return
}
[System.IO.Directory]::CreateDirectory([System.IO.Path]::GetDirectoryName($fullOutputPath)) | Out-Null
[System.IO.File]::WriteAllText($fullOutputPath, $content, $encoding)
