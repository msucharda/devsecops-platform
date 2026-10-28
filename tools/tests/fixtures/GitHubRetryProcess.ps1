param([string] $Program, [string] $TestsRoot)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $TestsRoot 'GitHubApiFixture.psm1') -Force
$processStub = @{
    RequestCount = 0
    Responses = @{
        '/orgs/example/actions/permissions' = (Get-GitHubApiFixture -Name actions/get-github-actions-permissions-organization |
                ConvertTo-Json -Depth 100 -Compress)
        '/orgs/example/actions/permissions/workflow' = (Get-GitHubApiFixture -Name actions/get-github-actions-default-workflow-permissions-organization |
                ConvertTo-Json -Depth 100 -Compress)
    }
}

$sendRequest = {
    param([string] $Uri, [string] $Method)
    $path = ([uri] $Uri).AbsolutePath
    if ($Method -ne 'GET' -or -not $processStub.Responses.ContainsKey($path)) {
        throw "Unexpected process fixture request: $Method $path"
    }
    $processStub.RequestCount++
    [pscustomobject]@{
        StatusCode = $(if ($processStub.RequestCount -eq 1) { 503 } else { 200 })
        Content = $processStub.Responses[$path]
        Headers = @{}
    }
}.GetNewClosure()
Set-Item -LiteralPath Function:\global:Invoke-WebRequest -Value $sendRequest

function global:Start-Sleep {
    param([int] $Seconds)
    if ($Seconds -ne 5) { throw "Unexpected retry delay: $Seconds" }
}

& $Program
if ($processStub.RequestCount -ne 3) { throw 'The process fixture did not observe exactly three HTTP requests.' }
