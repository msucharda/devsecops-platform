#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('development', 'standard')][string] $Mode,
    [Parameter(Mandatory)][string] $ExpectedReference,
    [string] $ExpectedApproval,
    [AllowEmptyString()][string] $ExpectedSourceRepository,
    [string] $ExpectedAttempt = '1',
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $ServerUrl = $env:GITHUB_SERVER_URL,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [string] $Revision = $env:GITHUB_SHA,
    [string] $EventName = $env:GITHUB_EVENT_NAME,
    [string] $RunAttempt = $env:GITHUB_RUN_ATTEMPT,
    [string] $AppId = $env:PLATFORM_APPROVAL_READER_APP_ID,
    [string] $InstallationId = $env:PLATFORM_APPROVAL_READER_INSTALLATION_ID,
    [string] $Enterprise = $env:PLATFORM_APPROVAL_READER_ENTERPRISE,
    [string] $PrivateKey = $env:PLATFORM_APPROVAL_READER_PRIVATE_KEY,
    [string] $IssuanceStatePath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# security-check: development-protected-context
function Assert-DevelopmentProtectedContext {
    param([string] $Reference, [string] $Server, [string] $Api, [string] $Name, [string] $Attempt)
    $address = [uri] $Server
    if ($Name -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+\z' -or
        $address.Scheme -ne 'https' -or -not $address.IsDefaultPort -or $address.UserInfo -or
        $address.Query -or $address.Fragment -or $address.AbsolutePath -cne '/' -or
        $Api.TrimEnd('/') -cne "https://api.$($address.DnsSafeHost)" -or
        $Reference -cne "$Server/$Name" -or $Attempt -ne '1') {
        throw 'Protected state inspection requires this exact HTTPS reference, Cloud API and fresh workflow attempt.'
    }
}

