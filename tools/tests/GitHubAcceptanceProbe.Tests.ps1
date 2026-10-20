BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $probe = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-GitHubBootstrapAcceptance.ps1'
}

Describe 'Live bootstrap acceptance probe public interface' {
    BeforeEach {
        $saved = @{}
        foreach ($name in @('PLATFORM_GITHUB_TOKENS', 'PLATFORM_APP_PRIVATE_KEY', 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID',
            'PLATFORM_STATE_STORAGE_ACCOUNT', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
            'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN', 'GITHUB_REPOSITORY_OWNER')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:GITHUB_REPOSITORY_OWNER = 'demo-a1b2c3-platform'
        $env:PLATFORM_GITHUB_TOKENS = '{"demo-a1b2c3-platform":"trial-token"}'
        $config = @{ instance = @{ name = 'demo' }; bootstrap = @{ tenantId = '11111111-1111-1111-1111-111111111111' } }
        $path = Join-Path $TestDrive 'instance.yaml'
        ConvertTo-Yaml $config | Set-Content $path
        $output = Join-Path $TestDrive 'result.json'
        Mock Invoke-RestMethod { throw 'Policy API unavailable' }
        Mock az { throw 'Azure must not run after a failed GitHub probe.' }
        Mock Invoke-WebRequest { throw 'Unexpected HTTP request.' }
    }
    AfterEach {
        foreach ($name in $saved.Keys) { [Environment]::SetEnvironmentVariable($name, $saved[$name]) }
    }

    It 'fails explicitly without publishing successful evidence when the policy API is unavailable' {
        Set-Content $output '{"passed":true}'
        { & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
            Should -Throw '*Policy API unavailable*'
        Test-Path $output | Should -BeFalse
        Should -Invoke az -Times 0 -Exactly
    }

    It 'probes the platform organization named by the repository owner <Owner>' -Tag 'DeploymentIdentifier' -TestCases @(
        @{ Owner = 'demo-a1b2c3-platform' }, @{ Owner = 'demo-platform' }
    ) {
        $env:GITHUB_REPOSITORY_OWNER = $Owner
        $env:PLATFORM_GITHUB_TOKENS = "{`"$Owner`":`"trial-token`"}"

        { & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
            Should -Throw '*Policy API unavailable*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -ceq "https://api.example.ghe.com/orgs/$Owner/actions/permissions" }
    }

    It 'rejects a repository owner <Owner> that is not the platform organization of the instance' -Tag 'DeploymentIdentifier' -TestCases @(
        @{ Owner = 'other-a1b2c3-platform' }, @{ Owner = 'demo-a1b2c3-workloads' }, @{ Owner = 'demo-A1B2C3-platform' }, @{ Owner = '' }
    ) {
        $env:GITHUB_REPOSITORY_OWNER = $Owner
        $env:PLATFORM_GITHUB_TOKENS = "{`"$Owner`":`"trial-token`"}"

        { & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
            Should -Throw '*not the platform organization*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'records the actual phase identity and key only after all live checks succeed for <Phase>' -TestCases @(
        @{ Phase = 'plan' }, @{ Phase = 'apply' }, @{ Phase = 'rulesetPlan' }
    ) {
        param($Phase)
        $env:AZURE_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
        $env:PLATFORM_STATE_STORAGE_ACCOUNT = 'stdemotfstate'
        $env:GITHUB_SHA = 'approved-main'; $env:GITHUB_RUN_ID = '80'; $env:GITHUB_RUN_ATTEMPT = '2'
        $key = [Security.Cryptography.RSA]::Create(2048)
        $env:PLATFORM_APP_PRIVATE_KEY = $key.ExportRSAPrivateKeyPem()
        $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($key.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
        $key.Dispose()
        Mock Invoke-RestMethod {
            if ($Uri -like '*/actions/permissions') { return @{ enabled_repositories = 'all' } }
            if ($Uri -like '*/rulesets`?*') { return ,@(@{ name = 'bootstrap-acceptance-probe'; id = 7 }) }
            if ($Uri -like '*/rulesets/7') { return @{ enforcement = 'disabled'; bypass_actors = @(@{ actor_type = 'OrganizationAdmin' }) } }
            return ,@()
        }
        $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            '{"appid":"44444444-4444-4444-4444-444444444444","tid":"11111111-1111-1111-1111-111111111111"}')).TrimEnd('=')
        Mock az {
            $global:LASTEXITCODE = 0
            if ($args[0] -eq 'account') { return "{`"accessToken`":`"header.$payload.signature`"}" }
            if ($args[[Array]::IndexOf($args, '--container-name') + 1] -eq 'bootstrap-probe') {
                $global:LASTEXITCODE = 1
                return 'AuthorizationPermissionMismatch'
            }
            return '[]'
        }
        Mock Invoke-WebRequest {
            [pscustomobject]@{ StatusCode = 403; Headers = @{ 'x-ms-error-code' = @('AuthorizationPermissionMismatch') } }
        }

        $result = & $probe -InstancePath $path -Phase $Phase -ApiUrl 'https://api.example.ghe.com' -ResultPath $output

        $result.passed | Should -BeTrue
        $record = Get-Content $output -Raw | ConvertFrom-Json -AsHashtable
        $record.keyFingerprint | Should -Be $fingerprint
        $record.runAttempt | Should -Be '2'
        $record.checks.otherModuleStateDenied | Should -BeTrue
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Headers.Authorization -eq 'Bearer trial-token' }

        Mock az { $global:LASTEXITCODE = 1; 'NameResolutionError' } -ParameterFilter {
            $args -contains 'bootstrap-probe'
        }
        Mock Invoke-WebRequest { throw 'NameResolutionError' }
        { & $probe -InstancePath $path -Phase $Phase -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
            Should -Throw '*state*'
        Test-Path $output | Should -BeFalse
    }

    Context 'State isolation diagnostic evidence' {
        BeforeEach {
            $diagnosticPath = Join-Path $TestDrive 'result.state-isolation.json'
            $env:AZURE_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
            $env:PLATFORM_STATE_STORAGE_ACCOUNT = 'stdemotfstate'
            $key = [Security.Cryptography.RSA]::Create(2048)
            $env:PLATFORM_APP_PRIVATE_KEY = $key.ExportRSAPrivateKeyPem()
            $key.Dispose()
            $payload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
                '{"appid":"44444444-4444-4444-4444-444444444444","tid":"11111111-1111-1111-1111-111111111111"}')).TrimEnd('=')
            Mock Invoke-RestMethod {
                if ($Uri -like '*/actions/permissions') { return @{ enabled_repositories = 'all' } }
                return ,@()
            }
            Mock az {
                $global:LASTEXITCODE = 0
                if ($args[0] -eq 'account') { return "{`"accessToken`":`"header.$payload.signature`"}" }
                return 'native-output-must-not-be-preserved'
            }
        }

        It 'fails and preserves bounded diagnostics when the native cross-module read succeeds' {
            { & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
                Should -Throw '*state*'

            Test-Path $output | Should -BeFalse
            $raw = Get-Content $diagnosticPath -Raw
            $record = ConvertFrom-Json $raw -AsHashtable
            $record.nativeExitCode | Should -Be 0
            $record.outcome | Should -Be 'UnexpectedSuccess'
            $raw.Length | Should -BeLessThan 1024
            $raw | Should -Not -Match 'native-output-must-not-be-preserved|accessToken|signature|PRIVATE KEY'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'proves denial from structured Storage evidence, not native error wording, and retains the immediate exit status' {
            Mock az { $global:LASTEXITCODE = 1; 'You do not have the required permissions. native-output-must-not-be-preserved' } -ParameterFilter {
                $args -contains 'bootstrap-probe'
            }
            Mock Invoke-WebRequest {
                $global:LASTEXITCODE = 0
                $responseHeaders = [Collections.Generic.Dictionary[string, Collections.Generic.IEnumerable[string]]]::new([StringComparer]::OrdinalIgnoreCase)
                $responseHeaders['x-ms-error-code'] = [string[]]@('AuthorizationPermissionMismatch')
                [pscustomobject]@{
                    StatusCode = 403
                    Headers = $responseHeaders
                    Content = 'response-body-must-not-be-preserved'
                }
            }

            $result = & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output

            $result.checks.otherModuleStateDenied | Should -BeTrue
            $raw = Get-Content $diagnosticPath -Raw
            $record = ConvertFrom-Json $raw -AsHashtable
            $record.nativeExitCode | Should -Be 1
            $record.httpStatus | Should -Be 403
            $record.errorCode | Should -Be 'AuthorizationPermissionMismatch'
            $record.outcome | Should -Be 'AuthorizationDenied'
            $raw | Should -Not -Match 'must-not-be-preserved|accessToken|signature|PRIVATE KEY'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
                $Method -ceq 'GET' -and
                $Uri -ceq 'https://stdemotfstate.blob.core.windows.net/bootstrap-probe?restype=container&comp=list&maxresults=1' -and
                $Headers.Authorization -ceq "Bearer header.$payload.signature" -and
                $Headers['x-ms-version'] -ceq '2023-11-03' -and
                $MaximumRedirection -eq 0 -and $MaximumRetryCount -eq 0 -and $SkipHttpErrorCheck
            }
        }

        It 'does not propagate the expected native denial as the successful pwsh step exit status' {
            Mock az { $global:LASTEXITCODE = 1; 'AuthorizationPermissionMismatch' } -ParameterFilter {
                $args -contains 'bootstrap-probe'
            }
            Mock Invoke-WebRequest {
                [pscustomobject]@{ StatusCode = 403; Headers = @{ 'x-ms-error-code' = 'AuthorizationPermissionMismatch' } }
            }

            $result = & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output
            $stepExitCode = $LASTEXITCODE

            $result.passed | Should -BeTrue
            $stepExitCode | Should -Be 0
            (Get-Content $diagnosticPath -Raw | ConvertFrom-Json).nativeExitCode | Should -Be 1
        }

        It 'fails closed with sanitized evidence for <Case>' -TestCases @(
            @{ Case = 'a successful REST read'; Status = 200; Code = $null; Outcome = 'UnexpectedSuccess'; SavedCode = 'missing' }
            @{ Case = 'generic authorization or firewall failure'; Status = 403; Code = 'AuthorizationFailure'; Outcome = 'UnrecognizedFailure'; SavedCode = 'AuthorizationFailure' }
            @{ Case = 'an expired or invalid credential'; Status = 403; Code = 'AuthenticationFailed'; Outcome = 'UnrecognizedFailure'; SavedCode = 'AuthenticationFailed' }
            @{ Case = 'a missing container'; Status = 404; Code = 'ContainerNotFound'; Outcome = 'UnrecognizedFailure'; SavedCode = 'ContainerNotFound' }
            @{ Case = 'a service error'; Status = 500; Code = 'InternalError'; Outcome = 'UnrecognizedFailure'; SavedCode = 'InternalError' }
            @{ Case = 'a redirect'; Status = 302; Code = 'AuthorizationPermissionMismatch'; Outcome = 'UnrecognizedFailure'; SavedCode = 'AuthorizationPermissionMismatch' }
            @{ Case = 'an incorrect status for the denial code'; Status = 400; Code = 'AuthorizationPermissionMismatch'; Outcome = 'UnrecognizedFailure'; SavedCode = 'AuthorizationPermissionMismatch' }
            @{ Case = 'a missing machine error code'; Status = 403; Code = $null; Outcome = 'UnrecognizedFailure'; SavedCode = 'missing' }
            @{ Case = 'an unrecognized code'; Status = 403; Code = 'sensitive-output-must-not-be-preserved'; Outcome = 'UnrecognizedFailure'; SavedCode = 'unrecognized' }
            @{ Case = 'a differently cased code'; Status = 403; Code = 'authorizationpermissionmismatch'; Outcome = 'UnrecognizedFailure'; SavedCode = 'unrecognized' }
            @{ Case = 'multiple error-code headers'; Status = 403; Code = @('AuthorizationPermissionMismatch', 'sensitive-output-must-not-be-preserved'); Outcome = 'UnrecognizedFailure'; SavedCode = 'unrecognized' }
            @{ Case = 'a malformed status'; Status = 'sensitive-output-must-not-be-preserved'; Code = 'AuthorizationPermissionMismatch'; Outcome = 'InvalidResponse'; SavedCode = 'not-observed' }
        ) {
            param($Case, $Status, $Code, $Outcome, $SavedCode)
            Mock az { $global:LASTEXITCODE = 1; 'AuthorizationPermissionMismatch sensitive-output-must-not-be-preserved' } -ParameterFilter {
                $args -contains 'bootstrap-probe'
            }
            $responseFixture = [pscustomobject]@{
                StatusCode = $Status; Headers = @{ 'x-ms-error-code' = $Code }
                Content = '<Error><Code>AuthorizationPermissionMismatch</Code><Message>sensitive-output-must-not-be-preserved</Message></Error>'
            }
            Mock Invoke-WebRequest { $responseFixture }
            Set-Content $output '{"passed":true}'
            Set-Content $diagnosticPath '{"outcome":"AuthorizationDenied"}'

            { & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
                Should -Throw '*state*'

            Test-Path $output | Should -BeFalse -Because $Case
            $raw = Get-Content $diagnosticPath -Raw
            $record = ConvertFrom-Json $raw -AsHashtable
            $record.nativeExitCode | Should -Be 1
            $record.outcome | Should -Be $Outcome
            $record.errorCode | Should -Be $SavedCode
            $raw.Length | Should -BeLessThan 1024
            $raw | Should -Not -Match 'sensitive-output|accessToken|signature|PRIVATE KEY'
            Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        }

        It 'rejects <Case> without leaking native or transport exception contents' -TestCases @(
            @{ Case = 'a native invocation failure'; NativeThrows = $true; Outcome = 'NativeInvocationFailure'; HttpCalls = 0 }
            @{ Case = 'a network failure'; NativeThrows = $false; Outcome = 'TransportFailure'; HttpCalls = 1 }
        ) {
            param($Case, $NativeThrows, $Outcome, $HttpCalls)
            $nativeFailure = $NativeThrows
            Mock az {
                if ($nativeFailure) { throw 'sensitive-output-must-not-be-preserved' }
                $global:LASTEXITCODE = 1
                'sensitive-output-must-not-be-preserved'
            } -ParameterFilter { $args -contains 'bootstrap-probe' }
            Mock Invoke-WebRequest { throw 'sensitive-output-must-not-be-preserved' }

            $message = try {
                & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output
                throw 'The state check unexpectedly passed.'
            }
            catch { $_.Exception.Message }

            $message | Should -Match 'state' -Because $Case
            $message | Should -Not -Match 'sensitive-output'
            Test-Path $output | Should -BeFalse
            $raw = Get-Content $diagnosticPath -Raw
            (ConvertFrom-Json $raw -AsHashtable).outcome | Should -Be $Outcome
            $raw | Should -Not -Match 'sensitive-output|accessToken|signature|PRIVATE KEY'
            Should -Invoke Invoke-WebRequest -Times $HttpCalls -Exactly
        }

        It 'rejects missing or malformed native exit status (<ExitStatus>)' -TestCases @(
            @{ ExitStatus = $null }, @{ ExitStatus = 'sensitive-output-must-not-be-preserved' }
        ) {
            param($ExitStatus)
            $nativeExitStatus = $ExitStatus
            Mock az { $global:LASTEXITCODE = $nativeExitStatus; 'AuthorizationPermissionMismatch' } -ParameterFilter {
                $args -contains 'bootstrap-probe'
            }

            { & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
                Should -Throw '*native exit status*'

            Test-Path $output | Should -BeFalse
            $raw = Get-Content $diagnosticPath -Raw
            $record = ConvertFrom-Json $raw -AsHashtable
            $record.nativeExitCode | Should -BeNullOrEmpty
            $record.outcome | Should -Be 'UnrecognizedFailure'
            $raw | Should -Not -Match 'sensitive-output'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        }

        It 'rejects incomplete structured responses (<Case>)' -TestCases @(
            @{ Case = 'no response'; Response = $null }
            @{ Case = 'no status'; Response = @{ Headers = @{ 'x-ms-error-code' = 'AuthorizationPermissionMismatch' } } }
            @{ Case = 'no headers'; Response = @{ StatusCode = 403 } }
            @{ Case = 'malformed headers'; Response = @{ StatusCode = 403; Headers = 'sensitive-output-must-not-be-preserved' } }
        ) {
            param($Case, $Response)
            Mock az { $global:LASTEXITCODE = 1; 'AuthorizationPermissionMismatch' } -ParameterFilter {
                $args -contains 'bootstrap-probe'
            }
            $responseFixture = $Response
            Mock Invoke-WebRequest { $responseFixture }

            { & $probe -InstancePath $path -Phase plan -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
                Should -Throw '*malformed*'

            Test-Path $output | Should -BeFalse -Because $Case
            $raw = Get-Content $diagnosticPath -Raw
            (ConvertFrom-Json $raw -AsHashtable).outcome | Should -Be 'InvalidResponse'
            $raw | Should -Not -Match 'sensitive-output'
        }
    }

    It 'preserves only safe structured Entra diagnostics when wrong-subject rejection is unrecognized' {
        $env:AZURE_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
        $env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://pipelines.actions.githubusercontent.com/oidctoken'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'runner-test-token'
        Mock Invoke-RestMethod { @{ value = 'assertion-must-not-be-preserved' } }
        Mock Write-Information {} -ParameterFilter { $MessageData -like '::add-mask::*' }
        $errorContent = ConvertTo-Json @{
            error = 'invalid_client'; error_codes = @(700016)
            trace_id = 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
            correlation_id = 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
            error_description = 'sensitive-output-must-not-be-preserved'
            access_token = 'access-token-must-not-be-preserved'
        }
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 400; Content = $errorContent } }
        Set-Content $output '{"passed":true}'

        { & $probe -InstancePath $path -Phase wrongSubject -ResultPath $output } |
            Should -Throw '*wrong-subject*'

        Test-Path $output | Should -BeFalse
        $raw = Get-Content (Join-Path $TestDrive 'result.federation.json') -Raw
        $diagnostic = ConvertFrom-Json $raw -AsHashtable
        $diagnostic.httpStatus | Should -Be 400
        $diagnostic.error_codes | Should -Be @(700016)
        $diagnostic.error | Should -Be 'invalid_client'
        $diagnostic.trace_id | Should -Be 'aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa'
        $diagnostic.correlation_id | Should -Be 'bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb'
        $diagnostic.outcome | Should -Be 'UnrecognizedFailure'
        $raw | Should -Not -Match 'must-not-be-preserved|assertion|access_token|error_description'
    }

    It 'fails closed with safe federation evidence for <Case>' -TestCases @(
        @{ Case = 'a token transport exception'; Transport = $true; Status = 400; Content = '{}'; Outcome = 'TransportFailure' }
        @{ Case = 'a non-JSON response'; Transport = $false; Status = 400; Content = 'sensitive-output-must-not-be-preserved'; Outcome = 'InvalidResponse' }
        @{ Case = 'a JSON array'; Transport = $false; Status = 400; Content = '["sensitive-output-must-not-be-preserved"]'; Outcome = 'InvalidResponse' }
        @{ Case = 'a malformed HTTP status'; Transport = $false; Status = 'sensitive-output-must-not-be-preserved'; Content = '{}'; Outcome = 'InvalidResponse' }
        @{ Case = 'an unexpected access token'; Transport = $false; Status = 200; Content = '{"access_token":"sensitive-output-must-not-be-preserved"}'; Outcome = 'UnrecognizedFailure' }
        @{ Case = 'untrusted diagnostic strings'; Transport = $false; Status = 401; Content = '{"error":"sensitive-output-must-not-be-preserved","error_codes":["sensitive-output-must-not-be-preserved"],"trace_id":"sensitive-output-must-not-be-preserved","correlation_id":"sensitive-output-must-not-be-preserved"}'; Outcome = 'UnrecognizedFailure' }
    ) {
        param($Case, $Transport, $Status, $Content, $Outcome)
        $env:AZURE_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
        $env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://pipelines.actions.githubusercontent.com/oidctoken'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'runner-test-token'
        Mock Invoke-RestMethod { @{ value = 'assertion-must-not-be-preserved' } }
        Mock Write-Information {} -ParameterFilter { $MessageData -like '::add-mask::*' }
        $transportFailure = $Transport
        $responseFixture = [pscustomobject]@{ StatusCode = $Status; Content = $Content }
        Mock Invoke-WebRequest {
            if ($transportFailure) { throw 'sensitive-output-must-not-be-preserved' }
            $responseFixture
        }
        $federationPath = Join-Path $TestDrive 'result.federation.json'
        Set-Content $federationPath '{"outcome":"SubjectRejected"}'
        Set-Content $output '{"passed":true}'

        $message = try { & $probe -InstancePath $path -Phase wrongSubject -ResultPath $output }
            catch { $_.Exception.Message }

        $message | Should -Match 'wrong-subject' -Because $Case
        $message | Should -Not -Match 'must-not-be-preserved'
        Test-Path $output | Should -BeFalse
        $raw = Get-Content $federationPath -Raw
        ($raw | ConvertFrom-Json).outcome | Should -Be $Outcome
        $raw.Length | Should -BeLessThan 1024
        $raw | Should -Not -Match 'must-not-be-preserved|assertion|access_token|error_description'
    }

    It 'accepts only the exact Entra wrong-subject rejection, not another login failure (<Status>/<Code>)' -TestCases @(
        @{ Status = 400; Code = 700213; Accepted = $true }
        @{ Status = 401; Code = 700213; Accepted = $true }
        @{ Status = 400; Code = 700016; Accepted = $false }
        @{ Status = 401; Code = 70021; Accepted = $false }
        @{ Status = 400; Code = 70021; Accepted = $false }
        @{ Status = 401; Code = 700212; Accepted = $false }
        @{ Status = 401; Code = 700211; Accepted = $false }
        @{ Status = 401; Code = 700024; Accepted = $false }
        @{ Status = 200; Code = 700213; Accepted = $false }
        @{ Status = 302; Code = 700213; Accepted = $false }
        @{ Status = 403; Code = 700213; Accepted = $false }
        @{ Status = 500; Code = 700213; Accepted = $false }
        @{ Status = 401; Code = @(700213, 700016); Accepted = $false }
        @{ Status = 401; Code = '700213'; Accepted = $false }
        @{ Status = 401; Code = $null; Accepted = $false }
        @{ Status = 401; Code = 700213; OAuthError = 'invalid_request'; Accepted = $false }
        @{ Status = 401; Code = 700213; OAuthError = $null; Accepted = $false }
    ) {
        param($Status, $Code, $Accepted, $OAuthError = 'invalid_client')
        $env:AZURE_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
        $env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://pipelines.actions.githubusercontent.com/oidctoken?api-version=2.0'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'runner-test-token'
        $subjectPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            '{"sub":"repo:demo-platform@10/instance@20:ref:refs/heads/main","aud":"api://AzureADTokenExchange"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $assertion = "header.$subjectPayload.signature"
        Mock Invoke-RestMethod { @{ value = $assertion } }
        Mock Write-Information {} -ParameterFilter { $MessageData -like '::add-mask::*' }
        $errorContent = ConvertTo-Json @{ error = $OAuthError; error_codes = @($Code) }
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $Status; Content = $errorContent } }
        if ($Accepted) {
            (& $probe -InstancePath $path -Phase wrongSubject -ResultPath $output).checks.wrongSubjectRejected | Should -BeTrue
            $diagnostic = Get-Content (Join-Path $TestDrive 'result.federation.json') -Raw | ConvertFrom-Json
            $diagnostic.httpStatus | Should -Be $Status
            $diagnostic.outcome | Should -Be 'SubjectRejected'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Uri -like '*audience=api%3A%2F%2FAzureADTokenExchange' -and $Headers.Authorization -eq 'Bearer runner-test-token'
            }

        }
        else {
            Set-Content $output '{"passed":true}'
            { & $probe -InstancePath $path -Phase wrongSubject -ResultPath $output } | Should -Throw '*AADSTS700213*'
            Test-Path $output | Should -BeFalse
        }
        Should -Invoke az -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Body.client_assertion -ceq $assertion -and $Body.scope -ceq 'https://management.azure.com/.default' -and
            $MaximumRetryCount -eq 0 -and $MaximumRedirection -eq 0 -and $SkipHttpErrorCheck
        }
    }
}

