BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $roleModule = Join-Path $PSScriptRoot '../../modules/organization-roles/scripts/OrganizationRoles.psm1'
    Import-Module $roleModule -Force
    $target = @{ ApiUrl = 'https://api.example.ghe.com'; Organization = 'demo-actions'; Team = 'security' }

    function Invoke-RoleApiStub {
        param([string] $Method, [string] $Path)

        $route = $Path.Split('?')[0] -replace '^/orgs/1/', '/orgs/demo-actions/' -replace '/teams/1$', '/teams/security'
        $body = switch ("$Method $route") {
            'GET /orgs/demo-actions/organization-roles' { , $roleStub.Roles }
            'GET /orgs/demo-actions/teams/security' { , $roleStub.Team }
            'GET /orgs/demo-actions/organization-roles/8030/teams' { , $roleStub.Assignments }
            'PUT /orgs/demo-actions/organization-roles/teams/security/8030' {
                $roleStub.Writes.Add('PUT')
                $other = @($roleStub.Assignments | Where-Object { $_.type -cne 'organization' -or $_.slug -ine 'security' })
                $assigned = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{ '0.slug' = 'security' }
                $roleStub.Assignments = $other + @($assigned)
            }
            'DELETE /orgs/demo-actions/organization-roles/teams/security/8030' {
                $roleStub.Writes.Add('DELETE')
                $roleStub.Assignments = @($roleStub.Assignments | Where-Object { $_.type -cne 'organization' -or $_.slug -ine 'security' })
            }
            default { throw "Unexpected organization-role request: $Method $Path." }
        }
        $status = if ($Method -cin @('PUT', 'DELETE')) { 204 } else { 200 }
        $content = if ($status -eq 204) { '' } else { ConvertTo-Json -InputObject $body -Depth 30 -Compress }
        [pscustomobject]@{ StatusCode = $status; Content = $content; Headers = @{} }
    }
}

