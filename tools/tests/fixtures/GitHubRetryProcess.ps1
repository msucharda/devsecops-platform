param([string] $Program, [string] $TestsRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $TestsRoot 'GitHubApiFixture.psm1') -Force
$script:retryProcessRequestCount = 0
$script:retryProcessResponses = @{
    '/orgs/example/actions/permissions' = (Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization |
            ConvertTo-Json -Depth 100 -Compress)
    '/orgs/example/actions/permissions/workflow' = (Get-GitHubApiFixture -Name actions/get-github-actions-default-workflow-permissions-organization |
            ConvertTo-Json -Depth 100 -Compress)
}

function global:Invoke-WebRequest {
    param([string] $Uri, [string] $Method)
    $path = ([uri] $Uri).AbsolutePath
    if ($Method -ne 'GET' -or -not $script:retryProcessResponses.ContainsKey($path)) {
        throw "Unexpected process fixture request: $Method $path"
    }
    $script:retryProcessRequestCount++
    [pscustomobject]@{
        StatusCode = $(if ($script:retryProcessRequestCount -eq 1) { 503 } else { 200 })
        Content = $script:retryProcessResponses[$path]
        Headers = @{}
    }
}

function global:Start-Sleep {
    param([int] $Seconds)
    if ($Seconds -ne 5) { throw "Unexpected retry delay: $Seconds" }
}

& $Program
if ($script:retryProcessRequestCount -ne 3) { throw 'The process fixture did not observe exactly three HTTP requests.' }
