Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

Import-Module (Join-Path $PSScriptRoot '..\..\organizations\scripts\Organizations.psm1')

# REST API 2026-03-10:
# https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/organization-roles
# https://docs.github.com/en/enterprise-cloud@latest/rest/teams/teams#get-a-team-by-name
# security-check: organization-roles-predefined-role
function Assert-SecurityManagerRole {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Role,
        [Parameter(Mandatory)][string] $Organization
    )

    if ($Role['source'] -isnot [string] -or $Role['source'] -cne 'Predefined') {
        throw 'The security_manager role is not a documented predefined role.'
    }
    if (($Role['id'] -isnot [int] -and $Role['id'] -isnot [long]) -or $Role['id'] -lt 1) {
        throw 'The security_manager role has no valid numeric ID.'
    }
    if ($Role['permissions'] -isnot [array] -or @($Role['permissions'] | Where-Object { $_ -isnot [string] }).Count -gt 0) {
        throw 'The security_manager role has unreadable permissions.'
    }
    if (-not $Role.Contains('organization')) {
        throw 'The security_manager role has no organization field.'
    }
    $owner = $Role['organization']
    if ($null -ne $owner) {
        if ($owner -isnot [System.Collections.IDictionary] -or $owner['type'] -isnot [string] -or $owner['type'] -cne 'Organization' -or
            $owner['login'] -isnot [string] -or
            -not [string]::Equals($owner['login'], $Organization, [StringComparison]::OrdinalIgnoreCase)) {
            throw "The security_manager role belongs to an unreadable or different organization than '$Organization'."
        }
    }
}

# security-check: organization-roles-team-identity
function Assert-SecurityManagerTeam {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $SecurityTeam,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Team
    )

    if ($SecurityTeam['type'] -isnot [string] -or $SecurityTeam['type'] -cne 'organization' -or $SecurityTeam['slug'] -isnot [string] -or
        -not [string]::Equals($SecurityTeam['slug'], $Team, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The security team '$Team' has a different slug or is not an organization team."
    }
    if (($SecurityTeam['id'] -isnot [int] -and $SecurityTeam['id'] -isnot [long]) -or $SecurityTeam['id'] -lt 1) {
        throw "The security team '$Team' has no valid numeric ID."
    }
    $owner = $SecurityTeam['organization']
    if ($owner -isnot [System.Collections.IDictionary] -or $owner['login'] -isnot [string] -or
        -not [string]::Equals($owner['login'], $Organization, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The security team '$Team' belongs to an unreadable or different organization than '$Organization'."
    }
}

# security-check: organization-roles-assignment
function Test-SecurityManagerAssignment {
    [CmdletBinding()]
    [OutputType([bool])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Assignment,
        [Parameter(Mandatory)][System.Collections.IDictionary] $SecurityTeam,
        [Parameter(Mandatory)][string] $Team,
        [switch] $MatchIdOnly
    )

    $matched = [Collections.Generic.List[object]]::new()
    foreach ($entry in $Assignment) {
        if ($entry -isnot [System.Collections.IDictionary] -or $entry['type'] -isnot [string] -or
            $entry['type'] -cnotin @('organization', 'enterprise')) {
            throw 'The team role assignment has an unreadable or unknown team type.'
        }
        if (($entry['id'] -isnot [int] -and $entry['id'] -isnot [long]) -or $entry['id'] -lt 1 -or
            $entry['slug'] -isnot [string] -or [string]::IsNullOrWhiteSpace($entry['slug'])) {
            throw 'The team role assignment has an unreadable identity.'
        }
        if ($entry['type'] -ceq 'enterprise') { continue }
        $sameId = $entry['id'] -eq $SecurityTeam['id']
        $sameSlug = [string]::Equals($entry['slug'], $Team, [StringComparison]::OrdinalIgnoreCase)
        if (-not $MatchIdOnly -and ($sameId -or $sameSlug) -and -not ($sameId -and $sameSlug)) {
            throw 'The team role assignment has a mismatched security-team identity.'
        }
        if (($sameId -or $entry.Contains('assignment')) -and
            ($entry['assignment'] -isnot [string] -or $entry['assignment'] -cnotin @('direct', 'indirect', 'mixed'))) {
            throw 'The team role assignment has an unreadable or unsupported assignment classification.'
        }
        if ($sameId -and ($MatchIdOnly -or $sameSlug)) { $matched.Add($entry) }
    }
    if ($matched.Count -gt 1) { throw 'The security team role assignment is listed more than once.' }
    return $matched.Count -eq 1 -and $matched[0]['assignment'] -cin @('direct', 'mixed')
}

# security-check: organization-roles-state
function Get-SecurityManagerRole {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z')][string] $Organization
    )

    $roles = (Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method GET -Path "/orgs/$Organization/organization-roles").Body
    if ($roles -isnot [System.Collections.IDictionary] -or $roles['roles'] -isnot [array]) {
        throw "The organization roles response for '$Organization' has no roles array."
    }
    foreach ($item in $roles['roles']) {
        if ($item -isnot [System.Collections.IDictionary] -or $item['name'] -isnot [string]) {
            throw "The organization roles array for '$Organization' has an unreadable role."
        }
    }
    $selected = @($roles['roles'] | Where-Object { $_['name'] -ceq 'security_manager' })
    if ($selected.Count -ne 1) { throw "Organization '$Organization' has no unique predefined security_manager role." }
    $role = $selected[0]
    Assert-SecurityManagerRole -Role $role -Organization $Organization
    return $role
}

