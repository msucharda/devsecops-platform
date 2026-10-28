BeforeAll {
    . (Join-Path $PSScriptRoot '../../modules/shared/scripts/GitHubRetry.ps1')
}

Describe 'GitHub request retry policy' {
    BeforeEach {
        $request = @{
            Uri = 'https://api.example.test/orgs/example?per_page=100&token=query-secret'
            Method = 'GET'
            Headers = @{ Authorization = 'Bearer header-secret' }
        }
        $script:attempt = 0
        $previousError = [Console]::Error
        $retryLog = [IO.StringWriter]::new()
        [Console]::SetError($retryLog)
        Mock Start-Sleep {}
        Mock Invoke-WebRequest {
            $script:attempt++
            [pscustomobject]@{ StatusCode = $(if ($script:attempt -eq 1) { 503 } else { 200 }); Content = '' }
        }
    }

    AfterEach {
        [Console]::SetError($previousError)
        $retryLog.Dispose()
    }

    It 'retries a transient GET once and preserves the successful response' {
        $reply = Invoke-GitHubRetryRequest -Request $request
        $reply.StatusCode | Should -Be 200
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        $retryLog.ToString().Trim() | Should -BeExactly 'GET /orgs/example status=503 attempt=1'
    }

    It 'bounds transient HTTP <HttpStatus> at three attempts with 5 and 10 second waits' -ForEach @(
        @{ HttpStatus = 502 }
        @{ HttpStatus = 503 }
        @{ HttpStatus = 504 }
    ) {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $HttpStatus; Content = '' } }
        (Invoke-GitHubRetryRequest -Request $request).StatusCode | Should -Be $HttpStatus
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 5 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 10 }
    }

    It 'recovers from a transient <Case> without logging the transport message' -ForEach @(
        @{ Case = 'connection'; Failure = [Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::ConnectionError, 'transport-secret') }
        @{ Case = 'DNS'; Failure = [Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::NameResolutionError, 'transport-secret') }
        @{ Case = 'closed connection'; Failure = [Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::ResponseEnded, 'transport-secret') }
        @{ Case = 'HTTP body connection'; Failure = [Net.Http.HttpIOException]::new([Net.Http.HttpRequestError]::ResponseEnded, 'transport-secret') }
        @{ Case = 'TLS'; Failure = [Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::SecureConnectionError, 'transport-secret') }
        @{ Case = 'timeout'; Failure = [Threading.Tasks.TaskCanceledException]::new('transport-secret') }
        @{ Case = 'explicit timeout'; Failure = [TimeoutException]::new('transport-secret') }
        @{ Case = 'socket'; Failure = [Net.Sockets.SocketException]::new([int][Net.Sockets.SocketError]::ConnectionReset) }
        @{ Case = 'legacy timeout'; Failure = [Net.WebException]::new('transport-secret', [Net.WebExceptionStatus]::Timeout) }
        @{ Case = 'nested TLS'; Failure = [Net.Http.HttpRequestException]::new('transport-secret', [Security.Authentication.AuthenticationException]::new('transport-secret')) }
    ) {
        Mock Invoke-WebRequest {
            $script:attempt++
            if ($script:attempt -eq 1) { throw $Failure }
            [pscustomobject]@{ StatusCode = 200; Content = '' }
        }
        (Invoke-GitHubRetryRequest -Request $request).StatusCode | Should -Be 200
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        $retryLog.ToString().Trim() | Should -BeExactly 'GET /orgs/example status=none attempt=1'
    }

    It 'fails closed after the third connection failure without leaking secrets' {
        Mock Invoke-WebRequest {
            throw [Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::ConnectionError, 'transport-secret')
        }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw '*GET /orgs/example status=none attempt=3'
        Should -Invoke Invoke-WebRequest -Times 3 -Exactly
        Should -Invoke Start-Sleep -Times 2 -Exactly
    }

    It 'does not retry HTTP <HttpStatus>' -ForEach @(
        @{ HttpStatus = 400 }, @{ HttpStatus = 401 }, @{ HttpStatus = 403 }, @{ HttpStatus = 404 },
        @{ HttpStatus = 408 }, @{ HttpStatus = 409 }, @{ HttpStatus = 422 }, @{ HttpStatus = 429 },
        @{ HttpStatus = 500 }, @{ HttpStatus = 501 }, @{ HttpStatus = 505 }
    ) {
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = $HttpStatus; Content = '' } }
        (Invoke-GitHubRetryRequest -Request $request).StatusCode | Should -Be $HttpStatus
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'does not retry <Method> after a 503' -ForEach @(
        @{ Method = 'POST' }, @{ Method = 'PATCH' }, @{ Method = 'PUT' }, @{ Method = 'DELETE' }
    ) {
        $request.Method = $Method
        (Invoke-GitHubRetryRequest -Request $request).StatusCode | Should -Be 503
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'does not retry an unclassified error or expose its message' {
        Mock Invoke-WebRequest { throw [InvalidOperationException]::new('transport-secret') }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw '*GET /orgs/example status=none attempt=1'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'allows only the explicit token-revocation DELETE exception' {
        $request.Method = 'DELETE'
        $request.Uri = 'https://api.example.test/installation/token'
        (Invoke-GitHubRetryRequest -Request $request -TokenRevocation).StatusCode | Should -Be 200
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
    }

    It 'does not allow token-revocation mode to retry <WriteMethod>' -ForEach @(
        @{ WriteMethod = 'POST' }, @{ WriteMethod = 'PATCH' }, @{ WriteMethod = 'PUT' }
    ) {
        $request.Method = $WriteMethod
        (Invoke-GitHubRetryRequest -Request $request -TokenRevocation).StatusCode | Should -Be 503
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'does not retry <WriteMethod> transport failures' -ForEach @(
        @{ WriteMethod = 'POST' }, @{ WriteMethod = 'PATCH' }, @{ WriteMethod = 'PUT' }, @{ WriteMethod = 'DELETE' }
    ) {
        $request.Method = $WriteMethod
        Mock Invoke-WebRequest { throw [TimeoutException]::new('transport-secret') }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw "*$WriteMethod /orgs/example status=none attempt=1"
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'does not classify a nontransport HttpRequestException as transient' {
        Mock Invoke-WebRequest {
            throw [Net.Http.HttpRequestException]::new([Net.Http.HttpRequestError]::InvalidResponse, 'transport-secret')
        }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw '*GET /orgs/example status=none attempt=1'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'does not retry a nontransport HttpIOException' {
        Mock Invoke-WebRequest { throw [Net.Http.HttpIOException]::new([Net.Http.HttpRequestError]::InvalidResponse, 'transport-secret') }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw '*GET /orgs/example status=none attempt=1'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'does not retry <WriteMethod> after a body connection failure' -ForEach @(
        @{ WriteMethod = 'POST' }, @{ WriteMethod = 'PATCH' }, @{ WriteMethod = 'PUT' }, @{ WriteMethod = 'DELETE' }
    ) {
        $request.Method = $WriteMethod
        Mock Invoke-WebRequest { throw [Net.Http.HttpIOException]::new([Net.Http.HttpRequestError]::ResponseEnded, 'transport-secret') }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw "*$WriteMethod /orgs/example status=none attempt=1"
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Start-Sleep -Times 0 -Exactly
    }

    It 'does not retry an HTTP 429 exception with a nested connection error' {
        Mock Invoke-WebRequest {
            throw [Net.Http.HttpRequestException]::new(
                'transport-secret', [TimeoutException]::new('transport-secret'), [Net.HttpStatusCode]::TooManyRequests)
        }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw '*GET /orgs/example status=429 attempt=1'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'retries an HTTP 503 exception before returning a successful response' {
        Mock Invoke-WebRequest {
            $script:attempt++
            if ($script:attempt -eq 1) {
                throw [Net.Http.HttpRequestException]::new('transport-secret', $null, [Net.HttpStatusCode]::ServiceUnavailable)
            }
            [pscustomobject]@{ StatusCode = 200; Content = '' }
        }
        (Invoke-GitHubRetryRequest -Request $request).StatusCode | Should -Be 200
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
    }

    It 'never exposes a malformed status or headers in a transport error' {
        # Deliberately invalid HTTP metadata, not a GitHub API response fixture.
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 'response-secret'; Content = 'body-secret' } }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw '*GET /orgs/example status=none attempt=1'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'does not retry a PowerShell HTTP 403 exception' {
        Mock Invoke-WebRequest {
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new(
                'transport-secret', [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::Forbidden))
        }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw '*GET /orgs/example status=403 attempt=1'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'does not retry an unrelated legacy WebException' {
        Mock Invoke-WebRequest { throw [Net.WebException]::new('transport-secret', [Net.WebExceptionStatus]::ProtocolError) }
        { Invoke-GitHubRetryRequest -Request $request } |
            Should -Throw '*GET /orgs/example status=none attempt=1'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'disables built-in retries and verbose transport output without mutating the caller request' {
        $request.MaximumRetryCount = 7
        $request.Verbose = $true
        $request.Debug = $true
        $null = Invoke-GitHubRetryRequest -Request $request
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter {
            $MaximumRetryCount -eq 0 -and $SkipHttpErrorCheck -and
            $ErrorAction -eq 'Stop' -and -not $Verbose -and -not $Debug
        }
        $request.MaximumRetryCount | Should -Be 7
        $request.Verbose | Should -BeTrue
        $request.Debug | Should -BeTrue
    }
}
