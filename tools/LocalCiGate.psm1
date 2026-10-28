#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

function Get-LocalCiProfile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string[]] $PesterPath = @(),
        [switch] $AllPester
    )
    $catalog = Import-PowerShellDataFile (Join-Path $RepositoryRoot 'tools/test-profiles.psd1')
    $full = @()
    $local = @()
    foreach ($category in 'Unit', 'Contract', 'Integration', 'Interruption') {
        foreach ($name in $catalog[$category]) {
            $path = "tools/tests/$name"
            if ($path -in $full) { throw "Duplicate test profile entry: $path" }
            if (-not (Test-Path -LiteralPath (Join-Path $RepositoryRoot $path) -PathType Leaf)) {
                throw "Test profile entry does not exist: $path"
            }
            $full += $path
            if ($category -in @('Unit', 'Contract')) { $local += $path }
        }
    }
    $discovered = @(Get-ChildItem (Join-Path $RepositoryRoot 'tools/tests') -Recurse -Filter '*.Tests.ps1' |
        ForEach-Object { [IO.Path]::GetRelativePath($RepositoryRoot, $_.FullName).Replace('\', '/') })
    $missing = @($discovered | Where-Object { $_ -notin $full })
    if ($missing.Count -gt 0) { throw "Tests missing from tools/test-profiles.psd1: $($missing -join ', ')" }
    $selected = @($local | Where-Object { $AllPester -or $_ -in $PesterPath })
    return @{
        Full = @($full | Sort-Object)
        Local = @($local | Sort-Object)
        Selected = @($selected | Sort-Object)
        Remote = @($full | Where-Object { $_ -notin $selected } | Sort-Object)
    }
}

function Invoke-LocalCiGitText {
    [CmdletBinding()]
    param([string] $RepositoryRoot, [string[]] $Argument)
    $start = [Diagnostics.ProcessStartInfo]::new('git')
    $start.UseShellExecute = $false
    $start.RedirectStandardOutput = $true
    $start.RedirectStandardError = $true
    $start.StandardOutputEncoding = [Text.UTF8Encoding]::new($false, $true)
    foreach ($item in @('-C', $RepositoryRoot) + $Argument) { $start.ArgumentList.Add($item) }
    $process = [Diagnostics.Process]::Start($start)
    try {
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.WaitForExit()
        if ($process.ExitCode -ne 0) { throw "git $($Argument -join ' ') failed: $($stderr.GetAwaiter().GetResult())" }
        return $stdout.GetAwaiter().GetResult()
    }
    finally { $process.Dispose() }
}

function Get-LocalCiChangedFile {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][string] $MergeBase,
        [string] $Head
    )
    $diff = @('diff', '--name-only', '--no-renames', '-z')
    $range = @($MergeBase)
    if ($Head) { $range += $Head }
    $changed = (Invoke-LocalCiGitText $RepositoryRoot ($diff + $range)).Split(
        [char]0, [StringSplitOptions]::RemoveEmptyEntries)
    $added = (Invoke-LocalCiGitText $RepositoryRoot ($diff + '--diff-filter=A' + $range)).Split(
        [char]0, [StringSplitOptions]::RemoveEmptyEntries)
    $untracked = (Invoke-LocalCiGitText $RepositoryRoot @('ls-files', '--others', '--exclude-standard', '-z')).Split(
        [char]0, [StringSplitOptions]::RemoveEmptyEntries)
    $unique = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($path in @($changed) + @($untracked)) { $null = $unique.Add($path) }
    return @{
        Changed = [string[]] @($unique | Sort-Object -CaseSensitive)
        Added = [string[]] @(@($added) + @($untracked))
    }
}

# security-check: local-ci-index-visibility
function Assert-LocalCiIndexVisibility {
    [CmdletBinding()]
    param([AllowEmptyCollection()][string[]] $Entry)
    if (@($Entry | Where-Object { $_ -cnotmatch '^H ' }).Count -gt 0) {
        throw 'Git index flags hide source state. Clear assume-unchanged and skip-worktree (including sparse-checkout) before running the gate.'
    }
}

