#Requires -Version 7.4
<#
.SYNOPSIS
Runs the checks of .github/workflows/ci.yml locally, under the same conditions as CI, before a push.

.DESCRIPTION
-Changed (default) runs the cheap checks in full and scopes Pester, the interruption harness, mutation tests and
Terraform to the diff against -Base. -Full runs every CI step without scoping. Pester always runs through
tools/Invoke-Tests.ps1, so StrictMode and the Pester version from tools/requirements.psd1 apply.
The script stops at the first failing step.

Exit codes: 0 all selected steps passed, 1 a step failed, 2 preflight or usage error.
#>
[CmdletBinding()]
param(
    [switch] $Changed,
    [switch] $Full,
    [string] $Base = 'origin/main',
    [switch] $Plan,
    [string] $LogPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$started = [Diagnostics.Stopwatch]::StartNew()
if (-not $LogPath) { $LogPath = Join-Path $repo "artifacts/local-ci/$(Get-Date -Format 'yyyyMMdd-HHmmss').log" }
$LogPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($LogPath)
$null = New-Item -ItemType Directory -Force -Path (Split-Path $LogPath -Parent)
Set-Content -LiteralPath $LogPath -Value "Invoke-LocalCi $(Get-Date -Format o)" -Encoding utf8NoBOM

function Add-LogLine {
    param([AllowEmptyString()][string] $Text)
    Add-Content -LiteralPath $LogPath -Value $Text -Encoding utf8NoBOM
}

function Write-Console {
    param([AllowEmptyString()][string] $Text)
    Add-LogLine $Text
    Write-Information $Text -InformationAction Continue
}

function Exit-Usage {
    param([string] $Message)
    Write-Console "ERROR: $Message"
    Write-Console "Log: $LogPath"
    exit 2
}

function Invoke-Git {
    param([string[]] $Arguments)
    # Only stdout is data; stderr (for example line-ending warnings) goes to the log.
    $output = @(& git -C $repo @Arguments 2>&1 | ForEach-Object {
        if ($_ -is [System.Management.Automation.ErrorRecord]) { Add-LogLine "git: $_" } else { "$_" }
    })
    return [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
}

if ($Changed -and $Full) { Exit-Usage '-Changed and -Full are mutually exclusive.' }
$mode = if ($Full) { 'Full' } else { 'Changed' }

Import-Module (Join-Path $PSScriptRoot 'LocalCi.psm1') -Force
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
$moduleProbe = { param($module) @(Get-Module -ListAvailable -Name $module | ForEach-Object { $_.Version.ToString() }) }
# ci.yml is parsed with powershell-yaml, so missing modules must be reported before parsing.
$moduleProblems = @(Get-LocalCiModuleProblem -Requirements $requirements -ModuleProbe $moduleProbe)
if ($moduleProblems.Count -gt 0) {
    foreach ($problem in $moduleProblems) { Add-LogLine "ERROR $problem"; Write-Information "ERROR $problem" -InformationAction Continue }
    Write-Console "Log: $LogPath"
    exit 2
}
try { $setting = Get-CiWorkflowSetting -WorkflowPath (Join-Path $repo '.github/workflows/ci.yml') }
catch { Exit-Usage "Cannot read .github/workflows/ci.yml: $($_.Exception.Message)" }
[string[]] $allRoots = @(& (Join-Path $PSScriptRoot 'Get-TerraformRoots.ps1') -RepositoryPath $repo | ConvertFrom-Json)
$temp = Join-Path $repo 'artifacts/local-ci/tmp'
# Selection
$changedFiles = @()
$newFiles = @()
if ($Base.StartsWith('origin/', [StringComparison]::Ordinal)) {
    $fetch = Invoke-Git @('fetch', 'origin', 'main', '--quiet')
    if ($fetch.ExitCode -ne 0) { Write-Console "WARN git fetch origin main failed; using the local $Base. $($fetch.Output -join ' ')" }
}
$mergeBase = Invoke-Git @('merge-base', $Base, 'HEAD')
if ($mergeBase.ExitCode -ne 0 -or $mergeBase.Output.Count -ne 1 -or $mergeBase.Output[0] -cnotmatch '^[0-9a-f]{40}$') {
    Exit-Usage "Invalid -Base '$Base': git merge-base failed. $($mergeBase.Output -join ' ')"
}
$mb = $mergeBase.Output[0]
$behind = Invoke-Git @('rev-list', '--count', "HEAD..$Base")
if ($behind.ExitCode -eq 0 -and [int] $behind.Output[0] -gt 0) {
    Write-Console "WARN HEAD is $($behind.Output[0]) commit(s) behind $Base. The CI pull_request run tests the merge result; rebase to test the same code."
}
$diff = Invoke-Git @('diff', '--name-only', '--no-renames', $mb)
$untracked = Invoke-Git @('ls-files', '--others', '--exclude-standard')
$added = Invoke-Git @('diff', '--name-only', '--no-renames', '--diff-filter=A', $mb)
if ($diff.ExitCode -ne 0 -or $untracked.ExitCode -ne 0 -or $added.ExitCode -ne 0) { Exit-Usage 'git could not list the changed files.' }
$changedFiles = @(@($diff.Output) + @($untracked.Output) | Where-Object { $_ } | Sort-Object -Unique -CaseSensitive)
$newFiles = @(@($added.Output) + @($untracked.Output) | Where-Object { $_ })

if ($mode -eq 'Full') {
    $selection = [pscustomobject]@{
        AllPester = $true; PesterPath = [string[]] @(); AllInterruption = $true; InterruptionPath = [string[]] @()
        AllMutation = $true; MutationCheck = [string[]] @(); TerraformRoot = $allRoots; Warning = [string[]] @(); Reason = [string[]] @('-Full')
    }
}
else {
    $ciChanged = $false
    if ($changedFiles -ccontains '.github/workflows/ci.yml') {
        $baseCi = Invoke-Git @('show', "$($mb):.github/workflows/ci.yml")
        if ($baseCi.ExitCode -ne 0) { $ciChanged = $true }
        else {
            $basePath = Join-Path (Split-Path $LogPath -Parent) "ci-base-$([guid]::NewGuid().ToString('N')).yml"
            try {
                Set-Content -LiteralPath $basePath -Value ($baseCi.Output -join "`n") -Encoding utf8NoBOM
                $baseSetting = Get-CiWorkflowSetting -WorkflowPath $basePath
                $ciChanged = $baseSetting.TerraformFingerprint -cne $setting.TerraformFingerprint
            }
            catch { $ciChanged = $true }
            finally { Remove-Item -LiteralPath $basePath -Force }
        }
    }
    $selection = Get-LocalCiSelection -RepoPath $repo -ChangedFile $changedFiles -TerraformRoot $allRoots -AllTerraformRoots:$ciChanged
}

$runInterruption = $selection.AllInterruption -or $selection.InterruptionPath.Count -gt 0
$runMutation = $selection.AllMutation -or $selection.MutationCheck.Count -gt 0
$pesterLabel = if ($selection.AllPester) { 'all' } else { "$($selection.PesterPath.Count) file(s)" }
$interruptionLabel = if ($selection.AllInterruption) { 'all' } elseif ($runInterruption) { "$($selection.InterruptionPath.Count) file(s)" } else { 'none' }
$mutationLabel = if ($selection.AllMutation) { 'all' } elseif ($runMutation) { $selection.MutationCheck -join ', ' } else { 'none' }

$planLines = [System.Collections.Generic.List[string]]::new()
$planLines.Add("Mode: $mode; base $Base (merge base $mb); $($changedFiles.Count) changed file(s)")
foreach ($file in $changedFiles) { $planLines.Add("  changed: $file") }
foreach ($reason in $selection.Reason) { $planLines.Add("Escalation: $reason") }
foreach ($warning in $selection.Warning) { $planLines.Add("WARN $warning") }
$planLines.Add('Steps: Preflight, Check PowerShell, Validate module manifests, Validate instance examples, Check generated workflows, ' +
    'Validate deployment workflow syntax, Validate instance workflows that call local reusable workflows, Discover Terraform roots, ' +
    'Terraform per root, Run Pester, Interrupt every state-changing step, Weaken every marked security check')
$planLines.Add("Pester: $pesterLabel")
foreach ($path in $selection.PesterPath) { $planLines.Add("  test: $path") }
$planLines.Add("Interruption: $interruptionLabel")
foreach ($path in $selection.InterruptionPath) { $planLines.Add("  test: $path") }
$planLines.Add("Mutation: $mutationLabel")
$planLines.Add("Terraform roots: $(if ($selection.TerraformRoot.Count) { $selection.TerraformRoot -join ', ' } else { 'none' })")
foreach ($line in $planLines) { Write-Console $line }
if ($Plan) { exit 0 }

# Environment
$savedEnvironment = @{}
# A nested or concurrent run would empty the per-worktree TEMP of the outer run.
if ($env:INVOKE_LOCAL_CI_ACTIVE) { Exit-Usage 'Another Invoke-LocalCi run is active in this process tree; nested runs are refused.' }
foreach ($name in 'TEMP', 'TMP', 'TMPDIR', 'TF_IN_AUTOMATION', 'INTERRUPTION_SHARD', 'INVOKE_LOCAL_CI_ACTIVE') {
    $savedEnvironment[$name] = [Environment]::GetEnvironmentVariable($name)
}
$results = [System.Collections.Generic.List[object]]::new()
$pesterCounts = [System.Collections.Generic.List[object]]::new()
$failed = $false

function Add-Result {
    param([string] $Name, [string] $Status, [double] $Seconds, [string] $Note)
    $results.Add([pscustomobject]@{ Name = $Name; Status = $Status; Seconds = $Seconds })
    $suffix = if ($Note) { " ($Note)" } else { '' }
    Write-Console ('{0,-4} {1} [{2:n1}s]{3}' -f $Status, $Name, $Seconds, $suffix)
}

function Invoke-Native {
    <#
    .SYNOPSIS
    Runs one external command, streams its output to the log and returns the exit code and the output lines.
    #>
    param([string] $FilePath, [string[]] $Arguments, [string] $WorkingDirectory = $repo)
    Add-LogLine "> $FilePath $($Arguments -join ' ')"
    $lines = [System.Collections.Generic.List[string]]::new()
    Push-Location -LiteralPath $WorkingDirectory
    try {
        $global:LASTEXITCODE = 0
        & $FilePath @Arguments 2>&1 | ForEach-Object {
            $line = "$_" -replace '\x1b\[[0-9;]*[A-Za-z]', ''
            $lines.Add($line)
            Add-Content -LiteralPath $LogPath -Value $line -Encoding utf8NoBOM
        }
        $code = $LASTEXITCODE
    }
    catch {
        $lines.Add($_.Exception.Message)
        Add-LogLine $_.Exception.Message
        $code = 1
    }
    finally { Pop-Location }
    return [pscustomobject]@{ ExitCode = $code; Output = $lines.ToArray() }
}

function Invoke-PwshScript {
    <#
    .SYNOPSIS
    Runs a pwsh script the way the GitHub Actions pwsh shell does: ErrorActionPreference Stop, then exit with LASTEXITCODE.
    #>
    param([string] $Script)
    $path = Join-Path $temp "step-$([guid]::NewGuid().ToString('N')).ps1"
    $body = "`$ErrorActionPreference = 'stop'`n$Script`nif ((Test-Path -LiteralPath variable:\LASTEXITCODE)) { exit `$LASTEXITCODE }`n"
    Set-Content -LiteralPath $path -Value $body -Encoding utf8NoBOM
    Add-LogLine $Script
    return Invoke-Native -FilePath ([Environment]::ProcessPath) -Arguments @('-NoProfile', '-NonInteractive', '-Command', ". '$path'")
}

function Write-FailureDetail {
    param([string[]] $Output, [switch] $Pester)
    $detail = @(if ($Pester) { Get-PesterFailureDetail -Line $Output })
    if ($detail.Count -eq 0) { $detail = @($Output | Where-Object { $_.Trim() } | Select-Object -Last 40) }
    foreach ($line in $detail) { Write-Console "    $line" }
}

function Invoke-Step {
    <#
    .SYNOPSIS
    Runs one step unless an earlier step failed. The body returns the native result; a non-zero exit code fails the step.
    #>
    param([string] $Name, [scriptblock] $Body, [switch] $Pester)
    if ($script:failed) { Add-Result -Name $Name -Status 'SKIP' -Seconds 0 -Note 'fail-fast'; return }
    Add-LogLine "=== $Name"
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $outcome = @(& $Body)
    $watch.Stop()
    $code = 0
    $output = [System.Collections.Generic.List[string]]::new()
    foreach ($item in $outcome) {
        if ($item.ExitCode -ne 0 -and $code -eq 0) { $code = $item.ExitCode }
        $output.AddRange([string[]] $item.Output)
        if ($item.ExitCode -ne 0) { break }
    }
    if ($Pester) {
        $count = Get-PesterCount -Line $output.ToArray()
        if ($count) { $pesterCounts.Add($count) }
    }
    if ($code -eq 0) { Add-Result -Name $Name -Status 'PASS' -Seconds $watch.Elapsed.TotalSeconds; return }
    $script:failed = $true
    Add-Result -Name $Name -Status 'FAIL' -Seconds $watch.Elapsed.TotalSeconds -Note "exit code $code"
    Write-FailureDetail -Output $output.ToArray() -Pester:$Pester
    if ($Pester) {
        $failedNew = @($newFiles | Where-Object { $_ -clike '*.Tests.ps1' -and ($output -match [regex]::Escape([IO.Path]::GetFileName($_))) })
        if ($failedNew.Count -gt 0) {
            Write-Console "    Hint: $($failedNew -join ', ') is new in this diff. Rerun once to rule out a race before you change code."
        }
    }
}

function Skip-Step {
    param([string] $Name, [string] $Reason)
    $note = if ($script:failed) { 'fail-fast' } else { $Reason }
    Add-Result -Name $Name -Status 'SKIP' -Seconds 0 -Note $note
}

function ConvertTo-PwshList {
    param([string[]] $Item)
    return ($Item | ForEach-Object { "'" + $_.Replace("'", "''") + "'" }) -join ','
}

try {
    $env:INVOKE_LOCAL_CI_ACTIVE = '1'
    # The default C:\Windows\TEMP allows creating files but denies deleting and enumerating them, so every run uses its own.
    Clear-LocalCiTemp -Path $temp
    foreach ($name in 'TEMP', 'TMP', 'TMPDIR') { [Environment]::SetEnvironmentVariable($name, $temp) }
    $env:TF_IN_AUTOMATION = 'true'
    Remove-Item Env:INTERRUPTION_SHARD -ErrorAction SilentlyContinue

    # 1. Preflight
    $watch = [Diagnostics.Stopwatch]::StartNew()
    $toolProbe = {
        param($tool)
        if (-not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) { return $null }
        $text = switch ($tool) {
            'terraform' { (& terraform version -json 2>$null | ConvertFrom-Json).terraform_version }
            'tflint' { (& tflint --version 2>$null | Select-Object -First 1) -replace '^TFLint version ', '' }
            'trivy' { (& trivy --version 2>$null | Where-Object { $_ -like 'Version:*' } | Select-Object -First 1) -replace '^Version:\s*', '' }
            'actionlint' { (& actionlint -version 2>$null | Select-Object -First 1) }
            'go' { (& go version 2>$null) }
        }
        return ([string] $text).Trim().TrimStart('v')
    }
    $problems = @(Get-LocalCiPreflightProblem -PowerShellVersion $PSVersionTable.PSVersion -Requirements $requirements -Setting $setting `
        -NeedsTerraformTools:($selection.TerraformRoot.Count -gt 0) -ModuleProbe $moduleProbe -ToolProbe $toolProbe)
    foreach ($problem in $problems) { Write-Console "$(if ($problem.Severity -eq 'Error') { 'ERROR' } else { 'WARN' }) $($problem.Message)" }
    if (@($problems | Where-Object Severity -eq 'Error').Count -gt 0) {
        Add-Result -Name 'Preflight' -Status 'FAIL' -Seconds $watch.Elapsed.TotalSeconds
        Write-Console "Log: $LogPath"
        exit 2
    }
    Add-Result -Name 'Preflight' -Status 'PASS' -Seconds $watch.Elapsed.TotalSeconds
    [string[]] $actionlint = if ((& $toolProbe 'actionlint') -ceq $setting.ActionlintVersion) { @('actionlint') }
    else { @('go', 'run', "github.com/rhysd/actionlint/cmd/actionlint@v$($setting.ActionlintVersion)") }

    # 2.-5. pwsh steps, in full and unchanged from ci.yml
    foreach ($name in 'Check PowerShell', 'Validate module manifests', 'Validate instance examples', 'Check generated workflows') {
        $stepScript = $setting.PwshSteps[$name]
        Invoke-Step -Name $name -Body { Invoke-PwshScript -Script $stepScript }
    }

    # 6.-7. actionlint
    Invoke-Step -Name 'Validate deployment workflow syntax' -Body {
        Invoke-Native -FilePath $actionlint[0] -Arguments (@($actionlint | Select-Object -Skip 1) + $setting.ActionlintArguments)
    }
    Invoke-Step -Name 'Validate instance workflows that call local reusable workflows' -Body {
        $project = Join-Path $temp "actionlint-$([guid]::NewGuid().ToString('N'))"
        $workflows = Join-Path $project '.github/workflows'
        $null = New-Item -ItemType Directory -Force -Path $workflows
        foreach ($file in $setting.InstanceWorkflowFiles) { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $workflows }
        Invoke-Native -FilePath 'git' -Arguments @('init', '-q', $project)
        Invoke-Native -FilePath $actionlint[0] -Arguments (@($actionlint | Select-Object -Skip 1) + $setting.InstanceActionlintArguments) -WorkingDirectory $project
    }

    # 8. Terraform
    Invoke-Step -Name 'Discover Terraform roots' -Body {
        Invoke-PwshScript -Script "./tools/Get-TerraformRoots.ps1 -GitHubOutputPath '$(Join-Path $temp 'github-output.txt')'"
    }
    if ($selection.TerraformRoot.Count -eq 0) { Skip-Step -Name 'Terraform' -Reason 'no root selected' }
    foreach ($root in $selection.TerraformRoot) {
        $commands = Get-LocalCiTerraformStepCommand -Root $root
        foreach ($name in $commands.Keys) {
            if ($name -eq 'Terraform test' -and -not (Test-Path -LiteralPath (Join-Path $repo "$root/tests") -PathType Container)) {
                Skip-Step -Name "$name ($root)" -Reason 'no tests directory'
                continue
            }
            $list = $commands[$name]
            Invoke-Step -Name "$name ($root)" -Body {
                foreach ($command in $list) {
                    $result = Invoke-Native -FilePath $command[0] -Arguments @($command | Select-Object -Skip 1)
                    $result
                    if ($result.ExitCode -ne 0) { break }
                }
            }
        }
    }

    # 9. Pester
    if ($selection.AllPester) { $pesterScript = './tools/Invoke-Tests.ps1 -CI' }
    elseif ($selection.PesterPath.Count -gt 0) { $pesterScript = "./tools/Invoke-Tests.ps1 -CI -Path $(ConvertTo-PwshList $selection.PesterPath)" }
    else { $pesterScript = $null }
    if ($pesterScript) { Invoke-Step -Name 'Run Pester' -Pester -Body { Invoke-PwshScript -Script $pesterScript } }
    else { Skip-Step -Name 'Run Pester' -Reason 'no test file mapped' }

    # 10. Interruption harness, all shards
    if ($runInterruption) {
        $interruptionScript = if ($selection.AllInterruption) { './tools/Invoke-Tests.ps1 -Tag Interruption' }
        else { "./tools/Invoke-Tests.ps1 -Tag Interruption -Path $(ConvertTo-PwshList $selection.InterruptionPath)" }
        Invoke-Step -Name 'Interrupt every state-changing step' -Pester -Body { Invoke-PwshScript -Script $interruptionScript }
    }
    else { Skip-Step -Name 'Interrupt every state-changing step' -Reason 'no test file mapped' }

    # 11. Mutation tests
    if ($runMutation) {
        $mutationScript = './tools/Invoke-MutationTests.ps1 -ReportPath ./artifacts/mutation-report.json'
        if (-not $selection.AllMutation) { $mutationScript += " -Check $(ConvertTo-PwshList $selection.MutationCheck)" }
        Invoke-Step -Name 'Weaken every marked security check' -Body { Invoke-PwshScript -Script $mutationScript }
    }
    else { Skip-Step -Name 'Weaken every marked security check' -Reason 'no marked check changed' }
}
finally {
    foreach ($name in $savedEnvironment.Keys) { [Environment]::SetEnvironmentVariable($name, $savedEnvironment[$name]) }
}

# Summary
$passed = @($results | Where-Object Status -eq 'PASS').Count
$failedCount = @($results | Where-Object Status -eq 'FAIL').Count
$skipped = @($results | Where-Object Status -eq 'SKIP').Count
Write-Console ''
Write-Console "Steps: $passed passed, $failedCount failed, $skipped skipped"
if ($pesterCounts.Count -gt 0) {
    Write-Console ("Pester tests: {0} passed, {1} failed, {2} not run" -f
        ($pesterCounts | Measure-Object Passed -Sum).Sum, ($pesterCounts | Measure-Object Failed -Sum).Sum, ($pesterCounts | Measure-Object NotRun -Sum).Sum)
}
Write-Console "Mapped test files: $pesterLabel Pester, $interruptionLabel interruption; Terraform roots: $($selection.TerraformRoot.Count)"
Write-Console ('Duration: {0:hh\:mm\:ss}' -f $started.Elapsed)
Write-Console "Log: $LogPath"
if ($mode -eq 'Changed') {
    Write-Console 'Not covered locally: unmapped tests, other roots, all interruption shards and mutation checks. CI runs them.'
}
exit $(if ($failed) { 1 } else { 0 })
