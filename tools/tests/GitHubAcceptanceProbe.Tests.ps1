BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $probe = Join-Path (Split-Path $PSScriptRoot -Parent) 'Test-GitHubBootstrapAcceptance.ps1'
}

Describe 'Live bootstrap acceptance probe public interface' {
    BeforeEach {
        $saved = @{}
        foreach ($name in @('PLATFORM_GITHUB_TOKENS', 'PLATFORM_APP_PRIVATE_KEY', 'AZURE_CLIENT_ID', 'AZURE_TENANT_ID',
            'PLATFORM_STATE_STORAGE_ACCOUNT', 'GITHUB_SHA', 'GITHUB_RUN_ID', 'GITHUB_RUN_ATTEMPT',
            'ACTIONS_ID_TOKEN_REQUEST_URL', 'ACTIONS_ID_TOKEN_REQUEST_TOKEN')) {
            $saved[$name] = [Environment]::GetEnvironmentVariable($name)
        }
        $env:PLATFORM_GITHUB_TOKENS = '{"demo-platform":"trial-token"}'
        $config = @{ instance = @{ name = 'demo' }; bootstrap = @{ tenantId = '11111111-1111-1111-1111-111111111111' } }
        $path = Join-Path $TestDrive 'instance.yaml'
        ConvertTo-Yaml $config | Set-Content $path
        $output = Join-Path $TestDrive 'result.json'
        Mock Invoke-RestMethod { throw 'Policy API unavailable' }
        Mock az { throw 'Azure must not run after a failed GitHub probe.' }
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
        { & $probe -InstancePath $path -Phase $Phase -ApiUrl 'https://api.example.ghe.com' -ResultPath $output } |
            Should -Throw '*other than authorization*'
        Test-Path $output | Should -BeFalse
    }

    It 'accepts only the exact Entra wrong-subject rejection, not another login failure (<Code>)' -TestCases @(
        @{ Code = 700213; Accepted = $true }, @{ Code = 700016; Accepted = $false }
    ) {
        param($Code, $Accepted)
        $env:AZURE_CLIENT_ID = '44444444-4444-4444-4444-444444444444'
        $env:AZURE_TENANT_ID = '11111111-1111-1111-1111-111111111111'
        $env:ACTIONS_ID_TOKEN_REQUEST_URL = 'https://pipelines.actions.githubusercontent.com/oidctoken?api-version=2.0'
        $env:ACTIONS_ID_TOKEN_REQUEST_TOKEN = 'runner-test-token'
        $subjectPayload = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes(
            '{"sub":"repo:demo-platform@10/instance@20:ref:refs/heads/main","aud":"api://AzureADTokenExchange"}')).TrimEnd('=').Replace('+', '-').Replace('/', '_')
        $assertion = "header.$subjectPayload.signature"
        Mock Invoke-RestMethod { @{ value = $assertion } }
        $errorContent = ConvertTo-Json @{ error_codes = @($Code) }
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 400; Content = $errorContent } }
        if ($Accepted) {
            (& $probe -InstancePath $path -Phase wrongSubject -ResultPath $output).checks.wrongSubjectRejected | Should -BeTrue
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
            $Body.client_assertion -ceq $assertion -and $Body.scope -ceq 'https://management.azure.com/.default'
        }
    }
}
