#Requires -Version 7.4
[CmdletBinding()]
[OutputType([string])]
param(
    [string] $RepositoryPath = (Join-Path $PSScriptRoot '..'),
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$repository = (Resolve-Path -LiteralPath $RepositoryPath).ProviderPath
$pending = [System.Collections.Generic.Queue[string]]::new()
$pending.Enqueue($repository)
$roots = [System.Collections.Generic.List[string]]::new()
while ($pending.Count -gt 0) {
    $directory = $pending.Dequeue()
    $items = @(Get-ChildItem -LiteralPath $directory -Force)
    if (@($items | Where-Object { -not $_.PSIsContainer -and ($_.Name -like '*.tf' -or $_.Name -like '*.tf.json') }).Count -gt 0) {
        $roots.Add([System.IO.Path]::GetRelativePath($repository, $directory).Replace('\', '/'))
    }
    foreach ($item in $items) {
        if ($item.PSIsContainer -and $item.Name -notin @('.git', '.terraform') -and
            -not ($item.Attributes -band [System.IO.FileAttributes]::ReparsePoint)) {
            $pending.Enqueue($item.FullName)
        }
    }
}
[string[]] $names = $roots.ToArray()
[System.Array]::Sort($names, [System.StringComparer]::Ordinal)
$json = ConvertTo-Json -InputObject $names -Compress
if ($GitHubOutputPath) {
    $hasRoots = if ($names.Count -gt 0) { 'true' } else { 'false' }
    [System.IO.File]::AppendAllText([System.IO.Path]::GetFullPath($GitHubOutputPath), "roots=$json`nhas-roots=$hasRoots`n", [System.Text.UTF8Encoding]::new($false))
}
$json
