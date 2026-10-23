#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][AllowEmptyString()][string] $NeedsJson,
    [Parameter(Mandatory)][string] $InstancePath,
    [Parameter(Mandatory)][string] $ModulesPath,
    [Parameter(Mandatory)][string] $ReportPath,
    [Parameter(Mandatory)][string] $GitHubOutputPath,
    [string] $PlatformOrganization = $env:GITHUB_REPOSITORY_OWNER,
    [string] $JobSummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string] $RunUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY/actions/runs/$env:GITHUB_RUN_ID"
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')

$incomplete = [System.Collections.Generic.List[string]]::new()
$drift = [System.Collections.Generic.List[string]]::new()
$uncovered = [System.Collections.Generic.List[string]]::new()

function Get-NeedValue {
    [CmdletBinding()]
    param([System.Collections.IDictionary] $Needs, [string] $Job, [string] $Output)

    if ($null -eq $Needs -or -not $Needs.Contains($Job) -or $Needs[$Job] -isnot [System.Collections.IDictionary]) { return $null }
    if (-not $Output) { return $Needs[$Job]['result'] }
    $outputs = $Needs[$Job]['outputs']
    if ($outputs -isnot [System.Collections.IDictionary] -or -not $outputs.Contains($Output)) { return $null }
    return $outputs[$Output]
}

function ConvertFrom-ModuleList {
    [CmdletBinding()]
    [OutputType([string[]])]
    param([AllowNull()][object] $Value)

    if ($Value -isnot [string]) { return $null }
    try { $list = ConvertFrom-Json -InputObject $Value -NoEnumerate -ErrorAction Stop } catch { return $null }
    if ($list -isnot [array] -or @($list | Where-Object { $_ -isnot [string] }).Count) { return $null }
    [string[]] $names = @($list)
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    return , $names
}

$modules = $null
$instance = $null
try {
    $modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
    $instance = Get-PlatformInstance -Path $InstancePath -Modules $modules -AllowUnboundApps
}
catch {
    $incomplete.Add("The trusted instance configuration or module manifests could not be read: $($_.Exception.Message)")
}

$needs = $null
try {
    $needs = ConvertFrom-Json -InputObject $NeedsJson -AsHashtable -ErrorAction Stop
}
catch { $needs = $null }
if ($needs -isnot [System.Collections.IDictionary]) {
    $needs = $null
    $incomplete.Add('The workflow job results could not be read.')
}

$revision = [string] (Get-NeedValue $needs 'authorize' 'revision')
if ($needs) {
    if ((Get-NeedValue $needs 'authorize') -cne 'success' -or (Get-NeedValue $needs 'authorize' 'allowed') -cne 'true' -or
        $revision -cnotmatch '^[a-f0-9]{40}$') {
        $incomplete.Add('The run was not confirmed on an immutable revision of protected main.')
    }
    elseif ((Get-NeedValue $needs 'validate') -cne 'success' -or (Get-NeedValue $needs 'select') -cne 'success') {
        $incomplete.Add('Configuration validation or trusted module selection did not succeed.')
    }
    else {
        $selected = ConvertFrom-ModuleList (Get-NeedValue $needs 'select' 'modules')
        $rulesetModules = ConvertFrom-ModuleList (Get-NeedValue $needs 'select' 'rulesetModules')
        if ($null -eq $selected -or $null -eq $rulesetModules) {
            $incomplete.Add('The module selection is missing or invalid; regenerate the drift workflow.')
        }
        elseif ($instance) {
            $expected = Get-PlatformModuleSelection -Instance $instance -Modules $modules
            [string[]] $expectedRulesets = @($expected | Where-Object { $modules[$_]['permissions']['githubApp'].Contains('rulesetPlan') })
            if ((ConvertTo-Json -InputObject $selected -Compress) -cne (ConvertTo-Json -InputObject @($expected) -Compress) -or
                (ConvertTo-Json -InputObject $rulesetModules -Compress) -cne (ConvertTo-Json -InputObject @($expectedRulesets) -Compress)) {
                $incomplete.Add('The module selection differs from the trusted instance configuration and module manifests.')
            }
        }
        if ($null -ne $selected -and $null -ne $rulesetModules) {
            foreach ($module in $selected) {
                $organizationScoped = $modules -and $modules.Contains($module) -and $modules[$module].Contains('organizationScoped')
                $expectedOrganizations = @()
                if ($organizationScoped -and $instance) {
                    try {
                        $expectedOrganizations = @(Get-PlatformModuleOrganization -Instance $instance -Manifest $modules[$module] -PlatformOrganization $PlatformOrganization)
                    }
                    catch { $incomplete.Add("Organization scope of '$module' could not be verified: $($_.Exception.Message)") }
                }
                $roots = @(@{ Job = 'module_' + $module.Replace('-', '_'); Label = 'Terraform plan' })
                if ($module -cin $rulesetModules) { $roots += @{ Job = 'ruleset_plan_' + $module.Replace('-', '_'); Label = 'rulesets' } }
                foreach ($root in $roots) {
                    $changes = Get-NeedValue $needs $root.Job 'changes'
                    # A plan can report changes before a later step fails the job; keep that drift visible.
                    if ($changes -ceq 'true' -and -not $organizationScoped) { $drift.Add("- ``$module`` ($($root.Label))") }
                    if ($organizationScoped) {
                        $results = $null
                        try {
                            $results = ConvertFrom-Json -InputObject (Get-NeedValue $needs $root.Job 'organizations') -AsHashtable -ErrorAction Stop
                        }
                        catch { $results = $null }
                        if ($results -isnot [System.Collections.IDictionary]) {
                            $incomplete.Add("Plan job $($root.Job) did not publish per-organization results.")
                            if ($changes -ceq 'true') { $drift.Add("- ``$module`` ($($root.Label); organization results unavailable)") }
                        }
                        else {
                            if ((ConvertTo-PlatformCanonicalJson @($results.PSBase.Keys | Sort-Object -CaseSensitive)) -cne
                                (ConvertTo-PlatformCanonicalJson @($expectedOrganizations | Sort-Object -CaseSensitive))) {
                                $incomplete.Add("Plan job $($root.Job) organization result keys differ from the complete instance organization set.")
                            }
                            $organizationChanges = $false
                            foreach ($organization in $expectedOrganizations) {
                                $record = $results[$organization]
                                if ($record -isnot [System.Collections.IDictionary]) {
                                    $incomplete.Add("Plan job $($root.Job) has no readable result for '$organization'.")
                                    continue
                                }
                                if ($record['changes'] -is [bool] -and $record['changes']) {
                                    $organizationChanges = $true
                                    $drift.Add("- ``$module`` / ``$organization`` ($($root.Label))")
                                }
                                if ($record['result'] -cne 'success' -or $record['changes'] -isnot [bool]) {
                                    $incomplete.Add("Plan job $($root.Job) did not complete organization '$organization' with a boolean change state.")
                                }
                            }
                            if ($changes -ceq 'true' -and -not $organizationChanges) {
                                $reason = if ($expectedOrganizations.Count -eq 0) { 'organization scope unverified' } else { 'organization results incomplete' }
                                $drift.Add("- ``$module`` ($($root.Label); $reason)")
                            }
                            if ($changes -cin @('true', 'false') -and
                                $changes -cne $organizationChanges.ToString().ToLowerInvariant()) {
                                $incomplete.Add("Plan job $($root.Job) aggregate change state differs from its organization results.")
                            }
                        }
                    }
                    if ((Get-NeedValue $needs $root.Job) -cne 'success' -or $changes -cnotin @('true', 'false')) {
                        $incomplete.Add("Plan job $($root.Job) did not complete with a published change state.")
                        continue
                    }
                    if ($root.Label -eq 'rulesets') {
                        $inherited = Get-NeedValue $needs $root.Job 'inheritedRulesets'
                        if ($inherited -isnot [string] -or $inherited -cnotmatch '^(0|[1-9][0-9]{0,5})$') {
                            $incomplete.Add("Plan job $($root.Job) did not verify ruleset bypass visibility.")
                        }
                        elseif ([int] $inherited -gt 0) {
                            $uncovered.Add("- $inherited inherited enterprise rulesets of ``$module`` organizations are not covered by organization ruleset drift detection.")
                        }
                    }
                }
            }
        }
    }
}

