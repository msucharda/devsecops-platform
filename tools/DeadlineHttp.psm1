Set-StrictMode -Version Latest

function Invoke-DeadlineHttpGet {
    <#
    .SYNOPSIS
    Sends one GET request and reads the whole response body before an absolute deadline.
    .DESCRIPTION
    One cancellation token bounds connecting, sending, the headers and the complete body. Redirects are not followed.
    Returns $null when the deadline passes first; any other transport error throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][uri] $Uri,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Headers,
        [Parameter(Mandatory)][datetime] $Deadline
    )

    $remaining = $Deadline.ToUniversalTime() - [DateTime]::UtcNow
    if ($remaining -le [TimeSpan]::Zero) { return $null }
    $cancellation = [System.Threading.CancellationTokenSource]::new($remaining)
    $handler = [System.Net.Http.SocketsHttpHandler]::new()
    $handler.AllowAutoRedirect = $false
    $client = [System.Net.Http.HttpClient]::new($handler)
    $client.Timeout = [System.Threading.Timeout]::InfiniteTimeSpan
    $request = [System.Net.Http.HttpRequestMessage]::new([System.Net.Http.HttpMethod]::Get, $Uri)
    try {
        foreach ($name in $Headers.Keys) { $null = $request.Headers.TryAddWithoutValidation([string] $name, [string] $Headers[$name]) }
        $null = $request.Headers.TryAddWithoutValidation('User-Agent', 'devsecops-platform-wait-pull-request-checks')
        $response = $client.SendAsync($request, [System.Net.Http.HttpCompletionOption]::ResponseHeadersRead, $cancellation.Token).GetAwaiter().GetResult()
        try {
            $content = $response.Content.ReadAsStringAsync($cancellation.Token).GetAwaiter().GetResult()
            return [pscustomobject]@{ StatusCode = [int] $response.StatusCode; Content = $content }
        }
        finally { $response.Dispose() }
    }
    catch {
        # .NET exceptions from method calls arrive wrapped in MethodInvocationException.
        for ($exception = $_.Exception; $null -ne $exception; $exception = $exception.InnerException) {
            if ($exception -is [System.OperationCanceledException] -and $cancellation.IsCancellationRequested) { return $null }
        }
        throw
    }
    finally {
        $request.Dispose()
        $client.Dispose()
        $cancellation.Dispose()
    }
}

Export-ModuleMember -Function Invoke-DeadlineHttpGet
