#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CandidatePath,
    [Parameter(Mandatory)][string] $TrustedPath,
    [Parameter(Mandatory)][string] $WorkPath,
    [Parameter(Mandatory)][string] $PlatformOrganization,
    [string] $SourceRepository,
    [AllowEmptyString()][string] $ApprovalJson = $env:PLATFORM_DEVELOPMENT_APPROVAL,
    [AllowEmptyString()][string] $ReferenceRepository = $env:PLATFORM_REFERENCE_REPOSITORY,
    [string] $RepositoryUrl = "$env:GITHUB_SERVER_URL/$env:GITHUB_REPOSITORY",
    [string] $Revision,
    [string] $PullRequest,
    [string] $GitHubOutputPath,
    [ValidateSet('plan', 'apply')][string] $Operation = 'plan'
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevelopmentCandidate.psm1')
$approval = ConvertFrom-Json -InputObject $ApprovalJson -AsHashtable -NoEnumerate
$document = [Text.Json.JsonDocument]::Parse($ApprovalJson)
try {
    $expiry = [Text.Json.JsonElement]::new()
    if ($document.RootElement.ValueKind -eq [Text.Json.JsonValueKind]::Object -and
        $document.RootElement.TryGetProperty('expiresAt', [ref] $expiry) -and
        $expiry.ValueKind -eq [Text.Json.JsonValueKind]::String) {
        $approval['expiresAt'] = $expiry.GetString()
    }
}
finally { $document.Dispose() }
$baseline = Get-DevelopmentCandidateSnapshot -Path $TrustedPath -TrustedRuntime
$candidate = Get-DevelopmentCandidateSnapshot -Path $CandidatePath
Assert-DevelopmentCandidateRevision -Path $CandidatePath -Revision $candidate.Revision `
    -ExpectedRevision $Revision -BaseRevision $baseline.Revision
Assert-DevelopmentCandidateApproval -Approval $approval -ReferenceRepository $ReferenceRepository `
    -RepositoryUrl $RepositoryUrl -Revision $candidate.Revision -BaseRevision $baseline.Revision `
    -Digest $candidate.Digest -PullRequest $PullRequest -Operation $Operation
Assert-DevelopmentCandidateBoundary -Baseline $baseline.Files -Candidate $candidate.Files

# Materialize the immutable baseline without the trusted runtime's ignored dependency cache.
$null = New-Item -ItemType Directory -Path $WorkPath -Force
$archive = Join-Path $WorkPath 'baseline.zip'
& git -C $TrustedPath archive --format=zip "--output=$archive" $baseline.Revision
if ($LASTEXITCODE -ne 0) { throw 'Cannot materialize the development baseline.' }
$baselinePath = Join-Path $WorkPath 'baseline'
if (Test-Path -LiteralPath $baselinePath) { throw 'Development preflight work path must be fresh.' }
[IO.Compression.ZipFile]::ExtractToDirectory($archive, $baselinePath)
& (Join-Path $PSScriptRoot 'Test-DeploymentRelease.ps1') -CandidatePath $baselinePath `
    -WorkPath (Join-Path $WorkPath 'release') -PlatformOrganization $PlatformOrganization -SourceRepository $SourceRepository
$candidate = Get-DevelopmentCandidateSnapshot -Path $CandidatePath
Assert-DevelopmentCandidateApproval -Approval $approval -ReferenceRepository $ReferenceRepository `
    -RepositoryUrl $RepositoryUrl -Revision $candidate.Revision -BaseRevision $baseline.Revision `
    -Digest $candidate.Digest -PullRequest $PullRequest -Operation $Operation
if ($GitHubOutputPath) {
    $receipt = ConvertTo-Json -InputObject $approval -Depth 10 -Compress
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath),
        "approval=$receipt`nreference=$ReferenceRepository`noperation=$Operation`n", [Text.UTF8Encoding]::new($false))
}
Write-Information "Verified development candidate $($candidate.Revision), SHA256 $($candidate.Digest); not a standard release." -InformationAction Continue
