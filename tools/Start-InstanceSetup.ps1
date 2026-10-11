#Requires -Version 7.4
<#
.SYNOPSIS
Interactive wizard for phase A of docs/reference-instance.md.

.DESCRIPTION
The wizard asks for the instance inputs, checks every prerequisite, performs the changes that have an API after
an explicit confirmation and guides the steps without an API. It writes instance.yaml and session.ps1 to the work
folder only from verified results and finishes with the bootstrap preflight. Every run repeats the checks, so the
wizard resumes after any interruption.

.PARAMETER WorkPath
Folder for instance data outside the source repository: instance.yaml, session.ps1, setup-state.json and keys.

.PARAMETER ModulesPath
Module manifests for the configuration validation and the preflight.

.PARAMETER Reconfirm
Asks again for every confirmation of a step without an API.

.PARAMETER PassThru
Returns the stage results, the manual prerequisite flags and the instance.yaml path.
#>
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string] $WorkPath = (Join-Path $HOME 'platform-reference'),
    [string] $ModulesPath = (Join-Path $PSScriptRoot 'tests/fixtures/runner-modules'),
    [switch] $Reconfirm,
    [switch] $PassThru
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'InstanceSetup.psm1') -Force
$result = Invoke-InstanceSetup -RepoPath (Join-Path $PSScriptRoot '..') -WorkPath $WorkPath -ModulesPath $ModulesPath -Reconfirm:$Reconfirm
if ($PassThru) { $result }
