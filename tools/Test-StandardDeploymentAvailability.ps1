#Requires -Version 7.4
[CmdletBinding()]
param(
    [AllowEmptyString()][string] $DevelopmentApprovalJson = $env:PLATFORM_DEVELOPMENT_APPROVAL,
    [AllowEmptyString()][string] $DispositionJson = $env:PLATFORM_DEVELOPMENT_DISPOSITION,
    [string] $RepositoryUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY",
    [string] $Revision = $env:GITHUB_SHA,
    [string] $EventName = $env:GITHUB_EVENT_NAME
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# security-check: standard-deployment-development-lock
function Assert-StandardDeploymentAvailability {
    param([string] $ApprovalJson, [string] $Disposition, [string] $Repository, [string] $MainRevision, [string] $Trigger)
    if ([string]::IsNullOrWhiteSpace($ApprovalJson) -and [string]::IsNullOrWhiteSpace($Disposition)) { return }
    if ([string]::IsNullOrWhiteSpace($ApprovalJson) -or [string]::IsNullOrWhiteSpace($Disposition)) {
        throw 'Standard deployment is locked by an outstanding development approval or incomplete disposition.'
    }
    $approval = ConvertFrom-Json -InputObject $ApprovalJson -AsHashtable -NoEnumerate
    $decision = ConvertFrom-Json -InputObject $Disposition -AsHashtable -NoEnumerate
    if ($approval -isnot [Collections.IDictionary] -or $decision -isnot [Collections.IDictionary] -or
        $decision['version'] -isnot [long] -or $decision['version'] -ne 1 -or
        $decision['operation'] -cnotin @('adopt', 'rollback') -or $Trigger -cnotin @('push', 'workflow_dispatch')) {
        throw 'Standard deployment disposition requires a protected adopt or rollback decision for main.'
    }
    foreach ($pair in @(
        @('repository', $Repository), @('mainRevision', $MainRevision),
        @('candidateRevision', $approval['revision']), @('candidateDigest', $approval['digest'])
    )) {
        if ($decision[$pair[0]] -isnot [string] -or [string]::IsNullOrWhiteSpace([string] $pair[1]) -or
            $decision[$pair[0]] -cne $pair[1]) {
            throw "Standard deployment disposition does not match $($pair[0])."
        }
    }
    foreach ($key in @('approvedBy', 'approvalUrl')) {
        if ($decision[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($decision[$key])) {
            throw "Standard deployment disposition requires $key."
        }
    }
    $document = [Text.Json.JsonDocument]::Parse($Disposition)
    try { $expiryText = $document.RootElement.GetProperty('expiresAt').GetString() }
    finally { $document.Dispose() }
    $expiry = [DateTimeOffset]::MinValue
    if (-not [DateTimeOffset]::TryParseExact($expiryText, 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref] $expiry) -or $expiry -le [DateTimeOffset]::UtcNow) {
        throw 'Standard deployment disposition is expired or invalid.'
    }
}

Assert-StandardDeploymentAvailability -ApprovalJson $DevelopmentApprovalJson -Disposition $DispositionJson `
    -Repository $RepositoryUrl -MainRevision $Revision -Trigger $EventName
