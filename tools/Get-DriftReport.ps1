#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][AllowEmptyString()][string] $NeedsJson,
    [Parameter(Mandatory)][string] $InstancePath,
    [Parameter(Mandatory)][string] $ModulesPath,
    [Parameter(Mandatory)][string] $ReportPath,
    [Parameter(Mandatory)][string] $GitHubOutputPath,
    [string] $CodeSecurityCoveragePath = './artifacts/code-security-coverage/code-security-coverage.json',
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
$codeSecuritySummaries = [System.Collections.Generic.List[string]]::new()
$coverageArtifactUrl = "$RunUrl#artifacts"

# security-check: code-security-coverage-artifact
function Test-CodeSecurityArtifactId {
    param([AllowNull()][object] $Value)

    return $Value -is [string] -and $Value -match '^[1-9][0-9]*$'
}

function Add-CodeSecurityCoverage {
    [CmdletBinding()]
    param([string] $Path, [string[]] $Organizations)

    $coverage = $null
    try { $coverage = ConvertFrom-Json -InputObject ([IO.File]::ReadAllText([IO.Path]::GetFullPath($Path))) -AsHashtable -ErrorAction Stop } catch { $coverage = $null }
    if ($coverage -isnot [Collections.IDictionary] -or $coverage['organizations'] -isnot [Collections.IDictionary]) {
        $incomplete.Add('Code Security coverage artifact did not publish a readable organization map.')
        return
    }
    $results = $coverage['organizations']
    if ((ConvertTo-PlatformCanonicalJson @($results.Keys | Sort-Object -CaseSensitive)) -cne
        (ConvertTo-PlatformCanonicalJson @($Organizations | Sort-Object -CaseSensitive))) {
        $incomplete.Add('Code Security coverage organization keys differ from the complete instance scope.')
    }
    foreach ($organization in $Organizations) {
        $result = $results[$organization]
        if ($result -isnot [Collections.IDictionary] -or $result['repositories'] -isnot [array]) {
            $incomplete.Add("Code Security coverage of '$organization' has no repository results.")
            continue
        }
        $counts = @{ compliant = 0; drift = 0; unverified = 0 }
        $directUnverified = 0
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($repository in $result['repositories']) {
            if ($repository -isnot [Collections.IDictionary] -or $repository['repository'] -isnot [string] -or
                $repository['repository'] -cnotmatch "^$([regex]::Escape($organization))/[A-Za-z0-9_.-]+$" -or
                $repository['status'] -isnot [string] -or $repository['status'] -cnotin @('compliant', 'drift', 'unverified') -or
                $repository['security_status'] -isnot [string] -or $repository['security_status'] -cnotin @('enabled', 'disabled', 'unverified')) {
                $incomplete.Add("Code Security coverage of '$organization' contains an invalid repository result.")
                continue
            }
            $name = $repository['repository']
            if (-not $seen.Add($name)) {
                $incomplete.Add("Code Security coverage repeats repository '$name'.")
                continue
            }
            $status = $repository['status']
            $counts[$status]++
            if ($repository['security_status'] -ceq 'unverified') { $directUnverified++ }
            if ($status -ceq 'unverified' -or $repository['security_status'] -ceq 'unverified') {
                $incomplete.Add("Code Security of repository '$name' is unverified; configuration coverage does not prove enabled repository security.")
            }
            if ($status -ceq 'drift') {
                $drift.Add("- Code Security coverage: ``$name`` (missing/unsuccessful attachment, configuration without Code Security or CodeQL, or disabled repository security; direct state: $($repository['security_status'])).")
            }
            elseif ($status -ceq 'compliant' -and $repository['security_status'] -cne 'enabled') {
                $incomplete.Add("Code Security coverage incorrectly labels repository '$name' compliant without readable enabled security.")
            }
        }
        foreach ($status in $counts.Keys) {
            if (($result[$status] -isnot [int] -and $result[$status] -isnot [long]) -or $result[$status] -ne $counts[$status]) {
                $incomplete.Add("Code Security coverage of '$organization' has an invalid '$status' counter.")
            }
        }
        $codeSecuritySummaries.Add("- ``$organization``: compliant $($counts.compliant), drift $($counts.drift), unverified $($counts.unverified); direct state unverified $directUnverified.")
    }
}

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
$selectedPhaseNodes = $null
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
            $selectedPhaseNodes = Get-PlatformModuleSelection -Instance $instance -Modules $modules -PhaseNodes
            [string[]] $expectedRulesets = @($expected | Where-Object {
                $_ -cin $selectedPhaseNodes -and $modules[$_]['permissions']['githubApp'].Contains('rulesetPlan')
            })
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
                $roots = @()
                if ($null -eq $selectedPhaseNodes -or $module -cin $selectedPhaseNodes) {
                    $roots += @{ Job = 'module_' + $module.Replace('-', '_'); Label = 'Terraform plan' }
                }
                if ($modules -and $modules.Contains($module) -and $modules[$module].Contains('phases')) {
                    foreach ($phase in $modules[$module]['phases'].Keys) {
                        if ($null -ne $selectedPhaseNodes -and "${module}:$phase" -cnotin $selectedPhaseNodes) { continue }
                        $roots += @{
                            Job = 'module_' + $module.Replace('-', '_') + '_' + $phase.Replace('-', '_')
                            Label = "phase $phase"
                            CodeSecurity = $module -ceq 'enterprise-baseline' -and $phase -ceq 'code-security'
                        }
                    }
                }
                if ($module -cin $rulesetModules) { $roots += @{ Job = 'ruleset_plan_' + $module.Replace('-', '_'); Label = 'rulesets' } }
                foreach ($root in $roots) {
                    if ($root.Contains('CodeSecurity') -and $root.CodeSecurity) {
                        $coverageOrganizations = $expectedOrganizations
                        if (-not $organizationScoped) {
                            $coverageOrganizations = @($instance['modules'][$module]['parameters']['target_organizations'])
                        }
                        if (-not (Test-CodeSecurityArtifactId (Get-NeedValue $needs $root.Job 'codeSecurityCoverage'))) {
                            $incomplete.Add("Code Security coverage artifact was not published by job $($root.Job); a previous attempt is not evidence.")
                        }
                        else {
                            Add-CodeSecurityCoverage -Path $CodeSecurityCoveragePath -Organizations $coverageOrganizations
                            $publishedUrl = Get-NeedValue $needs $root.Job 'codeSecurityCoverageUrl'
                            if ($publishedUrl -is [string] -and -not [string]::IsNullOrWhiteSpace($publishedUrl)) {
                                $coverageArtifactUrl = $publishedUrl
                            }
                        }
                    }
                    $changes = Get-NeedValue $needs $root.Job 'changes'
                    # A plan can report changes before a later step fails the job; keep that drift visible.
                    if ($changes -ceq 'true' -and -not $organizationScoped) { $drift.Add("- ``$module`` ($($root.Label))") }
                    if ($organizationScoped) {
                        $results = $null
                        try {
                            $results = ConvertFrom-Json -InputObject (Get-NeedValue $needs $root.Job 'organizations') -AsHashtable -NoEnumerate -ErrorAction Stop
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
if ($codeSecuritySummaries.Count) {
    $report.Add('### Repository Code Security coverage')
    $report.Add('')
    $report.AddRange($codeSecuritySummaries)
    $report.Add('Configuration attachment and readable repository security are separate evidence. Missing or forbidden security_and_analysis is unverified, never compliant.')
    $report.Add('')
}
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
$bytes = $encoding.GetByteCount($content)
if ($bytes -gt 50000) {
    $complete = $false
    $omitted = 0
    do {
        $last = $report.Count - 1
        $bytes -= $encoding.GetByteCount($report[$last] + "`n")
        $report.RemoveAt($last)
        $omitted++
        $notice = "`n### Drift detection INCOMPLETE: TRUNCATED`n$omitted omitted lines. Counts and actual drift precede unverified details. Full repository details: [code-security-coverage artifact]($coverageArtifactUrl), retained for 1 day. [Run]($RunUrl).`n"
    } while ($report.Count -gt 0 -and $bytes + $encoding.GetByteCount($notice) -gt 50000)
    $content = ($report -join "`n") + "`n" + $notice
}
[System.IO.File]::WriteAllText([System.IO.Path]::GetFullPath($ReportPath), $content, $encoding)
if ($JobSummaryPath) {
    [System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($JobSummaryPath), $content, $encoding)
}
$publish = ($drift.Count -gt 0 -or -not $complete).ToString().ToLowerInvariant()
[System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($GitHubOutputPath),
    "report=$publish`ncomplete=$($complete.ToString().ToLowerInvariant())`n", $encoding)
Write-Information $content -InformationAction Continue
