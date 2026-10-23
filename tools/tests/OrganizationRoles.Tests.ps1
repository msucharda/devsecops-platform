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
                $assigned = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{
                    '0.id' = $roleStub.Team.id; '0.slug' = 'security'
                }
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

    It 'rejects a changed stored role before removing' -Tag RoleRemove {
        { Remove-OrganizationSecurityManager @target -RoleId 8031 -TeamId 1 } | Should -Throw '*role identity changed*'
        $roleStub.Writes.Count | Should -Be 0
    }

    It 'does nothing when the saved team ID is absent even if its old slug is reused' -Tag RoleRemove {
        $roleStub.Team.id = 99
        $roleStub.Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{
            '0.id' = 99; '0.slug' = 'security'
        }

        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        $roleStub.Writes.Count | Should -Be 0
        $roleStub.Assignments[0].id | Should -Be 99
    }

    It 'rejects a replacement team appearing before DELETE' -Tag RoleRemove {
        $roleStub.Team.id = 99

        { Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 } | Should -Throw '*team identity changed before removal*'
        $roleStub.Writes.Count | Should -Be 0
    }

    It 'removes the saved team after a rename without touching another team' -Tag RoleRemove {
        $roleStub.Team.slug = 'renamed-security'
        $roleStub.Assignments[0].slug = 'renamed-security'
        $roleStub.Assignments += Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
            '0.id' = 2; '0.slug' = 'other'
        }
        Mock -ModuleName Organizations Invoke-WebRequest {
            $address = [uri] $Uri
            if ($address.AbsolutePath -ceq '/orgs/demo-actions/teams/renamed-security') {
                return [pscustomobject]@{
                    StatusCode = 200; Headers = @{}
                    Content = (ConvertTo-Json -InputObject $roleStub.Team -Depth 30 -Compress)
                }
            }
            if (([string] $Method).ToUpperInvariant() -ceq 'DELETE') {
                $address.AbsolutePath | Should -BeExactly '/orgs/demo-actions/organization-roles/teams/renamed-security/8030'
                $roleStub.Writes.Add('DELETE')
                $roleStub.Assignments = @($roleStub.Assignments | Where-Object { $_.id -ne 1 })
                return [pscustomobject]@{ StatusCode = 204; Content = ''; Headers = @{} }
            }
            Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path $address.PathAndQuery
        }

        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
        $roleStub.Assignments.Count | Should -Be 1
        $roleStub.Assignments[0].id | Should -Be 2
    }

    It 'detects a replacement created after the final team lookup and explains guarded recovery' -Tag RoleReplacementRace, RoleRemove {
        $roleStub.ReplacementCreated = $false
        Mock -ModuleName Organizations Invoke-WebRequest {
            $address = [uri] $Uri
            $reply = Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path $address.PathAndQuery
            if ($address.AbsolutePath -ceq '/orgs/demo-actions/teams/security' -and -not $roleStub.ReplacementCreated) {
                # A concurrent actor replaces the team after the server produced the valid lookup response.
                $roleStub.Team.id = 99
                $roleStub.Assignments = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-null -Set @{
                    '0.id' = 99; '0.slug' = 'security'
                }
                $roleStub.ReplacementCreated = $true
            }
            return $reply
        }

        $failure = { Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 } |
            Should -Throw '*security team identity changed after DELETE*' -PassThru

        $failure.Exception.Message | Should -Match 'original_team_id=1; new_team_id=99; slug=security; role_id=8030'
        $failure.Exception.Message | Should -Match 'Stop concurrent team lifecycle changes'
        $failure.Exception.Message | Should -Match 'REST_API_BEARER'
        $failure.Exception.Message | Should -Match ([regex]::Escape("Set-OrganizationSecurityManager -ApiUrl '$($target.ApiUrl)' -Organization 'demo-actions' -Team 'security' -RoleId 8030 -TeamId 99"))
        $roleStub.Writes.ToArray() | Should -Be @('DELETE')

        # Recovery is an explicit caller action, not part of the failed removal.
        Set-OrganizationSecurityManager @target -RoleId 8030 -TeamId 99

        $roleStub.Writes.ToArray() | Should -Be @('DELETE', 'PUT')
        (Get-OrganizationSecurityManagerState @target).team_id | Should -Be 99
        (Get-OrganizationSecurityManagerState @target).assigned | Should -BeTrue
    }

    It 'accepts confirmed team disappearance after DELETE without restoring any role' -Tag RoleRemove {
        Mock -ModuleName Organizations Invoke-WebRequest {
            $address = [uri] $Uri
            if ($address.AbsolutePath -ceq '/orgs/demo-actions/teams/security' -and $roleStub.Writes.Count -gt 0) {
                return [pscustomobject]@{
                    StatusCode = 404; Headers = @{}
                    Content = (ConvertTo-Json -InputObject (Get-GitHubApiFixture -Name org-roles/get-by-name.not-found) -Depth 30 -Compress)
                }
            }
            Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path $address.PathAndQuery
        }

        Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

        $roleStub.Writes.ToArray() | Should -Be @('DELETE')
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

    It 'rejects an incomplete assignment listing with unreadable pagination before no-op' -Tag RolePagination {
        Mock -ModuleName Organizations Invoke-WebRequest {
            if (([uri] $Uri).AbsolutePath -ceq '/orgs/demo-actions/organization-roles/8030/teams') {
                $page = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                    '0.id' = 2; '0.slug' = 'other'
                }
                # Intentionally invalid metadata cannot prove this partial page is complete.
                return [pscustomobject]@{
                    StatusCode = 200
                    Content = (ConvertTo-Json -InputObject $page -Depth 30 -Compress)
                    Headers = @{ Link = 'unreadable pagination' }
                }
            }
            Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path ([uri] $Uri).PathAndQuery
        }

        { Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 } | Should -Throw '*unreadable pagination*'
        $roleStub.Writes.Count | Should -Be 0
    }

    Context 'Assignment pagination' -Tag RolePagination {
        BeforeEach {
            $roleStub.Page2Url = "$($target.ApiUrl)/orgs/demo-actions/organization-roles/8030/teams?per_page=100&page=2"
            $roleStub.PageLink = "<$($roleStub.Page2Url)>; rel=`"next`", <$($roleStub.Page2Url)>; rel=`"last`""
            $roleStub.Page2Status = 200
            $roleStub.InvalidPage2 = $false
            $roleStub.PagesRead = [Collections.Generic.List[string]]::new()
            $roleStub.OtherAssignment = Get-GitHubApiFixture -Name org-roles/list-org-role-teams.organization.parent-object -Set @{
                '0.id' = 2; '0.slug' = 'other'
            }
            Mock -ModuleName Organizations Invoke-WebRequest {
                $address = [uri] $Uri
                if ($address.AbsolutePath -ceq '/orgs/demo-actions/organization-roles/8030/teams') {
                    $roleStub.PagesRead.Add($address.Query)
                    # A broken cycle guard must fail instead of hanging its mutation worker.
                    if ($roleStub.PagesRead.Count -gt 5) {
                        throw 'The client exceeded the test transport request budget.'
                    }
                    if ($address.Query -match '[?&]page=2(?:&|$)') {
                        # A scalar page is intentionally invalid for this list endpoint.
                        $page = if ($roleStub.InvalidPage2) { 'unreadable' } else { , @($roleStub.Assignments | Where-Object { $_.id -eq 1 }) }
                        return [pscustomobject]@{
                            StatusCode = $roleStub.Page2Status
                            Content = (ConvertTo-Json -InputObject $page -Depth 30 -Compress)
                            Headers = @{ Link = "<$($target.ApiUrl)/orgs/demo-actions/organization-roles/8030/teams?per_page=100>; rel=`"first`", <$($target.ApiUrl)/orgs/demo-actions/organization-roles/8030/teams?per_page=100>; rel=`"prev`"" }
                        }
                    }
                    return [pscustomobject]@{
                        StatusCode = 200
                        Content = (ConvertTo-Json -InputObject $roleStub.OtherAssignment -Depth 30 -Compress)
                        Headers = @{ Link = $roleStub.PageLink }
                    }
                }
                Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path $address.PathAndQuery
            }
        }

        It 'reads all assignment pages before DELETE and again to verify removal' {
            Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

            $roleStub.Writes.ToArray() | Should -Be @('DELETE')
            @($roleStub.PagesRead | Where-Object { $_ -match '[?&]page=2(?:&|$)' }).Count | Should -Be 2
            $roleStub.Assignments.Count | Should -Be 0
        }

        It 'verifies all assignment pages before accepting absence without DELETE' {
            $roleStub.Assignments = $roleStub.OtherAssignment

            Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

            $roleStub.PagesRead.Count | Should -Be 2
            $roleStub.Writes.Count | Should -Be 0
            $roleStub.Assignments[0].id | Should -Be 2
        }

        It 'follows next across separate Link header values' {
            $roleStub.PageLink = @("<$($roleStub.Page2Url)>; rel=`"next`"", "<$($roleStub.Page2Url)>; rel=`"last`"")

            Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

            $roleStub.Writes.ToArray() | Should -Be @('DELETE')
        }

        It 'follows a case-insensitive registered next relation instead of accepting a partial page' {
            $roleStub.PageLink = "<$($roleStub.Page2Url)>; rel=`"NEXT`""

            Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1

            $roleStub.Writes.ToArray() | Should -Be @('DELETE')
        }

        It 'rejects an incomplete assignment listing with <Case> before no-op' -ForEach @(
            @{ Case = 'blank Link'; Link = ''; ErrorPattern = '*unreadable pagination*' }
            @{ Case = 'non-string Link'; Link = 1; ErrorPattern = '*unreadable pagination*' }
            @{ Case = 'empty Link collection'; Link = @(); ErrorPattern = '*unreadable pagination*' }
            @{ Case = 'unsupported relation'; Link = '<https://api.example.ghe.com/next>; rel="unknown"'; ErrorPattern = '*unreadable pagination*' }
            @{ Case = 'foreign origin'; Link = '<https://other.invalid/next>; rel="next"'; ErrorPattern = '*pagination link outside*' }
            @{ Case = 'URL fragment'; Link = '<https://api.example.ghe.com/next#fragment>; rel="next"'; ErrorPattern = '*unreadable pagination target*' }
            @{ Case = 'duplicate next links'; Link = '<https://api.example.ghe.com/next>; rel="next", <https://api.example.ghe.com/another>; rel="next"'; ErrorPattern = '*multiple next-page links*' }
            @{ Case = 'cyclic next link'; Link = '<https://api.example.ghe.com/orgs/demo-actions/organization-roles/8030/teams?per_page=100>; rel="next"'; ErrorPattern = '*cyclic pagination link*' }
        ) {
            # Intentionally invalid pagination metadata cannot prove the first page is complete.
            $roleStub.PageLink = $Link

            { Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 } | Should -Throw $ErrorPattern
            $roleStub.Writes.Count | Should -Be 0
        }

        It 'rejects an incomplete assignment listing when the next page fails' {
            $roleStub.Page2Status = 500

            { Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 } | Should -Throw '*HTTP 500*'
            $roleStub.Writes.Count | Should -Be 0
        }

        It 'rejects an incomplete assignment listing when the next page has no array' {
            $roleStub.InvalidPage2 = $true

            { Remove-OrganizationSecurityManager @target -RoleId 8030 -TeamId 1 } | Should -Throw '*no JSON array*'
            $roleStub.Writes.Count | Should -Be 0
        }
    }

    Context 'Team lookup absence' {
        BeforeEach {
            $roleStub.TeamStatus = 404
            $roleStub.TeamBody = Get-GitHubApiFixture -Name org-roles/get-by-name.not-found
            Mock -ModuleName Organizations Invoke-WebRequest {
                if (([uri] $Uri).AbsolutePath -ceq '/orgs/demo-actions/teams/security') {
                    return [pscustomobject]@{
                        StatusCode = $roleStub.TeamStatus
                        Content = (ConvertTo-Json -InputObject $roleStub.TeamBody -Depth 30 -Compress)
                        Headers = @{}
                    }
                }
                Invoke-RoleApiStub -Method ([string] $Method).ToUpperInvariant() -Path ([uri] $Uri).PathAndQuery
            }
        }

        It 'reports documented team absence only when explicitly allowed' {
            $state = Get-OrganizationSecurityManagerState @target -AllowMissingTeam

            $state.role_id | Should -Be 8030
            $state.team_id | Should -BeNullOrEmpty
            $state.assigned | Should -BeFalse
        }

        It 'rejects documented team absence in the strict team lookup' {
            { Get-OrganizationSecurityManagerState @target } | Should -Throw '*HTTP 404*'
        }

        It 'rejects unsupported HTTP <Status> instead of treating a team lookup as absence' -ForEach @(
            @{ Status = 403 }
            @{ Status = 500 }
        ) {
            # Intentionally unsupported responses: only the documented 404 denotes absence.
            $roleStub.TeamStatus = $Status

            { Get-OrganizationSecurityManagerState @target -AllowMissingTeam } | Should -Throw "*HTTP $Status*"
        }

        It 'rejects an unreadable successful team lookup even when absence is allowed' {
            # Intentionally invalid: a successful team-full response cannot be an array.
            $roleStub.TeamStatus = 200
            $roleStub.TeamBody = @()

            { Get-OrganizationSecurityManagerState @target -AllowMissingTeam } | Should -Throw '*security team*unreadable*'
        }

        It 'rejects an unreadable not-found team lookup: <Case>' -ForEach @(
            @{ Case = 'array'; Body = @() }
            @{ Case = 'null'; Body = $null }
            @{ Case = 'scalar'; Body = 'unreadable' }
        ) {
            # Intentionally invalid: the documented basic-error response is an object.
            $roleStub.TeamBody = $Body

            { Get-OrganizationSecurityManagerState @target -AllowMissingTeam } | Should -Throw '*not-found response is unreadable*'
        }
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
