BeforeAll {
    $tools = Split-Path $PSScriptRoot -Parent
    $guard = Join-Path $tools 'Test-DevelopmentProtectedState.ps1'
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $ast = [Management.Automation.Language.Parser]::ParseFile($guard, [ref] $null, [ref] $null)
    foreach ($definition in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] }, $false)) {
        . ([scriptblock]::Create($definition.Extent.Text))
    }
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $privateKey = $rsa.ExportRSAPrivateKeyPem()
    $rsa.Dispose()
}

Describe 'Protected state context' {
    BeforeEach {
        $context = @{
            Reference = 'https://example.test/platform/instance'; Server = 'https://example.test'
            Api = 'https://api.example.test'; Name = 'platform/instance'; Attempt = '1'
        }
    }
    It 'accepts only the exact current reference and Cloud API' {
        { Assert-DevelopmentProtectedContext @context } | Should -Not -Throw
    }
    It 'rejects changed <Field>: <Value>' -ForEach @(
        @{ Field = 'Name'; Value = 'platform/instance/extra' }
        @{ Field = 'Server'; Value = 'http://example.test' }
        @{ Field = 'Server'; Value = 'https://example.test:444' }
        @{ Field = 'Server'; Value = 'https://user@example.test' }
        @{ Field = 'Server'; Value = 'https://example.test?query' }
        @{ Field = 'Server'; Value = 'https://example.test#fragment' }
        @{ Field = 'Server'; Value = 'https://example.test/path' }
        @{ Field = 'Api'; Value = 'https://api.other.test' }
        @{ Field = 'Api'; Value = 'https://API.example.test' }
        @{ Field = 'Reference'; Value = 'https://example.test/platform/other' }
        @{ Field = 'Reference'; Value = 'https://example.test/Platform/instance' }
        @{ Field = 'Attempt'; Value = '2' }
    ) {
        $context[$Field] = $Value
        if ($Field -in @('Server', 'Name')) {
            $context.Reference = "$($context.Server)/$($context.Name)"
            $context.Api = "https://api.$(([uri] $context.Server).DnsSafeHost)"
        }
        { Assert-DevelopmentProtectedContext @context } | Should -Throw
    }
}

