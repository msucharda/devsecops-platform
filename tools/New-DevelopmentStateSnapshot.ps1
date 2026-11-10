#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourcePath,
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][ValidatePattern('^[a-z][a-z0-9-]*\z')][string] $Module,
    [Parameter(Mandatory)][ValidateSet('main', 'rulesets', IgnoreCase = $false)][string] $StateRoot,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*\z')][string] $Organization,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{64}\z')][string] $ExpectedSha256,
    [Parameter(Mandatory)][ValidatePattern('^"0x[0-9A-Fa-f]+"\z')][string] $SourceETag,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}\z', Options = [Text.RegularExpressions.RegexOptions]::None)][string] $BaselineRevision,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}\z', Options = [Text.RegularExpressions.RegexOptions]::None)][string] $CandidateRevision,
    [Parameter(Mandatory)][ValidatePattern('^[a-f0-9]{40}\z', Options = [Text.RegularExpressions.RegexOptions]::None)][string] $ControlRevision
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# security-check: development-state-attributes
function Assert-DevelopmentStateAttributeMap {
    param([AllowNull()][object] $Attributes, [string] $Type, [string] $Org)
    if ($Attributes -isnot [Collections.IDictionary]) { throw 'Development state requires complete organization attributes.' }
    switch -CaseSensitive ($Type) {
        external {
            if ($Attributes['query'] -isnot [Collections.IDictionary] -or
                $Attributes['query']['organization'] -isnot [string] -or
                $Attributes['query']['organization'] -cne $Org) {
                throw 'Development state data queries contain foreign organization attributes.'
            }
        }
        terraform_data {
            foreach ($field in @('input', 'output')) {
                if ($Attributes[$field] -isnot [Collections.IDictionary] -or
                    $Attributes[$field]['value'] -isnot [Collections.IDictionary] -or
                    $Attributes[$field]['value']['organization'] -isnot [string] -or
                    $Attributes[$field]['value']['organization'] -cne $Org -or
                    $Attributes[$field]['value']['destroy_started'] -isnot [bool] -or
                    $Attributes[$field]['value']['destroy_started']) {
                    throw 'Development state creation intent contains foreign or incomplete organization attributes.'
                }
            }
        }
        restapi_object {
            if ($Attributes['path'] -isnot [string] -or $Attributes['path'] -cne "/orgs/$Org/rulesets" -or
                $Attributes['id'] -isnot [string] -or $Attributes['id'] -cnotmatch '^[1-9][0-9]{0,17}\z' -or
                $Attributes['api_response'] -isnot [string]) {
                throw 'Development state API resource contains invalid organization attributes.'
            }
            $response = ConvertFrom-Json -InputObject $Attributes['api_response'] -AsHashtable -NoEnumerate
            if ($response -isnot [Collections.IDictionary] -or $response['source'] -isnot [string] -or
                $response['source'] -cne $Org -or $response['source_type'] -isnot [string] -or
                $response['source_type'] -cne 'Organization' -or $response['id'] -isnot [long] -or
                [string] $response['id'] -cne $Attributes['id']) {
                throw 'Development state API response contains mismatched organization attributes.'
            }
        }
        default { throw 'Development state contains unsupported organization attributes.' }
    }
}

# security-check: development-state-field-names
function Assert-DevelopmentStateFieldSet {
    param([Collections.IDictionary] $Value)
    foreach ($name in $Value.get_Keys()) {
        # Terraform's Go decoder folds struct-field names; PowerShell dictionaries do not.
        if ($name -cnotmatch '^[a-z][a-z0-9_]*\z') { throw 'Development snapshot contains a noncanonical state JSON field.' }
    }
}

