#Requires -Version 7.4
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1')

function Get-PlatformGitHubTokenIssuancePath {
    [CmdletBinding()]
    param([Parameter(Mandatory)][uri] $ApiUrl, [Parameter(Mandatory)][string] $AppId)

    $root = if (-not $IsWindows -and $env:XDG_STATE_HOME) { $env:XDG_STATE_HOME }
    else { [Environment]::GetFolderPath([Environment+SpecialFolder]::LocalApplicationData) }
    if (-not $root -or -not [IO.Path]::IsPathFullyQualified($root)) {
        throw 'Installation token issuance requires an absolute private user state directory.'
    }
    $identity = "$($ApiUrl.GetLeftPart([UriPartial]::Authority).ToLowerInvariant())`n$AppId"
    $hash = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($identity))).ToLowerInvariant()
    Join-Path $root "devsecops-platform/token-issuance/$hash/pending.json"
}

# security-check: token-issuance-location
function Assert-PlatformGitHubTokenStateLocation {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $checkout = [IO.Path]::GetFullPath((Split-Path $PSScriptRoot -Parent))
    $comparison = if ($IsWindows) { [StringComparison]::OrdinalIgnoreCase } else { [StringComparison]::Ordinal }
    if ($Path.Equals($checkout, $comparison) -or $Path.StartsWith("$checkout$([IO.Path]::DirectorySeparatorChar)", $comparison)) {
        throw 'Installation token state must be outside the checkout.'
    }
}

# security-check: token-issuance-storage
function Assert-PlatformGitHubTokenStateAccess {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Access, [Parameter(Mandatory)][string] $Owner)

    $expected = @{ Directory = $true; ReparsePoint = $false; Owner = $Owner; Private = $true }
    if (-not [string]::Equals((ConvertTo-PlatformCanonicalJson $Access), (ConvertTo-PlatformCanonicalJson $expected), [StringComparison]::Ordinal)) {
        throw 'Installation token state directory must be regular, owned by the current user and accessible only to that user.'
    }
}

# security-check: token-issuance-ancestor
function Assert-PlatformGitHubTokenStateAncestorAccess {
    [CmdletBinding()]
    param([bool] $TrustedOwner, [bool] $Replaceable, [string] $Path)

    if (-not $TrustedOwner) {
        throw "Installation token state ancestor '$Path' has an untrusted owner."
    }
    if ($Replaceable) {
        throw "Installation token state ancestor '$Path' grants rights that can replace pending state."
    }
}

function Assert-PlatformGitHubTokenStateAncestorChain {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    if ($IsWindows) {
        $trusted = @([Security.Principal.WindowsIdentity]::GetCurrent().User.Value, 'S-1-5-18', 'S-1-5-32-544',
            'S-1-5-80-956008885-3418522649-1831038044-1853292631-2271478464')
        $replacementRights = [Security.AccessControl.FileSystemRights]::DeleteSubdirectoriesAndFiles -bor
            [Security.AccessControl.FileSystemRights]::Delete -bor [Security.AccessControl.FileSystemRights]::ChangePermissions -bor
            [Security.AccessControl.FileSystemRights]::TakeOwnership
    }
    else {
        $currentUser = & id -u
        if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the current user for installation token state.' }
        $trusted = @("$currentUser", '0')
    }
    $ancestor = [IO.DirectoryInfo]::new($Path).Parent
    while ($null -ne $ancestor) {
        if ($ancestor.Exists) {
            if ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint) {
                throw 'Installation token state cannot use a symlink or reparse-point ancestor.'
            }
            if ($IsWindows) {
                $acl = Get-Acl -LiteralPath $ancestor.FullName
                $actualOwner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
                $replaceable = @($acl.GetAccessRules($true, $true, [Security.Principal.SecurityIdentifier]) | Where-Object {
                    $_.AccessControlType -eq [Security.AccessControl.AccessControlType]::Allow -and
                    -not ($_.PropagationFlags -band [Security.AccessControl.PropagationFlags]::InheritOnly) -and
                    $_.IdentityReference.Value -notin $trusted -and ($_.FileSystemRights -band $replacementRights)
                }).Count -gt 0
            }
            else {
                $actualOwner = & stat -c '%u' -- $ancestor.FullName
                if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the installation token state ancestor owner.' }
                $mode = [IO.File]::GetUnixFileMode($ancestor.FullName)
                $replaceable = [bool] ($mode -band ([IO.UnixFileMode]::GroupWrite -bor [IO.UnixFileMode]::OtherWrite)) -and
                    -not ($mode -band [IO.UnixFileMode]::StickyBit)
            }
            Assert-PlatformGitHubTokenStateAncestorAccess -TrustedOwner ("$actualOwner" -in $trusted) -Replaceable $replaceable -Path $ancestor.FullName
        }
        $ancestor = $ancestor.Parent
    }
}