if ($instance) {
    foreach ($prerequisite in Get-PlatformManualPrerequisite -Instance $instance) {
        $state = if ($prerequisite.Confirmed) { 'confirmed declaration' } else { 'NOT confirmed' }
        $uncovered.Add("- manual enterprise prerequisite ``$($prerequisite.Name)``: $state; live state is not automatically verified.")
    }
    $selectedModules = Get-PlatformModuleSelection -Instance $instance -Modules $modules
    foreach ($module in $selectedModules) {
        foreach ($step in $modules[$module]['manualSteps']) {
            $limitation = 'Manual changes are not automatically detected.'
            if ($step.Contains('limitations')) { $limitation = $step['limitations']['drift'] }
            $uncovered.Add("- ``$module`` manual step ``$($step['id'])``: $limitation")
        }
    }
}
else {
    $uncovered.Add('- Manual prerequisites and manual steps could not be listed because the trusted configuration was not readable.')
}

$complete = $incomplete.Count -eq 0
$report = [System.Collections.Generic.List[string]]::new()
$report.Add('<!-- platform-drift-report -->')
$report.Add('## Infrastructure drift')
$report.Add('')
$report.Add("Run: $RunUrl")
if ($revision -cmatch '^[a-f0-9]{40}$') { $report.Add("Revision: ``$revision``") }
$report.Add('')
if ($drift.Count) {
    $report.Add('### Drift detected')
    $report.Add('')
    $report.AddRange($drift)
}
elseif ($complete) {
    $report.Add('No drift detected in the automatically planned resources.')
}
if (-not $complete) {
    $report.Add('')
    $report.Add('### Drift detection INCOMPLETE')
    $report.Add('')
    $report.Add('Modules without a completed plan may have undetected drift.')
    $report.Add('')
    foreach ($reason in $incomplete) { $report.Add("- $reason") }
}
$report.Add('')
$report.Add('### Not covered by automatic drift detection')
$report.Add('')
$report.AddRange($uncovered)
$content = ($report -join "`n") + "`n"
$encoding = [System.Text.UTF8Encoding]::new($false)
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($ReportPath), $content, $encoding)
if ($JobSummaryPath) {
    [System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($JobSummaryPath), $content, $encoding)
}
$publish = ($drift.Count -gt 0 -or -not $complete).ToString().ToLowerInvariant()
[System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($GitHubOutputPath),
    "report=$publish`ncomplete=$($complete.ToString().ToLowerInvariant())`n", $encoding)
Write-Information $content -InformationAction Continue