Describe 'Protected variable snapshot' {
    # Negative cases deliberately violate the pinned list-environment-variables response schema.
    BeforeEach {
        $responseBody = Get-GitHubApiFixture -Name actions/list-environment-variables
        $status = 200
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $status; Content = ConvertTo-Json -InputObject $responseBody -Depth 30 } }
    }
    It 'reads one complete protected snapshot without redirects or retries' {
        $responseBody.variables[0].name = 'PLATFORM_REFERENCE_REPOSITORY'
        $responseBody.variables[0].value = 'https://example.test/platform/instance'
        $responseBody.variables[1].name = 'PLATFORM_DEVELOPMENT_APPROVAL'
        $responseBody.variables[1].value = '{"approved":true}'
        $result = Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token
        $result.Reference | Should -BeExactly 'https://example.test/platform/instance'
        $result.Approval | Should -BeExactly '{"approved":true}'
        $result.Disposition | Should -BeExactly ''
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -ceq 'GET' -and $MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0 -and
            $Uri -ceq 'https://api.example.test/repos/platform/instance/environments/pr-authorization/variables?per_page=30&page=1'
        }
    }
    It 'rejects HTTP <StatusCode> instead of treating inaccessible state as absent' -ForEach @(
        @{ StatusCode = 301 }, @{ StatusCode = 401 }, @{ StatusCode = 403 }, @{ StatusCode = 404 }, @{ StatusCode = 500 }
    ) {
        $status = $StatusCode
        { Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token } | Should -Throw '*HTTP*'
    }
    It 'rejects an incomplete paginated snapshot' {
        $responseBody.total_count = 3
        { Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token } | Should -Throw '*one response*'
    }
    It 'rejects more than the maximum one-response variable count' {
        $responseBody.variables = @((1..31) | ForEach-Object { $responseBody.variables[0].Clone() })
        $responseBody.total_count = 31
        { Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token } | Should -Throw '*one response*'
    }
    It 'rejects duplicate variable names' {
        $responseBody.variables[1].name = $responseBody.variables[0].name
        { Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token } | Should -Throw '*duplicate*'
    }
    It 'recognizes noncanonical case without ignoring an active disposition' {
        $responseBody.variables[0].name = 'platform_development_disposition'
        $responseBody.variables[0].value = '{"operation":"adopt"}'
        (Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token).Disposition |
            Should -BeExactly '{"operation":"adopt"}'
    }
    It 'rejects case-folded duplicate variable names' {
        $responseBody.variables[1].name = $responseBody.variables[0].name.ToLowerInvariant()
        { Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token } | Should -Throw '*duplicate*'
    }
    It 'rejects invalid <Field> field <Case>' -ForEach @(
        @{ Field = 'name'; Case = 'missing'; Value = $null; Remove = $true }
        @{ Field = 'value'; Case = 'missing'; Value = $null; Remove = $true }
        @{ Field = 'created_at'; Case = 'missing'; Value = $null; Remove = $true }
        @{ Field = 'updated_at'; Case = 'missing'; Value = $null; Remove = $true }
        @{ Field = 'name'; Case = 'null'; Value = $null; Remove = $false }
        @{ Field = 'value'; Case = 'array'; Value = @('value'); Remove = $false }
        @{ Field = 'created_at'; Case = 'integer'; Value = 42; Remove = $false }
        @{ Field = 'updated_at'; Case = 'null'; Value = $null; Remove = $false }
    ) {
        if ($Remove) { $responseBody.variables[0].Remove($Field) } else { $responseBody.variables[0][$Field] = $Value }
        { Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token } | Should -Throw '*requires string*'
    }
    It 'rejects a non-object root' {
        $responseBody = @($responseBody)
        { Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token } | Should -Throw '*must be an object*'
    }
    It 'rejects an object in place of the variables array' {
        $responseBody.variables = @{}
        { Read-DevelopmentProtectedVariableSnapshot -Api https://api.example.test -RepositoryName platform/instance -Token fake-token } | Should -Throw '*one response*'
    }
}

Describe 'Protected reader result' {
    It 'requires one verified read and exactly one verified revocation' {
        { Assert-DevelopmentProtectedReaderResult -Result @{ Verified = $true; RevocationsVerified = 1 } -Reads 1 } | Should -Not -Throw
    }
    It 'rejects <Case>' -ForEach @(
        @{ Case = 'failed verification'; Verified = $false; Revocations = 1; Reads = 1 }
        @{ Case = 'missing revocation proof'; Verified = $true; Revocations = 0; Reads = 1 }
        @{ Case = 'extra installation'; Verified = $true; Revocations = 2; Reads = 1 }
        @{ Case = 'missing read'; Verified = $true; Revocations = 1; Reads = 0 }
        @{ Case = 'extra read'; Verified = $true; Revocations = 1; Reads = 2 }
    ) {
        { Assert-DevelopmentProtectedReaderResult -Result @{ Verified = $Verified; RevocationsVerified = $Revocations } -Reads $Reads } | Should -Throw
    }
}

