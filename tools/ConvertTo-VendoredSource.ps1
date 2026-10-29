#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourcePath,
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $CatalogPath,
    [string] $ModeManifestPath,
    [string] $ReleaseMarkerPath,
    [string] $ReleaseVersion,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*$')][string] $ActionsOrganization,
    [Parameter(Mandatory)][ValidateSet('action', 'release')][string] $Kind
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'ToolDependencies.psm1')
Import-Module (Get-ToolDependencyPath -Name powershell-yaml -ReuseLoaded)

# security-check: vendoring-release-tag
function Assert-VendoringReleaseTag {
    param([AllowNull()][object] $CatalogTag, [string] $ExpectedTag, [string] $Upstream)

    if ($CatalogTag -isnot [string] -or $CatalogTag -cne $ExpectedTag) {
        throw "Catalog tag for '$Upstream' must match release pin tag '$ExpectedTag'; update the action copy and catalog before importing this release."
    }
}

# security-check: vendoring-upstream-commit
function Assert-VendoringUpstreamCommit {
    param([AllowNull()][object] $Commit, [string] $Upstream)

    if ($Commit -isnot [string] -or $Commit -cnotmatch '^[a-f0-9]{40}\z') {
        throw "Catalog upstreamCommit for '$Upstream' must be a full lowercase commit SHA from its approved receipt."
    }
}

# security-check: vendoring-release-commit
function Assert-VendoringReleaseCommit {
    param([string] $CatalogCommit, [string] $Pin, [string] $Upstream)

    if ($CatalogCommit -cne $Pin) {
        throw "Upstream commit for '$Upstream' must match release pin '$Pin'; use a version 2 catalog with the approved upstreamCommit and a full lowercase release pin."
    }
}

# security-check: vendoring-release-marker-preparation
function Assert-VendoringReleaseMarkerPreparation {
    param([string] $Kind, [string] $ReleaseVersion, [AllowNull()][object] $Marker)
    if ($Kind -ne 'release') { throw 'Only release preparation can update a release marker.' }
    if ($ReleaseVersion -cnotmatch '^(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)\.(0|[1-9][0-9]*)(-rc\.(0|[1-9][0-9]*))?$') {
        throw 'A release marker requires a stable or release-candidate SemVer version without v.'
    }
    if ($Marker -isnot [Collections.IDictionary]) { throw 'The existing release marker must be an object.' }
    if ($Marker['instance'] -isnot [string] -or [string]::IsNullOrWhiteSpace($Marker['instance'])) {
        throw 'The existing release marker must identify the instance.'
    }
}

