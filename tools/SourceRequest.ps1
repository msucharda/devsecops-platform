#Requires -Version 7.4

function Invoke-SourceRequest {
    # https://docs.github.com/en/enterprise-cloud@latest/rest/using-the-rest-api/rate-limits-for-the-rest-api#exceeding-the-rate-limit
    param(
        [Parameter(Mandatory)][scriptblock] $Request,
        [ValidateRange(0, 3600)][int] $MaxRateLimitWaitSeconds = 300
    )
    $secondaryWait = 60
    for ($attempt = 1; ; $attempt++) {
        try { return & $Request }
        catch {
            $response = if ($_.Exception.PSObject.Properties['Response']) { $_.Exception.Response } else { $null }
            $status = if ($response) { [int] $response.StatusCode } else { 0 }
            if ($status -notin @(403, 429)) { throw }
            $header = {
                param($Name)
                $values = $null
                if ($response.Headers.TryGetValues($Name, [ref] $values)) { return @($values)[0] }
                return $null
            }
            $remaining = & $header 'x-ratelimit-remaining'
            $retryAfter = & $header 'retry-after'
            $message = if ($_.ErrorDetails) { $_.ErrorDetails.Message } else { '' }
            if ($remaining -eq '0') {
                $reset = & $header 'x-ratelimit-reset'
                $resetAt = if ($reset -match '^[0-9]+$') { [DateTimeOffset]::FromUnixTimeSeconds([long] $reset) } else { [DateTimeOffset]::UtcNow.AddHours(1) }
                $wait = [Math]::Max(1, [int] [Math]::Ceiling(($resetAt - [DateTimeOffset]::UtcNow).TotalSeconds))
            }
            elseif ($retryAfter -match '^[0-9]+$') { $wait = [Math]::Max(1, [int] $retryAfter) }
            elseif ($message -match 'secondary rate limit') { $wait = $secondaryWait; $secondaryWait *= 2 }
            else { throw }
            if ($attempt -gt 3 -or $wait -gt $MaxRateLimitWaitSeconds) {
                throw "GitHub API rate limit for the source is exhausted (HTTP $status); retry after $wait s. $($_.Exception.Message)"
            }
            Write-Warning "GitHub API rate limit reached (HTTP $status); retrying in $wait s."
            Start-Sleep -Seconds $wait
        }
    }
}
