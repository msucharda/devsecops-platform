#Requires -Version 7.4
<#
.SYNOPSIS
Measures documentation, small-change and isolated-profile fan-out gates on a fixed revision.
.DESCRIPTION
Creates disposable detached worktrees below artifacts, commits one harmless scenario change in each,
and runs the revision's unchanged gate repeatedly. Source checkout files and HEAD are never changed.
Dependencies must already be restored in the source checkout; each gate verifies the copied cache.
#>
[CmdletBinding()]
param(
    [string] $RepositoryRoot = (Join-Path $PSScriptRoot '..'),
    [string] $Revision = 'origin/main',
    [ValidateRange(1, 100)][int] $Repeat = 3,
    [Alias('Scenario')][ValidateSet('Documentation', 'Small change', 'Fan-out')]
    [string[]] $ScenarioName = @('Documentation', 'Small change', 'Fan-out'),
    [string] $OutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$RepositoryRoot = (Resolve-Path -LiteralPath $RepositoryRoot).ProviderPath
if (-not $OutputPath) {
    $OutputPath = Join-Path $RepositoryRoot "artifacts/local-ci/benchmark-$(Get-Date -Format 'yyyyMMdd-HHmmss')-$PID.json"
}
$OutputPath = $ExecutionContext.SessionState.Path.GetUnresolvedProviderPathFromPSPath($OutputPath)
$null = & git -C $RepositoryRoot --literal-pathspecs ls-files --error-unmatch -- $OutputPath 2>$null
if ($LASTEXITCODE -eq 0) { throw "Benchmark report path is tracked: '$OutputPath'." }
if ($LASTEXITCODE -ne 1) { throw "Cannot validate benchmark report path '$OutputPath' inside the source checkout." }
$artifactRoot = [IO.Path]::GetFullPath((Join-Path $RepositoryRoot 'artifacts')) + [IO.Path]::DirectorySeparatorChar
$comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
if (-not $OutputPath.StartsWith($artifactRoot, $comparison)) { throw 'Benchmark report path must be below artifacts in the source checkout.' }
$runRoot = Join-Path $RepositoryRoot "artifacts/local-ci/b-$([guid]::NewGuid().ToString('N').Substring(0, 8))"
$null = New-Item -ItemType Directory -Force -Path $runRoot, (Split-Path $OutputPath -Parent)

function Invoke-BenchmarkGit {
    [CmdletBinding()]
    param([string[]] $ArgumentList, [string] $WorkingDirectory = $RepositoryRoot)

    $output = @(& git -C $WorkingDirectory @ArgumentList 2>&1)
    if ($LASTEXITCODE -ne 0) { throw "git $($ArgumentList -join ' ') failed: $($output -join "`n")" }
    return ($output -join "`n")
}

$revisionSha = Invoke-BenchmarkGit -ArgumentList @('rev-parse', '--verify', "$Revision^{commit}")
$scenarios = @(
    @{ Name = 'Documentation'; Path = 'README.md'; Comment = '<!-- Local CI benchmark -->' }
    @{ Name = 'Small change'; Path = 'tools/Select-InstanceModules.ps1'; Comment = '# Local CI benchmark' }
    @{ Name = 'Fan-out'; Path = 'tools/Invoke-Tests.ps1'; Comment = '# Local CI benchmark' }
)
$scenarios = @($scenarios | Where-Object { $_.Name -in $ScenarioName })
$report = [ordered]@{
    Schema = 1
    Revision = $revisionSha
    RevisionRef = $Revision
    StartedAt = [datetimeoffset]::UtcNow.ToString('o')
    Platform = [Runtime.InteropServices.RuntimeInformation]::OSDescription
    PowerShell = $PSVersionTable.PSVersion.ToString()
    Repeat = $Repeat
    Status = 'running'
    Scenarios = [Collections.Generic.List[object]]::new()
}

function Save-BenchmarkReport {
    $report | ConvertTo-Json -Depth 8 | Set-Content -LiteralPath $OutputPath -Encoding utf8NoBOM
}

Save-BenchmarkReport
try {
    for ($index = 0; $index -lt $scenarios.Count; $index++) {
        $definition = $scenarios[$index]
        $worktree = Join-Path $runRoot "w$index"
        $created = $false
        $scenario = [ordered]@{
            Name = $definition.Name
            ChangedFile = $definition.Path
            Samples = [Collections.Generic.List[object]]::new()
            MedianSeconds = $null
        }
        $report.Scenarios.Add($scenario)
        try {
            $null = Invoke-BenchmarkGit -ArgumentList @('worktree', 'add', '--quiet', '--detach', $worktree, $revisionSha)
            $created = $true
            $changedPath = Join-Path $worktree $definition.Path
            if (-not (Test-Path -LiteralPath $changedPath -PathType Leaf)) {
                throw "Revision $revisionSha does not contain benchmark input '$($definition.Path)'."
            }
            [IO.File]::AppendAllText($changedPath, "`n$($definition.Comment)`n", [Text.UTF8Encoding]::new($false))
            $null = Invoke-BenchmarkGit -WorkingDirectory $worktree -ArgumentList @('add', '--', $definition.Path)
            $null = Invoke-BenchmarkGit -WorkingDirectory $worktree -ArgumentList @(
                '-c', 'user.name=Local CI benchmark', '-c', 'user.email=local-ci@example.invalid',
                '-c', 'commit.gpgsign=false', '-c', 'core.hooksPath=',
                'commit', '--quiet', '-m', "Benchmark: $($definition.Name)"
            )
            $dependencies = Join-Path $RepositoryRoot 'tools/.dependencies'
            if (Test-Path -LiteralPath $dependencies -PathType Container) {
                Copy-Item -LiteralPath $dependencies -Destination (Join-Path $worktree 'tools/.dependencies') -Recurse
            }
            for ($iteration = 1; $iteration -le $Repeat; $iteration++) {
                $log = Join-Path $runRoot "$index-$iteration.log"
                $watch = [Diagnostics.Stopwatch]::StartNew()
                & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $worktree 'tools/Invoke-LocalCi.ps1') `
                    -Base $revisionSha -LogPath $log *> (Join-Path $runRoot "$index-$iteration.console.log")
                $code = $LASTEXITCODE
                $watch.Stop()
                $scenario.Samples.Add([ordered]@{
                    Iteration = $iteration
                    Seconds = $watch.Elapsed.TotalSeconds
                    ExitCode = $code
                    LogPath = $log
                })
                Save-BenchmarkReport
                Write-Information ('{0} {1}/{2}: {3:F3}s (exit {4})' -f $definition.Name, $iteration, $Repeat, $watch.Elapsed.TotalSeconds, $code) -InformationAction Continue
                if ($code -ne 0) { throw "Benchmark gate failed; inspect '$log'. No successful baseline is reported." }
            }
            $sorted = @($scenario.Samples.Seconds | Sort-Object)
            $middle = [int] [Math]::Floor($sorted.Count / 2)
            $scenario.MedianSeconds = if ($sorted.Count % 2) { $sorted[$middle] } else { ($sorted[$middle - 1] + $sorted[$middle]) / 2 }
            Write-Information ('MEDIAN {0}: {1:F3}s ({2} runs)' -f $definition.Name, $scenario.MedianSeconds, $Repeat) -InformationAction Continue
            Save-BenchmarkReport
        }
        finally {
            if ($created) { $null = Invoke-BenchmarkGit -ArgumentList @('worktree', 'remove', '--force', $worktree) }
        }
    }
    $report.Status = 'passed'
}
catch {
    $report.Status = 'failed'
    throw
}
finally {
    Save-BenchmarkReport
    Write-Information "Benchmark: $OutputPath; revision $revisionSha" -InformationAction Continue
}
