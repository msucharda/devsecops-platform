#Requires -Version 7.4
Set-StrictMode -Version Latest
$script:absentControlRef = [object]::new()

# security-check: development-control-http
function Invoke-DevelopmentControlRead {
    param([string] $Uri, [Collections.IDictionary] $Request, [switch] $AllowAbsent)
    $response = Invoke-WebRequest -Uri $Uri @Request
    if ($AllowAbsent -and $response.StatusCode -eq 404) { return $script:absentControlRef }
    if ($response.StatusCode -ne 200) { throw "Cannot read protected control state: HTTP $($response.StatusCode)." }
    return ConvertFrom-Json -InputObject ([string] $response.Content) -AsHashtable -NoEnumerate
}

# security-check: development-control-reference
function Get-DevelopmentControlRevision {
    param([AllowNull()][object] $Value, [string] $ExpectedRef)
    if ($Value -isnot [Collections.IDictionary] -or $Value['ref'] -isnot [string] -or $Value['ref'] -cne $ExpectedRef -or
        $Value['object'] -isnot [Collections.IDictionary] -or
        $Value['object']['type'] -isnot [string] -or $Value['object']['type'] -cne 'commit' -or
        $Value['object']['sha'] -isnot [string] -or $Value['object']['sha'] -cnotmatch '^[a-f0-9]{40}\z') {
        throw 'Invalid protected control ref; require the exact ref and full commit SHA.'
    }
    return $Value['object']['sha']
}

# security-check: development-control-tree
function Get-DevelopmentControlFileSha {
    param([AllowNull()][object] $Tree)
    if ($Tree -isnot [Collections.IDictionary] -or $Tree['truncated'] -isnot [bool] -or
        $Tree['truncated'] -or $Tree['tree'] -isnot [Collections.IList]) {
        throw 'A complete control tree is required.'
    }
    $entries = @($Tree['tree'] | Where-Object {
        $_ -is [Collections.IDictionary] -and $_['path'] -is [string] -and $_['path'] -ceq 'development-control.json'
    })
    if ($entries.Count -ne 1 -or $entries[0]['type'] -isnot [string] -or $entries[0]['type'] -cne 'blob' -or
        $entries[0]['mode'] -isnot [string] -or $entries[0]['mode'] -cne '100644' -or
        $entries[0]['sha'] -isnot [string] -or $entries[0]['sha'] -cnotmatch '^[a-f0-9]{40}\z') {
        throw 'Exactly one regular control file is required; links, executable files, directories and submodules are unsupported.'
    }
    return $entries[0]['sha']
}

# security-check: development-control-file
function Read-DevelopmentControlFile {
    param([AllowNull()][object] $File, [string] $ExpectedSha)
    if ($File -isnot [Collections.IDictionary] -or $File['type'] -isnot [string] -or $File['type'] -cne 'file' -or
        $File['name'] -isnot [string] -or $File['name'] -cne 'development-control.json' -or
        $File['path'] -isnot [string] -or $File['path'] -cne 'development-control.json' -or
        $File['sha'] -isnot [string] -or $File['sha'] -cne $ExpectedSha -or
        $File['encoding'] -isnot [string] -or $File['encoding'] -cne 'base64' -or
        $File['size'] -isnot [long] -or $File['size'] -le 0 -or $File['size'] -gt 65536 -or
        $File['content'] -isnot [string]) {
        throw 'Invalid protected control content; require the exact regular file, Git object, base64 encoding and bounded size.'
    }
    $bytes = [Convert]::FromBase64String($File['content'])
    if ($bytes.Length -ne $File['size']) { throw 'Protected control content size does not match the response.' }
    return [Text.UTF8Encoding]::new($false, $true).GetString($bytes)
}

# security-check: development-control-document
function ConvertFrom-DevelopmentControl {
    param([string] $Json)
    $document = [Text.Json.JsonDocument]::Parse($Json)
    try {
        $root = $document.RootElement
        if ($root.ValueKind -ne [Text.Json.JsonValueKind]::Object) { throw 'Control document must be an object.' }
        $seen = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
        foreach ($property in $root.EnumerateObject()) {
            if (-not $seen.Add($property.Name)) { throw 'Control document contains duplicate fields.' }
        }
        $version = [Text.Json.JsonElement]::new()
        if (-not $root.TryGetProperty('version', [ref] $version)) { throw "Control document requires 'version'." }
        if ($version.GetRawText() -cne '1') {
            throw 'Unsupported control document version.'
        }
        $values = @{}
        foreach ($field in @('reference', 'source', 'approval', 'disposition')) {
            $value = [Text.Json.JsonElement]::new()
            if (-not $root.TryGetProperty($field, [ref] $value)) { throw "Control document requires '$field'." }
            if ($value.ValueKind -ne [Text.Json.JsonValueKind]::String) { throw "Control document requires string '$field'." }
            $values[$field] = $value.GetString()
        }
        return $values
    }
    finally { $document.Dispose() }
}

# security-check: development-control-stability
function Assert-DevelopmentControlStability {
    param([string] $Before, [string] $After)
    if ($Before -cne $After) { throw 'Protected control ref changed during inspection; start a fresh dispatch.' }
}