$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
if ($catalog -isnot [Collections.IDictionary] -or $catalog['version'] -isnot [long] -or
    $catalog['version'] -ne 2 -or $catalog['actions'] -isnot [Collections.IDictionary]) {
    throw 'Action catalog must declare version 2 and an actions mapping; migrate upstreamCommit from approved receipts.'
}
foreach ($entry in $catalog['actions'].PSBase.Keys) {
    $copy = $catalog['actions'][$entry]
    if ($entry -cnotmatch '^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?/[a-z0-9_.-]{1,100}$' -or
        $copy -isnot [Collections.IDictionary] -or
        $copy['repository'] -cne "$ActionsOrganization/$($entry.Replace('/', '-'))" -or
        $copy['sha'] -cnotmatch '^[a-f0-9]{40}$') {
        throw "Invalid catalog entry '$entry': expected $ActionsOrganization/owner-repo and a full commit SHA."
    }
    Assert-VendoringUpstreamCommit -Commit $copy['upstreamCommit'] -Upstream $entry
}
$source = (Resolve-Path -LiteralPath $SourcePath).Path
$output = [IO.Path]::GetFullPath($OutputPath)
if ($output -eq $source -or $output.StartsWith("$source$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
    throw 'Output must not be inside the source.'
}
if (Test-Path -LiteralPath $output) { throw "Output '$output' already exists; use a new staging directory." }
if ($ModeManifestPath) {
    $modePath = [IO.Path]::GetFullPath($ModeManifestPath)
    if ((Test-Path -LiteralPath $modePath) -or $modePath -eq $source -or $modePath -eq $output -or
        $modePath.StartsWith("$source$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase) -or
        $modePath.StartsWith("$output$([IO.Path]::DirectorySeparatorChar)", [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Mode manifest must be a new file outside the source and prepared trees.'
    }
}
$items = @(Get-ChildItem -LiteralPath $source -Recurse -Force)
if (@($items | Where-Object { $_.Attributes -band [IO.FileAttributes]::ReparsePoint }).Count) {
    throw 'Source must not contain symbolic links.'
}
$files = @($items | Where-Object { -not $_.PSIsContainer })
$pending = [Collections.Generic.List[object]]::new()
foreach ($file in $files) {
    $relative = [IO.Path]::GetRelativePath($source, $file.FullName).Replace('\', '/')
    if ($relative -match '(^|/)\.git(/|$)' -or ($Kind -eq 'action' -and $relative.StartsWith('.github/'))) { continue }
    if ($Kind -eq 'release' -and -not (Test-PlatformReleaseFile -RelativePath $relative)) { continue }
    if ($relative -in @('.vendoring.json', 'platform/.vendoring.json')) { throw "Source contains reserved metadata '$relative'." }
    $bytes = [IO.File]::ReadAllBytes($file.FullName)
    $isManifest = $Kind -eq 'action' -and $file.Name -in @('action.yml', 'action.yaml')
    $isWorkflow = $Kind -eq 'release' -and $relative -match '^templates/instance/\.github/workflows/[^/]+\.ya?ml$'
    if ($isManifest -or $isWorkflow) {
        $text = [Text.Encoding]::UTF8.GetString($bytes)
        $parser = [YamlDotNet.Core.Parser]::new([IO.StringReader]::new($text))
        while ($parser.MoveNext()) {
            if ($parser.Current -is [YamlDotNet.Core.Events.AnchorAlias] -or
                ($parser.Current -is [YamlDotNet.Core.Events.NodeEvent] -and -not $parser.Current.Anchor.IsEmpty)) {
                throw "YAML anchors and aliases are not supported in '$relative'; expand them before import."
            }
        }
        $yaml = [YamlDotNet.RepresentationModel.YamlStream]::new()
        $yaml.Load([IO.StringReader]::new($text))
        if ($yaml.Documents.Count -ne 1) { throw "Expected one YAML document in '$relative'." }
        $root = $yaml.Documents[0].RootNode
        $references = [Collections.Generic.List[object]]::new()
        $getValue = {
            param($Node, [string] $Key)
            if ($Node -is [YamlDotNet.RepresentationModel.YamlMappingNode]) {
                foreach ($pair in $Node.Children.GetEnumerator()) {
                    if ($pair.Key -is [YamlDotNet.RepresentationModel.YamlScalarNode] -and $pair.Key.Value -ceq $Key) { return ,$pair.Value }
                }
            }
        }
        $collectSteps = {
            param($Steps)
            if ($Steps -is [YamlDotNet.RepresentationModel.YamlSequenceNode]) {
                foreach ($step in $Steps.Children) {
                    $reference = & $getValue $step 'uses'
                    if ($reference) { $references.Add($reference) }
                }
            }
        }
        if ($isManifest) {
            & $collectSteps (& $getValue (& $getValue $root 'runs') 'steps')
        }
        else {
            $jobs = & $getValue $root 'jobs'
            if ($jobs -is [YamlDotNet.RepresentationModel.YamlMappingNode]) {
                foreach ($job in $jobs.Children.Values) {
                    $reference = & $getValue $job 'uses'
                    if ($reference) { $references.Add($reference) }
                    & $collectSteps (& $getValue $job 'steps')
                }
            }
        }
        foreach ($node in @($references | Sort-Object { $_.Start.Index } -Descending)) {
            if ($node -isnot [YamlDotNet.RepresentationModel.YamlScalarNode]) { throw "Invalid uses in '$relative'." }
            $reference = $node.Value
            if ($reference.StartsWith('./') -or $reference.StartsWith('docker://')) { continue }
            if ($reference -cnotmatch '^([A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+)(/[^@]+)?@([^@\s]+)$') {
                throw "Unsupported uses '$reference' in '$relative'."
            }
            $upstream = $Matches[1].ToLowerInvariant()
            $subpath = $Matches[2]
            $pin = $Matches[3]
            if (-not $catalog['actions'].Contains($upstream)) {
                throw "Action '$upstream' is missing from the catalog (uses '$reference' in '$relative')."
            }
            $copy = $catalog['actions'][$upstream]
            if ($Kind -eq 'release') {
                Assert-VendoringReleaseCommit -CatalogCommit $copy['upstreamCommit'] -Pin $pin -Upstream $upstream
                $lineEnd = $text.IndexOf("`n", $node.End.Index)
                if ($lineEnd -lt 0) { $lineEnd = $text.Length }
                $comment = $text.Substring($node.End.Index, $lineEnd - $node.End.Index)
                $pinTag = [regex]::Match($comment, '^\s+#\s+(?<tag>v[0-9][0-9A-Za-z.+_-]*)(?:\s|$)')
                if ($pinTag.Success) {
                    Assert-VendoringReleaseTag -CatalogTag $copy['tag'] -ExpectedTag $pinTag.Groups['tag'].Value -Upstream $upstream
                }
            }
            $replacement = "'$($copy['repository'])$subpath@$($copy['sha'])'"
            $text = $text.Remove($node.Start.Index, $node.End.Index - $node.Start.Index).Insert($node.Start.Index, $replacement)
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    }
    $destinationPath = if ($Kind -eq 'release') { "platform/$relative" } else { $relative }
    $pending.Add(@{ Path = $destinationPath; Bytes = $bytes; Source = $file.FullName })
}
if (-not $pending.Count) { throw 'Source has no importable files.' }
if ($ReleaseMarkerPath) {
    $marker = Get-Content -LiteralPath $ReleaseMarkerPath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    Assert-VendoringReleaseMarkerPreparation -Kind $Kind -ReleaseVersion $ReleaseVersion -Marker $marker
    Import-Module (Join-Path $PSScriptRoot 'ReleaseIntegrity.psm1')
    $rawFiles = Get-ReleaseFileHash -Path $source -RawRelease
    $updatedMarker = @{ instance = $marker['instance']; releaseVersion = $ReleaseVersion; files = $rawFiles }
    $pending.Add(@{
        Path = '.platform-bootstrap.json'
        Bytes = [Text.UTF8Encoding]::new($false).GetBytes(($updatedMarker | ConvertTo-Json -Depth 10) + "`n")
        Source = $null
    })
}
foreach ($item in $pending) {
    $destination = Join-Path $output $item.Path
    $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
    [IO.File]::WriteAllBytes($destination, $item.Bytes)
    if (-not $IsWindows -and $item.Source) { [IO.File]::SetUnixFileMode($destination, [IO.File]::GetUnixFileMode($item.Source)) }
}
if ($ModeManifestPath) {
    $modes = [ordered]@{}
    foreach ($item in $pending) {
        $modes[$item.Path] = -not $IsWindows -and $item.Source -and (([int] [IO.File]::GetUnixFileMode($item.Source) -band 73) -ne 0)
    }
    @{ version = 1; files = $modes } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $ModeManifestPath -Encoding utf8NoBOM
}
