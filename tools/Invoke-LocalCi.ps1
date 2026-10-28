#Requires -Version 7.4
<#
.SYNOPSIS
Runs the selected local pre-push gate, or the complete CI profile on explicit request.

.DESCRIPTION
-Changed (default) checks changed PowerShell, manifests, generated workflows and affected isolated unit/contract suites.
Terraform, process integration tests, interruption and mutation run in authoritative Linux CI. -Full runs every CI step.
The local result is bound to HEAD, base SHA and working-tree content. Pester always runs through
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
    [string] $LogPath,
    [string] $TempRoot,
    [string] $StateRoot,
    [ValidateRange(0, 64)][int] $WorkerBudget = 0,
    [ValidateRange(1, 86400)][int] $QueueWaitSeconds = 900,
    [Parameter(DontShow)][switch] $WorkerProcess
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$repo = (Resolve-Path -LiteralPath (Join-Path $PSScriptRoot '..')).ProviderPath
$started = [Diagnostics.Stopwatch]::StartNew()
if (-not $LogPath) { $LogPath = Join-Path $repo "artifacts/local-ci/$(Get-Date -Format 'yyyyMMdd-HHmmss-fff')-$PID.log" }
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
Import-Module (Join-Path $PSScriptRoot 'LocalCiGate.psm1') -Force
Import-Module (Join-Path $PSScriptRoot 'LocalCiConcurrency.psm1') -Force
if (-not $StateRoot) { $StateRoot = Get-LocalCiMachineStateRoot }
if ($env:INVOKE_LOCAL_CI_ACTIVE -and -not $Plan) { Exit-Usage 'Another Invoke-LocalCi run is active in this process tree; nested runs are refused.' }
if ($IsWindows -and -not $Plan -and -not $WorkerProcess) {
    $forward = @{}
    foreach ($key in $PSBoundParameters.Keys) {
        $value = $PSBoundParameters[$key]
        $forward[$key] = if ($value -is [Management.Automation.SwitchParameter]) { [bool] $value } else { $value }
    }
    $forward.WorkerProcess = $true
    $forward.LogPath = $LogPath
    $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(($forward | ConvertTo-Json -Compress)))
    $command = "`$parameters = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String('$payload')) | ConvertFrom-Json -AsHashtable; & '$($PSCommandPath.Replace("'", "''"))' @parameters; exit `$LASTEXITCODE"
    & ([Environment]::ProcessPath) -NoProfile -NonInteractive -OutputFormat Text -EncodedCommand ([Convert]::ToBase64String([Text.Encoding]::Unicode.GetBytes($command)))
    exit $LASTEXITCODE
}
if ($IsWindows -and -not $Plan) {
    try { Initialize-LocalCiWorkerLifetime }
    catch { Exit-Usage $_.Exception.Message }
}
$worktreeLease = $null
$machineLease = $null
try {
if (-not $Plan) {
    try { $worktreeLease = Enter-LocalCiWorktreeLock -RepositoryRoot $repo }
    catch { Exit-Usage $_.Exception.Message }
    # A failed or abruptly interrupted rerun must never leave an earlier success usable.
    Clear-LocalCiGateResult -RepositoryRoot $repo
}
try { $startState = Get-LocalCiContentState -RepositoryRoot $repo -Base $Base }
catch { Exit-Usage "Invalid -Base '$Base' or unreadable source state: $($_.Exception.Message)" }
if (-not $Plan -and -not $startState.Clean) { Exit-Usage 'Commit all source changes before running the local gate.' }
$requirements = Import-PowerShellDataFile (Join-Path $PSScriptRoot 'requirements.psd1')
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1')
$moduleProbe = {
    param($module)
    try {
        $path = Get-ToolDependencyPath -Name $module
        (Import-PowerShellDataFile $path).ModuleVersion
    }
    catch { Write-Warning $_.Exception.Message }
}
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
if (-not $TempRoot -and $IsWindows) { $TempRoot = Join-Path ([Environment]::GetFolderPath('UserProfile')) '.dci' }
$temp = if ($TempRoot) { Get-LocalCiTempPath -RepoPath $repo -DataRoot $TempRoot } else { Get-LocalCiTempPath -RepoPath $repo }
# Selection
$changedFiles = @()
$newFiles = @()
# The gate is offline. Refresh remote refs explicitly before it, not during the measured run.
$mb = $startState.MergeBase
$behind = Invoke-Git @('rev-list', '--count', "$($startState.Head)..$($startState.BaseSha)")
if ($behind.ExitCode -eq 0 -and [int] $behind.Output[0] -gt 0) {
    Write-Console "WARN HEAD is $($behind.Output[0]) commit(s) behind $Base. The CI pull_request run tests the merge result; rebase to test the same code."
}
$fileArguments = @{ RepositoryRoot = $repo; MergeBase = $mb }
if (-not $Plan) { $fileArguments.Head = $startState.Head }
try { $files = Get-LocalCiChangedFile @fileArguments }
catch { Exit-Usage "git could not list the changed files: $($_.Exception.Message)" }
$changedFiles = $files.Changed
$newFiles = $files.Added

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

$testProfile = Get-LocalCiProfile -RepositoryRoot $repo -PesterPath $selection.PesterPath -AllPester:(
    $selection.AllPester -or @($changedFiles | Where-Object { $_ -in @(
        'tools/Invoke-LocalCi.ps1', 'tools/LocalCi.psm1', 'tools/LocalCiGate.psm1', 'tools/LocalCiConcurrency.psm1',
        'tools/test-profiles.psd1', 'tools/Test-PowerShell.ps1', 'tools/Test-LocalCiResult.ps1',
        '.githooks/pre-push', '.github/workflows/ci.yml'
    ) }).Count -gt 0)
$staticPaths = @($changedFiles | Where-Object {
    $_ -match '\.(ps1|psm1|psd1)$' -and (Test-Path -LiteralPath (Join-Path $repo $_) -PathType Leaf)
})
if ($mode -eq 'Changed') {
    $selection.AllPester = $false
    $selection.PesterPath = [string[]] $testProfile.Selected
    $selection.AllInterruption = $false
    $selection.InterruptionPath = [string[]] @()
    $selection.AllMutation = $false
    $selection.MutationCheck = [string[]] @()
    $selection.TerraformRoot = [string[]] @()
}
if (-not $Plan) {
    $selectedState = Get-LocalCiContentState -RepositoryRoot $repo -Base $Base
    foreach ($key in 'Head', 'BaseSha', 'MergeBase', 'Fingerprint') {
        if ($startState[$key] -cne $selectedState[$key]) { Exit-Usage "Source changed during test selection ($key); rerun the gate." }
    }
}

$runInterruption = $selection.AllInterruption -or $selection.InterruptionPath.Count -gt 0
$runMutation = $selection.AllMutation -or $selection.MutationCheck.Count -gt 0
$pesterLabel = if ($selection.AllPester) { 'all' } else { "$($selection.PesterPath.Count) file(s)" }
$interruptionLabel = if ($selection.AllInterruption) { 'all' } elseif ($runInterruption) { "$($selection.InterruptionPath.Count) file(s)" } else { 'none' }
$mutationLabel = if ($selection.AllMutation) { 'all' } elseif ($runMutation) { $selection.MutationCheck -join ', ' } else { 'none' }

$planLines = [System.Collections.Generic.List[string]]::new()
$planLines.Add("Mode: $mode; base $Base (merge base $mb); $($changedFiles.Count) changed file(s)")
$planLines.Add("Profile: $(if ($Full) { 'Full (all CI categories)' } else { 'Local (isolated unit and contract suites)' })")
foreach ($file in $changedFiles) { $planLines.Add("  changed: $file") }
foreach ($reason in $selection.Reason) { $planLines.Add("Full-profile mapping: $reason") }
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
if (-not $Full) {
    $planLines.Add("Remote-only this run: $($testProfile.Remote.Count) test file(s), all interruption shards, all mutations and all Terraform roots")
    foreach ($path in $testProfile.Remote) { $planLines.Add("  remote: $path") }
}
foreach ($line in $planLines) { Write-Console $line }
if ($Plan) { exit 0 }

# Environment
$savedEnvironment = @{}
# A nested or concurrent run would empty the per-worktree TEMP of the outer run.
if ($env:INVOKE_LOCAL_CI_ACTIVE) { Exit-Usage 'Another Invoke-LocalCi run is active in this process tree; nested runs are refused.' }
foreach ($name in 'TEMP', 'TMP', 'TMPDIR', 'TF_IN_AUTOMATION', 'INTERRUPTION_SHARD', 'PESTER_SHARD', 'INVOKE_LOCAL_CI_ACTIVE', 'LOCAL_CI_WORKER_BUDGET', 'PATH') {
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
    return Invoke-Native -FilePath ([Environment]::ProcessPath) -Arguments @('-NoProfile', '-NonInteractive', '-File', $path)
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
        $failedFiles = @(Get-PesterFailureDetail -Line $output.ToArray() | Where-Object { $_ -match '^\s+at ' })
        $failedNew = @($newFiles | Where-Object {
            $leaf = [IO.Path]::GetFileName($_)
            $_ -clike '*.Tests.ps1' -and @($failedFiles | Where-Object { $_ -match "[\\/]$([regex]::Escape($leaf)):\d+$" }).Count -gt 0
        })
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
    try { Assert-LocalCiWindowsTempRoot -Path $TempRoot -UserProfile ([Environment]::GetFolderPath('UserProfile')) -Windows $IsWindows }
    catch { Exit-Usage $_.Exception.Message }
    Assert-LocalCiTempPath -Path $temp
    if ($IsWindows) {
        Initialize-LocalCiPrivateTempDirectory -Path $TempRoot
        Initialize-LocalCiPrivateTempDirectory -Path (Split-Path -Path $temp -Parent)
        Initialize-LocalCiPrivateTempDirectory -Path $temp
    }
    # Acquire the machine turn before clearing or using the worktree's shared TEMP.
    $machineLease = Enter-LocalCiMachineQueue -StateRoot $StateRoot -WorkerBudget $WorkerBudget -WaitSeconds $QueueWaitSeconds
    Enable-LocalCiLeaseInheritance -Handle @($worktreeLease, $machineLease.Handle, $machineLease.TicketHandle)
    $env:LOCAL_CI_WORKER_BUDGET = [string] $machineLease.WorkerBudget
    Write-Console "Machine queue admitted; worker budget: $($machineLease.WorkerBudget)"
    # The default C:\Windows\TEMP allows creating files but denies deleting and enumerating them, so every run uses its own.
    Clear-LocalCiTemp -Path $temp
    foreach ($name in 'TEMP', 'TMP', 'TMPDIR') { [Environment]::SetEnvironmentVariable($name, $temp) }
    $env:TF_IN_AUTOMATION = 'true'
    Remove-Item Env:INTERRUPTION_SHARD -ErrorAction SilentlyContinue
    Remove-Item Env:PESTER_SHARD -ErrorAction SilentlyContinue

    # 1. Preflight
    $watch = [Diagnostics.Stopwatch]::StartNew()
    if ($mode -eq 'Full' -and $selection.TerraformRoot.Count -gt 0) {
        try {
            $terraformPackage = Get-ToolBinaryPackage -Name Terraform
            if (Test-Path -LiteralPath $terraformPackage.CachePath -PathType Leaf) {
                $terraformPath = Get-ToolBinaryPath -Name Terraform -DestinationPath (Join-Path $temp 'terraform-bin')
                $env:PATH = (Split-Path $terraformPath -Parent) + [IO.Path]::PathSeparator + $env:PATH
            }
            $null = Test-LocalCiRuntime -TempPath $temp
        }
        catch { Exit-Usage $_.Exception.Message }
    }
    try { $actionlintPath = Get-ToolBinaryPath -Name Actionlint -DestinationPath (Join-Path $temp 'actionlint-bin') }
    catch { Exit-Usage "$($_.Exception.Message) Run ./tools/Install-ToolDependencies.ps1 -Binary Actionlint." }
    $toolProbe = {
        param($tool)
        if ($tool -ne 'actionlint' -and -not (Get-Command $tool -CommandType Application -ErrorAction SilentlyContinue)) { return $null }
        $text = switch ($tool) {
            'terraform' { (& terraform version -json 2>$null | ConvertFrom-Json).terraform_version }
            'tflint' { (& tflint --version 2>$null | Select-Object -First 1) -replace '^TFLint version ', '' }
            'trivy' { (& trivy --version 2>$null | Where-Object { $_ -like 'Version:*' } | Select-Object -First 1) -replace '^Version:\s*', '' }
            'actionlint' { (& $actionlintPath -version 2>$null | Select-Object -First 1) }
        }
        return ([string] $text).Trim().TrimStart('v')
    }
    $problems = @(Get-LocalCiPreflightProblem -PowerShellVersion $PSVersionTable.PSVersion -Requirements $requirements -Setting $setting `
        -NeedsTerraformTools:($selection.TerraformRoot.Count -gt 0) -SkipTerraform:($mode -eq 'Changed') -ModuleProbe $moduleProbe -ToolProbe $toolProbe)
    foreach ($problem in $problems) { Write-Console "$(if ($problem.Severity -eq 'Error') { 'ERROR' } else { 'WARN' }) $($problem.Message)" }
    if (@($problems | Where-Object Severity -eq 'Error').Count -gt 0) {
        Add-Result -Name 'Preflight' -Status 'FAIL' -Seconds $watch.Elapsed.TotalSeconds
        Write-Console "Log: $LogPath"
        exit 2
    }
    Add-Result -Name 'Preflight' -Status 'PASS' -Seconds $watch.Elapsed.TotalSeconds

    # 2.-5. pwsh steps, in full and unchanged from ci.yml
    foreach ($name in 'Check PowerShell', 'Validate module manifests', 'Validate instance examples', 'Check generated workflows') {
        $stepScript = $setting.PwshSteps[$name]
        if ($name -eq 'Check PowerShell' -and $mode -eq 'Changed') {
            if ($staticPaths.Count -eq 0) { Skip-Step -Name $name -Reason 'no changed PowerShell file'; continue }
            $stepScript = "./tools/Test-PowerShell.ps1 -Path $(ConvertTo-PwshList $staticPaths)"
        }
        Invoke-Step -Name $name -Body { Invoke-PwshScript -Script $stepScript }
    }

    # 6.-7. actionlint
    Invoke-Step -Name 'Validate deployment workflow syntax' -Body {
        Invoke-Native -FilePath $actionlintPath -Arguments $setting.ActionlintArguments
    }
    Invoke-Step -Name 'Validate instance workflows that call local reusable workflows' -Body {
        $project = Join-Path $temp "actionlint-$([guid]::NewGuid().ToString('N'))"
        $workflows = Join-Path $project '.github/workflows'
        $null = New-Item -ItemType Directory -Force -Path $workflows
        foreach ($file in $setting.InstanceWorkflowFiles) { Copy-Item -LiteralPath (Join-Path $repo $file) -Destination $workflows }
        Invoke-Native -FilePath 'git' -Arguments @('init', '-q', $project)
        Invoke-Native -FilePath $actionlintPath -Arguments $setting.InstanceActionlintArguments -WorkingDirectory $project
    }

    # 8. Terraform
    Invoke-Step -Name 'Discover Terraform roots' -Body {
        Invoke-PwshScript -Script "./tools/Get-TerraformRoots.ps1 -GitHubOutputPath $(ConvertTo-PwshList (Join-Path $temp 'github-output.txt'))"
    }
    if ($selection.TerraformRoot.Count -eq 0) {
        Skip-Step -Name 'Terraform' -Reason $(if ($Full) { 'no root selected' } else { 'remote-only in the Local profile' })
    }
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
    else {
        Skip-Step -Name 'Interrupt every state-changing step' -Reason $(if ($Full) { 'no test file mapped' } else { 'remote-only in the Local profile' })
    }

    # 11. Mutation tests
    if ($runMutation) {
        $mutationScript = './tools/Invoke-MutationTests.ps1 -ReportPath ./artifacts/mutation-report.json'
        if (-not $selection.AllMutation) { $mutationScript += " -Check $(ConvertTo-PwshList $selection.MutationCheck)" }
        Invoke-Step -Name 'Weaken every marked security check' -Body { Invoke-PwshScript -Script $mutationScript }
    }
    else {
        Skip-Step -Name 'Weaken every marked security check' -Reason $(if ($Full) { 'no marked check changed' } else { 'remote-only in the Local profile' })
    }
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
    Write-Console 'Not covered locally: process integration suites, unselected isolated suites, all Terraform roots, interruption and mutation. Linux CI must pass on the PR head before merge.'
}
if (-not $failed) {
    $endState = Get-LocalCiContentState -RepositoryRoot $repo -Base $Base
    foreach ($key in 'Head', 'BaseSha', 'MergeBase', 'Fingerprint') {
        if ($endState[$key] -cne $startState[$key]) { throw "Local gate result is stale: $key changed during the run." }
    }
    Save-LocalCiGateResult -RepositoryRoot $repo -State $startState -GateProfile $(if ($Full) { 'Full' } else { 'Local' })
    Write-Console "Selected local gate passed (vybran`u{fd} lok`u{e1}ln`u{ed} gate pro`u{161}el); HEAD $($startState.Head); base $($startState.BaseSha); fingerprint $($startState.Fingerprint)"
}
exit $(if ($failed) { 1 } else { 0 })
}
finally {
    try { if ($null -ne $machineLease) { Exit-LocalCiMachineQueue -Lease $machineLease } }
    finally { if ($null -ne $worktreeLease) { $worktreeLease.Dispose() } }
}