# security-check: development-control-protection
function Get-DevelopmentControlProtectionId {
    param([AllowNull()][object] $Rules)
    if ($Rules -isnot [Collections.IList]) { throw 'Control ref requires enterprise update and deletion rules.' }
    $updates = [Collections.Generic.HashSet[long]]::new()
    $deletions = [Collections.Generic.HashSet[long]]::new()
    foreach ($rule in $Rules) {
        if ($rule -isnot [Collections.IDictionary] -or $rule['type'] -isnot [string] -or
            $rule['ruleset_id'] -isnot [long] -or $rule['ruleset_id'] -le 0) { continue }
        if ($rule['type'] -ceq 'update') { $null = $updates.Add($rule['ruleset_id']) }
        if ($rule['type'] -ceq 'deletion') { $null = $deletions.Add($rule['ruleset_id']) }
    }
    if (-not $updates.Overlaps($deletions)) { throw 'Control ref requires enterprise update and deletion rules from one active enterprise ruleset.' }
    return @($updates | Where-Object { $deletions.Contains($_) } | Sort-Object)
}

# security-check: development-control-ruleset
function Test-DevelopmentControlRuleset {
    param([AllowNull()][object] $Ruleset, [long] $ExpectedId)
    if ($Ruleset -isnot [Collections.IDictionary] -or $Ruleset['id'] -isnot [long] -or
        $Ruleset['id'] -ne $ExpectedId -or $Ruleset['source_type'] -isnot [string] -or
        $Ruleset['source_type'] -cnotin @('Repository', 'Organization', 'Enterprise')) {
        throw 'Invalid enterprise control ruleset identity.'
    }
    if ($Ruleset['source_type'] -cne 'Enterprise') { return $false }
    if ($Ruleset['target'] -isnot [string] -or $Ruleset['target'] -cne 'branch' -or
        $Ruleset['enforcement'] -isnot [string] -or $Ruleset['enforcement'] -cne 'active' -or
        $Ruleset['rules'] -isnot [Collections.IList]) {
        throw 'An active enterprise branch control ruleset is required.'
    }
    $update = $false
    $deletion = $false
    foreach ($rule in $Ruleset['rules']) {
        if ($rule -isnot [Collections.IDictionary] -or $rule['type'] -isnot [string]) { continue }
        if ($rule['type'] -ceq 'update') {
            if ($rule['parameters'] -isnot [Collections.IDictionary] -or
                $rule['parameters']['update_allows_fetch_and_merge'] -isnot [bool] -or
                $rule['parameters']['update_allows_fetch_and_merge']) {
                throw 'The enterprise control ruleset must explicitly forbid upstream fetch-and-merge updates.'
            }
            $update = $true
        }
        if ($rule['type'] -ceq 'deletion') { $deletion = $true }
    }
    if (-not $update -or -not $deletion) { throw 'The enterprise control ruleset must restrict update and deletion.' }
    return $true
}

# security-check: development-control-snapshot
function Read-DevelopmentControl {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Repository,
        [Parameter(Mandatory)][string] $ReadToken,
        [switch] $AllowAbsent
    )

    $headers = @{
        Authorization = "Bearer $ReadToken"; Accept = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = '2026-03-10'
    }
    $request = @{
        Headers = $headers; Method = 'GET'; MaximumRedirection = 0; TimeoutSec = 60
        MaximumRetryCount = 0; SkipHttpErrorCheck = $true
    }
    $root = "$($ApiUrl.TrimEnd('/'))/repos/$Repository"
    $main = Invoke-DevelopmentControlRead -Uri "$root/git/ref/heads/main" -Request $request
    $null = Get-DevelopmentControlRevision -Value $main -ExpectedRef refs/heads/main
    $reference = Invoke-DevelopmentControlRead -Uri "$root/git/ref/heads/platform-control" -Request $request -AllowAbsent:$AllowAbsent
    if ([object]::ReferenceEquals($reference, $script:absentControlRef)) { return $null }
    $revision = Get-DevelopmentControlRevision -Value $reference -ExpectedRef refs/heads/platform-control
    $tree = Invoke-DevelopmentControlRead -Uri "$root/git/trees/$revision" -Request $request
    $sha = Get-DevelopmentControlFileSha -Tree $tree
    $file = Invoke-DevelopmentControlRead -Uri "$root/contents/development-control.json?ref=$revision" -Request $request
    $state = ConvertFrom-DevelopmentControl -Json (Read-DevelopmentControlFile -File $file -ExpectedSha $sha)
    $again = Invoke-DevelopmentControlRead -Uri "$root/git/ref/heads/platform-control" -Request $request
    Assert-DevelopmentControlStability -Before $revision -After (Get-DevelopmentControlRevision -Value $again -ExpectedRef refs/heads/platform-control)
    $rules = Invoke-DevelopmentControlRead -Uri "$root/rules/branches/platform-control?per_page=100&page=1" -Request $request
    $protectionIds = @(Get-DevelopmentControlProtectionId -Rules $rules)
    $protected = $false
    foreach ($id in $protectionIds) {
        $ruleset = Invoke-DevelopmentControlRead -Uri "$root/rulesets/${id}?includes_parents=true" -Request $request
        if (Test-DevelopmentControlRuleset -Ruleset $ruleset -ExpectedId $id) { $protected = $true }
    }
    if (-not $protected) { throw 'Control ref requires enterprise update and deletion rules from one active enterprise ruleset.' }
    return @{
        Reference = $state['reference']; Source = $state['source']
        Approval = $state['approval']; Disposition = $state['disposition']
        ControlRevision = $revision
    }
}

Export-ModuleMember -Function Read-DevelopmentControl
