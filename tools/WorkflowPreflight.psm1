#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')

function Invoke-WorkflowGit {
    param([string] $RepositoryPath, [string[]] $Arguments)

    $text = (& git -C $RepositoryPath @Arguments 2>&1 | Out-String).TrimEnd("`r", "`n")
    if ($LASTEXITCODE -ne 0) { throw "Workflow preflight cannot read Git revision: $text" }
    return $text
}

# security-check: workflow-repository-root
function Get-WorkflowRevision {
    param([string] $RepositoryPath)

    $root = Invoke-WorkflowGit $RepositoryPath @('rev-parse', '--show-toplevel')
    if ([IO.Path]::GetFullPath($root) -cne [IO.Path]::GetFullPath($RepositoryPath)) {
        throw 'Workflow preflight requires the instance repository root.'
    }
    $revision = Invoke-WorkflowGit $RepositoryPath @('rev-parse', '--verify', 'HEAD')
    if ($revision -notmatch '^[a-f0-9]{40}\z') { throw 'Workflow preflight requires a full HEAD SHA.' }
    return $revision
}

# security-check: workflow-uses-reference
function Assert-WorkflowReference {
    param([AllowNull()][object] $Value, [string] $ActionsOrganization, [string] $Location)

    if ($Value -isnot [string] -or [string]::IsNullOrWhiteSpace($Value)) {
        throw "Workflow preflight: unsupported uses in ${Location}; require a nonempty string."
    }
    if ($Value.StartsWith('./', [StringComparison]::Ordinal)) {
        if ($Value -ceq './') { return '.' }
        $local = $Value.Substring(2)
        if ($local -notmatch '^[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*\z' -or
            @($local.Split('/') | Where-Object { $_ -in @('.', '..') }).Count -gt 0) {
            throw "Workflow preflight: unsafe local uses '$Value' in ${Location}."
        }
        return $local
    }
    if ($Value -notmatch '^([A-Za-z0-9-]+)/[A-Za-z0-9_.-]+(?:/[A-Za-z0-9_.-]+)*@[a-fA-F0-9]{40}\z') {
        throw "Workflow preflight: unsupported uses in ${Location}: '$Value'; require an actions organization reference with a full SHA."
    }
    if ($Matches[1] -ine $ActionsOrganization) {
        throw "Workflow preflight: uses owner in '$Value' is not actions organization '$ActionsOrganization' (${Location})."
    }
}

# security-check: workflow-document-shape
function Get-WorkflowDocumentReference {
    param(
        [Collections.IDictionary] $Document, [string] $Path, [switch] $Action,
        [Collections.Generic.Dictionary[string, string]] $Files
    )

    $steps = [Collections.Generic.List[object]]::new()
    if ($Action) {
        $runs = $Document['runs']
        if ($runs -isnot [Collections.IDictionary]) { throw "Workflow preflight: missing runs mapping in '$Path'." }
        if ($runs['using'] -isnot [string]) {
            throw "Workflow preflight: unsupported action runtime or image in '$Path'; require a runtime string."
        }
        if ($runs['using'] -ceq 'composite') {
            $steps.Add($runs['steps'])
        }
        elseif ($runs['using'] -cin @('node20', 'node24')) {
            if ($runs['main'] -isnot [string] -or [string]::IsNullOrWhiteSpace($runs['main']) -or $runs.Contains('steps')) {
                throw "Workflow preflight: invalid JavaScript action in '$Path'."
            }
        }
        elseif ($runs['using'] -ceq 'docker') {
            $image = $runs['image']
            if ($image -isnot [string] -or $image -notmatch '^[A-Za-z0-9_-][A-Za-z0-9_.-]*\z') {
                throw "Workflow preflight: unsupported action runtime or image in '$Path'; require a local Dockerfile."
            }
            $imagePath = if ($Path.Contains('/')) { "$($Path.Substring(0, $Path.LastIndexOf('/')))/$image" } else { $image }
            if (-not $Files.ContainsKey($imagePath) -or $Files[$imagePath] -cnotin @('100644', '100755')) {
                throw "Workflow preflight: Dockerfile '$imagePath' must be a regular file in HEAD."
            }
        }
        else {
            throw "Workflow preflight: unsupported action runtime or image in '$Path'; only composite and JavaScript actions are supported."
        }
    }
    else {
        $jobs = $Document['jobs']
        if ($jobs -isnot [Collections.IDictionary] -or $jobs.PSBase.Count -eq 0) {
            throw "Workflow preflight: expected nonempty jobs mapping in '$Path'."
        }
        foreach ($job in $jobs.PSBase.Values) {
            if ($job -isnot [Collections.IDictionary]) { throw "Workflow preflight: invalid job in '$Path'." }
            if ($job.Contains('uses')) {
                if ($job.Contains('steps')) { throw "Workflow preflight: reusable workflow job also has steps in '$Path'." }
                [pscustomobject]@{ Value = $job['uses']; Reusable = $true }
            }
            else { $steps.Add($job['steps']) }
        }
    }
    foreach ($sequence in $steps) {
        if ($sequence -isnot [Collections.IList] -or $sequence.Count -eq 0) {
            throw "Workflow preflight: expected nonempty steps sequence in '$Path'."
        }
        foreach ($step in $sequence) {
            if ($step -isnot [Collections.IDictionary]) { throw "Workflow preflight: invalid step in '$Path'." }
            if ($step.Contains('uses')) {
                if ($step.Contains('run')) { throw "Workflow preflight: step has both uses and run in '$Path'." }
                [pscustomobject]@{ Value = $step['uses']; Reusable = $false }
            }
            elseif ($step['run'] -isnot [string] -or [string]::IsNullOrWhiteSpace($step['run'])) {
                throw "Workflow preflight: unknown step without uses or run in '$Path'."
            }
        }
    }
}

