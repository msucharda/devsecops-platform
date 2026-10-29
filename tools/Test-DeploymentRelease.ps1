#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $CandidatePath,
    [Parameter(Mandatory)][string] $WorkPath,
    [Parameter(Mandatory)][string] $PlatformOrganization,
    [AllowEmptyString()][string] $SourceRepository
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')
Import-Module (Join-Path $PSScriptRoot 'ReleaseIntegrity.psm1')

# security-check: deployment-release-marker
function Assert-DeploymentReleaseMarker {
    param([AllowNull()][object] $Marker, [string] $InstanceName)
    if ($Marker -isnot [Collections.IDictionary]) { throw 'Release marker must be an object.' }
    if ($Marker.get_Count() -ne 3) { throw 'Release marker must declare exactly instance, releaseVersion and files.' }
    if ($Marker['files'] -isnot [Collections.IDictionary]) { throw 'Release marker must declare a files mapping.' }
    if ($Marker['instance'] -cne $InstanceName) { throw 'Release marker instance differs from instance.yaml.' }
    if ($Marker['releaseVersion'] -isnot [string]) { throw 'Release marker version must be a string.' }
}

$candidate = (Resolve-Path -LiteralPath $CandidatePath).Path
$markerPath = Join-Path $candidate '.platform-bootstrap.json'
if ((Get-Item -LiteralPath $markerPath -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
    throw 'Release marker must not be a symbolic link.'
}
$marker = Get-Content -LiteralPath $markerPath -Raw | ConvertFrom-Json -AsHashtable
$instancePath = Join-Path $candidate 'instance.yaml'
$instance = Get-PlatformYaml -Path $instancePath
Assert-DeploymentReleaseMarker -Marker $marker -InstanceName $instance['instance']['name']
$inputs = & (Join-Path $PSScriptRoot 'Resolve-PlatformReleaseImport.ps1') `
    -Tag "v$($marker['releaseVersion'])" -InstancePath $instancePath `
    -PlatformOrganization $PlatformOrganization -SourceRepository $SourceRepository

# No source credential is read: public release verification must finish before any deployment App key is loaded.
$source = & (Join-Path $PSScriptRoot 'Get-VendoringSource.ps1') `
    -Repository $inputs.SourceRepository -Tag $inputs.Tag -AssetName $inputs.Asset `
    -ApiUrl 'https://api.github.com' -WorkPath (Join-Path $WorkPath 'source') -InstallationToken '' `
    -RequireAttestation -SignerWorkflow "$($inputs.SourceRepository)/.github/workflows/release.yml" -ProtectedBranch main
$raw = Get-ReleaseFileHash -Path $source.SourcePath -RawRelease
Assert-ReleaseFileHash -Expected $raw -Actual $marker['files'] -Label Marker
$actualFiles = Get-ReleaseFileHash -Path (Join-Path $candidate 'platform')
# The receipt is publisher metadata, not executable release content or evidence used by this check.
$null = $actualFiles.Remove('.vendoring.json')
if (Test-RawReleaseCandidate -Raw $raw -Candidate $actualFiles) {
    Write-Information "Verified exact raw bootstrap release $($inputs.SourceRepository)@$($inputs.Tag), commit $($source.Commit), SHA256 $($source.Sha256)." -InformationAction Continue
    return
}
$expected = Join-Path $WorkPath 'expected'
& (Join-Path $PSScriptRoot 'ConvertTo-VendoredSource.ps1') -SourcePath $source.SourcePath `
    -OutputPath $expected -CatalogPath (Join-Path $candidate 'vendoring/actions.json') `
    -ActionsOrganization $inputs.ActionsOrganization -Kind release
$expectedFiles = Get-ReleaseFileHash -Path (Join-Path $expected 'platform')
Assert-ReleaseFileHash -Expected $expectedFiles -Actual $actualFiles -Label Candidate
Write-Information "Verified release $($inputs.SourceRepository)@$($inputs.Tag), commit $($source.Commit), SHA256 $($source.Sha256)." -InformationAction Continue