function Initialize-PlatformGitHubTokenStateDirectory {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    Assert-PlatformGitHubTokenStateAncestorChain -Path $Path
    $ancestor = [IO.DirectoryInfo]::new($Path)
    while ($null -ne $ancestor) {
        if ($ancestor.Exists -and ($ancestor.Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Installation token state cannot use a symlink or reparse-point ancestor.'
        }
        $ancestor = $ancestor.Parent
    }
    if ($IsWindows) {
        $owner = [Security.Principal.WindowsIdentity]::GetCurrent().User
        $security = [Security.AccessControl.DirectorySecurity]::new()
        $security.SetOwner($owner)
        $security.SetAccessRuleProtection($true, $false)
        $security.AddAccessRule([Security.AccessControl.FileSystemAccessRule]::new(
            $owner, [Security.AccessControl.FileSystemRights]::FullControl,
            ([Security.AccessControl.InheritanceFlags]::ContainerInherit -bor [Security.AccessControl.InheritanceFlags]::ObjectInherit),
            [Security.AccessControl.PropagationFlags]::None, [Security.AccessControl.AccessControlType]::Allow))
        if (-not [IO.Directory]::Exists($Path)) {
            $null = [IO.FileSystemAclExtensions]::CreateDirectory($security, $Path)
        }
        $sections = [Security.AccessControl.AccessControlSections]::Owner -bor [Security.AccessControl.AccessControlSections]::Access
        $acl = Get-Acl -LiteralPath $Path
        $ownerId = $owner.Value
        $actualOwner = $acl.GetOwner([Security.Principal.SecurityIdentifier]).Value
        $private = $acl.GetSecurityDescriptorSddlForm($sections) -ceq $security.GetSecurityDescriptorSddlForm($sections)
    }
    else {
        $mode = [IO.UnixFileMode]::UserRead -bor [IO.UnixFileMode]::UserWrite -bor [IO.UnixFileMode]::UserExecute
        $null = [IO.Directory]::CreateDirectory($Path, $mode)
        $ownerId = & id -u
        if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the current user for installation token state.' }
        $actualOwner = & stat -c '%u' -- $Path
        if ($LASTEXITCODE -ne 0) { throw 'Cannot determine the installation token state owner.' }
        $private = [IO.File]::GetUnixFileMode($Path) -eq $mode
    }
    Assert-PlatformGitHubTokenStateAncestorChain -Path $Path
    $directory = Get-Item -LiteralPath $Path -Force
    Assert-PlatformGitHubTokenStateAccess -Owner "$ownerId" -Access @{
        Directory = $directory.PSIsContainer
        ReparsePoint = [bool] ($directory.Attributes -band [IO.FileAttributes]::ReparsePoint)
        Owner = "$actualOwner"
        Private = [bool] $private
    }
}

function Open-PlatformGitHubTokenIssuance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path)

    $fullPath = [IO.Path]::GetFullPath($Path)
    Assert-PlatformGitHubTokenStateLocation -Path $fullPath
    Initialize-PlatformGitHubTokenStateDirectory -Path ([IO.Path]::GetDirectoryName($fullPath))
    foreach ($file in @($fullPath, "$fullPath.lock")) {
        if ((Test-Path -LiteralPath $file) -and ((Get-Item -LiteralPath $file -Force).Attributes -band [IO.FileAttributes]::ReparsePoint)) {
            throw 'Installation token state and lock must not be symlinks or reparse points.'
        }
    }
    try { $lock = [IO.File]::Open("$fullPath.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch { throw "Cannot exclusively lock installation token state '$fullPath'. Another issuer or resolver may still be running." }
    @{ Path = $fullPath; Lock = $lock; Started = $false; Content = $null; Record = $null }
}

function Get-PlatformGitHubTokenPendingDescription {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Context)

    $description = "Pending state: '$($Context.Path)'."
    try {
        $document = [Text.Json.JsonDocument]::Parse([IO.File]::ReadAllText($Context.Path))
        try {
            $record = $document.RootElement
            $ids = @($record.GetProperty('installationIds').EnumerateArray() | ForEach-Object { $_.GetString() })
            $description += " Intent: $($record.GetProperty('intentId').GetString()); installations: $($ids -join ', '); recorded UTC: $($record.GetProperty('createdAtUtc').GetString())."
        }
        finally { $document.Dispose() }
    }
    catch { $description += ' Pending metadata is unreadable; explicit operator confirmation is required for resolution.' }
    $description
}

# security-check: token-issuance-pending
function Assert-PlatformGitHubTokenIssuanceClear {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Context)

    if (Test-Path -LiteralPath $Context.Path) {
        throw "Unresolved installation token issuance: a token may have been created and cannot be revoked without the response token. Do not retry issuance. $(Get-PlatformGitHubTokenPendingDescription -Context $Context) Use Resolve-PlatformGitHubTokenIssuance.ps1 after establishing expiry or independent revocation."
    }
}

