Set-StrictMode -Version Latest

# Terraform job commands from .github/workflows/ci.yml, per step name. LocalCi.Tests.ps1 compares them with ci.yml,
# so a change in ci.yml fails the tests until this list follows it. {root} is the Terraform root.
$script:TerraformStepCommands = [ordered]@{
    'Terraform format' = @(, @('terraform', '-chdir={root}', 'fmt', '-check', '-diff'))
    'Terraform validate' = @(
        @('terraform', '-chdir={root}', 'init', '-backend=false', '-input=false'),
        @('terraform', '-chdir={root}', 'validate'))
    'Terraform test' = @(, @('terraform', '-chdir={root}', 'test'))
    'TFLint' = @(
        @('tflint', '--chdir={root}', '--init'),
        @('tflint', '--chdir={root}'))
    'Trivy' = @(, @('trivy', 'config', '--exit-code', '1', '--severity', 'HIGH,CRITICAL', '{root}'))
}

$script:PesterEscalationFiles = @('tools/Invoke-Tests.ps1', 'tools/requirements.psd1')
$script:MutationEngineFiles = @(
    'tools/tests/security-checks.psd1',
    'tools/MutationTesting.psm1',
    'tools/Invoke-MutationTests.ps1',
    'tools/tests/Invoke-MutationWorker.ps1')

function Get-LocalCiTerraformStepCommand {
    <#
    .SYNOPSIS
    Returns the Terraform job commands that Invoke-LocalCi runs for one root, per ci.yml step name.
    #>
    [CmdletBinding()]
    [OutputType([System.Collections.Specialized.OrderedDictionary])]
    param([Parameter(Mandatory)][string] $Root)

    $result = [ordered]@{}
    foreach ($name in $script:TerraformStepCommands.Keys) {
        $result[$name] = @(foreach ($command in $script:TerraformStepCommands[$name]) {
            , @($command | ForEach-Object { $_.Replace('{root}', $Root) })
        })
    }
    return $result
}

function Get-CiWorkflowStep {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Workflow,
        [Parameter(Mandatory)][string] $Job,
        [Parameter(Mandatory)][string] $Name
    )

    $steps = @($Workflow['jobs'][$Job]['steps'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['name'] -ceq $Name })
    if ($steps.Count -ne 1) { throw "ci.yml job '$Job' must contain exactly one step '$Name'; found $($steps.Count). Update tools/LocalCi.psm1." }
    return $steps[0]
}

function Get-CiActionInput {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Workflow,
        [Parameter(Mandatory)][string] $Job,
        [Parameter(Mandatory)][string] $Action,
        [Parameter(Mandatory)][string] $InputName
    )

    $steps = @($Workflow['jobs'][$Job]['steps'] | Where-Object {
        $_ -is [System.Collections.IDictionary] -and $_['uses'] -is [string] -and $_['uses'].StartsWith("$Action@", [StringComparison]::Ordinal)
    })
    if ($steps.Count -ne 1 -or $steps[0]['with'] -isnot [System.Collections.IDictionary] -or
        [string]::IsNullOrWhiteSpace([string] $steps[0]['with'][$InputName])) {
        throw "ci.yml job '$Job' must use '$Action' once with input '$InputName'. Update tools/LocalCi.psm1."
    }
    return [string] $steps[0]['with'][$InputName]
}

function ConvertFrom-ActionlintCommand {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Line)

    if ($Line.Trim() -cnotmatch '^go run github\.com/rhysd/actionlint/cmd/actionlint@v(?<version>[0-9.]+)(?<arguments>( [A-Za-z0-9_./=-]+)+)$') {
        throw "ci.yml actionlint command has an unexpected form: '$Line'. Update tools/LocalCi.psm1."
    }
    return [pscustomobject]@{
        Version = $Matches['version']
        Arguments = [string[]] @($Matches['arguments'].Trim().Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    }
}

