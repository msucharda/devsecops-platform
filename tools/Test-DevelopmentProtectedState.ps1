#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('development', 'standard')][string] $Mode,
    [AllowEmptyString()][string] $ExpectedReference,
    [AllowEmptyString()][string] $ExpectedControlRevision,
    [string] $ExpectedApproval,
    [AllowEmptyString()][string] $ExpectedSourceRepository,
    [string] $ExpectedAttempt = '1',
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $ServerUrl = $env:GITHUB_SERVER_URL,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [string] $Revision = $env:GITHUB_SHA,
    [string] $EventName = $env:GITHUB_EVENT_NAME,
    [string] $RunAttempt = $env:GITHUB_RUN_ATTEMPT,
    [string] $ReadToken = $env:DEVELOPMENT_READ_TOKEN
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# security-check: development-protected-continuity
function Assert-DevelopmentProtectedContinuity {
    param([AllowNull()][object] $State, [string] $Reference, [string] $ControlRevision)
    if ($null -eq $State) {
        if ($Reference -or $ControlRevision) { throw 'Protected control state disappeared after authorization.' }
        return
    }
    if ($State.Reference -cne $Reference -or $State.ControlRevision -cne $ControlRevision) {
        throw 'Protected control state changed after authorization; start a fresh dispatch.'
    }
}

$state = & (Join-Path $PSScriptRoot 'Read-DevelopmentControl.ps1') -Mode $Mode -Repository $Repository `
    -ServerUrl $ServerUrl -ApiUrl $ApiUrl -ReadToken $ReadToken -RunAttempt $RunAttempt -AllowNonReference:($Mode -eq 'standard')
Assert-DevelopmentProtectedContinuity -State $state -Reference $ExpectedReference -ControlRevision $ExpectedControlRevision
if ($null -eq $state) {
    Write-Information 'Verified non-reference deployment with no protected control ref.' -InformationAction Continue
    return
}
if ($Mode -eq 'development') {
    if ($state.Source -cne $ExpectedSourceRepository) { throw 'Protected release source changed after authorization.' }
    & (Join-Path $PSScriptRoot 'Test-DevelopmentApprovalContinuity.ps1') -CurrentApproval $state.Approval `
        -ExpectedApproval $ExpectedApproval -ExpectedAttempt $ExpectedAttempt -RunAttempt $RunAttempt -Disposition $state.Disposition
    $approval = ConvertFrom-Json -InputObject $state.Approval -AsHashtable -NoEnumerate
    $document = [Text.Json.JsonDocument]::Parse($state.Approval)
    try { $approval['expiresAt'] = $document.RootElement.GetProperty('expiresAt').GetString() }
    finally { $document.Dispose() }
    Import-Module (Join-Path $PSScriptRoot 'DevelopmentCandidate.psm1')
    Assert-DevelopmentCandidateApproval -Approval $approval -ReferenceRepository $state.Reference `
        -RepositoryUrl $ExpectedReference -Revision $approval['revision'] -BaseRevision $Revision `
        -Digest $approval['digest'] -PullRequest $approval['pullRequest'] -Operation $approval['operation']
}
else {
    & (Join-Path $PSScriptRoot 'Test-StandardDeploymentAvailability.ps1') -DevelopmentApprovalJson $state.Approval `
        -DispositionJson $state.Disposition -RepositoryUrl $ExpectedReference -Revision $Revision -EventName $EventName
}
Write-Information 'Current protected control state verified with the existing job token before deployment credentials.' -InformationAction Continue
