#Requires -Version 7.4
[CmdletBinding()]
param(
    [AllowEmptyString()][string] $CurrentApproval = $env:PLATFORM_DEVELOPMENT_APPROVAL,
    [Parameter(Mandatory)][string] $ExpectedApproval,
    [Parameter(Mandatory)][string] $ExpectedAttempt,
    [string] $RunAttempt = $env:GITHUB_RUN_ATTEMPT,
    [AllowEmptyString()][string] $Disposition = $env:PLATFORM_DEVELOPMENT_DISPOSITION,
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# security-check: development-approval-continuity
function Assert-DevelopmentApprovalContinuity {
    param([string] $Current, [string] $Expected, [string] $Attempt, [string] $AuthorizedAttempt, [string] $CurrentDisposition)
    if ($Attempt -ne '1' -or $AuthorizedAttempt -ne $Attempt) {
        throw 'Development execution requires a fresh dispatch, not a re-run of previous jobs.'
    }
    if (-not [string]::IsNullOrWhiteSpace($CurrentDisposition)) {
        throw 'Development execution is locked by a standard adoption or rollback disposition.'
    }
    if ([string]::IsNullOrWhiteSpace($Current) -or
        -not [Text.Json.Nodes.JsonNode]::DeepEquals(
            [Text.Json.Nodes.JsonNode]::Parse($Current),
            [Text.Json.Nodes.JsonNode]::Parse($Expected))) {
        throw 'Development approval was revoked or replaced after authorization.'
    }
}

Assert-DevelopmentApprovalContinuity -Current $CurrentApproval -Expected $ExpectedApproval `
    -Attempt $RunAttempt -AuthorizedAttempt $ExpectedAttempt -CurrentDisposition $Disposition
if ($GitHubOutputPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath),
        "attempt=$RunAttempt`n", [Text.UTF8Encoding]::new($false))
}
