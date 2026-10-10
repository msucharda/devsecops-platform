#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $NeedsJson,
    [string] $JobSummaryPath = $env:GITHUB_STEP_SUMMARY
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$needs = ConvertFrom-Json -InputObject $NeedsJson -AsHashtable
$failure = $null
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
    foreach ($module in $selected) {
        $suffix = $module.Replace('-', '_')
        foreach ($job in @("module_$suffix", "ruleset_plan_$suffix")) {
            if ($job.StartsWith('ruleset_plan_') -and $module -cnotin $rulesetModules) { continue }
            if (-not $needs.Contains($job) -or $needs[$job]['result'] -cne 'success') { $failed.Add($job) }
        }
    }
    if ($failed.Count) {
        $text = "Cloud plan INCOMPLETE: $($failed -join ', '). Apply is blocked."
        $failure = $text
    }
    elseif ($selected.Count -eq 0) {
        $text = 'No modules selected. No cloud plan or apply is required.'
    }
    else {
        $text = "Cloud plan completed for all selected modules, prerequisites and declared ruleset exceptions: $($selected -join ', '). Manual confirmations are not automatically verified."
    }
}
if ($JobSummaryPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($JobSummaryPath), "## Deployment plan`n`n$text`n", [Text.UTF8Encoding]::new($false))
}
Write-Information $text -InformationAction Continue
if ($failure) { throw $failure }
