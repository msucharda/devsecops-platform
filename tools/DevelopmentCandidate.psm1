#Requires -Version 7.4
Set-StrictMode -Version Latest

function Invoke-DevelopmentGit {
    param([string] $Path, [string[]] $Arguments)
    $result = (& git -C $Path @Arguments 2>&1 | Out-String).TrimEnd("`r", "`n")
    if ($LASTEXITCODE -ne 0) { throw "Development candidate Git validation failed: $result" }
    return $result
}

# security-check: development-candidate-snapshot
function Get-DevelopmentCandidateSnapshot {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [switch] $TrustedRuntime)

    $root = [IO.Path]::GetFullPath($Path)
    if ((Get-Item -LiteralPath $root -Force).Attributes -band [IO.FileAttributes]::ReparsePoint) {
        throw 'Development candidate repository root must not be a symbolic link.'
    }
    $actualRoot = Invoke-DevelopmentGit $root @('rev-parse', '--show-toplevel')
    $pathComparer = if ($IsWindows) { [StringComparer]::OrdinalIgnoreCase } else { [StringComparer]::Ordinal }
    if (-not $pathComparer.Equals([IO.Path]::GetFullPath($actualRoot), $root)) { throw 'Development candidate must be a repository root.' }
    $revision = Invoke-DevelopmentGit $root @('rev-parse', 'HEAD')
    if ($revision -cnotmatch '^[a-f0-9]{40}\z') { throw 'Development candidate requires a full commit SHA.' }
    if (Invoke-DevelopmentGit $root @('status', '--porcelain', '--untracked-files=all')) {
        throw 'Development candidate requires a clean checkout without untracked files.'
    }
    $ignored = Invoke-DevelopmentGit $root @('ls-files', '--others', '--ignored', '--exclude-standard', '-z')
    foreach ($path in $ignored.Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries)) {
        if (-not $TrustedRuntime -or -not $path.StartsWith('platform/tools/.dependencies/', [StringComparison]::Ordinal)) {
            throw 'Development candidate contains ignored files outside the trusted dependency cache.'
        }
    }
    $files = [Collections.Generic.Dictionary[string,string]]::new([StringComparer]::Ordinal)
    $manifest = [Collections.Generic.List[object]]::new()
    foreach ($entry in (Invoke-DevelopmentGit $root @('ls-tree', '-r', '-z', $revision)).Split([char] 0, [StringSplitOptions]::RemoveEmptyEntries)) {
        if ($entry -cnotmatch '^(100644|100755) blob ([a-f0-9]{40})\t(.+)\z') {
            throw 'Development candidate must contain only regular tracked files.'
        }
        $mode = $Matches[1]; $blob = $Matches[2]; $relative = $Matches[3]
        if ($relative.Contains('\')) { throw 'Development candidate contains an unsafe path.' }
        $file = Join-Path $root $relative
        $item = Get-Item -LiteralPath $file -Force -ErrorAction Stop
        if ($item.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Development candidate contains a symbolic link.' }
        for ($parent = $item.Directory; -not $pathComparer.Equals($parent.FullName, $root); $parent = $parent.Parent) {
            if ($parent.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Development candidate contains a symbolic link.' }
        }
        if ((Invoke-DevelopmentGit $root @('hash-object', '--no-filters', '--', $relative)) -cne $blob) {
            throw "Development candidate working bytes differ from HEAD: '$relative'."
        }
        $hash = (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash.ToLowerInvariant()
        $files.Add($relative, "$mode`:$hash")
        $manifest.Add(@($relative, $mode, $hash))
    }
    if ($files.Count -eq 0) { throw 'Development candidate has no tracked files.' }
    $json = ConvertTo-Json -InputObject @($manifest.ToArray()) -Depth 10 -Compress
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
    [pscustomobject]@{ Revision = $revision; Digest = $digest; Files = $files }
}

# security-check: development-candidate-approval
function Assert-DevelopmentCandidateApproval {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Approval, [string] $ReferenceRepository, [string] $RepositoryUrl,
        [string] $Revision, [string] $BaseRevision, [string] $Digest, [string] $PullRequest,
        [ValidateSet('plan', 'apply')][string] $Operation
    )
    if ($Operation -cnotin @('plan', 'apply')) { throw 'Development approval operation must be plan or apply.' }
    if ([string]::IsNullOrWhiteSpace($ReferenceRepository) -or $ReferenceRepository -cne $RepositoryUrl) {
        throw 'Development mode is restricted to the externally configured reference repository.'
    }
    if ($Approval -isnot [Collections.IDictionary]) { throw 'Development approval must be an external JSON object.' }
    $expected = @{
        version = 1; repository = $RepositoryUrl; revision = $Revision; baseRevision = $BaseRevision
        digest = $Digest; pullRequest = $PullRequest; operation = $Operation
    }
    foreach ($key in $expected.Keys) {
        if ($key -ceq 'version') {
            if ($Approval[$key] -isnot [long] -or $Approval[$key] -ne 1) { throw 'Development approval version must be integer 1.' }
        }
        elseif ($Approval[$key] -isnot [string] -or $Approval[$key] -cne $expected[$key]) {
            throw "Development approval does not match $key."
        }
    }
    foreach ($key in @('approvedBy', 'approvalUrl')) {
        if ($Approval[$key] -isnot [string] -or [string]::IsNullOrWhiteSpace($Approval[$key])) {
            throw "Development approval requires $key."
        }
    }
    $expiry = [DateTimeOffset]::MinValue
    if ($Approval['expiresAt'] -isnot [string] -or
        -not [DateTimeOffset]::TryParseExact($Approval['expiresAt'], 'o', [Globalization.CultureInfo]::InvariantCulture,
            [Globalization.DateTimeStyles]::None, [ref] $expiry) -or $expiry -le [DateTimeOffset]::UtcNow) {
        throw 'Development approval is expired or has an invalid expiresAt timestamp.'
    }
}

# security-check: development-candidate-boundary
function Assert-DevelopmentCandidateBoundary {
    [CmdletBinding()]
    param([Collections.IDictionary] $Baseline, [Collections.IDictionary] $Candidate)

    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Baseline.get_Keys()) { $null = $paths.Add($path) }
    foreach ($path in $Candidate.get_Keys()) { $null = $paths.Add($path) }
    $changed = 0
    foreach ($path in $paths) {
        if ($Baseline.get_Keys() -ccontains $path -and $Candidate.get_Keys() -ccontains $path -and $Baseline[$path] -ceq $Candidate[$path]) { continue }
        $changed++
        # Authorization and credential contracts are deliberately outside the candidate's editable boundary.
        if ($path -cnotmatch '^platform/(modules/|tools/)' -or $path -imatch '(^|/)module\.yaml\z' -or
            $path -imatch '(^|/)\.dependencies(/|$)' -or
            $path -imatch '^platform/tools/(DevelopmentCandidate|DevelopmentControl|DevelopmentToken|Read-DevelopmentControl|New-DevelopmentStateSnapshot|Test-StandardDeployment|Test-Deployment|Test-Development|New-PlatformGitHubToken|Remove-PlatformGitHubToken|GitHubToken|PlatformTools|ToolDependencies|Select-InstanceModules|ReleaseIntegrity|Get-VendoringSource|ConvertTo-VendoredSource|Resolve-PlatformReleaseImport|VendoringCatalog|Install-ToolDependencies)') {
            throw "Development candidate changes protected authorization or instance content: '$path'."
        }
    }
    if ($changed -eq 0) { throw 'Development candidate must contain an exact development change.' }
}

# security-check: development-protected-module
function Get-DevelopmentProtectedModule {
    [CmdletBinding()]
    param([Collections.IDictionary] $Modules)
    $protected = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    $pending = [Collections.Generic.Queue[string]]::new()
    foreach ($name in $Modules.get_Keys()) {
        $manifest = $Modules[$name]
        $permissions = $manifest['permissions']
        $enterprisePermissions = @($permissions['githubApp'].PSBase.Values | ForEach-Object {
            $declaration = $_
            $_['permissions'].get_Keys() | Where-Object {
                $_.StartsWith('enterprise_', [StringComparison]::Ordinal) -or
                ($_ -ceq 'members' -and $declaration['permissions'][$_] -ceq 'write')
            }
        })
        if (@($permissions['azure']).Count -eq 0 -and @($permissions['microsoftGraph']).Count -eq 0 -and
            (-not $permissions.Contains('entraDirectoryRoles') -or @($permissions['entraDirectoryRoles']).Count -eq 0) -and
            $enterprisePermissions.Count -eq 0) { continue }
        $null = $protected.Add($name)
        $pending.Enqueue($name)
    }
    while ($pending.Count -gt 0) {
        $name = $pending.Dequeue()
        foreach ($prerequisite in $Modules[$name]['prerequisites']) {
            $dependency = $prerequisite.Split(':')[0]
            if ($protected.Add($dependency)) { $pending.Enqueue($dependency) }
        }
    }
    return @($protected | Sort-Object -CaseSensitive)
}

# security-check: development-protected-execution
function Assert-DevelopmentProtectedExecution {
    [CmdletBinding()]
    param(
        [Collections.IDictionary] $Baseline, [Collections.IDictionary] $Candidate, [Collections.IDictionary] $Modules
    )
    $protectedModules = @(Get-DevelopmentProtectedModule -Modules $Modules)
    if ($ProtectedModules.Count -eq 0) { return }
    $runtime = @(
        'platform/tools/Invoke-Module.ps1', 'platform/tools/PlatformTools.psm1',
        'platform/tools/ToolDependencies.psm1', 'platform/tools/requirements.psd1',
        'platform/tools/WorkflowPreflight.psm1',
        'platform/modules/shared/scripts/GitHubRetry.ps1'
    )
    $prefixes = @('platform/tools/vendor/') + @($ProtectedModules | ForEach-Object { "platform/modules/$_/" })
    $paths = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in $Baseline.get_Keys()) { $null = $paths.Add($path) }
    foreach ($path in $Candidate.get_Keys()) { $null = $paths.Add($path) }
    foreach ($path in $paths) {
        $protected = $runtime -ccontains $path -or @($prefixes | Where-Object { $path.StartsWith($_, [StringComparison]::Ordinal) }).Count -gt 0
        if (-not $protected) { continue }
        if ($Baseline.get_Keys() -cnotcontains $path -or $Candidate.get_Keys() -cnotcontains $path -or $Baseline[$path] -cne $Candidate[$path]) {
            throw "Development candidate changes protected executable closure: '$path'; use a standard release."
        }
    }
}

# security-check: development-phase-authority
function Assert-DevelopmentPhaseAuthority {
    [CmdletBinding()]
    param([Collections.IDictionary] $Instance, [Collections.IDictionary] $Modules, [string] $Repository)
    $parts = $Repository.Split('/')
    if ($parts.Count -ne 2) { throw 'Development authority inspection requires the exact reference repository.' }
    $protected = @(Get-DevelopmentProtectedModule -Modules $Modules)
    foreach ($name in $Instance['credentials'].get_Keys()) {
        if ($protected -ccontains $name) { continue }
        foreach ($binding in $Instance['credentials'][$name].PSBase.Values) {
            if (-not $binding.Contains('githubApp')) { continue }
            $app = $Instance['githubApps'][$binding['githubApp']]
            $resources = $app['resources']
            if ($resources.Contains('enterprise')) { throw 'Candidate execution must not receive enterprise installation authority.' }
            if ($resources['organizations'] -inotcontains $parts[0]) { continue }
            $reachesReference = -not $resources.Contains('repositories')
            if ($resources.Contains('repositories')) {
                foreach ($owner in $resources['repositories'].get_Keys()) {
                    if ($owner -ieq $parts[0] -and $resources['repositories'][$owner] -icontains $parts[1]) { $reachesReference = $true }
                }
            }
            $writes = @($app['permissions'].get_Keys() | Where-Object { $app['permissions'][$_] -ceq 'write' })
            $organizationWrites = @($writes | Where-Object { $_ -cnotin @('administration', 'contents', 'actions', 'workflows') })
            if ($writes.Count -gt 0 -and ($reachesReference -or $organizationWrites.Count -gt 0)) {
                throw "Candidate module '$name' has reference repository authority; use a standard release or remove that candidate-reachable authority."
            }
        }
    }
}

# security-check: development-prerequisite-artifact
function Assert-DevelopmentPrerequisiteArtifact {
    [CmdletBinding()]
    param([AllowEmptyString()][string] $ArtifactId)
    if ($ArtifactId -notmatch '^[1-9][0-9]*\z') { throw 'A nonempty immutable prerequisite artifact ID is required; downloading all artifacts is forbidden.' }
}

# security-check: development-candidate-revision
function Assert-DevelopmentCandidateRevision {
    [CmdletBinding()]
    param([string] $Path, [string] $Revision, [string] $ExpectedRevision, [string] $BaseRevision)
    if ($ExpectedRevision -cnotmatch '^[a-f0-9]{40}\z' -or $Revision -cne $ExpectedRevision) {
        throw 'Development candidate does not match the authorized PR head.'
    }
    $null = & git -C $Path merge-base --is-ancestor $BaseRevision $Revision 2>&1
    if ($LASTEXITCODE -ne 0) { throw 'Development candidate must descend from the verified baseline.' }
}

Export-ModuleMember -Function Get-DevelopmentCandidateSnapshot, Assert-DevelopmentCandidateApproval, Assert-DevelopmentCandidateBoundary, Assert-DevelopmentCandidateRevision, Get-DevelopmentProtectedModule, Assert-DevelopmentProtectedExecution, Assert-DevelopmentPhaseAuthority, Assert-DevelopmentPrerequisiteArtifact
