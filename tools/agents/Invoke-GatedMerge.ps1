#Requires -Version 7.4
<#
.SYNOPSIS
Merges a pull request only after a fresh pass of the merge gate, as a squash merge pinned to the evaluated head.

.DESCRIPTION
1. Evaluates the merge gate again; an earlier result is never reused.
2. already-merged exits 3, fail exits 1, pending waits up to WaitPendingMinutes and then exits 2.
3. pass runs 'gh pr merge --squash --match-head-commit <gate.headSha>'. It never uses --admin, --auto, --merge or --rebase.
4. A refused merge evaluates the gate once more and reports that verdict; it does not retry with other flags.
5. After the merge it reads the merge state and the rule suite of the merge commit, which must pass without bypass.
Writes one JSON object to stdout. Exit codes: 0 merged and verified, 1 fail, 2 pending, 3 already-merged, 4 invalid
input, 5 evaluation error or failed post-merge verification.

Authorization stays with the caller: Reason records the user consent or mandate and goes only into the output.

.EXAMPLE
./tools/agents/Invoke-GatedMerge.ps1 -Repository msucharda/devsecops-platform -Pr 85 -ExpectedHeadSha <sha> -Reason 'user: "merge #85" 2026-10-22'
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $Repository,
    [Parameter(Mandatory)][int] $Pr,
    [Parameter(Mandatory)][string] $ExpectedHeadSha,
    [Parameter(Mandatory)][string] $Reason,
    [string] $AcknowledgeWorkflowChanges,
    [ValidateRange(0, 240)][int] $WaitPendingMinutes = 0,
    [switch] $DeleteBranch
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MergeGate.psm1') -Force

$result = Invoke-GatedMerge @PSBoundParameters
[Console]::Error.WriteLine("action=$($result['action']) reason=$($result['reason'])")
Write-Output (ConvertTo-MergeGateJson -Result $result)
exit $result['exitCode']