# security-check: workflow-local-target
function Get-WorkflowLocalTarget {
    param([string] $Local, [bool] $Reusable, [Collections.Generic.Dictionary[string, string]] $Files)

    if ($Reusable) {
        if ($Local -cnotmatch '^\.github/workflows/[^/]+\.ya?ml\z') {
            throw "Workflow preflight: local reusable workflow must be in .github/workflows: '$Local'."
        }
        return $Local
    }
    $prefix = if ($Local -ceq '.') { '' } else { "$Local/" }
    $manifests = @('action.yml', 'action.yaml' | ForEach-Object { "$prefix$_" } | Where-Object { $Files.ContainsKey($_) })
    if ($manifests.Count -ne 1) {
        throw "Workflow preflight: local action '$Local' must contain exactly one action.yml or action.yaml in HEAD."
    }
    return $manifests[0]
}

# security-check: workflow-yaml-document
function Read-WorkflowDocument {
    param([string] $RepositoryPath, [string] $Revision, [string] $Path)

    $text = Invoke-WorkflowGit $RepositoryPath @('show', "${Revision}:$Path")
    $parser = [YamlDotNet.Core.Parser]::new([IO.StringReader]::new($text))
    while ($parser.MoveNext()) {
        if ($parser.Current -is [YamlDotNet.Core.Events.AnchorAlias] -or
            ($parser.Current -is [YamlDotNet.Core.Events.NodeEvent] -and -not $parser.Current.Anchor.IsEmpty)) {
            throw "Workflow preflight: YAML anchors and aliases are unsupported in '$Path'."
        }
    }
    return Get-PlatformYaml -Yaml $text
}

# security-check: workflow-checkout-revision
function Assert-PlatformWorkflowRevision {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryPath, [Parameter(Mandatory)][string] $Revision)

    if ((Get-WorkflowRevision $RepositoryPath) -cne $Revision) {
        throw 'Workflow preflight: HEAD changed after validation; rerun plan or apply.'
    }
}

# security-check: workflow-repository-snapshot
function Assert-PlatformWorkflowUses {
    [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseSingularNouns', '', Justification = 'Uses is the GitHub Actions YAML keyword.')]
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $RepositoryPath,
        [Parameter(Mandatory)][ValidatePattern('^[a-z0-9][a-z0-9-]*$')][string] $ActionsOrganization
    )

    $RepositoryPath = [IO.Path]::GetFullPath($RepositoryPath)
    $revision = Get-WorkflowRevision $RepositoryPath
    $files = [Collections.Generic.Dictionary[string, string]]::new([StringComparer]::Ordinal)
    foreach ($entry in (Invoke-WorkflowGit $RepositoryPath @('ls-tree', '-r', '-z', $revision)).Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($entry -notmatch '^([0-9]{6}) (?:blob|commit) [a-f0-9]{40}\t(.+)\z') {
            throw 'Workflow preflight cannot read the Git tree.'
        }
        $files[$Matches[2]] = $Matches[1]
    }
    $workflows = @($files.Keys | Where-Object { $_ -cmatch '^\.github/workflows/[^/]+\.ya?ml\z' })
    if ($workflows.Count -eq 0) { throw 'Workflow preflight found no live workflows in HEAD.' }
    $references = 0
    $pending = [Collections.Generic.Queue[object]]::new()
    foreach ($path in $workflows) { $pending.Enqueue(@{ Path = $path; Action = $false }) }
    $visited = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    while ($pending.Count -gt 0) {
        $item = $pending.Dequeue()
        $path = $item.Path
        if (-not $visited.Add("$($item.Action):$path")) { continue }
        if (-not $files.ContainsKey($path) -or $files[$path] -cnotin @('100644', '100755')) {
            throw "Workflow preflight: '$path' must be a regular file in HEAD (no symlinks or submodules)."
        }
        $document = Read-WorkflowDocument $RepositoryPath $revision $path
        foreach ($reference in @(Get-WorkflowDocumentReference $document $path -Action:$item.Action -Files $files)) {
            $references++
            $local = Assert-WorkflowReference $reference.Value $ActionsOrganization $path
            if ($local) {
                $target = Get-WorkflowLocalTarget $local $reference.Reusable $files
                $pending.Enqueue(@{ Path = $target; Action = -not $reference.Reusable })
            }
        }
    }
    Assert-PlatformWorkflowRevision -RepositoryPath $RepositoryPath -Revision $revision
    [pscustomobject]@{ Revision = $revision; Workflows = $workflows.Count; References = $references }
}

Export-ModuleMember -Function Assert-PlatformWorkflowUses, Assert-PlatformWorkflowRevision
