BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PlatformTools.psm1') -Force
}

Describe 'Supported bootstrap request policy' {
    It 'rejects <Method> before the caller transport in no-change mode' -ForEach @(
        @{ Method = 'POST' }, @{ Method = 'PUT' }, @{ Method = 'PATCH' }, @{ Method = 'DELETE' }
    ) {
        { Assert-PlatformBootstrapRequest -Uri 'https://example.invalid/resource' -Method $Method -NoChanges } |
            Should -Throw '*NoChanges refuses*'
    }
    It 'does not let an approving callback override no-change enforcement' {
        { Assert-PlatformBootstrapRequest -Uri 'https://example.invalid/resource' -Method PUT -NoChanges -RequestPolicy { $true } } |
            Should -Throw '*NoChanges refuses*'
    }
    It 'allows a read-only POST in no-change mode only for the exact POST method' {
        { Assert-PlatformBootstrapRequest -Uri 'https://example.invalid/graphql' -Method POST -NoChanges -ReadOnlyPost } | Should -Not -Throw
        { Assert-PlatformBootstrapRequest -Uri 'https://example.invalid/resource' -Method GET -NoChanges } | Should -Not -Throw
    }
    It 'rejects <Method> in no-change mode even for a read-only POST request' -ForEach @(
        @{ Method = 'PUT' }, @{ Method = 'DELETE' }, @{ Method = 'post' }, @{ Method = 'get' }
    ) {
        { Assert-PlatformBootstrapRequest -Uri 'https://example.invalid/resource' -Method $Method -NoChanges -ReadOnlyPost } |
            Should -Throw '*NoChanges refuses*'
    }
    It 'requires exactly one boolean true from the request supervisor (<Case>)' -ForEach @(
        @{ Case = 'empty'; Policy = {} }
        @{ Case = 'false'; Policy = { $false } }
        @{ Case = 'string'; Policy = { 'true' } }
        @{ Case = 'multiple'; Policy = { $true; $true } }
    ) {
        { Assert-PlatformBootstrapRequest -Uri 'https://example.invalid/resource' -Method GET -RequestPolicy $Policy } |
            Should -Throw '*did not authorize*'
    }
    It 'exposes operation metadata but not authorization headers or tokens' {
        $policy = {
            param($Operation)
            @($Operation.PSObject.Properties.Name | Sort-Object) | Should -Be @('Body', 'Kind', 'Method', 'Uri')
            $Operation.Kind | Should -BeExactly 'TokenIssue'
            return $true
        }
        { Assert-PlatformBootstrapRequest -Uri 'https://example.invalid/access_tokens' -Method POST `
            -Kind TokenIssue -Body @{ permissions = @{ members = 'read' } } -RequestPolicy $policy } | Should -Not -Throw
    }
}