Describe 'Organization security manager role' {
    BeforeEach {
        $env:REST_API_BEARER = 'test-org-token'
        $roleStub = @{
            Writes = [Collections.Generic.List[string]]::new()
            Roles = Get-GitHubApiFixture -Name org-roles/list-org-roles.organization-null -Set @{
                'roles.0.name' = 'security_manager'; 'roles.0.source' = 'Predefined'
            }
            Team = Get-GitHubApiFixture -Name org-roles/get-by-name -Set @{
                slug = 'security'; 'organization.login' = 'demo-actions'
            }
            Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{
                '0.slug' = 'security'
            }
        }
        Mock -ModuleName Organizations Invoke-WebRequest {
            $Headers['X-GitHub-Api-Version'] | Should -BeExactly '2026-03-10'
            Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path ([Uri] $Uri).PathAndQuery
        }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    It 'reads the predefined role and direct organization-team assignment from documented contracts' {
        $state = Get-OrganizationSecurityManagerState @target

        $state.role_id | Should -Be 8030
        $state.team_id | Should -Be 1
        $state.assigned | Should -BeTrue
    }

    It 'rejects an array masquerading as the <Case> enum string' -Tag RoleWireShape -ForEach @(
        @{ Case = 'team type'; Kind = 'team'; Error = '*security team*slug*' }
        @{ Case = 'role organization type'; Kind = 'role'; Error = '*security_manager role*unreadable or different organization*' }
    ) {
        # Intentionally invalid: a one-item array must not pass a scalar enum comparison.
        if ($Kind -ceq 'team') { $roleStub.Team.type = @('organization') }
        else {
            $roleStub.Roles = Get-GitHubApiFixture -Name org-roles/list-org-roles.organization-simple-user -Set @{
                'roles.0.name' = 'security_manager'; 'roles.0.source' = 'Predefined'
                'roles.0.organization.login' = 'demo-actions'; 'roles.0.organization.type' = @('Organization')
            }
        }

        { Get-OrganizationSecurityManagerState @target } | Should -Throw $Error
    }

    It 'rejects an array masquerading as an assignment <Field>' -Tag RoleWireShape -ForEach @(
        @{ Field = 'type'; Value = @('organization'); ErrorPattern = '*team role assignment*unknown team type*' }
        @{ Field = 'assignment'; Value = @('direct'); ErrorPattern = '*team role assignment*classification*' }
    ) {
        # Intentionally invalid: the documented enum is a scalar string.
        $roleStub.Assignments[0][$Field] = $Value

        { Get-OrganizationSecurityManagerState @target } | Should -Throw $ErrorPattern
    }

    It 'rejects an unsupported roles wrapper: <Case>' -ForEach @(
        @{ Case = 'array wrapper' }
        @{ Case = 'scalar wrapper' }
        @{ Case = 'missing optional roles' }
        @{ Case = 'role object instead of an array' }
    ) {
        # Missing roles is documented but unreadable; the other shapes are intentionally invalid.
        switch ($Case) {
            'array wrapper' { $roleStub.Roles = @($roleStub.Roles) }
            'scalar wrapper' { $roleStub.Roles = 'unreadable' }
            'missing optional roles' { $roleStub.Roles.Remove('roles') }
            'role object instead of an array' { $roleStub.Roles.roles = $roleStub.Roles.roles[0] }
        }

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*has no roles array*'
    }

    It 'rejects an unreadable role array item: <Case>' -ForEach @(
        @{ Case = 'non-object item' }
        @{ Case = 'numeric name' }
    ) {
        # Intentionally invalid: alter one role item or its required string name.
        if ($Case -ceq 'non-object item') { $roleStub.Roles.roles[0] = 1 }
        else { $roleStub.Roles.roles[0].name = 1 }

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*roles array*unreadable role*'
    }

    It 'rejects a missing required role organization field instead of treating it as null' {
        # Intentionally invalid: nullable does not make the required property optional.
        $roleStub.Roles.roles[0].Remove('organization')

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*role has no organization field*'
    }

    It 'rejects a scalar permission instead of accepting it as an array' {
        # Intentionally invalid: one permission string is not the documented string array.
        $roleStub.Roles.roles[0].permissions = 'read_organization'

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*role has unreadable permissions*'
    }

    It 'rejects an unsupported role organization: <Case>' -ForEach @(
        @{ Case = 'scalar owner' }
        @{ Case = 'user type' }
        @{ Case = 'noncanonical type' }
    ) {
        $roleStub.Roles = Get-GitHubApiFixture -Name org-roles/list-org-roles.organization-simple-user -Set @{
            'roles.0.name' = 'security_manager'; 'roles.0.source' = 'Predefined'; 'roles.0.organization.login' = 'demo-actions'
        }
        # Intentionally invalid for this boundary: alter only the owner or its type.
        switch ($Case) {
            'scalar owner' { $roleStub.Roles.roles[0].organization = 'unreadable' }
            'user type' { $roleStub.Roles.roles[0].organization.type = 'User' }
            'noncanonical type' { $roleStub.Roles.roles[0].organization.type = 'organization' }
        }

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*role belongs to an unreadable or different organization*'
    }

    It 'does not coerce a numeric organization owner login in the <Boundary> response' -ForEach @(
        @{ Boundary = 'role' }
        @{ Boundary = 'team' }
    ) {
        $numericTarget = $target.Clone()
        $numericTarget.Organization = '1'
        $roleStub.Team.organization.login = '1'
        $roleStub.Roles = Get-GitHubApiFixture -Name org-roles/list-org-roles.organization-simple-user -Set @{
            'roles.0.name' = 'security_manager'; 'roles.0.source' = 'Predefined'; 'roles.0.organization.login' = '1'
        }
        (Get-OrganizationSecurityManagerState @numericTarget).assigned | Should -BeTrue
        # Intentionally invalid: change only the string login to a JSON number.
        if ($Boundary -ceq 'role') {
            $roleStub.Roles.roles[0].organization.login = 1
            $pattern = '*security_manager role belongs to an unreadable or different organization*'
        }
        else {
            $roleStub.Team.organization.login = 1
            $pattern = '*security team*belongs to an unreadable or different organization*'
        }

        { Get-OrganizationSecurityManagerState @numericTarget } | Should -Throw $pattern
    }

    It 'does not coerce a numeric team slug in the <Boundary> response' -ForEach @(
        @{ Boundary = 'team' }
        @{ Boundary = 'assignment' }
    ) {
        $numericTarget = $target.Clone()
        $numericTarget.Team = '1'
        $roleStub.Team.slug = '1'
        $roleStub.Assignments[0].slug = '1'
        (Get-OrganizationSecurityManagerState @numericTarget).assigned | Should -BeTrue
        # Intentionally invalid: change only the string slug to a JSON number.
        if ($Boundary -ceq 'team') {
            $roleStub.Team.slug = 1
            $pattern = '*security team*slug*'
        }
        else {
            $roleStub.Assignments[0].slug = 1
            $pattern = '*team role assignment*unreadable identity*'
        }

        { Get-OrganizationSecurityManagerState @numericTarget } | Should -Throw $pattern
    }

    It 'rejects a non-object full team response' {
        # Intentionally invalid: the full-team response must be an object.
        $roleStub.Team = 'unreadable'

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*security team*unreadable*'
    }

    It 'rejects a non-object role assignment item' {
        # Intentionally invalid: the list must contain team objects.
        $roleStub.Assignments = @('unreadable')

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*team role assignment*unknown team type*'
    }

    It 'rejects the selected role with <Case>' -ForEach @(
        @{ Case = 'a custom organization source'; Field = 'source'; Value = 'Organization' }
        @{ Case = 'an enterprise source'; Field = 'source'; Value = 'Enterprise' }
        @{ Case = 'a null source'; Field = 'source'; Value = $null }
        @{ Case = 'a noncanonical source'; Field = 'source'; Value = 'predefined' }
        @{ Case = 'a zero ID'; Field = 'id'; Value = 0 }
        @{ Case = 'a string ID'; Field = 'id'; Value = '8030' }
        @{ Case = 'unreadable permissions'; Field = 'permissions'; Value = $null }
        @{ Case = 'a list instead of a source'; Field = 'source'; Value = @('Predefined') }
        @{ Case = 'a non-string permission'; Field = 'permissions'; Value = @(1) }
    ) {
        # Intentionally invalid for this control: one identity field differs from the valid contract.
        $roleStub.Roles.roles[0][$Field] = $Value

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*security_manager role*'
    }

    It 'accepts the documented nullable-role and parent-team variants: <RoleVariant>, <ParentVariant>' -ForEach @(
        @{ RoleVariant = 'organization-null'; ParentVariant = 'parent-object' }
        @{ RoleVariant = 'organization-simple-user'; ParentVariant = 'parent-null' }
        @{ RoleVariant = 'organization-simple-user'; ParentVariant = 'parent-object' }
    ) {
        $set = @{ 'roles.0.name' = 'security_manager'; 'roles.0.source' = 'Predefined' }
        if ($RoleVariant -ceq 'organization-simple-user') { $set['roles.0.organization.login'] = 'DEMO-actions' }
        $roleStub.Roles = Get-GitHubApiFixture -Name "org-roles/list-org-roles.$RoleVariant" -Set $set
        $roleStub.Assignments = Get-GitHubApiFixture -Name "org-roles/list-org-role-teams.organization.$ParentVariant" -Set @{ '0.slug' = 'SECURITY' }

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeTrue
    }

    It 'rejects a security_manager role that belongs to another organization' {
        $roleStub.Roles = Get-GitHubApiFixture -Name org-roles/list-org-roles.organization-simple-user -Set @{
            'roles.0.name' = 'security_manager'; 'roles.0.source' = 'Predefined'; 'roles.0.organization.login' = 'unrelated'
        }

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*security_manager role*organization*'
    }

    It 'rejects a missing or ambiguous security_manager role: <Count>' -ForEach @(
        @{ Count = 0 }
        @{ Count = 2 }
    ) {
        if ($Count -eq 0) { $roleStub.Roles.roles = @() }
        else { $roleStub.Roles.roles += $roleStub.Roles.roles[0] }

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*unique*security_manager role*'
    }

    It 'rejects unreadable roles instead of an array' {
        # Intentionally invalid: roles is a documented array.
        $roleStub.Roles.roles = 'security_manager'

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*roles*array*'
    }

    It 'rejects the security team with <Case>' -ForEach @(
        @{ Case = 'a different slug'; Field = 'slug'; Value = 'other' }
        @{ Case = 'an enterprise type'; Field = 'type'; Value = 'enterprise' }
        @{ Case = 'an unknown type'; Field = 'type'; Value = 'Organization' }
        @{ Case = 'a zero ID'; Field = 'id'; Value = 0 }
        @{ Case = 'a string ID'; Field = 'id'; Value = '1' }
        @{ Case = 'no organization'; Field = 'organization'; Value = $null }
    ) {
        # Intentionally invalid for this identity check: change one field in the documented full-team body.
        $roleStub.Team[$Field] = $Value

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*security team*'
    }

    It 'rejects a security team belonging to another organization' {
        $roleStub.Team.organization.login = 'unrelated'

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*security team*organization*'
    }

    It 'reports a missing assignment without claiming compliance' {
        $roleStub.Assignments = @()

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeFalse
    }

    It 'distinguishes documented assignment <Assignment> from a direct assignment' -ForEach @(
        @{ Assignment = 'direct'; Expected = $true }
        @{ Assignment = 'mixed'; Expected = $true }
        @{ Assignment = 'indirect'; Expected = $false }
    ) {
        $roleStub.Assignments[0].assignment = $Assignment

        (Get-OrganizationSecurityManagerState @target).assigned | Should -Be $Expected
    }

    It 'does not treat an enterprise team as the organization team: <ParentVariant>' -ForEach @(
        @{ ParentVariant = 'parent-null' }
        @{ ParentVariant = 'parent-object' }
    ) {
        $roleStub.Assignments = Get-GitHubApiFixture -Name "org-roles/list-org-role-teams.enterprise.$ParentVariant" -Set @{ '0.slug' = 'security' }

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeFalse
    }

    It 'rejects an unreadable team role assignment: <Case>' -ForEach @(
        @{ Case = 'unknown type'; Field = 'type'; Value = 'unknown'; ErrorPattern = '*unknown team type*' }
        @{ Case = 'missing type'; Field = 'type'; Value = $null; ErrorPattern = '*unknown team type*' }
        @{ Case = 'noncanonical type'; Field = 'type'; Value = 'Organization'; ErrorPattern = '*unknown team type*' }
        @{ Case = 'unknown assignment'; Field = 'assignment'; Value = 'unknown'; ErrorPattern = '*classification*' }
        @{ Case = 'missing assignment'; Field = 'assignment'; Value = $null; ErrorPattern = '*classification*' }
        @{ Case = 'noncanonical assignment'; Field = 'assignment'; Value = 'Direct'; ErrorPattern = '*classification*' }
        @{ Case = 'zero ID'; Field = 'id'; Value = 0; ErrorPattern = '*unreadable identity*' }
        @{ Case = 'string ID'; Field = 'id'; Value = '1'; ErrorPattern = '*unreadable identity*' }
        @{ Case = 'empty slug'; Field = 'slug'; Value = ''; ErrorPattern = '*unreadable identity*' }
    ) {
        # Intentionally invalid or unsupported: alter one documented assignment field.
        $roleStub.Assignments[0][$Field] = $Value

        { Get-OrganizationSecurityManagerState @target } | Should -Throw "*team role assignment*$ErrorPattern"
    }

    It 'rejects duplicate assignments of the same organization team' {
        $roleStub.Assignments += $roleStub.Assignments[0]

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*team role assignment*more than once*'
    }

    It 'rejects an assignment that matches only the team <Field>' -ForEach @(
        @{ Field = 'id'; SetField = 'slug'; Value = 'other' }
        @{ Field = 'slug'; SetField = 'id'; Value = 2 }
    ) {
        $roleStub.Assignments[0][$SetField] = $Value

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*team role assignment*identity*'
    }

    It 'ignores an unrelated organization team without changing its role' {
        $roleStub.Assignments[0].id = 2
        $roleStub.Assignments[0].slug = 'other'

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeFalse
    }

    It 'ignores an unrelated team with omitted optional assignment and preserves its role' -Tag RoleOptionalAssignment {
        $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.assignment-absent -Set @{
            '0.id' = 2; '0.slug' = 'other'
        }

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeTrue
        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        $roleStub.Assignments.Count | Should -Be 1
        $roleStub.Assignments[0].slug | Should -BeExactly 'other'
        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
    }

    It 'rejects an omitted optional assignment when it cannot classify the security team' -Tag RoleOptionalAssignment {
        $roleStub.Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.assignment-absent -Set @{
            '0.slug' = 'security'
        }

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*assignment classification*'
    }

    It 'rejects an invalid optional assignment on an unrelated team when present' -Tag RoleOptionalAssignment {
        $other = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.assignment-absent -Set @{
            '0.id' = 2; '0.slug' = 'other'
        }
        # Intentionally invalid: an optional field must still use its documented enum when present.
        $other[0]['assignment'] = 'unknown'
        $roleStub.Assignments += $other

        { Get-OrganizationSecurityManagerState @target } | Should -Throw '*assignment classification*'
    }

    It 'assigns only the managed security_manager role and verifies the result' -Tag RoleWrite {
        $roleStub.Assignments = @()

        Set-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeTrue
        $roleStub.Writes.ToArray() | Should -Be @('PUT')
    }

    It 'accepts a pre-existing assignment without repeating PUT' -Tag RoleWrite {
        Set-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        $roleStub.Writes.Count | Should -Be 0
        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeTrue
    }

    It 'recovers a completed assignment without repeating PUT' -Tag RoleWrite {
        Set-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeTrue
        $roleStub.Writes.Count | Should -Be 0
    }

    It 'rejects a changed stored <Identity> before assigning' -Tag RoleWrite -ForEach @(
        @{ Identity = 'role'; RoleId = 8031; TeamId = 1 }
        @{ Identity = 'team'; RoleId = 8030; TeamId = 2 }
    ) {
        { Set-OrganizationSecurityManager @target -RoleId $RoleId -TeamId $TeamId } | Should -Throw '*identity changed*'
        $roleStub.Writes.Count | Should -Be 0
    }

    It 'rejects a PUT success response when the assignment was not applied' -Tag RoleWrite {
        $roleStub.Assignments = @()
        Mock -ModuleName Organizations Invoke-WebRequest {
            if (([string] $Method).ToUpperInvariant() -ceq 'PUT') { return [pscustomobject]@{ StatusCode = 204; Content = ''; Headers = @{} } }
            Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path ([Uri] $Uri).PathAndQuery
        }

        { Set-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 } | Should -Throw '*not assigned after PUT*'
    }

    It 'removes only the declared security_manager assignment and verifies the result' -Tag RoleRemove {
        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeFalse
        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
    }

    It 'removes a pre-existing assignment as declaratively managed state' -Tag RoleDeclarative, RoleRemove {
        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeFalse
        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
    }

    It 'recovers a completed removal without repeating DELETE' -Tag RoleRemove {
        $roleStub.Assignments = @()

        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        $roleStub.Writes.Count | Should -Be 0
        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeFalse
    }

    It 'rejects a changed stored <Identity> before removing' -Tag RoleRemove -ForEach @(
        @{ Identity = 'role'; RoleId = 8031; TeamId = 1 }
        @{ Identity = 'team'; RoleId = 8030; TeamId = 2 }
    ) {
        { Remove-OrganizationSecurityManager @target -RoleId $RoleId -TeamId $TeamId } | Should -Throw '*identity changed*'
        $roleStub.Writes.Count | Should -Be 0
    }

    It 'rejects a DELETE success response when the assignment was not removed' -Tag RoleRemove {
        Mock -ModuleName Organizations Invoke-WebRequest {
            if (([string] $Method).ToUpperInvariant() -ceq 'DELETE') { return [pscustomobject]@{ StatusCode = 204; Content = ''; Headers = @{} } }
            Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path ([Uri] $Uri).PathAndQuery
        }

        { Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 } | Should -Throw '*still assigned after DELETE*'
    }

    It 'accepts DELETE 404 only when the assignment is absent afterward' -Tag RoleRemove {
        Mock -ModuleName Organizations Invoke-WebRequest {
            $reply = Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path ([Uri] $Uri).PathAndQuery
            if (([string] $Method).ToUpperInvariant() -ceq 'DELETE') {
                $reply.StatusCode = 404
                $reply.Content = '{"message":"Not Found"}'
            }
            return $reply
        }

        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeFalse
        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
    }

    It 'preserves an unrelated team assignment while removing the declared assignment' -Tag RoleRemove {
        $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
            '0.id' = 2; '0.slug' = 'other'
        }

        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeFalse
        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
        $roleStub.Assignments.Count | Should -Be 1
        $roleStub.Assignments[0].slug | Should -BeExactly 'other'
    }
}