function Save-PlatformGitHubTokenIssuance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Context,
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $AppId,
        [Parameter(Mandatory)][string[]] $InstallationIds
    )

    if ($Context.Started) { Assert-PlatformGitHubTokenStateContent -Context $Context -Content $Context.Content }
    $record = @{
        apiUrl = $ApiUrl; appId = $AppId; installationIds = $InstallationIds
        intentId = [guid]::NewGuid().ToString('D'); createdAtUtc = [DateTimeOffset]::UtcNow.ToString('o')
    }
    $content = ($record | ConvertTo-Json -Depth 5 -Compress) + "`n"
    $temporary = "$($Context.Path).$($record.intentId).tmp"
    try {
        $stream = [IO.File]::Open($temporary, [IO.FileMode]::CreateNew, [IO.FileAccess]::Write, [IO.FileShare]::None)
        try {
            $bytes = [Text.UTF8Encoding]::new($false).GetBytes($content)
            $stream.Write($bytes)
            $stream.Flush($true)
        }
        finally { $stream.Dispose() }
        if ($Context.Started) { [IO.File]::Replace($temporary, $Context.Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Context.Path) }
        $Context.Content = $content
        $Context.Record = $record
        $Context.Started = $true
    }
    finally { if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) } }
}

# security-check: token-issuance-content
function Assert-PlatformGitHubTokenStateContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Context, [Parameter(Mandatory)][AllowEmptyString()][string] $Content)

    if ([IO.File]::ReadAllText($Context.Path) -cne $Content) {
        throw 'Installation token pending state changed; refusing to remove it.'
    }
}

function Complete-PlatformGitHubTokenIssuance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Context)

    if (-not $Context.Started) { return }
    Assert-PlatformGitHubTokenStateContent -Context $Context -Content $Context.Content
    [IO.File]::Delete($Context.Path)
    $Context.Started = $false
}

# security-check: token-issuance-resolution
function Assert-PlatformGitHubTokenResolution {
    [CmdletBinding()]
    param([bool] $TimestampValid, [DateTimeOffset] $RecordedAt, [bool] $OperatorConfirmed)

    if (-not $OperatorConfirmed -and (-not $TimestampValid -or $RecordedAt -gt [DateTimeOffset]::UtcNow.AddMinutes(-70))) {
        throw 'Pending token issuance is younger than 70 minutes or its UTC timestamp is unreadable. ConfirmTokenExpiredOrRevoked requires explicit operator confirmation of expiry or independent revocation.'
    }
}

function Resolve-PlatformGitHubTokenIssuance {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [switch] $ConfirmTokenExpiredOrRevoked)

    $context = Open-PlatformGitHubTokenIssuance -Path $Path
    try {
        $content = [IO.File]::ReadAllText($context.Path)
        $recordedAt = [DateTimeOffset]::MinValue
        $timestampValid = $false
        try {
            $document = [Text.Json.JsonDocument]::Parse($content)
            try { $timestamp = $document.RootElement.GetProperty('createdAtUtc').GetString() }
            finally { $document.Dispose() }
            $timestampValid = [DateTimeOffset]::TryParseExact($timestamp, 'o', [Globalization.CultureInfo]::InvariantCulture,
                [Globalization.DateTimeStyles]::None, [ref] $recordedAt)
            $timestampValid = $timestampValid -and $recordedAt.Offset -eq [TimeSpan]::Zero
        }
        catch { $timestampValid = $false }
        Assert-PlatformGitHubTokenResolution -TimestampValid $timestampValid -RecordedAt $recordedAt -OperatorConfirmed $ConfirmTokenExpiredOrRevoked
        Assert-PlatformGitHubTokenStateContent -Context $context -Content $content
        [IO.File]::Delete($context.Path)
        [pscustomobject]@{
            Resolved = $true; Verified = $false; IssuanceStatePath = $context.Path
            Disposition = $(if ($ConfirmTokenExpiredOrRevoked) { 'OperatorConfirmedExpiredOrRevoked' } else { 'SeventyMinuteWaitElapsed' })
            Message = 'Pending issuance was manually resolved. No token was revoked by this command and cleanup was not independently verified.'
        }
    }
    finally { $context.Lock.Dispose() }
}

Export-ModuleMember -Function Get-PlatformGitHubTokenIssuancePath, Open-PlatformGitHubTokenIssuance,
    Assert-PlatformGitHubTokenIssuanceClear, Save-PlatformGitHubTokenIssuance, Complete-PlatformGitHubTokenIssuance,
    Get-PlatformGitHubTokenPendingDescription, Resolve-PlatformGitHubTokenIssuance
