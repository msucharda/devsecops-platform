BeforeAll {
    $revoke = Join-Path $PSScriptRoot '../Remove-PlatformGitHubToken.ps1'
}

Describe 'Job installation token revocation retry' {
    BeforeEach {
        $savedTokens = $env:PLATFORM_GITHUB_TOKENS
        $env:PLATFORM_GITHUB_TOKENS = '{"example":"job-token-secret"}'
        $revocationState = @{ Attempt = 0; Revoked = $false; Applied = 0 }
        Mock Start-Sleep {}
        Mock Invoke-RestMethod { throw 'Unexpected legacy request.' }
        Mock Invoke-WebRequest {
            $revocationState.Attempt++
            [pscustomobject]@{ StatusCode = $(if ($revocationState.Attempt -eq 1) { 503 } else { 204 }); Content = '' }
        }
    }

    AfterEach {
        $env:PLATFORM_GITHUB_TOKENS = $savedTokens
    }

    It 'survives one 503 and requires the documented 204 response' {
        & $revoke -ApiUrl https://api.example.test
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter {
            $Method -ceq 'DELETE' -and $Uri -ceq 'https://api.example.test/installation/token' -and
            $Headers.Authorization -ceq 'Bearer job-token-secret' -and
            $Headers['X-GitHub-Api-Version'] -ceq '2026-03-10' -and $MaximumRetryCount -eq 0
        }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
    }

    It 'rejects HTTP <HttpStatus> without treating it as confirmed revocation' -ForEach @(
        @{ HttpStatus = 200; Attempts = 1 }, @{ HttpStatus = 202; Attempts = 1 },
        @{ HttpStatus = 401; Attempts = 1 }, @{ HttpStatus = 403; Attempts = 1 },
        @{ HttpStatus = 429; Attempts = 1 }, @{ HttpStatus = 500; Attempts = 1 },
        @{ HttpStatus = 503; Attempts = 3 }
    ) {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $HttpStatus; Content = '' } }
        { & $revoke -ApiUrl https://api.example.test } |
            Should -Throw "*Token revocation failed*DELETE /installation/token status=$HttpStatus*"
        Should -Invoke Invoke-WebRequest -Times $Attempts -Exactly
    }

    It 'still revokes the other tokens when one token fails' {
        $env:PLATFORM_GITHUB_TOKENS = '{"one":"token-one","two":"token-two"}'
        Mock Invoke-WebRequest {
            param($Headers)
            [pscustomobject]@{
                StatusCode = $(if ($Headers.Authorization -ceq 'Bearer token-one') { 403 } else { 204 })
                Content = ''
            }
        }
        { & $revoke -ApiUrl https://api.example.test } | Should -Throw "*Token revocation failed for 'one'*"
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Headers.Authorization -ceq 'Bearer token-two' }
    }

    It 'reports an applied revocation with a lost response as unconfirmed and does not retry the 401' {
        Mock Invoke-WebRequest {
            if (-not $revocationState.Revoked) {
                $revocationState.Revoked = $true
                $revocationState.Applied++
                throw [TimeoutException]::new('response-lost-secret')
            }
            [pscustomobject]@{ StatusCode = 401; Content = '' }
        }
        { & $revoke -ApiUrl https://api.example.test } | Should -Throw '*DELETE /installation/token status=401*'
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly
        { & $revoke -ApiUrl https://api.example.test } | Should -Throw '*DELETE /installation/token status=401*'
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        $revocationState.Applied | Should -Be 1
    }

    It 'respects WhatIf without attempting revocation' {
        & $revoke -ApiUrl https://api.example.test -WhatIf
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'does nothing when no job tokens were issued' {
        $env:PLATFORM_GITHUB_TOKENS = $null
        & $revoke -ApiUrl https://api.example.test
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }
}
