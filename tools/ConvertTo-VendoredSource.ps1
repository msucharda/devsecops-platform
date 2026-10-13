#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $SourcePath,
    [Parameter(Mandatory)][string] $OutputPath,
    [Parameter(Mandatory)][string] $CatalogPath,
    [string] $ModeManifestPath,
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*$')][string] $ActionsOrganization,
    [Parameter(Mandatory)][ValidateSet('action', 'release')][string] $Kind
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module powershell-yaml -RequiredVersion 0.4.12
$catalog = Get-Content -LiteralPath $CatalogPath -Raw | ConvertFrom-Json -AsHashtable
if ($catalog['version'] -ne 1 -or $catalog['actions'] -isnot [Collections.IDictionary]) {
    throw 'Action catalog must declare version 1 and an actions mapping.'
}
foreach ($entry in $catalog['actions'].PSBase.Keys) {
    $copy = $catalog['actions'][$entry]
    if ($entry -cnotmatch '^[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+$' -or
        $copy -isnot [Collections.IDictionary] -or
        $copy['repository'] -cne "$ActionsOrganization/$($entry.Replace('/', '-'))" -or
        $copy['sha'] -cnotmatch '^[a-f0-9]{40}$') {
        throw "Invalid catalog entry '$entry': expected $ActionsOrganization/owner-repo and a full commit SHA."
    }
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
            $upstream = $Matches[1]
            $subpath = $Matches[2]
            if (-not $catalog['actions'].Contains($upstream)) {
                throw "Action '$upstream' is missing from the catalog (uses '$reference' in '$relative')."
            }
            $copy = $catalog['actions'][$upstream]
            $replacement = "'$($copy['repository'])$subpath@$($copy['sha'])'"
            $text = $text.Remove($node.Start.Index, $node.End.Index - $node.Start.Index).Insert($node.Start.Index, $replacement)
        }
        $bytes = [Text.UTF8Encoding]::new($false).GetBytes($text)
    }
    $destinationPath = if ($Kind -eq 'release') { "platform/$relative" } else { $relative }
    $pending.Add(@{ Path = $destinationPath; Bytes = $bytes; Source = $file.FullName })
}
if (-not $pending.Count) { throw 'Source has no importable files.' }
foreach ($item in $pending) {
    $destination = Join-Path $output $item.Path
    $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
    [IO.File]::WriteAllBytes($destination, $item.Bytes)
    if (-not $IsWindows) { [IO.File]::SetUnixFileMode($destination, [IO.File]::GetUnixFileMode($item.Source)) }
}
if ($ModeManifestPath) {
    $modes = [ordered]@{}
    foreach ($item in $pending) {
        $modes[$item.Path] = -not $IsWindows -and (([int] [IO.File]::GetUnixFileMode($item.Source) -band 73) -ne 0)
    }
    @{ version = 1; files = $modes } | ConvertTo-Json -Depth 10 |
        Set-Content -LiteralPath $ModeManifestPath -Encoding utf8NoBOM
}
