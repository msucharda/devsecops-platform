param([string] $Program, [string] $TestsRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $TestsRoot 'GitHubApiFixture.psm1') -Force
$global:retryProcessRequestCount = 0
$global:retryProcessResponses = @{
    '/orgs/example/actions/permissions' = (Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization |
            ConvertTo-Json -Depth 100 -Compress)
    '/orgs/example/actions/permissions/workflow' = (Get-GitHubApiFixture -Name actions/get-github-actions-default-workflow-permissions-organization |
            ConvertTo-Json -Depth 100 -Compress)
}

function global:Invoke-WebRequest {
    param([string] $Uri, [string] $Method)
    $path = ([uri] $Uri).AbsolutePath
    if ($Method -ne 'GET' -or -not $global:retryProcessResponses.ContainsKey($path)) {
        throw "Unexpected process fixture request: $Method $path"
    }
    $global:retryProcessRequestCount++
    [pscustomobject]@{
        StatusCode = $(if ($global:retryProcessRequestCount -eq 1) { 503 } else { 200 })
        Content = $global:retryProcessResponses[$path]
        Headers = @{}
    }
}

function global:Start-Sleep {
    param([int] $Seconds)
    if ($Seconds -ne 5) { throw "Unexpected retry delay: $Seconds" }
}

& $Program
if ($global:retryProcessRequestCount -ne 3) { throw 'The process fixture did not observe exactly three HTTP requests.' }
