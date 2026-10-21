BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PlatformTools.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force

    function Get-SimpleUserOwner {
        (Get-GitHubApiFixture -Name apps/get-app.owner-simple-user -Set @{ 'owner.login' = 'example'; 'owner.type' = 'enterprise' }).owner
    }

    function Get-EnterpriseOwner {
        (Get-GitHubApiFixture -Name apps/get-app.owner-enterprise -Set @{ 'owner.slug' = 'example' }).owner
    }
}

Describe 'Test-PlatformGitHubAppOwner' {
    Context 'GET /app owner oneOf[0] simple-user' {
        It 'accepts the observed enterprise owner with type <Type> and login <Login>' -ForEach @(
            @{ Type = 'enterprise'; Login = 'example' }
            @{ Type = 'Enterprise'; Login = 'example' }
            @{ Type = 'enterprise'; Login = 'Example' }
        ) {
            $owner = Get-SimpleUserOwner
            $owner['type'] = $Type
            $owner['login'] = $Login

            Test-PlatformGitHubAppOwner -Owner $owner -Enterprise example | Should -BeTrue
        }

        It 'rejects a simple-user owner with <Case>' -ForEach @(
            @{ Case = 'another login'; Change = { param($Owner) $Owner['login'] = 'another' } }
            @{ Case = 'an empty login'; Change = { param($Owner) $Owner['login'] = '' } }
            @{ Case = 'a null login'; Change = { param($Owner) $Owner['login'] = $null } }
            # Intentionally invalid: login is a string in the simple-user schema.
            @{ Case = 'a login array'; Change = { param($Owner) $Owner['login'] = @('example') } }
            @{ Case = 'type User'; Change = { param($Owner) $Owner['type'] = 'User' } }
            @{ Case = 'type Organization'; Change = { param($Owner) $Owner['type'] = 'Organization' } }
            @{ Case = 'an empty type'; Change = { param($Owner) $Owner['type'] = '' } }
            @{ Case = 'a missing type'; Change = { param($Owner) $Owner.Remove('type') } }
            # Intentionally invalid: type is a string in the simple-user schema.
            @{ Case = 'a type array'; Change = { param($Owner) $Owner['type'] = @('enterprise') } }
            @{ Case = 'a missing id'; Change = { param($Owner) $Owner.Remove('id') } }
            @{ Case = 'a zero id'; Change = { param($Owner) $Owner['id'] = 0 } }
            # Intentionally invalid: id is an integer in the simple-user schema.
            @{ Case = 'a string id'; Change = { param($Owner) $Owner['id'] = '1' } }
            @{ Case = 'a missing node_id'; Change = { param($Owner) $Owner.Remove('node_id') } }
            @{ Case = 'an empty node_id'; Change = { param($Owner) $Owner['node_id'] = '' } }
        ) {
            $owner = Get-SimpleUserOwner
            & $Change $owner

            Test-PlatformGitHubAppOwner -Owner $owner -Enterprise example | Should -BeFalse
        }
    }

    Context 'GET /app owner oneOf[1] enterprise' {
        It 'accepts the documented Enterprise variant' {
            Test-PlatformGitHubAppOwner -Owner (Get-EnterpriseOwner) -Enterprise example | Should -BeTrue
        }

        It 'rejects an Enterprise owner with <Case>' -ForEach @(
            @{ Case = 'another slug'; Change = { param($Owner) $Owner['slug'] = 'another' } }
            @{ Case = 'a slug in different case'; Change = { param($Owner) $Owner['slug'] = 'Example' } }
            @{ Case = 'an empty slug'; Change = { param($Owner) $Owner['slug'] = '' } }
            @{ Case = 'a missing slug'; Change = { param($Owner) $Owner.Remove('slug') } }
            # Intentionally invalid: slug is a string in the enterprise schema.
            @{ Case = 'a slug array'; Change = { param($Owner) $Owner['slug'] = @('example') } }
            # Intentionally invalid: the enterprise schema has no type; a type mixes both variants.
            @{ Case = 'an extra type'; Change = { param($Owner) $Owner['type'] = 'enterprise' } }
            @{ Case = 'a missing id'; Change = { param($Owner) $Owner.Remove('id') } }
            @{ Case = 'a zero id'; Change = { param($Owner) $Owner['id'] = 0 } }
            @{ Case = 'a negative id'; Change = { param($Owner) $Owner['id'] = -42 } }
            # Intentionally invalid: id is an integer in the enterprise schema.
            @{ Case = 'a string id'; Change = { param($Owner) $Owner['id'] = '42' } }
            # Intentionally invalid: id is an integer in the enterprise schema.
            @{ Case = 'an id array'; Change = { param($Owner) $Owner['id'] = @(42) } }
            @{ Case = 'a missing node_id'; Change = { param($Owner) $Owner.Remove('node_id') } }
            @{ Case = 'an empty node_id'; Change = { param($Owner) $Owner['node_id'] = '' } }
            @{ Case = 'a whitespace node_id'; Change = { param($Owner) $Owner['node_id'] = ' ' } }
            # Intentionally invalid: node_id is a string in the enterprise schema.
            @{ Case = 'a node_id array'; Change = { param($Owner) $Owner['node_id'] = @('MDEwOlJlcG9zaXRvcnkxMjk2MjY5') } }
        ) {
            $owner = Get-EnterpriseOwner
            & $Change $owner

            Test-PlatformGitHubAppOwner -Owner $owner -Enterprise example | Should -BeFalse
        }
    }

    Context 'Unknown owner shape' {
        # Intentionally invalid owners that match no documented variant.
        It 'rejects <Case>' -ForEach @(
            @{ Case = 'no owner'; Owner = $null }
            @{ Case = 'a string owner'; Owner = 'example' }
            @{ Case = 'an owner array'; Owner = @(@{ login = 'example'; type = 'enterprise' }) }
            @{ Case = 'an empty owner'; Owner = @{} }
            @{ Case = 'login and type without identifiers'; Owner = @{ login = 'example'; type = 'enterprise' } }
            @{ Case = 'a slug without identifiers'; Owner = @{ slug = 'example' } }
        ) {
            Test-PlatformGitHubAppOwner -Owner $Owner -Enterprise example | Should -BeFalse
        }
    }
}
