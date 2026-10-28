#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $StatePath,
    [Parameter(Mandatory)][string] $TracePath,
    [switch] $Aba,
    [string] $AcknowledgedSha = ''
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'MergeGateStub.psm1')
$stub = Initialize-MergeGateStub -Scenario pr-78
$state = Get-Content -LiteralPath $StatePath -Raw | ConvertFrom-Json -AsHashtable -Depth 100
foreach ($key in $state.get_Keys()) { $stub[$key] = $state[$key] }
$abaEnabled = $Aba.IsPresent
$moves = [Collections.Generic.List[string]]::new()

$ghStub = {
    $arguments = [string[]] $args
    $head = $stub.PullRequest.headRefOid
    $move = $abaEnabled -and $arguments[-1] -match '/pulls/\d+/files\?'
    if ($move) {
        $files = $stub.Files
        if ($stub.ContainsKey('AbaFiles')) { $stub.Files = $stub.AbaFiles }
        $stub.PullRequest.headRefOid = 'c' * 40
        $moves.Add($stub.PullRequest.headRefOid)
    }
    try { Invoke-MergeGateStub -Stub $stub -Arguments $arguments }
    finally {
        if ($move) {
            $stub.Files = $files
            $stub.PullRequest.headRefOid = $head
            $moves.Add($head)
        }
        $global:LASTEXITCODE = 0
    }
}.GetNewClosure()
Set-Item -LiteralPath Function:\global:gh -Value $ghStub

$parameters = @{
    Repository = 'msucharda/devsecops-platform'; Pr = 78
    ExpectedHeadSha = $stub.PullRequest.headRefOid; Now = $stub.Now
}
if ($AcknowledgedSha) { $parameters['AcknowledgeWorkflowChanges'] = $AcknowledgedSha }
& (Join-Path $PSScriptRoot '../agents/Test-MergeGate.ps1') @parameters
$code = $LASTEXITCODE
@{
    calls = $stub.Calls.ToArray()
    moves = $moves.ToArray()
} | ConvertTo-Json -Depth 100 | Set-Content -LiteralPath $TracePath
exit $code
