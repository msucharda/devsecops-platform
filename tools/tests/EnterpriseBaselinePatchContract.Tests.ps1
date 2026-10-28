BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $moduleRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/enterprise-baseline'
    $root = Join-Path $TestDrive 'modules/enterprise-baseline'
    New-Item -ItemType Directory -Path $root -Force | Out-Null
    Copy-Item -Path (Join-Path $moduleRoot '*.tf'), (Join-Path $moduleRoot '.terraform.lock.hcl'),
        (Join-Path $moduleRoot 'organization-patch-allowlist.json') -Destination $root
    Copy-Item -LiteralPath (Join-Path $moduleRoot 'scripts'), (Join-Path $moduleRoot 'tests') -Destination $root -Recurse
    Copy-Item -LiteralPath (Join-Path $moduleRoot '../shared') -Destination (Split-Path $root -Parent) -Recurse
    $fixtureDirectory = Join-Path $TestDrive 'tools/tests/fixtures/github-api/orgs'
    New-Item -ItemType Directory -Path $fixtureDirectory -Force | Out-Null
    Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/github-api/orgs/get.json') -Destination $fixtureDirectory
    $mainPath = Join-Path $root 'main.tf'
    $allowListPath = Join-Path $root 'organization-patch-allowlist.json'
    $originalMain = Get-Content -LiteralPath $mainPath -Raw
    $originalAllowList = Get-Content -LiteralPath $allowListPath -Raw

    function Invoke-PatchContract {
        $testFile = Join-Path 'tests' 'organization_patch_contract.tftest.hcl'
        $output = & terraform "-chdir=$root" test "-filter=$testFile" -no-color 2>&1 | Out-String
        [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output }
    }

    $output = & terraform "-chdir=$root" init -backend=false -input=false -no-color 2>&1 | Out-String
    if ($LASTEXITCODE -ne 0) { throw "Terraform init failed: $output" }
}

Describe 'enterprise-baseline offline PATCH allow-list' -Tag 'Terraform' {
    BeforeEach {
        Set-Content -LiteralPath $mainPath -Value $originalMain -NoNewline
        Set-Content -LiteralPath $allowListPath -Value $originalAllowList -NoNewline
    }

    It 'accepts the documented apply and destroy payloads with explicit reasons' {
        $result = Invoke-PatchContract
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match '1 passed, 0 failed'
    }

    It 'records an explicit disposition for every enterprise-policy candidate' {
        $allowList = $originalAllowList | ConvertFrom-Json -AsHashtable
        $allowList.apiVersion | Should -BeExactly '2026-03-10'
        $allowList.documentation | Should -BeExactly 'https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/orgs#update-an-organization'
        $candidates = @(
            'default_repository_permission'
            'members_can_create_repositories'
            'members_can_create_public_repositories'
            'members_can_create_private_repositories'
            'members_can_create_internal_repositories'
            'members_can_fork_private_repositories'
            'has_organization_projects'
            'has_repository_projects'
            'deploy_keys_enabled_for_repositories'
        )
        $documented = (Get-GitHubApiFixtureContract -Name orgs/update).requestProperties
        foreach ($group in @($allowList.allowedFields, $allowList.omittedEnterpriseFields)) {
            foreach ($field in $group.get_Keys()) {
                $documented | Should -Contain $field
                $group[$field] | Should -BeOfType [string]
                $group[$field].Trim() | Should -Not -BeNullOrEmpty
            }
        }
        foreach ($field in $candidates) {
            @($allowList.allowedFields.get_Keys() + $allowList.omittedEnterpriseFields.get_Keys() |
                Where-Object { $_ -ceq $field }).Count | Should -Be 1 -Because "'$field' must be either allowed or omitted, never both"
        }
    }

    It 'rejects a payload mutation without an allow-list entry: <Map>' -ForEach @(
        @{ Map = 'organization_settings' }
        @{ Map = 'github_defaults' }
    ) {
        # A documented PATCH field deliberately added without an allow-list entry.
        $mutated = $originalMain.Replace("jsonencode(local.$Map)", "jsonencode(merge(local.$Map, { has_organization_projects = false }))")
        $mutated | Should -Not -BeExactly $originalMain
        Set-Content -LiteralPath $mainPath -Value $mutated -NoNewline

        $result = Invoke-PatchContract
        $result.ExitCode | Should -Not -Be 0 -Because 'adding a field must fail the same Terraform contract used by CI'
        $result.Output | Should -Match 'PATCH payload fields must have a nonempty reason in the explicit allow-list'
    }

    It 'rejects an unreadable allow-list: <Case>' -ForEach @(
        @{ Case = 'missing file' }
        @{ Case = 'malformed JSON' }
    ) {
        if ($Case -ceq 'missing file') { Remove-Item -LiteralPath $allowListPath }
        else { Set-Content -LiteralPath $allowListPath -Value '{' }

        $result = Invoke-PatchContract
        $result.ExitCode | Should -Not -Be 0 -Because 'an unreadable allow-list must fail closed'
        $result.Output | Should -Match 'PATCH payload fields must have a nonempty reason in the explicit allow-list'
    }

    It 'rejects an empty payload: <Map>' -ForEach @(
        @{ Map = 'organization_settings' }
        @{ Map = 'github_defaults' }
    ) {
        $mutated = $originalMain.Replace("jsonencode(local.$Map)", 'jsonencode({})')
        $mutated | Should -Not -BeExactly $originalMain
        Set-Content -LiteralPath $mainPath -Value $mutated -NoNewline

        $result = Invoke-PatchContract
        $result.ExitCode | Should -Not -Be 0 -Because 'an empty payload must not satisfy the allow-list vacuously'
        $result.Output | Should -Match 'PATCH payload fields must have a nonempty reason in the explicit allow-list'
    }

    It 'rejects an allowed candidate without a reason: <Case>' -ForEach @(
        @{ Case = 'missing entry'; Mode = 'remove' }
        @{ Case = 'empty reason'; Mode = 'empty' }
        @{ Case = 'whitespace reason'; Mode = 'whitespace' }
        @{ Case = 'null reason'; Mode = 'null' }
        @{ Case = 'non-string reason'; Mode = 'boolean' }
    ) {
        $allowList = $originalAllowList | ConvertFrom-Json -AsHashtable
        switch ($Mode) {
            'remove' { $allowList.allowedFields.Remove('default_repository_permission') }
            'empty' { $allowList.allowedFields.default_repository_permission = '' }
            'whitespace' { $allowList.allowedFields.default_repository_permission = " `t " }
            'null' { $allowList.allowedFields.default_repository_permission = $null }
            'boolean' { $allowList.allowedFields.default_repository_permission = $true }
        }
        Set-Content -LiteralPath $allowListPath -Value ($allowList | ConvertTo-Json -Depth 10)

        $result = Invoke-PatchContract
        $result.ExitCode | Should -Not -Be 0 -Because 'a candidate without justification must fail closed'
        $result.Output | Should -Match 'PATCH payload fields must have a nonempty reason in the explicit allow-list'
    }
}
