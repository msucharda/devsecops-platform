BeforeDiscovery {
    $fixtureRoot = Join-Path $PSScriptRoot 'fixtures/github-api'
    $fixtureCases = @(Get-ChildItem -LiteralPath $fixtureRoot -Recurse -File -Filter '*.json' | ForEach-Object {
        @{ Name = [IO.Path]::ChangeExtension([IO.Path]::GetRelativePath($fixtureRoot, $_.FullName), $null).TrimEnd('.').Replace('\', '/') }
    })
}

BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $toolRoot = Split-Path $PSScriptRoot -Parent
    $sentApiVersions = @(Get-ChildItem -LiteralPath $toolRoot -File | Where-Object { $_.Extension -in @('.ps1', '.psm1') } |
        Select-String -Pattern "'X-GitHub-Api-Version'\s*=\s*'([0-9]{4}-[0-9]{2}-[0-9]{2})'" |
        ForEach-Object { $_.Matches[0].Groups[1].Value } | Sort-Object -Unique)
}

Describe 'GitHub API contract fixture <Name>' -ForEach $fixtureCases {
    BeforeAll {
        $contract = Get-GitHubApiFixtureContract -Name $Name
    }

    It 'cites the primary GraphQL documentation and the pinned schema' -Skip:(-not $Name.StartsWith('graphql/')) {
        $contract.source.operation | Should -Match '^(query|mutation) [A-Za-z]+(\([a-zA-Z:,]*\))?$'
        $contract.source.documentation | Should -Match '^https://docs\.github\.com/en/enterprise-cloud@latest/graphql/reference/(queries|mutations)#[a-z]+$'
        $contract.source.description | Should -Match '^https://github\.com/github/docs/blob/[0-9a-f]{40}/src/graphql/data/ghec/schema\.docs\.graphql$'
        $contract.source.status | Should -Be 200
        $contract.source.schema | Should -Not -BeNullOrEmpty
        $contract.body.Contains('data') | Should -BeTrue -Because 'every GraphQL response contains data'
        if ($contract.body.Contains('errors')) {
            $contract.source.errors | Should -Be 'https://spec.graphql.org/October2021/#sec-Errors'
        }
    }

    It 'cites the primary documentation and the API version the tools send' -Skip:($Name.StartsWith('graphql/')) {
        $contract.source.operation | Should -Match '^(GET|POST|PUT|PATCH|DELETE) /\S+$'
        $contract.source.operationId | Should -Match '^[a-z-]+/[a-z0-9-]+$'
        $contract.source.documentation | Should -Match '^https://docs\.github\.com/en/enterprise-cloud@latest/rest/\S+#\S+$'
        $contract.source.description | Should -Match '^https://github\.com/github/rest-api-description/blob/[0-9a-f]{40}/descriptions/ghec/ghec\.\d{4}-\d{2}-\d{2}\.json$'
        $contract.source.description | Should -BeLike "*/ghec.$($contract.source.apiVersion).json"
        $contract.source.apiVersion | Should -BeIn $sentApiVersions
        $contract.source.status | Should -BeOfType [long]
        $contract.source.schema | Should -Not -BeNullOrEmpty
    }

    It 'contains every field the documented schema requires' {
        $contract.required.Count | Should -BeGreaterThan 0
        foreach ($path in $contract.required.Keys) {
            $nodes = @(Get-GitHubApiFixtureNode -Body $contract.body -Path $path)
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

Describe 'GitHub API fixture access' {
    It 'returns a fresh copy of the documented body for every call' {
        $first = Get-GitHubApiFixture -Name apps/get-app.owner-simple-user
        $first.owner.login = 'changed'
        (Get-GitHubApiFixture -Name apps/get-app.owner-simple-user).owner.login | Should -Not -Be 'changed'
    }

    It 'overrides documented fields by path, including array items' {
        $app = Get-GitHubApiFixture -Name apps/get-app.owner-simple-user -Set @{ id = 101; 'owner.login' = 'example' }
        $app.id | Should -Be 101
        $app.owner.login | Should -Be 'example'
        $installations = Get-GitHubApiFixture -Name apps/list-installations -Set @{ '0.account.login' = 'platform' }
        $installations -is [array] | Should -BeTrue
        $installations[0].account.login | Should -Be 'platform'
    }

    It 'refuses to add a field that the documented fixture does not contain' {
        { Get-GitHubApiFixture -Name apps/get-app.owner-enterprise -Set @{ 'owner.login' = 'example' } } |
            Should -Throw "*'owner.login'*not part of the documented fixture*"
    }

    It 'refuses an unknown fixture' {
        { Get-GitHubApiFixture -Name apps/unknown } | Should -Throw '*GitHub API fixture*apps/unknown*'
    }
}
