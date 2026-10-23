param(
    [Parameter(Mandatory)]
    [ValidateSet('AssertIdentity', 'Assign', 'Remove', IgnoreCase = $false)]
    [string] $Action
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'OrganizationRoles.psm1') -Force

try {
    $query = ConvertFrom-OrganizationRoleInput -Json $env:ORGANIZATION_ROLES_INPUT -ForChange
    $identity = @{
        ApiUrl       = $query['api_url']
        Organization = $query['organization']
        Team         = $query['team']
        RoleId       = $query['role_id']
        TeamId       = $query['team_id']
    }
    switch -CaseSensitive ($Action) {
        AssertIdentity { $null = Assert-OrganizationSecurityManagerIdentity @identity }
        Assign { Set-OrganizationSecurityManager @identity }
        Remove { Remove-OrganizationSecurityManager @identity }
    }
}
catch {
    [Console]::Error.WriteLine($_.Exception.Message)
    exit 1
}