function Get-LocalCiContentState {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot, [Parameter(Mandatory)][string] $Base)
    $head = (Invoke-LocalCiGitText $RepositoryRoot @('rev-parse', '--verify', 'HEAD^{commit}')).Trim()
    $baseSha = (Invoke-LocalCiGitText $RepositoryRoot @('rev-parse', '--verify', "$Base^{commit}")).Trim()
    $mergeBase = (Invoke-LocalCiGitText $RepositoryRoot @('merge-base', $baseSha, $head)).Trim()
    $indexEntries = (Invoke-LocalCiGitText $RepositoryRoot @('ls-files', '-v', '-z')).Split(
        [char]0, [StringSplitOptions]::RemoveEmptyEntries)
    Assert-LocalCiIndexVisibility -Entry $indexEntries
    $paths = (Invoke-LocalCiGitText $RepositoryRoot @('ls-files', '-z', '--cached', '--others', '--exclude-standard')).Split(
        [char]0, [StringSplitOptions]::RemoveEmptyEntries)
    $hash = [Security.Cryptography.IncrementalHash]::CreateHash([Security.Cryptography.HashAlgorithmName]::SHA256)
    try {
        foreach ($path in @($paths | Sort-Object -Unique -CaseSensitive)) {
            $file = Join-Path $RepositoryRoot $path
            $contentHash = if (Test-Path -LiteralPath $file -PathType Leaf) { (Get-FileHash -LiteralPath $file -Algorithm SHA256).Hash }
            elseif (-not (Test-Path -LiteralPath $file)) { 'deleted' }
            else { throw "Cannot fingerprint non-file Git entry: $path" }
            $hash.AppendData([Text.Encoding]::UTF8.GetBytes("$($path.Length):$path=$contentHash`n"))
        }
        $fingerprint = [Convert]::ToHexString($hash.GetHashAndReset()).ToLowerInvariant()
    }
    finally { $hash.Dispose() }
    if ((Invoke-LocalCiGitText $RepositoryRoot @('rev-parse', 'HEAD')).Trim() -cne $head) {
        throw 'HEAD changed while computing the local gate fingerprint.'
    }
    $clean = (Invoke-LocalCiGitText $RepositoryRoot @('status', '--porcelain=v1', '-z', '--untracked-files=normal')).Length -eq 0
    return @{ Head = $head; Base = $Base; BaseSha = $baseSha; MergeBase = $mergeBase; Fingerprint = $fingerprint; Clean = $clean }
}

function Get-LocalCiResultPath {
    param([string] $RepositoryRoot)
    return (Invoke-LocalCiGitText $RepositoryRoot @('rev-parse', '--path-format=absolute', '--git-path', 'local-ci-pass.json')).Trim()
}

function Clear-LocalCiGateResult {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $RepositoryRoot)
    $path = Get-LocalCiResultPath $RepositoryRoot
    if (Test-Path -LiteralPath $path) { Remove-Item -LiteralPath $path -Force }
}

function Save-LocalCiGateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [Parameter(Mandatory)][hashtable] $State,
        [Parameter(Mandatory)][ValidateSet('Local', 'Full')][string] $GateProfile
    )
    $result = @{ Schema = 1; Status = 'selected-local-gate-passed'; Profile = $GateProfile; State = $State; CompletedAt = [datetime]::UtcNow.ToString('o') }
    $path = Get-LocalCiResultPath $RepositoryRoot
    $temporary = "$path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, ($result | ConvertTo-Json -Depth 5), [Text.UTF8Encoding]::new($false))
        [IO.File]::Move($temporary, $path, $true)
    }
    finally { if (Test-Path -LiteralPath $temporary) { Remove-Item -LiteralPath $temporary -Force } }
}

# security-check: local-ci-result-binding
function Test-LocalCiGateResult {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $RepositoryRoot,
        [string] $Base,
        [string] $ExpectedHead
    )
    $path = Get-LocalCiResultPath $RepositoryRoot
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) { throw 'No successful local gate result; run tools/Invoke-LocalCi.ps1 before pushing.' }
    $result = Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate
    if ($result -isnot [hashtable] -or $result['Schema'] -isnot [long] -or $result['Schema'] -ne 1 -or
        $result['Status'] -isnot [string] -or $result['Status'] -cne 'selected-local-gate-passed' -or
        $result['Profile'] -isnot [string] -or $result['Profile'] -cnotin @('Local', 'Full') -or $result['State'] -isnot [hashtable]) {
        throw 'Invalid local gate result; rerun tools/Invoke-LocalCi.ps1.'
    }
    if (-not $Base) {
        if ($result.State['Base'] -isnot [string] -or [string]::IsNullOrWhiteSpace($result.State['Base'])) {
            throw 'Invalid local gate result: missing base reference.'
        }
        $Base = $result.State['Base']
    }
    $current = Get-LocalCiContentState -RepositoryRoot $RepositoryRoot -Base $Base
    foreach ($key in 'Head', 'BaseSha', 'MergeBase', 'Fingerprint') {
        if ($result.State[$key] -isnot [string] -or $result.State[$key] -cne $current[$key]) {
            throw "Local gate result is stale ($key changed); rerun tools/Invoke-LocalCi.ps1."
        }
    }
    if (-not $current.Clean) { throw 'Commit all source changes before running the local gate; the push must publish the tested content.' }
    if ($ExpectedHead -and $ExpectedHead -cne $current.Head) { throw 'Local gate result is stale: push does not target the validated HEAD.' }
    return $true
}