# security-check: development-state-closure
function Assert-DevelopmentStateClosure {
    param([AllowNull()][object] $State, [string] $Name, [string] $Root, [string] $Org)

    if ($Name -cne 'organization-rulesets') { throw 'Development state snapshots currently support only the organization-rulesets roots.' }
    if ($State -isnot [Collections.IDictionary] -or $State['version'] -isnot [long] -or
        $State['version'] -ne 4 -or $State['serial'] -isnot [long] -or $State['serial'] -lt 0 -or
        $State['lineage'] -isnot [string] -or $State['lineage'] -cnotmatch '^[a-f0-9]{8}(-[a-f0-9]{4}){3}-[a-f0-9]{12}\z' -or
        $State['resources'] -isnot [Collections.IList]) {
        throw 'Development state requires a complete version-4 snapshot with lineage and serial.'
    }
    Assert-DevelopmentStateFieldSet -Value $State
    if ($State['outputs'] -isnot [Collections.IDictionary] -or
        $State['outputs']['organizations'] -isnot [Collections.IDictionary]) {
        throw 'Development state outputs must identify exactly the selected organization.'
    }
    Assert-DevelopmentStateFieldSet -Value $State['outputs']['organizations']
    $organizations = $State['outputs']['organizations']['value']
    if ($organizations -isnot [Collections.IList] -or $organizations.Count -ne 1 -or
        $organizations[0] -isnot [string] -or $organizations[0] -cne $Org) {
        throw 'Development state outputs must identify exactly the selected organization.'
    }
    $expected = @(if ($Root -ceq 'rulesets') {
        @('data:external:ruleset_plan_state', 'data:external:ruleset_state',
            'managed:terraform_data:ruleset_intent', 'managed:restapi_object:ruleset')
    })
    $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($resource in $State['resources']) {
        if ($resource -isnot [Collections.IDictionary] -or $resource.Contains('module') -or
            $resource['mode'] -isnot [string] -or $resource['type'] -isnot [string] -or
            $resource['name'] -isnot [string]) { throw 'Development state contains an unsupported resource address.' }
        Assert-DevelopmentStateFieldSet -Value $resource
        $address = "$($resource['mode']):$($resource['type']):$($resource['name'])"
        if ($expected -cnotcontains $address -or -not $seen.Add($address)) {
            throw 'Development state contains a foreign or duplicate resource address.'
        }
        $instances = $resource['instances']
        if ($instances -isnot [Collections.IList] -or $instances.Count -ne 1 -or
            $instances[0] -isnot [Collections.IDictionary] -or
            $instances[0]['index_key'] -isnot [string] -or $instances[0]['index_key'] -cne $Org -or
            $instances[0]['status'] -or $instances[0]['deposed']) {
            throw 'Development state contains a foreign, incomplete, tainted or deposed organization instance.'
        }
        Assert-DevelopmentStateFieldSet -Value $instances[0]
        Assert-DevelopmentStateAttributeMap -Attributes $instances[0]['attributes'] -Type $resource['type'] -Org $Org
    }
    if ($seen.Count -ne $expected.Count) { throw 'Development state is missing part of the selected organization resource closure.' }
}

# security-check: development-state-path
function Assert-DevelopmentStatePath {
    param([string] $Path)
    for ($current = $Path; $current; $current = [IO.Path]::GetDirectoryName($current)) {
        if (-not (Test-Path -LiteralPath $current)) { continue }
        if ((Get-Item -LiteralPath $current -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
            throw 'Development state paths must not traverse symbolic links.'
        }
    }
}

# security-check: development-state-published
function Assert-DevelopmentPublishedSnapshot {
    param([string] $Directory, [string] $StateName, [string] $Digest, [string] $Manifest)
    $entries = @(Get-ChildItem -LiteralPath $Directory -Force)
    if ($entries.Count -ne 2) { throw 'Existing development snapshot has an unexpected file set.' }
    foreach ($name in @($StateName, 'snapshot.json')) {
        $path = Join-Path $Directory $name
        Assert-DevelopmentStatePath -Path $path
        if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'Existing development snapshot is incomplete.' }
    }
    if ((Get-FileHash -LiteralPath (Join-Path $Directory $StateName)).Hash.ToLowerInvariant() -cne $Digest -or
        [IO.File]::ReadAllText((Join-Path $Directory 'snapshot.json')) -cne $Manifest) {
        throw 'Existing development snapshot differs from the authorized source or provenance.'
    }
}