function Get-CiWorkflowSetting {
    <#
    .SYNOPSIS
    Reads the commands, tool pins and actionlint invocations that Invoke-LocalCi mirrors from ci.yml.
    .DESCRIPTION
    Every value comes from ci.yml so local runs cannot drift from CI. An unexpected ci.yml shape throws.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $WorkflowPath)

    Import-Module powershell-yaml -ErrorAction Stop
    $workflow = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $WorkflowPath -Raw) -Ordered
    $pwshSteps = [ordered]@{}
    foreach ($name in 'Check PowerShell', 'Validate module manifests', 'Validate instance examples', 'Check generated workflows') {
        $step = Get-CiWorkflowStep -Workflow $workflow -Job platform -Name $name
        if ($step['shell'] -cne 'pwsh' -or [string]::IsNullOrWhiteSpace($step['run'])) {
            throw "ci.yml step '$name' must be a pwsh run step. Update tools/LocalCi.psm1."
        }
        $pwshSteps[$name] = [string] $step['run']
    }

    $syntax = Get-CiWorkflowStep -Workflow $workflow -Job platform -Name 'Validate deployment workflow syntax'
    $syntaxLines = @(([string] $syntax['run']).Split("`n") | Where-Object { $_.Trim() })
    if ($syntaxLines.Count -ne 1) { throw "ci.yml step 'Validate deployment workflow syntax' must run one command. Update tools/LocalCi.psm1." }
    $actionlint = ConvertFrom-ActionlintCommand -Line $syntaxLines[0]

    $instance = Get-CiWorkflowStep -Workflow $workflow -Job platform -Name 'Validate instance workflows that call local reusable workflows'
    $instanceLines = @(([string] $instance['run']).Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ })
    $copy = @($instanceLines | Where-Object { $_ -cmatch '^cp (?<files>.+) "\$project/\.github/workflows/"$' })
    $lint = @($instanceLines | Where-Object { $_.StartsWith('go run ', [StringComparison]::Ordinal) })
    if ($copy.Count -ne 1 -or $lint.Count -ne 1) {
        throw "ci.yml step 'Validate instance workflows that call local reusable workflows' has an unexpected form. Update tools/LocalCi.psm1."
    }
    $null = $copy[0] -cmatch '^cp (?<files>.+) "\$project/\.github/workflows/"$'
    $instanceFiles = [string[]] @($Matches['files'].Split(' ', [StringSplitOptions]::RemoveEmptyEntries))
    $instanceLint = ConvertFrom-ActionlintCommand -Line $lint[0]
    if ($instanceLint.Version -cne $actionlint.Version) { throw 'ci.yml uses two actionlint versions. Update tools/LocalCi.psm1.' }

    $terraformCommands = [ordered]@{}
    foreach ($name in $script:TerraformStepCommands.Keys) {
        $step = Get-CiWorkflowStep -Workflow $workflow -Job terraform -Name $name
        $terraformCommands[$name] = [string] $step['run']
    }

    return [pscustomobject]@{
        PwshSteps = $pwshSteps
        ActionlintVersion = $actionlint.Version
        ActionlintArguments = $actionlint.Arguments
        InstanceWorkflowFiles = $instanceFiles
        InstanceActionlintArguments = $instanceLint.Arguments
        TerraformVersion = Get-CiActionInput -Workflow $workflow -Job terraform -Action 'hashicorp/setup-terraform' -InputName terraform_version
        PlatformTerraformVersion = Get-CiActionInput -Workflow $workflow -Job platform -Action 'hashicorp/setup-terraform' -InputName terraform_version
        TflintVersion = (Get-CiActionInput -Workflow $workflow -Job terraform -Action 'terraform-linters/setup-tflint' -InputName tflint_version).TrimStart('v')
        TrivyVersion = (Get-CiActionInput -Workflow $workflow -Job terraform -Action 'aquasecurity/setup-trivy' -InputName version).TrimStart('v')
        TerraformRunCommands = $terraformCommands
        TerraformFingerprint = ConvertTo-Json -Compress -Depth 20 -InputObject @(
            $workflow['jobs']['terraform'],
            @($workflow['jobs']['platform']['steps'] | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['uses'] -is [string] -and $_['uses'].StartsWith('hashicorp/setup-terraform@', [StringComparison]::Ordinal) }))
    }
}

function Test-TextContainsToken {
    [CmdletBinding()]
    [OutputType([bool])]
    param([Parameter(Mandatory)][AllowEmptyString()][string] $Text, [Parameter(Mandatory)][string] $Token)

    return [regex]::IsMatch($Text, '(?<![A-Za-z0-9_.-])' + [regex]::Escape($Token) + '(?![A-Za-z0-9_/-]|\.[A-Za-z0-9_-])')
}

