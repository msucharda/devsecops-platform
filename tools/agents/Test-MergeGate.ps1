#Requires -Version 7.4
<#
.SYNOPSIS
Evaluates whether an agent may merge a pull request. Read-only: the script never changes GitHub state.

.DESCRIPTION
Runs the checks G1-G11 of the merge gate (issue #85) and writes one JSON object to stdout. Diagnostics go to stderr.
Exit codes: 0 pass, 1 fail, 2 pending, 3 already-merged, 4 invalid input, 5 evaluation error (the JSON then has verdict fail).

The coordinator extracts tools/ from origin/main into a trusted temporary directory, preserving the layout:
  git archive origin/main tools | tar -xf - -C <trusted-directory>
Run <trusted-directory>/tools/agents/Test-MergeGate.ps1 there. G10 uses the bundled, hash-verified YAML parser;
copying only the gate scripts omits that runtime. Never load dependencies from the pull request branch.

.EXAMPLE
./tools/agents/Test-MergeGate.ps1 -Repository msucharda/devsecops-platform -Pr 85 -ExpectedHeadSha <sha>

.EXAMPLE
./tools/agents/Test-MergeGate.ps1 -Repository example.ghe.com/example-platform/instance -Pr 8 -ExpectMerged
#>
[CmdletBinding()]
param(
    # 'owner/repo' or 'host/owner/repo' (GHE.com).
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][int] $Pr,
    # The head SHA the caller expects; another head fails with head-moved.
    [string] $ExpectedHeadSha,
    # The head SHA for which a human approved sensitive .github workflow changes.
    [string] $AcknowledgeWorkflowChanges,
    # Verifies a reported merge: already-merged exits 3, anything else fails with not-merged.
    [switch] $ExpectMerged,
    [int] $CopilotRoundCap = 2,
    [bool] $RequireCopilotReview = $true,
    [switch] $RequireCopilotOnHead,
    [switch] $RequireUpToDate,
    [string[]] $ExpectedWorkflows = @('Source CI'),
    [int] $MissingCheckGraceMinutes = 15,
    [int] $CopilotPostGraceMinutes = 45,
    # Test seam; the default is the current UTC time.
    [datetime] $Now
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MergeGate.psm1') -Force

$parameters = @{} + $PSBoundParameters
$result = Invoke-MergeGate @parameters
foreach ($reason in @($result.reasons)) { [Console]::Error.WriteLine("$($reason.status) $($reason.check)/$($reason.code): $($reason.message)") }
Write-Output (ConvertTo-MergeGateJson -Result $result)
exit $result.exitCode