# security-check: organization-roles-team-state
function Get-SecurityManagerTeam {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z')][string] $Organization,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z')][string] $Team,
        [switch] $AllowMissingTeam
    )

    $acceptedStatus = @(200)
    if ($AllowMissingTeam) { $acceptedStatus += 404 }
    $response = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method GET -Path "/orgs/$Organization/teams/$Team" -AcceptStatus $acceptedStatus
    if ($response.Status -eq 404) {
        if ($response.Body -isnot [System.Collections.IDictionary]) { throw "The security team '$Team' not-found response is unreadable." }
        return $null
    }
    $securityTeam = $response.Body
    if ($securityTeam -isnot [System.Collections.IDictionary]) { throw "The security team '$Team' is unreadable." }
    Assert-SecurityManagerTeam -SecurityTeam $securityTeam -Organization $Organization -Team $Team
    return $securityTeam
}

function Get-OrganizationSecurityManagerState {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z')][string] $Organization,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z')][string] $Team,
        [switch] $AllowMissingTeam
    )

    $role = Get-SecurityManagerRole -ApiUrl $ApiUrl -Organization $Organization
    $securityTeam = Get-SecurityManagerTeam -ApiUrl $ApiUrl -Organization $Organization -Team $Team -AllowMissingTeam:$AllowMissingTeam
    if ($null -eq $securityTeam) {
        return [ordered]@{ role_id = $role['id']; team_id = $null; assigned = $false }
    }
    $assignments = (Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method GET -AllPages `
            -Path "/orgs/$Organization/organization-roles/$($role['id'])/teams?per_page=100").Body
    $assigned = Test-SecurityManagerAssignment -Assignment $assignments -SecurityTeam $securityTeam -Team $Team
    return [ordered]@{ role_id = $role['id']; team_id = $securityTeam['id']; assigned = $assigned }
}

# security-check: organization-roles-bound-identity
function Assert-OrganizationSecurityManagerIdentity {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Team,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $RoleId,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $TeamId
    )

    $state = Get-OrganizationSecurityManagerState -ApiUrl $ApiUrl -Organization $Organization -Team $Team
    if ($state['role_id'] -ne $RoleId) { throw 'The security_manager role identity changed after the intent was stored.' }
    if ($state['team_id'] -ne $TeamId) { throw 'The security team identity changed after the intent was stored.' }
    return $state
}

# security-check: organization-roles-assignment-result
function Set-OrganizationSecurityManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Team,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $RoleId,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $TeamId
    )

    $identity = @{ ApiUrl = $ApiUrl; Organization = $Organization; Team = $Team; RoleId = $RoleId; TeamId = $TeamId }
    $state = Assert-OrganizationSecurityManagerIdentity @identity
    if ($state['assigned']) { return }
    $null = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method PUT `
        -Path "/orgs/$Organization/organization-roles/teams/$Team/$RoleId" -AcceptStatus @(204)
    $state = Assert-OrganizationSecurityManagerIdentity @identity
    if (-not $state['assigned']) { throw 'The security_manager role was not assigned after PUT.' }
}

