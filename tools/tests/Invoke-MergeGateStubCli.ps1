#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StatePath,
    [Parameter(Mandatory)][string] $TracePath,
    [switch] $Aba
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MergeGateStub.psm1')
$global:MergeGateCliStub = Initialize-MergeGateStub -Scenario pr-78
$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
foreach ($key in $state.Keys) { $global:MergeGateCliStub[$key] = $state[$key] }
$global:MergeGateCliAba = $Aba.IsPresent
$global:MergeGateCliMoves = [Collections.Generic.List[string]]::new()

function global:gh {
    $arguments = [string[]] $args
    $head = $global:MergeGateCliStub.PullRequest.headRefOid
    $move = $global:MergeGateCliAba -and $arguments[-1] -match '/pulls/\d+/files\?'
    if ($move) {
        $global:MergeGateCliStub.PullRequest.headRefOid = 'c' * 40
        $global:MergeGateCliMoves.Add($global:MergeGateCliStub.PullRequest.headRefOid)
    }
    try { Invoke-MergeGateStub -Stub $global:MergeGateCliStub -Arguments $arguments }
    finally {
        if ($move) {
            $global:MergeGateCliStub.PullRequest.headRefOid = $head
            $global:MergeGateCliMoves.Add($head)
        }
        $global:LASTEXITCODE = 0
    }
}

& (Join-Path $PSScriptRoot '../agents/Test-MergeGate.ps1') -Repository msucharda/devsecops-platform -Pr 78 `
    -ExpectedHeadSha $global:MergeGateCliStub.PullRequest.headRefOid -Now $global:MergeGateCliStub.Now
$code = $LASTEXITCODE
@{
    calls = $global:MergeGateCliStub.Calls.ToArray()
    moves = $global:MergeGateCliMoves.ToArray()
} | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $TracePath
exit $code
