#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $IssuanceStatePath,
    [switch] $ConfirmTokenExpiredOrRevoked
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'GitHubTokenIssuance.psm1')
Resolve-PlatformGitHubTokenIssuance -Path $IssuanceStatePath -ConfirmTokenExpiredOrRevoked:$ConfirmTokenExpiredOrRevoked
