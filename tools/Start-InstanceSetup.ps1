#Requires -Version 7.4
<#
.SYNOPSIS
Interactive prerequisite, module manual-step and GitHub bootstrap acceptance wizard.

.DESCRIPTION
The wizard asks for the instance inputs, checks every prerequisite, performs the changes that have an API after
an explicit confirmation and guides the steps without an API. It writes instance.yaml and session.ps1 to the work
folder only from verified results and finishes with the bootstrap preflight. Every run repeats the checks, so the
wizard resumes after any interruption.
With -GitHubAcceptance, it reads the verified prerequisite configuration without modifying it, prepares an
isolated non-production acceptance candidate and runs bootstrap and live read-only checks after consent.
It records incomplete checks, actual nightly runs and human evidence separately; it never deletes resources,
posts an issue comment or closes an issue. Live apply-identity checks require both platform and security approvals.
With -Phase ManualSteps, it guides selected module manifest steps, records resumable human declarations outside
the source checkout and never performs the manual actions or changes instance.yaml.

.PARAMETER WorkPath
Folder for instance data outside the source repository: instance.yaml, session.ps1, setup-state.json and keys.

.PARAMETER ModulesPath
Module manifests for the configuration validation and the preflight.
Defaults to the actual modules for ManualSteps, and prerequisite test manifests otherwise.

.PARAMETER Phase
Prerequisites (default) or the independent ManualSteps phase.

.PARAMETER ManualStep
One selected module/id in ManualSteps. Without it, the wizard offers an interactive selection.

.PARAMETER Reconfirm
Asks again for every confirmation of a step without an API.

.PARAMETER GitHubAcceptance
Runs issue #11 acceptance with external data under WorkPath/github-acceptance.

.PARAMETER ReleasePath
Approved clean source checkout or release export used to prepare the isolated acceptance candidate.
The wizard must run from the same source version. The source provenance requires human approval.

.PARAMETER ReleaseVersion
SemVer without a v prefix for the acceptance candidate; this is not a production release.

.PARAMETER PassThru
Returns prerequisite results, acceptance results or manual-step statuses and the local progress path.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string] $WorkPath = (Join-Path $HOME 'platform-reference'),
    [string] $ModulesPath,
    [ValidateSet('Prerequisites', 'ManualSteps')][string] $Phase = 'Prerequisites',
    [string] $ManualStep,
    [switch] $GitHubAcceptance,
    [string] $ReleasePath,
    [ValidatePattern('^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$')][string] $ReleaseVersion,
    [switch] $Reconfirm,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'InstanceSetup.psm1')
if (-not $ModulesPath) {
    $ModulesPath = if ($Phase -eq 'ManualSteps') { Join-Path $PSScriptRoot '../modules' }
    else { Join-Path $PSScriptRoot 'tests/fixtures/runner-modules' }
}
$result = Invoke-InstanceSetup -RepoPath (Join-Path $PSScriptRoot '..') -WorkPath $WorkPath -ModulesPath $ModulesPath `
    -Phase $Phase -ManualStep $ManualStep -Reconfirm:$Reconfirm -GitHubAcceptance:$GitHubAcceptance `
    -ReleasePath $ReleasePath -ReleaseVersion $ReleaseVersion
if ($PassThru) { $result }
