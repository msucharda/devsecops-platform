#Requires -Version 7.4
[CmdletBinding(DefaultParameterSetName = 'Plan')]
param(
    [Parameter(Mandatory)][string] $NeedsJson,
    [string] $JobSummaryPath = $env:GITHUB_STEP_SUMMARY,
    [string] $GitHubOutputPath,
    [Parameter(Mandatory, ParameterSetName = 'Apply')][switch] $Apply,
    [Parameter(Mandatory, ParameterSetName = 'Apply')][ValidateSet('true', 'false')][string] $ApplyRequested,
    [Parameter(ParameterSetName = 'Apply')][string] $RunAttempt = $env:GITHUB_RUN_ATTEMPT
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# security-check: deployment-plan-change-output
function Get-DeploymentPlanChange {
    param([System.Collections.IDictionary] $Job, [string] $Name)

    $outputs = $Job['outputs']
    if ($outputs -isnot [System.Collections.IDictionary]) {
        throw [FormatException]::new("Cloud plan INCOMPLETE: $Name has no readable plan outputs. Apply is blocked.")
    }
    if (-not $outputs.Contains('changes')) {
        throw [FormatException]::new("Cloud plan INCOMPLETE: $Name is missing the changes output. Promote the updated vendored deployment workflow template to the live .github/workflows in a separate reviewed PR (see platform/docs/vendoring.md). Apply is blocked.")
    }
    if ($outputs['changes'] -isnot [string] -or $outputs['changes'] -cnotin @('true', 'false')) {
        throw [FormatException]::new("Cloud plan INCOMPLETE: $Name has an invalid changes output. Apply is blocked.")
    }
    return $outputs['changes'] -eq 'true'
}

# security-check: deployment-apply-completion
function Get-DeploymentApplySummary {
    param([Collections.IDictionary] $Needs, [string] $Attempt, [string] $Requested)

    if ($Attempt -notmatch '^[1-9][0-9]*\z' -or
        $Needs['authorize']['outputs']['attempt'] -isnot [string] -or
        $Needs['authorize']['outputs']['attempt'] -ne $Attempt) {
        throw 'Apply INCOMPLETE: stale authorization attempt. Use Re-run all jobs outside the reference, or a new dispatch for the reference.'
    }
    if ($Needs['authorize']['result'] -cne 'success') { throw 'Apply INCOMPLETE: trusted authorization failed.' }
    if ($Needs['authorize']['outputs']['allowed'] -ceq 'false') { return 'Apply NOT PERFORMED: the author is not authorized for deployment credentials.' }
    if ($Needs['authorize']['outputs']['allowed'] -cne 'true') { throw 'Apply INCOMPLETE: unreadable authorization decision.' }
    if ($Needs['select']['result'] -cne 'success' -or $Needs['plan_complete']['result'] -cne 'success') {
        throw 'Apply INCOMPLETE: trusted selection or cloud plan failed.'
    }
    if ($Requested -eq 'false') { return 'Apply NOT PERFORMED: this event or operation requests plan only.' }
    $nodes = ConvertFrom-Json -InputObject $Needs['select']['outputs']['phaseNodes'] -NoEnumerate
    if ($nodes -isnot [array] -or @($nodes | Where-Object {
        $_ -isnot [string] -or $_ -cnotmatch '^[a-z][a-z0-9-]*(:[a-z][a-z0-9-]*)?\z'
    }).Count -gt 0) { throw 'Apply INCOMPLETE: unreadable selected phases.' }
    if ($Needs['plan_complete']['outputs']['changes'] -cnotin @('true', 'false')) { throw 'Apply INCOMPLETE: unreadable plan change decision.' }
    if ($Needs['plan_complete']['outputs']['changes'] -ceq 'false') { return 'No changes. No apply was required or performed.' }
    if ($nodes.Count -eq 0) { throw 'Apply INCOMPLETE: an empty phase selection cannot require apply.' }
    if ($Needs['approve_apply']['result'] -cne 'success') { throw 'Apply INCOMPLETE: shared apply approval did not succeed.' }
    foreach ($node in $nodes) {
        $job = 'apply_' + $node.Replace('-', '_').Replace(':', '_')
        if (-not $Needs.Contains($job) -or $Needs[$job]['result'] -cne 'success') { throw "Apply INCOMPLETE: $job did not succeed." }
    }
    return 'Apply completed for every selected phase. Manual confirmations are not automatically verified.'
}

$needs = ConvertFrom-Json -InputObject $NeedsJson -AsHashtable
if ($Apply) {
    $text = Get-DeploymentApplySummary -Needs $needs -Attempt $RunAttempt -Requested $ApplyRequested
    if ($JobSummaryPath) {
        [IO.File]::AppendAllText([IO.Path]::GetFullPath($JobSummaryPath), "## Deployment apply`n`n$text`n", [Text.UTF8Encoding]::new($false))
    }
    Write-Information $text -InformationAction Continue
    return
}
$failure = $null
$hasChanges = $false
if ($needs['authorize']['result'] -cne 'success') {
    $text = 'Cloud plan NOT PERFORMED: trusted authorization failed. No deployment credentials were released.'
    $failure = 'Trusted deployment authorization failed.'
}
elseif ($needs['authorize']['outputs']['allowed'] -cne 'true') {
    $text = 'Cloud plan NOT PERFORMED: fork, App-created PR or author without verified platform-team membership. Configuration validation is not a cloud plan. Review and merge an import PR to run plan from protected main before apply.'
}
elseif ($needs['validate']['result'] -cne 'success' -or $needs['select']['result'] -cne 'success') {
    $text = 'Cloud plan NOT PERFORMED: configuration validation or trusted module selection failed.'
    $failure = 'Configuration validation or trusted module selection failed.'
}
else {
    $selected = @(ConvertFrom-Json -InputObject $needs['select']['outputs']['modules'])
    $failed = [Collections.Generic.List[string]]::new()
    $rulesetModules = @()
    if (-not $needs['select']['outputs'].Contains('rulesetModules')) {
        $failed.Add('missing declared ruleset selection; regenerate the deployment workflow')
    }
    else {
        $rulesetModules = @(ConvertFrom-Json -InputObject $needs['select']['outputs']['rulesetModules'])
    }
    $jobNames = [Collections.Generic.List[string]]::new()
    if ($needs['select']['outputs'].Contains('phaseNodes')) {
        $selectedNodes = $null
        try {
            $selectedNodes = ConvertFrom-Json -InputObject $needs['select']['outputs']['phaseNodes'] -NoEnumerate -ErrorAction Stop
        }
        catch { $selectedNodes = $null }
        if ($selectedNodes -isnot [array] -or
            @($selectedNodes | Where-Object { $_ -isnot [string] -or $_ -cnotmatch '^[a-z][a-z0-9-]*(:[a-z][a-z0-9-]*)?$' }).Count -gt 0 -or
            ($selected.Count -gt 0 -and $selectedNodes.Count -eq 0)) {
            $failed.Add('invalid selected deployment phases')
        }
        else {
            foreach ($node in $selectedNodes) {
                $jobNames.Add('module_' + $node.Replace('-', '_').Replace(':', '_'))
            }
            foreach ($module in $rulesetModules) {
                if ($module -cnotin $selected -or $module -cnotin $selectedNodes) {
                    $failed.Add('invalid selected ruleset phase')
                }
                else {
                    $jobNames.Add('ruleset_plan_' + $module.Replace('-', '_'))
                }
            }
        }
    }
    else {
        foreach ($module in $selected) {
            $suffix = $module.Replace('-', '_')
            $jobNames.Add("module_$suffix")
            if ($module -cin $rulesetModules) { $jobNames.Add("ruleset_plan_$suffix") }
        }
    }
    foreach ($job in $jobNames) {
            if (-not $needs.Contains($job) -or $needs[$job]['result'] -cne 'success') { $failed.Add($job) }
    }
    if ($failed.Count) {
        $text = "Cloud plan INCOMPLETE: $($failed -join ', '). Apply is blocked."
        $failure = $text
    }
    elseif ($selected.Count -eq 0) {
        $text = 'No modules selected. No cloud plan or apply is required.'
    }
    else {
        foreach ($job in $jobNames) {
            try { $changed = Get-DeploymentPlanChange -Job $needs[$job] -Name $job }
            catch [FormatException] {
                $failure = $_.Exception.Message
                break
            }
            if ($changed) { $hasChanges = $true }
        }
        if ($failure) { $text = $failure }
        else {
            $text = "Cloud plan completed for all selected modules, prerequisites and declared ruleset exceptions: $($selected -join ', '). Manual confirmations are not automatically verified."
            if (-not $hasChanges) { $text += ' No changes. No apply approval or apply is required.' }
        }
    }
}
if ($JobSummaryPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($JobSummaryPath), "## Deployment plan`n`n$text`n", [Text.UTF8Encoding]::new($false))
}
Write-Information $text -InformationAction Continue
if ($failure) { throw $failure }
if ($GitHubOutputPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath),
        "changes=$($hasChanges.ToString().ToLowerInvariant())`n", [Text.UTF8Encoding]::new($false))
}