function Get-LocalCiSelection {
    <#
    .SYNOPSIS
    Maps changed files to the Pester files, interruption files, mutation checks and Terraform roots that -Changed runs.
    .PARAMETER ChangedFile
    Repository-relative paths with forward slashes, including deleted files.
    .PARAMETER TerraformRoot
    Repository-relative Terraform roots from Get-TerraformRoots.ps1.
    .PARAMETER AllTerraformRoots
    Set when ci.yml changed the Terraform steps or tool pins.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ChangedFile,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $TerraformRoot,
        [switch] $AllTerraformRoots
    )

    $testRoot = Join-Path $RepoPath 'tools/tests'
    $tests = @(Get-ChildItem -LiteralPath $testRoot -Recurse -File -Filter '*.Tests.ps1' | ForEach-Object {
        [pscustomobject]@{
            Path = [IO.Path]::GetRelativePath($RepoPath, $_.FullName).Replace('\', '/')
            Text = Get-Content -LiteralPath $_.FullName -Raw
        }
    })
    $selected = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $warnings = [System.Collections.Generic.List[string]]::new()
    $reasons = [System.Collections.Generic.List[string]]::new()
    $escalatePester = $false
    $allMutation = $false
    $checks = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)
    $roots = [System.Collections.Generic.SortedSet[string]]::new([StringComparer]::Ordinal)

    foreach ($file in $ChangedFile) {
        $fullPath = Join-Path $RepoPath $file
        $exists = Test-Path -LiteralPath $fullPath -PathType Leaf
        $leaf = [IO.Path]::GetFileName($file)
        $mapped = [System.Collections.Generic.List[string]]::new()

        if ($file -cin $script:PesterEscalationFiles) {
            $escalatePester = $true
            $reasons.Add("$file changed: every Pester and interruption test runs.")
        }
        if ($file -cin $script:MutationEngineFiles) {
            $allMutation = $true
            $reasons.Add("$file changed: every security check is mutated.")
        }
        if ($file -clike 'tools/tests/*.Tests.ps1' -and $exists) { $mapped.Add($file) }
        if ($file -clike '*.ps1' -or $file -clike '*.psm1') {
            foreach ($test in $tests) {
                if ($test.Path -cne $file -and (Test-TextContainsToken -Text $test.Text -Token $leaf)) { $mapped.Add($test.Path) }
            }
            if ($exists -and (Get-Content -LiteralPath $fullPath -Raw) -cmatch '(?m)^\s*# security-check: ') {
                foreach ($match in [regex]::Matches((Get-Content -LiteralPath $fullPath -Raw), '(?m)^\s*# security-check: (?<name>[a-z0-9-]+)\s*$')) {
                    $null = $checks.Add($match.Groups['name'].Value)
                }
            }
        }
        if ($file -cmatch '^modules/(?<module>[^/]+)/') {
            $module = $Matches['module']
            foreach ($test in $tests) {
                if ($test.Text.Contains("modules/$module/", [StringComparison]::Ordinal) -or
                    $test.Text.Contains("modules/$module'", [StringComparison]::Ordinal) -or
                    ($file -ceq "modules/$module/module.yaml" -and $test.Text.Contains("$module/module.yaml", [StringComparison]::Ordinal))) {
                    $mapped.Add($test.Path)
                }
            }
        }
        if ($file -cmatch '^tools/tests/fixtures/(?<top>[^/]+)(?<rest>/.*)?$') {
            $top = $Matches['top']
            $apiFixture = [regex]::Match($file, '^tools/tests/fixtures/(github|microsoft)-api/(?<name>[^/]+/[^/]+)\.json$')
            foreach ($test in $tests) {
                # The contract test of every API fixture refers to the fixture directory, not to the fixture name.
                if ($apiFixture.Success) {
                    if ((Test-TextContainsToken -Text $test.Text -Token $apiFixture.Groups['name'].Value) -or
                        $test.Text.Contains("fixtures/$top", [StringComparison]::Ordinal)) {
                        $mapped.Add($test.Path)
                    }
                }
                elseif ($test.Text.Contains("fixtures/$top", [StringComparison]::Ordinal)) { $mapped.Add($test.Path) }
            }
        }
        foreach ($path in $mapped) { $null = $selected.Add($path) }
        if (($file -clike '*.ps1' -or $file -clike '*.psm1' -or $file -clike '*.psd1') -and $mapped.Count -eq 0 -and
            $file -cnotin $script:PesterEscalationFiles) {
            $warnings.Add("$file maps to no Pester test.")
        }

        $deepest = $null
        foreach ($root in $TerraformRoot) {
            if ($root -ceq '.' -or $file.StartsWith("$root/", [StringComparison]::Ordinal)) {
                if ($null -eq $deepest -or $root.Length -gt $deepest.Length) { $deepest = $root }
            }
        }
        if ($null -ne $deepest) { $null = $roots.Add($deepest) }
    }

    if ($AllTerraformRoots) {
        $reasons.Add('ci.yml changed the Terraform steps or tool pins: every Terraform root runs.')
        foreach ($root in $TerraformRoot) { $null = $roots.Add($root) }
    }

    $pester = @($selected | Where-Object { $_ -cnotlike '*.Interruption.Tests.ps1' })
    $interruption = @($selected | Where-Object { $_ -clike '*.Interruption.Tests.ps1' })
    return [pscustomobject]@{
        AllPester = $escalatePester
        PesterPath = [string[]] @(if ($escalatePester) { @() } else { $pester })
        AllInterruption = $escalatePester
        InterruptionPath = [string[]] @(if ($escalatePester) { @() } else { $interruption })
        AllMutation = $allMutation
        MutationCheck = [string[]] @(if ($allMutation) { @() } else { @($checks) })
        TerraformRoot = [string[]] @($roots)
        Warning = [string[]] $warnings.ToArray()
        Reason = [string[]] $reasons.ToArray()
    }
}

