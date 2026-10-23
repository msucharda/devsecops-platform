#Requires -Version 7.4
<#
.SYNOPSIS
Lists manual App installations and security-team preparation from the selected manifests.
.DESCRIPTION
This is a desired-state checklist, not a live verification. Unbound Apps are explicitly marked as requiring registration.
#>
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $InstancePath,
    [string] $ModulesPath = (Join-Path $PSScriptRoot '..\modules'),
    [ValidatePattern('^[a-z][a-z0-9]*(-[a-z0-9]+)*\.ghe\.com$')][string] $GitHubHost
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
$modules = Get-PlatformModuleGraph -ModulesPath $ModulesPath
$instance = Get-PlatformInstance -Path $InstancePath -Modules $modules -AllowUnboundApps
if (-not $GitHubHost) {
    if (-not $instance.Contains('bootstrap')) { throw 'Supply -GitHubHost or configure bootstrap.githubHost for the installation checklist.' }
    $GitHubHost = $instance['bootstrap']['githubHost']
}
$installations = @(Get-PlatformAppInstallationRequirement -Instance $instance -Modules $modules -GitHubHost $GitHubHost)
$teamOrganizations = @($installations | Where-Object { $_.module -ceq 'organization-roles' } |
        ForEach-Object organization | Sort-Object -Unique)
$teams = @(foreach ($organization in $teamOrganizations) {
        $parameters = $instance['modules']['organization-roles']['parameters']
        $team = if ($parameters.Contains('security_team')) { $parameters['security_team'] } else { 'security' }
        [ordered]@{
            organization = $organization
            team = $team
            idpGroupName = "$($instance['instance']['name'])-security-team"
            createTeam = "Create the organization team '$team' if it does not exist."
            linkTeam = 'Link the team to the Entra ID security group in the team settings.'
            teamsUrl = "https://$GitHubHost/orgs/$organization/teams"
            teamUrl = "https://$GitHubHost/orgs/$organization/teams/$team"
            manualPrerequisite = 'organizationSecurityTeamsLinked'
        }
    })
ConvertTo-Json -InputObject ([ordered]@{ securityTeams = $teams; installations = $installations }) -Depth 100