function Assert-LocalCiTempPath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [bool] $Windows = $IsWindows)
    if ($Windows -and [IO.Path]::GetFullPath($Path).Length -gt 64) {
        throw "TEMP path exceeds 64 characters: $Path. Use -TempRoot with a short private directory for nested test repositories and git refs."
    }
}

function Test-LocalCiRuntime {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $TempPath,
        [string] $Executable = 'pwsh'
    )
    $probe = Join-Path $TempPath "external-probe-$([guid]::NewGuid().ToString('N')).ps1"
    $process = $null
    try {
        $null = New-Item -ItemType Directory -Force -Path $TempPath
        [IO.File]::WriteAllText($probe, @'
$ErrorActionPreference = 'Stop'
$query = [Console]::In.ReadToEnd() | ConvertFrom-Json -AsHashtable
if ($query['probe'] -cne 'local-ci') { throw 'Invalid preflight input' }
@{ probe = 'local-ci'; version = $PSVersionTable.PSVersion.ToString() } | ConvertTo-Json -Compress
'@)
        # .NET can launch Store aliases that Go (and Terraform) reject. Probe Go's os/exec, not .NET's pwsh lookup.
        if (-not (Get-Command go -CommandType Application -ErrorAction SilentlyContinue)) {
            throw 'Go is missing. Install Go to run the Terraform-compatible external-program preflight.'
        }
        $start = [Diagnostics.ProcessStartInfo]::new('go')
        $start.UseShellExecute = $false
        $start.RedirectStandardInput = $true
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in 'run', '-p=1', (Join-Path $PSScriptRoot 'probes/powershell-external.go'), $Executable, $probe) { $start.ArgumentList.Add($argument) }
        $start.Environment['GOMAXPROCS'] = '1'
        $process = [Diagnostics.Process]::Start($start)
        $stdout = $process.StandardOutput.ReadToEndAsync()
        $stderr = $process.StandardError.ReadToEndAsync()
        $process.StandardInput.Close()
        if (-not $process.WaitForExit(60000)) {
            $process.Kill($true)
            $process.WaitForExit()
            throw 'The Go/pwsh preflight did not finish within 60 seconds.'
        }
        if ($process.ExitCode -ne 0) { throw "pwsh exited $($process.ExitCode): $($stderr.GetAwaiter().GetResult())" }
        $response = $stdout.GetAwaiter().GetResult() | ConvertFrom-Json -AsHashtable -NoEnumerate
        if ($response -isnot [hashtable] -or $response.Count -ne 2 -or $response['probe'] -isnot [string] -or $response['probe'] -cne 'local-ci' -or
            $response['version'] -isnot [string] -or [version] $response['version'] -lt [version] '7.4') {
            throw 'pwsh did not return the expected external-program string map for PowerShell 7.4 or newer.'
        }
        return $true
    }
    catch {
        throw "pwsh external-program preflight failed: $($_.Exception.Message) Install a working PowerShell distribution and put its directory before Microsoft Store aliases on PATH."
    }
    finally {
        if ($null -ne $process) {
            if (-not $process.HasExited) { $process.Kill($true); $process.WaitForExit() }
            $process.Dispose()
        }
        if (Test-Path -LiteralPath $probe) { Remove-Item -LiteralPath $probe -Force }
    }
}