function Get-LocalCiModuleProblem {
    <#
    .SYNOPSIS
    Returns one message per module from tools/requirements.psd1 that is not available in the exact version.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Requirements,
        [Parameter(Mandatory)][scriptblock] $ModuleProbe
    )

    foreach ($group in 'Runtime', 'Development') {
        if (-not $Requirements.Contains($group)) { continue }
        foreach ($name in @($Requirements[$group].Keys | Sort-Object)) {
            $wanted = [string] $Requirements[$group][$name]
            $available = @(& $ModuleProbe $name | ForEach-Object { [string] $_ })
            if ($wanted -cnotin $available) {
                "Module $name $wanted is missing (found: $(if ($available) { $available -join ', ' } else { 'none' })). Run ./tools/Install-ToolDependencies.ps1 -Development"
            }
        }
    }
}

function Clear-LocalCiTemp {
    <#
    .SYNOPSIS
    Creates the per-worktree temp directory and removes everything an earlier, possibly interrupted, run left in it.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if (Test-Path -LiteralPath $Path) { Get-ChildItem -LiteralPath $Path -Force | Remove-Item -Recurse -Force }
    $null = New-Item -ItemType Directory -Force -Path $Path
    if (@(Get-ChildItem -LiteralPath $Path -Force).Count -gt 0) { throw "The temp directory $Path could not be emptied." }
}

