Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OrganizationRoles.psm1') -Force

try {
    $query = ConvertFrom-OrganizationRoleInput -Json ([Console]::In.ReadToEnd())
    $state = Get-OrganizationSecurityManagerState -ApiUrl $query['api_url'] -Organization $query['organization'] -Team $query['team'] -AllowMissingTeam
    $result = [ordered]@{
        role_id  = [string] $state['role_id']
        team_id  = [string] $state['team_id']
        assigned = $state['assigned'].ToString().ToLowerInvariant()
    }
    [Console]::Out.Write((ConvertTo-Json -InputObject $result -Compress))
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