Describe 'Protected state credential boundary' {
    BeforeEach {
        $approval = @{
            version = 1L; repository = 'https://example.test/platform/instance'
            baseRevision = 'a' * 40; revision = 'b' * 40; digest = 'c' * 64; pullRequest = '42'
            operation = 'apply'; approvedBy = 'reviewer'; approvalUrl = 'https://example.test/approval/1'
            expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
        }
        $variables = @{
            PLATFORM_REFERENCE_REPOSITORY = $approval.repository
            PLATFORM_SOURCE_REPOSITORY = 'https://github.com/example/platform'
            PLATFORM_DEVELOPMENT_APPROVAL = ConvertTo-Json $approval
            PLATFORM_DEVELOPMENT_DISPOSITION = ''
        }
        $arguments = @{
            Mode = 'development'; ExpectedReference = $approval.repository
            ExpectedApproval = ConvertTo-Json $approval; ExpectedSourceRepository = $variables.PLATFORM_SOURCE_REPOSITORY
            Repository = 'platform/instance'; ServerUrl = 'https://example.test'; ApiUrl = 'https://api.example.test'
            Revision = 'a' * 40; EventName = 'workflow_dispatch'; RunAttempt = '1'
            AppId = '101'; InstallationId = '201'; Enterprise = 'example'; PrivateKey = $privateKey
            IssuanceStatePath = Join-Path $TestDrive "$([guid]::NewGuid())/pending.json"
        }
        $cloud = @{ Issued = 0; Revoked = 0; FailRead = $false; ProofStatus = 401; LostIssuance = $false }
        $permissions = @{ environments = 'read' }
        $repositoryNames = @('instance')
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Uri -eq 'https://api.example.test/app') {
                return Get-GitHubApiFixture -Name apps/get-app.owner-enterprise -Set @{
                    id = 101; 'owner.slug' = 'example'; permissions = $permissions
                }
            }
            if ($Uri -like '*/app/installations`?*') {
                return ,(Get-GitHubApiFixture -Name apps/list-installations -Set @{
                    '0.id' = 201; '0.account.login' = 'platform'; '0.target_type' = 'Organization'
                    '0.permissions' = $permissions; '0.suspended_at' = $null; '0.repository_selection' = 'selected'
                })
            }
            if ($Uri -like '*/access_tokens') {
                $cloud.Issued++
                if ($cloud.LostIssuance) { throw 'Injected issuance response loss.' }
                return Get-GitHubApiFixture -Name apps/create-installation-access-token -Set @{ token = 'fake-reader'; permissions = $permissions }
            }
            if ($Uri -like '*/installation/repositories`?*') {
                $repositories = @($repositoryNames | ForEach-Object {
                    (Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{ 'repositories.0.name' = $_ }).repositories[0]
                })
                return Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation -Set @{
                    total_count = $repositories.Count; repositories = $repositories
                }
            }
            throw "Unexpected offline issuer request: $Method $Uri"
        }
        Mock Invoke-WebRequest {
            param($Uri, $Method)
            if ($Uri -like '*/environments/pr-authorization/variables`?*') {
                if ($cloud.FailRead) { throw 'Injected protected read failure.' }
                $body = Get-GitHubApiFixture -Name actions/list-environment-variables
                $template = $body.variables[0]
                $body.variables = @($variables.Keys | ForEach-Object {
                    $entry = $template.Clone(); $entry.name = $_; $entry.value = $variables[$_]; $entry
                })
                $body.total_count = $body.variables.Count
                return [pscustomobject]@{ StatusCode = 200; Content = ConvertTo-Json $body -Depth 20 }
            }
            if ($Method -eq 'DELETE') { $cloud.Revoked++; return [pscustomobject]@{ StatusCode = 204 } }
            return [pscustomobject]@{ StatusCode = $cloud.ProofStatus }
        }
    }
    It 'reads protected approval with a separate exact-scope reader and revokes it before returning' {
        { & $guard @arguments 6>$null } | Should -Not -Throw
        $cloud.Issued | Should -Be 1
        $cloud.Revoked | Should -Be 1
        Test-Path $arguments.IssuanceStatePath | Should -BeFalse
    }
    It 'rejects <Case> after a phase environment wait' -ForEach @(
        @{ Case = 'revoked approval'; Name = 'PLATFORM_DEVELOPMENT_APPROVAL'; Value = '' }
        @{ Case = 'replaced approval'; Name = 'PLATFORM_DEVELOPMENT_APPROVAL'; Value = '{"revision":"changed"}' }
        @{ Case = 'changed reference'; Name = 'PLATFORM_REFERENCE_REPOSITORY'; Value = 'https://example.test/platform/other' }
        @{ Case = 'changed source'; Name = 'PLATFORM_SOURCE_REPOSITORY'; Value = 'https://github.com/example/other' }
        @{ Case = 'standard transition'; Name = 'PLATFORM_DEVELOPMENT_DISPOSITION'; Value = '{"operation":"adopt"}' }
    ) {
        $variables[$Name] = $Value
        { & $guard @arguments 6>$null } | Should -Throw
        $cloud.Revoked | Should -Be 1
    }
    It 'blocks on protected read failure and still revokes its reader token' {
        $cloud.FailRead = $true
        { & $guard @arguments 6>$null } | Should -Throw '*protected read failure*'
        $cloud.Revoked | Should -Be 1
    }
    It 'blocks on missing revocation proof' {
        $cloud.ProofStatus = 200
        { & $guard @arguments 6>$null } | Should -Throw '*HTTP 401*'
    }
    It 'checks approval expiry again after reader-token revocation' {
        $approval.expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        $variables.PLATFORM_DEVELOPMENT_APPROVAL = ConvertTo-Json $approval
        $arguments.ExpectedApproval = $variables.PLATFORM_DEVELOPMENT_APPROVAL
        { & $guard @arguments 6>$null } | Should -Throw '*expired*'
        $cloud.Revoked | Should -Be 1
    }
    It 'rejects a removed reference rather than enabling standard deployment' {
        $arguments.Mode = 'standard'
        $variables.Remove('PLATFORM_REFERENCE_REPOSITORY')
        { & $guard @arguments 6>$null } | Should -Throw '*exact HTTPS reference*'
        $cloud.Revoked | Should -Be 1
    }
    It 'requires the separately protected reader key before issuance' {
        $arguments.PrivateKey = ''
        { & $guard @arguments 6>$null } | Should -Throw '*private key*'
        $cloud.Issued | Should -Be 0
    }
    It 'requires an environment-level source when authorize resolved a repository-level override' {
        $source = $variables.PLATFORM_SOURCE_REPOSITORY
        $variables.Remove('PLATFORM_SOURCE_REPOSITORY')
        { & $guard @arguments 6>$null } | Should -Throw '*source changed*'
        $variables.PLATFORM_SOURCE_REPOSITORY = $source
        { & $guard @arguments 6>$null } | Should -Not -Throw
    }
    It 'retains uncertain issuance and refuses to retry it' {
        $cloud.LostIssuance = $true
        { & $guard @arguments 6>$null } | Should -Throw '*issuance response loss*'
        { & $guard @arguments 6>$null } | Should -Throw '*Unresolved*issuance*'
        $cloud.Issued | Should -Be 1
    }
    It 'rejects broader reader permissions without issuing a token' {
        $permissions.environments = 'write'
        { & $guard @arguments 6>$null } | Should -Throw
        $cloud.Issued | Should -Be 0
    }
    It 'rejects an extra installation repository and revokes the token' {
        $repositoryNames = @('instance', 'other')
        { & $guard @arguments 6>$null } | Should -Throw '*repository access*'
        $cloud.Revoked | Should -Be 1
    }
    It 'checks current standard disposition rather than the authorize snapshot' {
        $arguments.Mode = 'standard'
        $decision = @{
            version = 1L; operation = 'adopt'; repository = $approval.repository
            mainRevision = 'a' * 40; candidateRevision = 'b' * 40; candidateDigest = 'c' * 64
            approvedBy = 'reviewer'; approvalUrl = 'https://example.test/approval/2'
            expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
        }
        $variables.PLATFORM_DEVELOPMENT_DISPOSITION = ConvertTo-Json $decision
        { & $guard @arguments 6>$null } | Should -Not -Throw
        $variables.PLATFORM_DEVELOPMENT_DISPOSITION = ''
        { & $guard @arguments 6>$null } | Should -Throw '*locked*'
        $decision.expiresAt = [DateTimeOffset]::UtcNow.AddMinutes(-1).ToString('o')
        $variables.PLATFORM_DEVELOPMENT_DISPOSITION = ConvertTo-Json $decision
        { & $guard @arguments 6>$null } | Should -Throw '*expired*'
    }
}