function Get-LocalCiPreflightProblem {
    <#
    .SYNOPSIS
    Returns the errors and warnings of the local CI preflight. Any error stops Invoke-LocalCi with exit code 2.
    .PARAMETER ModuleProbe
    Returns the available versions of a module name.
    .PARAMETER ToolProbe
    Returns the version of a tool name, or $null when the tool is missing.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][version] $PowerShellVersion,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Requirements,
        [Parameter(Mandatory)][object] $Setting,
        [switch] $NeedsTerraformTools,
        [Parameter(Mandatory)][scriptblock] $ModuleProbe,
        [Parameter(Mandatory)][scriptblock] $ToolProbe
    )

    $problems = [System.Collections.Generic.List[object]]::new()
    $fail = { param($message) $problems.Add([pscustomobject]@{ Severity = 'Error'; Message = $message }) }
    $warn = { param($message) $problems.Add([pscustomobject]@{ Severity = 'Warning'; Message = $message }) }

    if ($PowerShellVersion -lt [version] '7.4') { & $fail "PowerShell $PowerShellVersion is too old; install PowerShell 7.4 or newer." }
    foreach ($message in @(Get-LocalCiModuleProblem -Requirements $Requirements -ModuleProbe $ModuleProbe)) { & $fail $message }

    $terraform = & $ToolProbe 'terraform'
    if ([string]::IsNullOrWhiteSpace($terraform)) {
        & $fail "terraform is missing; Pester tests run Terraform. Install Terraform $($Setting.TerraformVersion): winget install Hashicorp.Terraform or https://releases.hashicorp.com/terraform/$($Setting.TerraformVersion)/"
    }
    elseif ($terraform -cne $Setting.TerraformVersion) { & $warn "terraform $terraform differs from CI $($Setting.TerraformVersion)." }

    if ($NeedsTerraformTools) {
        $tflint = & $ToolProbe 'tflint'
        if ([string]::IsNullOrWhiteSpace($tflint)) {
            & $fail "tflint is missing. Install TFLint $($Setting.TflintVersion): https://github.com/terraform-linters/tflint/releases/tag/v$($Setting.TflintVersion)"
        }
        elseif ($tflint -cne $Setting.TflintVersion) {
            & $fail "tflint $tflint differs from CI $($Setting.TflintVersion); its bundled rule set decides findings. Install https://github.com/terraform-linters/tflint/releases/tag/v$($Setting.TflintVersion)"
        }
        $trivy = & $ToolProbe 'trivy'
        if ([string]::IsNullOrWhiteSpace($trivy)) {
            & $fail "trivy is missing. Install Trivy $($Setting.TrivyVersion): winget install AquaSecurity.Trivy or https://github.com/aquasecurity/trivy/releases/tag/v$($Setting.TrivyVersion)"
        }
        elseif ($trivy -cne $Setting.TrivyVersion) { & $warn "trivy $trivy differs from CI $($Setting.TrivyVersion)." }
    }

    $actionlint = & $ToolProbe 'actionlint'
    $go = & $ToolProbe 'go'
    if ($actionlint -cne $Setting.ActionlintVersion -and [string]::IsNullOrWhiteSpace($go)) {
        $version = $Setting.ActionlintVersion
        $found = if ([string]::IsNullOrWhiteSpace($actionlint)) { 'missing' } else { "version $actionlint" }
        & $fail ("actionlint $version is $found and go is missing. Download " +
            "https://github.com/rhysd/actionlint/releases/download/v$version/actionlint_$($version)_<os>_<arch>.<tar.gz|zip>, " +
            "check its SHA-256 against https://github.com/rhysd/actionlint/releases/download/v$version/actionlint_$($version)_checksums.txt " +
            '(Get-FileHash -Algorithm SHA256) and put actionlint on PATH.')
    }
    return $problems.ToArray()
}

function Get-PesterFailureDetail {
    <#
    .SYNOPSIS
    Extracts failed test names, their first error line and file:line from detailed Pester output.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Line)

    $Line = @($Line | ForEach-Object { $_ -replace '\x1b\[[0-9;]*[A-Za-z]', '' })
    for ($index = 0; $index -lt $Line.Count; $index++) {
        if ($Line[$index] -notmatch '^\s*\[-\] ') { continue }
        $Line[$index].Trim()
        $message = $null
        $location = $null
        for ($next = $index + 1; $next -lt $Line.Count -and $Line[$next] -notmatch '^\s*\[[-+!?]\] |^(Describing|Context) '; $next++) {
            if ($null -eq $location -and $Line[$next] -match '(?<location>[^\s,]+\.ps1:\d+)') { $location = $Matches['location'] }
            elseif ($null -eq $message -and $Line[$next].Trim() -and $Line[$next] -notmatch '^\s*\d+(\.\d+)?m?s \(' -and
                $Line[$next] -notmatch '^\s*at ') {
                $message = $Line[$next].Trim()
            }
        }
        if ($location) { "    at $location" }
        if ($message) { "    $message" }
    }
}

function Get-PesterCount {
    <#
    .SYNOPSIS
    Reads the passed, failed and not-run counts from the Pester summary line.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $Line)

    $Line = @($Line | ForEach-Object { $_ -replace '\x1b\[[0-9;]*[A-Za-z]', '' })
    $summary = @($Line | Where-Object { $_ -match 'Tests Passed: \d+, Failed: \d+, Skipped: \d+' } | Select-Object -Last 1)
    if ($summary.Count -eq 0) { return $null }
    $null = $summary[0] -match 'Tests Passed: (?<passed>\d+), Failed: (?<failed>\d+), Skipped: (?<skipped>\d+)'
    $passed = [int] $Matches['passed']
    $failed = [int] $Matches['failed']
    $notRun = if ($summary[0] -match 'NotRun: (?<notrun>\d+)') { [int] $Matches['notrun'] } else { 0 }
    return [pscustomobject]@{ Passed = $passed; Failed = $failed; NotRun = $notRun }
}

Export-ModuleMember -Function Get-CiWorkflowSetting, Get-LocalCiSelection, Get-LocalCiPreflightProblem, Get-LocalCiModuleProblem, Clear-LocalCiTemp,
    Get-LocalCiTerraformStepCommand, Get-PesterFailureDetail, Get-PesterCount