# security-check: development-protected-variable
function Read-DevelopmentProtectedVariableSnapshot {
    param([string] $Api, [string] $RepositoryName, [string] $Token)
    $response = Invoke-WebRequest -Uri "$($Api.TrimEnd('/'))/repos/$RepositoryName/environments/pr-authorization/variables?per_page=30&page=1" `
        -Headers @{ Authorization = "Bearer $Token"; Accept = 'application/vnd.github+json'; 'X-GitHub-Api-Version' = '2026-03-10' } `
        -Method GET -MaximumRedirection 0 -TimeoutSec 60 -MaximumRetryCount 0 -SkipHttpErrorCheck
    if ($response.StatusCode -ne 200) { throw "Cannot read current protected variables: HTTP $($response.StatusCode)." }
    $document = [Text.Json.JsonDocument]::Parse([string] $response.Content)
    try {
        if ($document.RootElement.ValueKind -ne [Text.Json.JsonValueKind]::Object) {
            throw 'Protected variables response must be an object.'
        }
        $count = $document.RootElement.GetProperty('total_count').GetInt32()
        $variables = $document.RootElement.GetProperty('variables')
        if ($variables.ValueKind -ne [Text.Json.JsonValueKind]::Array -or
            $count -ne $variables.GetArrayLength() -or $count -gt 30) {
            throw 'Protected variables must fit completely in one response; pagination is not an authorization snapshot.'
        }
        $values = @{ Reference = ''; Source = ''; Disposition = ''; Approval = '' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($variable in $variables.EnumerateArray()) {
            foreach ($field in @('name', 'value', 'created_at', 'updated_at')) {
                $property = [Text.Json.JsonElement]::new()
                if (-not $variable.TryGetProperty($field, [ref] $property) -or
                    $property.ValueKind -ne [Text.Json.JsonValueKind]::String) {
                    throw "Protected variable response requires string '$field'."
                }
            }
            $name = $variable.GetProperty('name').GetString()
            if (-not $seen.Add($name)) { throw 'Protected variable response contains duplicate names.' }
            $value = $variable.GetProperty('value').GetString()
            switch ($name) {
                PLATFORM_REFERENCE_REPOSITORY { $values.Reference = $value }
                PLATFORM_SOURCE_REPOSITORY { $values.Source = $value }
                PLATFORM_DEVELOPMENT_DISPOSITION { $values.Disposition = $value }
                PLATFORM_DEVELOPMENT_APPROVAL { $values.Approval = $value }
            }
        }
        return $values
    }
    finally { $document.Dispose() }
}

# security-check: development-protected-reader-result
function Assert-DevelopmentProtectedReaderResult {
    param([object] $Result, [int] $Reads)
    if (-not $Result.Verified -or $Result.RevocationsVerified -ne 1 -or $Reads -ne 1) {
        throw 'Protected state inspection requires complete reads and verified reader-token revocation.'
    }
}

Assert-DevelopmentProtectedContext -Reference $ExpectedReference -Server $ServerUrl -Api $ApiUrl `
    -Name $Repository -Attempt $RunAttempt
$parts = $Repository.Split('/')
$reader = @{
    appId = $AppId; installationId = $InstallationId; enterprise = $Enterprise
    permissions = @{ environments = 'read' }
    resources = @{ organizations = @($parts[0]); repositories = @{ $parts[0] = @($parts[1]) } }
}
$state = @{ Reads = 0; Value = $null }
$readVariables = ${function:Read-DevelopmentProtectedVariableSnapshot}
$readApi = $ApiUrl
$readRepository = $Repository
$lifecycle = {
    param($LifecycleEvent)
    if ($LifecycleEvent.Event -ceq 'Issued') {
        Write-Information "::add-mask::$($LifecycleEvent.Token)" -InformationAction Continue
        $state.Value = & $readVariables -Api $readApi -RepositoryName $readRepository -Token $LifecycleEvent.Token
        $state.Reads++
    }
    return $true
}.GetNewClosure()
$result = & (Join-Path $PSScriptRoot 'New-PlatformGitHubToken.ps1') -BootstrapApp $reader -ValidateOnly `
    -PrivateKey $PrivateKey -ApiUrl $ApiUrl -TokenLifecycle $lifecycle -VerifyRevocation -IssuanceStatePath $IssuanceStatePath
Assert-DevelopmentProtectedReaderResult -Result $result -Reads $state.Reads
$state = $state.Value
Assert-DevelopmentProtectedContext -Reference $state.Reference -Server $ServerUrl -Api $ApiUrl `
    -Name $Repository -Attempt $RunAttempt
if ($Mode -ceq 'development') {
    if ($state.Source -cne $ExpectedSourceRepository) { throw 'Protected release source changed after authorization.' }
    & (Join-Path $PSScriptRoot 'Test-DevelopmentApprovalContinuity.ps1') -CurrentApproval $state.Approval `
        -ExpectedApproval $ExpectedApproval -ExpectedAttempt $ExpectedAttempt -RunAttempt $RunAttempt -Disposition $state.Disposition
    $approval = ConvertFrom-Json -InputObject $state.Approval -AsHashtable -NoEnumerate
    $document = [Text.Json.JsonDocument]::Parse($state.Approval)
    try { $approval['expiresAt'] = $document.RootElement.GetProperty('expiresAt').GetString() }
    finally { $document.Dispose() }
    Import-Module (Join-Path $PSScriptRoot 'DevelopmentCandidate.psm1')
    Assert-DevelopmentCandidateApproval -Approval $approval -ReferenceRepository $state.Reference `
        -RepositoryUrl $ExpectedReference -Revision $approval['revision'] -BaseRevision $Revision `
        -Digest $approval['digest'] -PullRequest $approval['pullRequest'] -Operation $approval['operation']
}
else {
    & (Join-Path $PSScriptRoot 'Test-StandardDeploymentAvailability.ps1') -DevelopmentApprovalJson $state.Approval `
        -DispositionJson $state.Disposition -RepositoryUrl $ExpectedReference -Revision $Revision -EventName $EventName
}
Write-Information 'Current protected state verified after environment review; reader token revoked before deployment credentials.' -InformationAction Continue
