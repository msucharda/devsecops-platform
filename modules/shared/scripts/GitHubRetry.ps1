#Requires -Version 7.4
Set-StrictMode -Version Latest

# security-check: github-retry-method
function Test-GitHubRetryMethod {
    param([string] $Method, [switch] $TokenRevocation)
    return ($Method -eq 'GET' -or ($TokenRevocation -and $Method -eq 'DELETE'))
}

# security-check: github-retry-status
function Test-GitHubRetryStatus {
    param([int] $StatusCode)
    return ($StatusCode -in @(502, 503, 504))
}

function Test-GitHubRetryTransport {
    param([Parameter(Mandatory)][Exception] $Exception)

    while ($null -ne $Exception) {
        if (($Exception -is [Net.Http.HttpRequestException] -or $Exception -is [Net.Http.HttpIOException]) -and
            $Exception.HttpRequestError -in @(
                [Net.Http.HttpRequestError]::NameResolutionError,
                [Net.Http.HttpRequestError]::ConnectionError,
                [Net.Http.HttpRequestError]::SecureConnectionError,
                [Net.Http.HttpRequestError]::ResponseEnded
            )) { return $true }
        if ($Exception -is [Net.Sockets.SocketException] -or
            $Exception -is [Security.Authentication.AuthenticationException] -or
            $Exception -is [TimeoutException] -or
            $Exception -is [Threading.Tasks.TaskCanceledException]) { return $true }
        if ($Exception -is [Net.WebException] -and
            $Exception.Status -in @(
                [Net.WebExceptionStatus]::ConnectFailure,
                [Net.WebExceptionStatus]::ConnectionClosed,
                [Net.WebExceptionStatus]::KeepAliveFailure,
                [Net.WebExceptionStatus]::NameResolutionFailure,
                [Net.WebExceptionStatus]::ProxyNameResolutionFailure,
                [Net.WebExceptionStatus]::ReceiveFailure,
                [Net.WebExceptionStatus]::SendFailure,
                [Net.WebExceptionStatus]::SecureChannelFailure,
                [Net.WebExceptionStatus]::TrustFailure,
                [Net.WebExceptionStatus]::Timeout
            )) { return $true }
        $Exception = $Exception.InnerException
    }
    return $false
}

function Invoke-GitHubRetryRequest {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Request,
        [switch] $TokenRevocation
    )

    $parameters = $Request.Clone()
    $parameters.MaximumRetryCount = 0
    $parameters.SkipHttpErrorCheck = $true
    $parameters.ErrorAction = 'Stop'
    $parameters.Verbose = $false
    $parameters.Debug = $false
    $method = ([string] $parameters.Method).ToUpperInvariant()
    $path = ([uri] $parameters.Uri).AbsolutePath
    $retryMethod = Test-GitHubRetryMethod -Method $method -TokenRevocation:$TokenRevocation
    for ($attempt = 1; $attempt -le 3; $attempt++) {
        $reply = $null
        $status = 'none'
        try {
            $reply = Invoke-WebRequest @parameters
            $status = [int] $reply.StatusCode
            $transient = Test-GitHubRetryStatus -StatusCode $status
        }
        catch {
            $reply = $null
            $exception = $_.Exception
            while ($null -ne $exception) {
                if ($exception -is [Microsoft.PowerShell.Commands.HttpResponseException]) {
                    $status = [int] $exception.Response.StatusCode
                    break
                }
                if ($exception -is [Net.Http.HttpRequestException] -and $null -ne $exception.StatusCode) {
                    $status = [int] $exception.StatusCode
                    break
                }
                $exception = $exception.InnerException
            }
            $transient = if ('none' -ceq $status) {
                Test-GitHubRetryTransport -Exception $_.Exception
            }
            else { Test-GitHubRetryStatus -StatusCode $status }
        }
        if (-not $retryMethod -or -not $transient -or $attempt -eq 3) {
            if ($null -ne $reply) { return $reply }
            throw "$method $path status=$status attempt=$attempt"
        }
        [Console]::Error.WriteLine("$method $path status=$status attempt=$attempt")
        Start-Sleep -Seconds (5 * $attempt)
    }
}