# security-check: organization-roles-removal-result
function Remove-OrganizationSecurityManager {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9]+(?:-[A-Za-z0-9]+)*\z')][string] $Team,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $RoleId,
        [Parameter(Mandatory)][ValidateRange(1, [long]::MaxValue)][long] $TeamId
    )

    $role = Get-SecurityManagerRole -ApiUrl $ApiUrl -Organization $Organization
    if ($role['id'] -ne $RoleId) { throw 'The security_manager role identity changed after the intent was stored.' }
    $assignments = (Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method GET -AllPages `
            -Path "/orgs/$Organization/organization-roles/$RoleId/teams?per_page=100").Body
    $savedTeam = @{ id = $TeamId }
    if (-not (Test-SecurityManagerAssignment -Assignment $assignments -SecurityTeam $savedTeam -Team $Team -MatchIdOnly)) {
        Write-Verbose "The saved team '$TeamId' has no direct security_manager assignment."
        return
    }
    $assignedTeam = @($assignments | Where-Object { $_['type'] -ceq 'organization' -and $_['id'] -eq $TeamId })[0]
    $currentSlug = $assignedTeam['slug']
    $securityTeam = Get-SecurityManagerTeam -ApiUrl $ApiUrl -Organization $Organization -Team $currentSlug
    if ($securityTeam['id'] -ne $TeamId) { throw 'The security team identity changed before removal.' }
    $null = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method DELETE `
        -Path "/orgs/$Organization/organization-roles/teams/$currentSlug/$RoleId" -AcceptStatus @(204, 404)
    $currentTeam = Get-SecurityManagerTeam -ApiUrl $ApiUrl -Organization $Organization -Team $currentSlug -AllowMissingTeam
    if ($null -ne $currentTeam -and $currentTeam['id'] -ne $TeamId) {
        $newTeamId = $currentTeam['id']
        $modulePath = (Join-Path $PSScriptRoot 'OrganizationRoles.psm1').Replace("'", "''")
        $quotedApiUrl = $ApiUrl.Replace("'", "''")
        $restoreCommand = "Import-Module '$modulePath' -Force; Set-OrganizationSecurityManager -ApiUrl '$quotedApiUrl' -Organization '$Organization' -Team '$currentSlug' -RoleId $RoleId -TeamId $newTeamId"
        throw "The security team identity changed after DELETE: original_team_id=$TeamId; new_team_id=$newTeamId; slug=$currentSlug; role_id=$RoleId. The replacement team's role may have been removed. Stop concurrent team lifecycle changes and confirm that the new team should have security_manager. Set REST_API_BEARER to the apply token for organization '$Organization', then restore the role with:`n$restoreCommand`nThis command revalidates both IDs. No automatic restoration was attempted."
    }
    $remaining = (Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method GET -AllPages `
            -Path "/orgs/$Organization/organization-roles/$RoleId/teams?per_page=100").Body
    if (Test-SecurityManagerAssignment -Assignment $remaining -SecurityTeam $savedTeam -Team $Team -MatchIdOnly) {
        throw 'The security_manager role is still assigned after DELETE.'
    }
}

# security-check: organization-roles-input
function ConvertFrom-OrganizationRoleInput {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Json,
        [switch] $ForChange
    )

    $query = ConvertFrom-Json -InputObject $Json -AsHashtable -Depth 20 -NoEnumerate
    if ($query -isnot [System.Collections.IDictionary]) { throw 'The organization-role input must be a JSON object.' }
    foreach ($name in @('api_url', 'organization', 'team')) {
        if ($query[$name] -isnot [string] -or [string]::IsNullOrWhiteSpace($query[$name])) {
            throw "The organization-role input field '$name' must be a nonempty string."
        }
    }
    if ($ForChange) {
        foreach ($name in @('role_id', 'team_id')) {
            if (($query[$name] -isnot [int] -and $query[$name] -isnot [long]) -or $query[$name] -lt 1) {
                throw "The organization-role input field '$name' must be a valid numeric ID."
            }
        }
    }
    return $query
}

Export-ModuleMember -Function Get-OrganizationSecurityManagerState, Assert-OrganizationSecurityManagerIdentity, Set-OrganizationSecurityManager, Remove-OrganizationSecurityManager, ConvertFrom-OrganizationRoleInput