# security-check: development-state-source
function Read-DevelopmentSnapshotSource {
    param([string] $SourcePath, [string] $OutputPath, [string] $ExpectedDigest)
    $source = [IO.Path]::GetFullPath($SourcePath)
    $destination = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($OutputPath))
    if (-not [IO.Path]::GetDirectoryName($destination)) { throw 'Development snapshot publication requires a named subdirectory.' }
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    foreach ($directory in @($destination, "$destination.new", "$destination.lock")) {
        if ($source.Equals($directory, $comparison) -or
            $source.StartsWith($directory + [IO.Path]::DirectorySeparatorChar, $comparison)) {
            throw 'Development snapshot source and publication paths must be disjoint.'
        }
        Assert-DevelopmentStatePath -Path $directory
    }
    Assert-DevelopmentStatePath -Path $source
    if (-not (Test-Path -LiteralPath $source -PathType Leaf)) { throw 'Development snapshot requires an existing source state file.' }
    $bytes = [IO.File]::ReadAllBytes($source)
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bytes)).ToLowerInvariant()
    if ($digest -cne $ExpectedDigest) { throw 'Development source state does not match the authorized snapshot digest.' }
    return [pscustomobject]@{ Bytes = $bytes; Digest = $digest; Destination = $destination }
}

# security-check: development-state-publication
function Publish-DevelopmentSnapshot {
    param([string] $Destination, [string] $StateName, [byte[]] $Bytes, [string] $Digest, [string] $Manifest)
    $staging = "$Destination.new"
    [IO.Directory]::CreateDirectory([IO.Path]::GetDirectoryName($Destination)) | Out-Null
    # Keep the lock file: deleting it can let two publishers lock different file objects.
    $lease = [IO.File]::Open("$Destination.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
    try {
        if (-not (Test-Path -LiteralPath $Destination)) {
            if (Test-Path -LiteralPath $staging) {
                foreach ($entry in @(Get-ChildItem -LiteralPath $staging -Force)) {
                    if ($entry.Name -cnotin @($StateName, 'snapshot.json') -or $entry -isnot [IO.FileInfo]) {
                        throw 'Interrupted development snapshot contains an unexpected staging entry.'
                    }
                    Assert-DevelopmentStatePath -Path $entry.FullName
                }
                foreach ($name in @($StateName, 'snapshot.json')) { [IO.File]::Delete((Join-Path $staging $name)) }
            }
            [IO.Directory]::CreateDirectory($staging) | Out-Null
            [IO.File]::WriteAllBytes((Join-Path $staging $StateName), $Bytes)
            [IO.File]::WriteAllText((Join-Path $staging 'snapshot.json'), $Manifest, [Text.UTF8Encoding]::new($false))
            [IO.Directory]::Move($staging, $Destination)
        }
        Assert-DevelopmentPublishedSnapshot -Directory $Destination -StateName $StateName -Digest $Digest -Manifest $Manifest
        return [pscustomobject]@{
            StatePath = Join-Path $Destination $StateName
            ManifestPath = Join-Path $Destination 'snapshot.json'
        }
    }
    finally { $lease.Dispose() }
}

$snapshot = Read-DevelopmentSnapshotSource -SourcePath $SourcePath -OutputPath $OutputPath -ExpectedDigest $ExpectedSha256
$state = [Text.UTF8Encoding]::new($false, $true).GetString($snapshot.Bytes) | ConvertFrom-Json -AsHashtable -NoEnumerate
Assert-DevelopmentStateClosure -State $state -Name $Module -Root $StateRoot -Org $Organization
$stateName = if ($StateRoot -ceq 'rulesets') { 'terraform.rulesets.tfstate' } else { 'terraform.tfstate' }
$manifest = [ordered]@{
    version = 1; module = $Module; organization = $Organization; root = $StateRoot
    baselineRevision = $BaselineRevision; candidateRevision = $CandidateRevision; controlRevision = $ControlRevision
    source = [ordered]@{
        container = $Module; key = "organizations/$Organization/$stateName"; etag = $SourceETag
        sha256 = $snapshot.Digest; lineage = $state['lineage']; serial = $state['serial']
    }
}
Publish-DevelopmentSnapshot -Destination $snapshot.Destination -StateName $stateName -Bytes $snapshot.Bytes `
    -Digest $snapshot.Digest -Manifest ((ConvertTo-Json $manifest -Depth 10) + "`n")