Describe 'Bootstrap acceptance diagnostic artifact contract' {
    It 'retains only the declared evidence files even after <Job> fails' -TestCases @(
        @{ Job = 'probe' }, @{ Job = 'apply_probe' }
    ) {
        param($Job)
        $workflowPath = Join-Path (Split-Path $PSScriptRoot -Parent) 'acceptance/github/bootstrap-acceptance.yml'
        $workflow = Get-Content $workflowPath -Raw | ConvertFrom-Yaml
        $upload = @($workflow.jobs[$Job].steps | Where-Object { $_.Contains('uses') -and $_.uses -like 'actions/upload-artifact@*' })
        $upload.Count | Should -Be 1
        $upload[0]['if'] | Should -Be 'always()'
        @($upload[0].with.path.Trim() -split '\r?\n').Count | Should -Be 2
        $upload[0].with.path | Should -Match '(?m)^\s*evidence/result\.json\s*$'
        $upload[0].with.path | Should -Match '(?m)^\s*evidence/result\.state-isolation\.json\s*$'
        $upload[0].with.'retention-days' | Should -Be 7
    }
}

Describe 'Bootstrap acceptance wrong-subject identity handoff' {
    It 'passes identity metadata from an isolated job without Azure login masking' {
        $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
        $workflow = Get-Content (Join-Path $root 'tools/acceptance/github/bootstrap-acceptance.yml') -Raw | ConvertFrom-Yaml
        $consumer = $workflow.jobs.wrong_subject
        $provider = $workflow.jobs[$consumer.needs]

        @($provider.steps | Where-Object { $_.Contains('uses') -and $_.uses -like 'Azure/login@*' }).Count |
            Should -Be 0 -Because 'Azure/login masks the client ID and GitHub then withholds that job output.'
        $provider.needs | Should -Be 'probe'
        $provider.environment | Should -Be '${{ github.event_name == ''schedule'' && ''enterprise-baseline-plan-drift'' || ''enterprise-baseline-plan'' }}'
        $provider.permissions.Count | Should -Be 0
        $provider.outputs.client | Should -Be '${{ steps.identity.outputs.client }}'
        $provider.outputs.tenant | Should -Be '${{ steps.identity.outputs.tenant }}'
        $provider.steps.Count | Should -Be 1
        $provider.steps[0].env.CLIENT | Should -Be '${{ vars.AZURE_CLIENT_ID }}'
        $provider.steps[0].env.TENANT | Should -Be '${{ vars.AZURE_TENANT_ID }}'
        $provider.steps[0].run | Should -Match '"client=\$env:CLIENT" >> \$env:GITHUB_OUTPUT'
        $provider.steps[0].run | Should -Match '"tenant=\$env:TENANT" >> \$env:GITHUB_OUTPUT'
        $consumer.Contains('environment') | Should -BeFalse
        $consumer.permissions.'id-token' | Should -Be 'write'
        $probeStep = @($consumer.steps | Where-Object { $_.Contains('run') -and $_.run -like '*-Phase wrongSubject*' })
        $probeStep.Count | Should -Be 1
        $probeStep[0].env.AZURE_CLIENT_ID | Should -Be '${{ needs.wrong_subject_identity.outputs.client }}'
        $probeStep[0].env.AZURE_TENANT_ID | Should -Be '${{ needs.wrong_subject_identity.outputs.tenant }}'
    }
}