# security-check: local-ci-temp-root-scope
function Assert-LocalCiWindowsTempRoot {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyString()][string] $Path,
        [Parameter(Mandatory)][string] $UserProfile,
        [bool] $Windows = $IsWindows
    )
    if (-not $Windows) {
        if ($Path) { throw '-TempRoot is only supported on Windows. Omit it on other platforms and use the default private data directory.' }
        return
    }
    $root = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($Path))
    $profileRoot = [IO.Path]::TrimEndingDirectorySeparator([IO.Path]::GetFullPath($UserProfile))
    if (-not [string]::Equals([IO.Path]::GetDirectoryName($root), $profileRoot, [StringComparison]::OrdinalIgnoreCase)) {
        throw 'Unsafe CI TEMP root: use a direct child of UserProfile, for example <UserProfile>\.dci. Nested paths and volume-root children are not supported.'
    }
}

# security-check: local-ci-temp-access
function Assert-LocalCiTempAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Access, [Parameter(Mandatory)][string] $UserSid)
    if ($Access.Directory -isnot [bool] -or -not $Access.Directory -or
        $Access.ReparsePoint -isnot [bool] -or $Access.ReparsePoint) { throw 'Unsafe CI TEMP: not a regular directory.' }
    if ($Access.Owner -cnotin @($UserSid, 'S-1-5-18')) { throw 'Unsafe CI TEMP: directory has an untrusted owner.' }
    if ($Access.Protected -isnot [bool] -or -not $Access.Protected) { throw 'Unsafe CI TEMP: ACL inheritance is not disabled.' }
    $expected = @($UserSid, 'S-1-5-18' | Sort-Object -Unique -CaseSensitive)
    if (@($Access.Rules).Count -ne $expected.Count) { throw 'Unsafe CI TEMP: unexpected access rules.' }
    foreach ($sid in $expected) {
        if (@($Access.Rules | Where-Object Sid -CEQ $sid).Count -ne 1) { throw 'Unsafe CI TEMP: missing or duplicate access identity.' }
    }
    $fullControl = [int] [Security.AccessControl.FileSystemRights]::FullControl
    $inheritBoth = [int] ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit)
    foreach ($rule in $Access.Rules) {
        if ($rule.Type -cne 'Allow' -or $rule.Rights -ne $fullControl -or $rule.Inheritance -ne $inheritBoth -or
            $rule.Propagation -ne 0 -or $rule.Inherited -isnot [bool] -or $rule.Inherited) {
            throw 'Unsafe CI TEMP: access rule does not grant exclusive owner/SYSTEM control.'
        }
    }
}

function Initialize-LocalCiPrivateTempDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)
    if (-not $IsWindows) {
        $null = New-Item -ItemType Directory -Force -Path $Path
        return
    }
    $user = [Security.Principal.WindowsIdentity]::GetCurrent().User
    if (-not (Test-Path -LiteralPath $Path)) {
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($user)
        $security.SetAccessRuleProtection($true, $false)
        foreach ($sid in @($user.Value, 'S-1-5-18' | Sort-Object -Unique -CaseSensitive)) {
            $rule = [Security.AccessControl.FileSystemAccessRule]::new(
                [Security.Principal.SecurityIdentifier]::new($sid),
                [Security.AccessControl.FileSystemRights]::FullControl,
                ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
                [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow)
            $null = $security.AddAccessRule($rule)
        }
        # Supply the protected ACL during creation, never repair an existing untrusted directory.
        $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, [IO.Path]::GetFullPath($Path))
    }
    $directory = Get-Item -LiteralPath $Path -Force
    $acl = Get-Acl -LiteralPath $Path
    $access = @{
        Directory = $directory.PSIsContainer
        ReparsePoint = [bool] ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)
        Owner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        Protected = $acl.AreAccessRulesProtected
        Rules = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | ForEach-Object {
            @{
                Sid = $_.IdentityReference.Value; Type = $_.AccessControlType.ToString()
                Rights = [int] $_.FileSystemRights; Inheritance = [int] $_.InheritanceFlags
                Propagation = [int] $_.PropagationFlags; Inherited = $_.IsInherited
            }
        })
    }
    Assert-LocalCiTempAccess -Access $access -UserSid $user.Value
}

Export-ModuleMember -Function Get-LocalCiProfile, Get-LocalCiChangedFile, Get-LocalCiContentState, Clear-LocalCiGateResult, Save-LocalCiGateResult,
    Test-LocalCiGateResult, Assert-LocalCiTempPath, Test-LocalCiRuntime, Assert-LocalCiWindowsTempRoot, Assert-LocalCiTempAccess, Initialize-LocalCiPrivateTempDirectory
