BeforeDiscovery {
    $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/microsoft-api'
    $fixtureCases = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File -Filter '*.json' | ForEach-Object {
        @{ Name = [IO.Path]::ChangeExtension([IO.Path]::GetRelativePath($fixtureRoot, $_.FullName), $null).TrimEnd('.').Replace('\', '/') }
    })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'MicrosoftApiFixture.psm1') -Force
    $toolRoot = Split-Path $PSScriptRoot -Parent
    $toolText = (Get-ChildItem -LiteralPath $toolRoot -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') } |
        ForEach-Object { Get-Content -LiteralPath $_.FullName -Raw }) -join "`n"
}

Describe 'Microsoft API contract fixture <Name>' -ForEach $fixtureCases {
    BeforeAll {
        $contract = Get-MicrosoftApiFixtureContract -Name $Name
    }

    It 'cites the primary Microsoft Learn documentation and the API version the tools send' {
        $contract.source.operation | Should -Match '^(GET|POST|PUT|PATCH|DELETE) /\S+'
        $contract.source.documentation | Should -Match '^https://learn\.microsoft\.com/en-us/(graph|rest/api)/\S+#\S+$'
        $contract.source.schema | Should -Match '^https://learn\.microsoft\.com/en-us/(graph|rest/api)/\S+$'
        $contract.source.status | Should -BeOfType [long]
        if ($contract.source.api -ceq 'Microsoft Graph') {
            $contract.source.apiVersion | Should -Be 'v1.0'
            $contract.source.documentation | Should -BeLike '*view=graph-rest-1.0*'
            $toolText | Should -Match ([regex]::Escape('https://graph.microsoft.com/v1.0'))
        }
        else {
            $contract.source.api | Should -Be 'Azure Resource Manager'
            $contract.source.apiVersion | Should -Match '^\d{4}-\d{2}-\d{2}(-preview)?$'
            $toolText | Should -Match ([regex]::Escape("api-version=$($contract.source.apiVersion)"))
        }
    }

    It 'contains every documented field the tools read' {
        $contract.required.Count | Should -BeGreaterThan 0
        foreach ($path in $contract.required.Keys) {
            $nodes = @(Get-MicrosoftApiFixtureNode -Body $contract.body -Path $path)
            $nodes.Count | Should -BeGreaterThan 0 -Because "required path '$path' must resolve in the body"
            foreach ($node in $nodes) {
                $node | Should -BeOfType [System.Collections.IDictionary] -Because "required path '$path' must be an object"
                foreach ($field in $contract.required[$path]) {
                    $node.Contains($field) | Should -BeTrue -Because "'$path' requires '$field'"
                }
            }
        }
    }
}

Describe 'Microsoft API fixture access' {
    It 'returns a fresh copy and overrides documented fields including dotted OData names' {
        $first = Get-MicrosoftApiFixture -Name graph/user-get
        $first.id = 'changed'
        (Get-MicrosoftApiFixture -Name graph/user-get).id | Should -Not -Be 'changed'
        $page = Get-MicrosoftApiFixture -Name graph/serviceprincipal-list-approleassignedto.next-page -Set @{
            '@odata.nextLink' = 'https://graph.microsoft.com/v1.0/next'
            'value.0.principalId' = 'user'
        }
        $page['@odata.nextLink'] | Should -Be 'https://graph.microsoft.com/v1.0/next'
        $page.value[0].principalId | Should -Be 'user'
    }

    It 'refuses to add a field that the documented fixture does not contain' {
        { Get-MicrosoftApiFixture -Name graph/user-get -Set @{ 'manager.id' = 'x' } } |
            Should -Throw "*'manager.id'*not part of the documented fixture*"
    }

    It 'refuses an unknown fixture' {
        { Get-MicrosoftApiFixture -Name graph/unknown } | Should -Throw '*Microsoft API fixture*graph/unknown*'
    }
}
