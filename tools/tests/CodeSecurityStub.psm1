Set-StrictMode -Version Latest

# In-memory GitHub for the code security and custom pattern endpoints of one organization (API version 2026-03-10).
# Every response object starts from a documented fixture in fixtures/github-api; the stub only changes field values.

Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')

function Copy-StubValue {
    param([AllowNull()][object] $Value)

    if ($null -eq $Value) { return $null }
    return , (ConvertTo-Json -InputObject $Value -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate)
}

function Initialize-CodeSecurityStub {
    <#
    .SYNOPSIS
    Creates the state of a stub organization with repositories and the global GitHub recommended configuration.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Origin,
        [Parameter(Mandatory)][string] $Token,
        [string[]] $Repository = @('app', 'lib')
    )

    $global = (Get-GitHubApiFixture -Name code-security/get-configurations-for-org)[0]
    $state = [hashtable]::Synchronized(@{
        Organization          = $Organization
        Origin                = $Origin.TrimEnd('/')
        Token                 = $Token
        Configurations        = [Collections.Generic.List[object]]::new()
        Repositories          = [ordered]@{}
        Defaults              = @{ public = $null; private_and_internal = $null }
        Patterns              = [Collections.Generic.List[object]]::new()
        PatternConfigVersion  = 1
        NextId                = 5000
        PageSize              = 100
        AttachPendingReads    = 0
        CreatedPatternState   = 'published'
        PatternConfigOverride = $true
        IncludePatternVersion = $false
        PatchReturnsNoContent = $false
        DropNext              = $null
        RepositorySelection   = 'all'
        AttachStatus          = 'attached'
        AttachSkip            = @()
        PushProtectionIgnored = $false
        AttachHiddenReads     = 0
        ConcurrentPatternWrites = 0
        TotalCountOffset      = 0
        Requests              = [Collections.Generic.List[string]]::new()
        Bodies                = [Collections.Generic.List[object]]::new()
    })
    $state.Configurations.Add($global)
    $repositoryId = 100
    foreach ($name in $Repository) {
        $state.Repositories["$Organization/$name"] = @{ id = ++$repositoryId; name = $name; configuration = $null; status = $null }
    }
    return $state
}

function ConvertTo-StubReply {
    param([int] $Status, [AllowNull()][object] $Body, [string] $Link)

    $json = if ($null -eq $Body) { $null } else { ConvertTo-Json -InputObject $Body -Depth 100 -Compress }
    return [pscustomobject]@{ Status = $Status; Body = $json; Link = $Link; Drop = $false }
}

function Get-StubPage {
    param([hashtable] $State, [string] $Path, [hashtable] $Query, [object[]] $Items)

    $size = [Math]::Min([int] $State.PageSize, $(if ($Query['per_page']) { [int] $Query['per_page'] } else { 30 }))
    $start = if ($Query['after']) { [int] $Query['after'] } else { 0 }
    $page = @($Items | Select-Object -Skip $start -First $size)
    $link = $null
    if ($start + $size -lt $Items.Count) {
        $next = @{} + $Query
        $next['after'] = [string] ($start + $size)
        $queryString = ($next.GetEnumerator() | Sort-Object Name | ForEach-Object { "$($_.Name)=$($_.Value)" }) -join '&'
        $link = "<$($State.Origin)$Path`?$queryString>; rel=`"next`""
    }
    return ConvertTo-StubReply -Status 200 -Body $page -Link $link
}

function Get-StubInstallationRepository {
    param([hashtable] $State, [string] $Path, [hashtable] $Query)

    $items = @(foreach ($entry in $State.Repositories.GetEnumerator()) {
        $item = (Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation)['repositories'][0]
        $item['id'] = $entry.Value.id
        $item['name'] = $entry.Value.name
        $item['full_name'] = $entry.Key
        $item['owner']['login'] = $State.Organization
        $item
    })
    $page = Get-StubPage -State $State -Path $Path -Query $Query -Items $items
    $body = Get-GitHubApiFixture -Name apps/list-repos-accessible-to-installation
    $body['total_count'] = $items.Count + $State.TotalCountOffset
    $body['repositories'] = ConvertFrom-Json -InputObject $page.Body -AsHashtable -Depth 100 -NoEnumerate
    # repository_selection is an optional property of the documented response.
    if ($State.RepositorySelection) { $body['repository_selection'] = $State.RepositorySelection }
    return ConvertTo-StubReply -Status 200 -Body $body -Link $page.Link
}

function Find-StubConfiguration {
    param([hashtable] $State, [long] $Id)

    return $State.Configurations | Where-Object { [long] $_['id'] -eq $Id } | Select-Object -First 1
}

function Get-StubPatternVersion {
    param([hashtable] $Pattern)

    return "v$($Pattern['id'])-$($Pattern['revision'])"
}

function ConvertTo-StubPattern {
    param([hashtable] $State, [hashtable] $Pattern)

    $item = (Get-GitHubApiFixture -Name secret-scanning/list-org-custom-patterns)[0]
    foreach ($field in @('id', 'name', 'pattern', 'slug', 'state', 'push_protection_enabled', 'start_delimiter', 'end_delimiter', 'must_match', 'must_not_match')) {
        $item[$field] = $Pattern[$field]
    }
    # custom_pattern_version is an optional field of the documented list schema; the documented example omits it.
    if ($State.IncludePatternVersion) { $item['custom_pattern_version'] = Get-StubPatternVersion -Pattern $Pattern }
    return $item
}

function Invoke-CodeSecurityStubRequest {
    <#
    .SYNOPSIS
    Handles one request. Drop applies the change but tells the caller to lose the response.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $State,
        [Parameter(Mandatory)][string] $Method,
        [Parameter(Mandatory)][string] $PathAndQuery,
        [System.Collections.IDictionary] $Headers = @{},
        [AllowNull()][string] $Body
    )

    $path, $queryString = $PathAndQuery.Split('?', 2)
    $query = @{}
    if ($queryString) {
        foreach ($pair in $queryString.Split('&')) {
            $key, $value = $pair.Split('=', 2)
            $query[$key] = [Uri]::UnescapeDataString([string] $value)
        }
    }
    $State.Requests.Add("$Method $path")
    $request = if ([string]::IsNullOrWhiteSpace($Body)) { $null } else { $Body | ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate }
    $State.Bodies.Add([pscustomobject]@{ Method = $Method; Path = $path; Body = $request })

    if ($Headers['Authorization'] -cne "Bearer $($State.Token)" -or $Headers['X-GitHub-Api-Version'] -cne '2026-03-10') {
        return ConvertTo-StubReply -Status 401 -Body @{ message = 'Bad credentials' }
    }

    $reply = Invoke-StubRoute -State $State -Method $Method -Path $path -Query $query -Request $request
    if ($State.DropNext -and "$Method $path" -match $State.DropNext) {
        $State.DropNext = $null
        $reply.Drop = $true
    }
    return $reply
}

function Invoke-StubRoute {
    param([hashtable] $State, [string] $Method, [string] $Path, [hashtable] $Query, [AllowNull()][object] $Request)

    $org = [regex]::Escape($State.Organization)
    $notFound = ConvertTo-StubReply -Status 404 -Body @{ message = 'Not Found' }
    $route = "$Method $Path"

    if ($route -ceq 'GET /installation/repositories') {
        return Get-StubInstallationRepository -State $State -Path $Path -Query $Query
    }
    if ($route -cmatch "^GET /orgs/$org/code-security/configurations$") {
        $items = @($State.Configurations | Where-Object { $Query['target_type'] -ceq 'all' -or $_['target_type'] -ceq $(if ($Query['target_type']) { $Query['target_type'] } else { 'all' }) })
        return Get-StubPage -State $State -Path $Path -Query $Query -Items $items
    }
    if ($route -cmatch "^POST /orgs/$org/code-security/configurations$") {
        if (@($State.Configurations | Where-Object { $_['target_type'] -cne 'global' -and $_['name'] -ceq $Request['name'] }).Count) { return ConvertTo-StubReply -Status 422 -Body @{ message = 'Name has already been taken' } }
        $configuration = Get-GitHubApiFixture -Name code-security/create-configuration
        foreach ($key in $Request.Keys) { $configuration[$key] = Copy-StubValue $Request[$key] }
        $configuration['id'] = ++$State.NextId
        $configuration['target_type'] = 'organization'
        $State.Configurations.Add($configuration)
        return ConvertTo-StubReply -Status 201 -Body $configuration
    }
    if ($route -cmatch "^GET /orgs/$org/code-security/configurations/defaults$") {
        $defaults = @(
            if ($State.Defaults.public -and $State.Defaults.public -eq $State.Defaults.private_and_internal) {
                @{ default_for_new_repos = 'all'; configuration = Find-StubConfiguration $State $State.Defaults.public }
            }
            else {
                foreach ($visibility in @('public', 'private_and_internal')) {
                    if ($State.Defaults[$visibility]) {
                        @{ default_for_new_repos = $visibility; configuration = Find-StubConfiguration $State $State.Defaults[$visibility] }
                    }
                }
            })
        return ConvertTo-StubReply -Status 200 -Body $defaults
    }
    if ($route -cmatch "^(?<method>GET|PATCH|DELETE) /orgs/$org/code-security/configurations/(?<id>[0-9]+)$") {
        $id = [long] $Matches['id']
        $configuration = Find-StubConfiguration $State $id
        if (-not $configuration) { return $notFound }
        switch ($Method) {
            'GET' { return ConvertTo-StubReply -Status 200 -Body $configuration }
            'PATCH' {
                foreach ($key in $Request.Keys) { $configuration[$key] = Copy-StubValue $Request[$key] }
                if ($State.PatchReturnsNoContent) { return ConvertTo-StubReply -Status 204 }
                return ConvertTo-StubReply -Status 200 -Body $configuration
            }
            'DELETE' {
                $null = $State.Configurations.Remove($configuration)
                foreach ($repository in $State.Repositories.Values) {
                    if ($repository.configuration -eq $id) { $repository.configuration = $null; $repository.status = $null }
                }
                foreach ($visibility in @('public', 'private_and_internal')) { if ($State.Defaults[$visibility] -eq $id) { $State.Defaults[$visibility] = $null } }
                return ConvertTo-StubReply -Status 204
            }
        }
    }
    if ($route -cmatch "^PUT /orgs/$org/code-security/configurations/(?<id>[0-9]+)/defaults$") {
        $id = [long] $Matches['id']
        $configuration = Find-StubConfiguration $State $id
        if (-not $configuration) { return $notFound }
        $visibility = $Request['default_for_new_repos']
        switch ($visibility) {
            'all' { $State.Defaults.public = $id; $State.Defaults.private_and_internal = $id }
            'none' { foreach ($key in @('public', 'private_and_internal')) { if ($State.Defaults[$key] -eq $id) { $State.Defaults[$key] = $null } } }
            { $_ -in @('public', 'private_and_internal') } { $State.Defaults[$visibility] = $id }
            default { return ConvertTo-StubReply -Status 422 -Body @{ message = 'Invalid default_for_new_repos' } }
        }
        $reply = Get-GitHubApiFixture -Name code-security/set-configuration-as-default
        $reply['default_for_new_repos'] = $visibility
        $reply['configuration'] = $configuration
        return ConvertTo-StubReply -Status 200 -Body $reply
    }
    if ($route -cmatch "^POST /orgs/$org/code-security/configurations/(?<id>[0-9]+)/attach$") {
        $id = [long] $Matches['id']
        if (-not (Find-StubConfiguration $State $id)) { return $notFound }
        if ($Request['scope'] -cne 'all') { return ConvertTo-StubReply -Status 422 -Body @{ message = 'Unsupported scope' } }
        foreach ($entry in $State.Repositories.GetEnumerator()) {
            if ($entry.Key -cin $State.AttachSkip) { continue }
            $entry.Value.configuration = $id
            $entry.Value.status = if ($State.AttachPendingReads -gt 0) { 'attaching' } else { $State.AttachStatus }
        }
        return ConvertTo-StubReply -Status 202 -Body @{}
    }
    if ($route -cmatch "^GET /orgs/$org/code-security/configurations/(?<id>[0-9]+)/repositories$") {
        $id = [long] $Matches['id']
        if (-not (Find-StubConfiguration $State $id)) { return $notFound }
        if ($State.AttachPendingReads -gt 0) {
            $State.AttachPendingReads--
        }
        else {
            foreach ($repository in $State.Repositories.Values) { if ($repository.status -ceq 'attaching') { $repository.status = $State.AttachStatus } }
        }
        if ($State.AttachHiddenReads -gt 0) {
            $State.AttachHiddenReads--
            return Get-StubPage -State $State -Path $Path -Query $Query -Items @()
        }
        $items = @(foreach ($entry in $State.Repositories.GetEnumerator()) {
            if ($entry.Value.configuration -ne $id) { continue }
            $item = (Get-GitHubApiFixture -Name code-security/get-repositories-for-configuration)[0]
            $item['status'] = $entry.Value.status
            $item['repository']['id'] = $entry.Value.id
            $item['repository']['name'] = $entry.Value.name
            $item['repository']['full_name'] = $entry.Key
            $item
        })
        return Get-StubPage -State $State -Path $Path -Query $Query -Items $items
    }
    if ($route -cmatch "^GET /orgs/$org/secret-scanning/custom-patterns$") {
        $items = @($State.Patterns | ForEach-Object { ConvertTo-StubPattern -State $State -Pattern $_ })
        return Get-StubPage -State $State -Path $Path -Query $Query -Items $items
    }
    if ($route -cmatch "^POST /orgs/$org/secret-scanning/custom-patterns$") {
        $created = @(foreach ($item in $Request['patterns']) {
            if (@($State.Patterns | Where-Object { $_['name'] -ceq $item['name'] }).Count) {
                return ConvertTo-StubReply -Status 422 -Body @{ message = 'Validation failed'; validation_errors = @() }
            }
            $pattern = @{
                id = ++$State.NextId; revision = 1; name = $item['name']; pattern = $item['pattern']
                slug = ($item['name'].ToLowerInvariant() -replace '[^a-z0-9]+', '-'); state = $State.CreatedPatternState
                push_protection_enabled = $false; start_delimiter = $item['start_delimiter']; end_delimiter = $item['end_delimiter']
                must_match = $item['must_match']; must_not_match = $item['must_not_match']
            }
            $State.Patterns.Add($pattern)
            ConvertTo-StubPattern -State $State -Pattern $pattern
        })
        $reply = Get-GitHubApiFixture -Name secret-scanning/bulk-create-org-custom-patterns
        $reply['created_patterns'] = $created
        return ConvertTo-StubReply -Status 201 -Body $reply
    }
    if ($route -cmatch "^PATCH /orgs/$org/secret-scanning/custom-patterns/(?<id>[0-9]+)$") {
        $pattern = $State.Patterns | Where-Object { $_['id'] -eq [long] $Matches['id'] } | Select-Object -First 1
        if (-not $pattern) { return $notFound }
        if ($Request['custom_pattern_version'] -cne (Get-StubPatternVersion -Pattern $pattern)) { return ConvertTo-StubReply -Status 412 -Body @{ message = 'Precondition Failed' } }
        foreach ($field in @('pattern', 'start_delimiter', 'end_delimiter', 'must_match', 'must_not_match')) {
            if ($Request.Contains($field)) { $pattern[$field] = Copy-StubValue $Request[$field] }
        }
        $pattern['revision']++
        $reply = Get-GitHubApiFixture -Name secret-scanning/update-org-custom-pattern
        foreach ($field in @('id', 'name', 'pattern', 'slug', 'state', 'push_protection_enabled', 'start_delimiter', 'end_delimiter', 'must_match', 'must_not_match')) {
            $reply[$field] = $pattern[$field]
        }
        $reply['custom_pattern_version'] = Get-StubPatternVersion -Pattern $pattern
        return ConvertTo-StubReply -Status 200 -Body $reply
    }
    if ($route -cmatch "^DELETE /orgs/$org/secret-scanning/custom-patterns$") {
        foreach ($item in $Request['patterns']) {
            $pattern = $State.Patterns | Where-Object { $_['id'] -eq [long] $item['pattern_id'] } | Select-Object -First 1
            if (-not $pattern) { return $notFound }
            if ($item.Contains('custom_pattern_version') -and $item['custom_pattern_version'] -cne (Get-StubPatternVersion -Pattern $pattern)) {
                return ConvertTo-StubReply -Status 412 -Body @{ message = 'Precondition Failed' }
            }
        }
        foreach ($item in $Request['patterns']) {
            $null = $State.Patterns.Remove(($State.Patterns | Where-Object { $_['id'] -eq [long] $item['pattern_id'] } | Select-Object -First 1))
        }
        return ConvertTo-StubReply -Status 204
    }
    if ($route -cmatch "^GET /orgs/$org/secret-scanning/pattern-configurations$") {
        $reply = Get-GitHubApiFixture -Name secret-scanning/list-org-pattern-configs
        $reply['pattern_config_version'] = "p$($State.PatternConfigVersion)"
        $template = $reply['custom_pattern_overrides'][0]
        $reply['custom_pattern_overrides'] = @(foreach ($pattern in $State.Patterns) {
            if ($pattern['state'] -cne 'published' -or -not $State.PatternConfigOverride) { continue }
            $override = Copy-StubValue $template
            $override['token_type'] = "cp_$($pattern['id'])"
            $override['custom_pattern_version'] = Get-StubPatternVersion -Pattern $pattern
            $override['slug'] = $pattern['slug']
            $override['display_name'] = $pattern['name']
            $override['setting'] = if ($pattern['push_protection_enabled']) { 'enabled' } else { 'disabled' }
            $override
        })
        return ConvertTo-StubReply -Status 200 -Body $reply
    }
    if ($route -cmatch "^PATCH /orgs/$org/secret-scanning/pattern-configurations$") {
        if ($State.ConcurrentPatternWrites -gt 0) {
            # Another writer changed the organization pattern configuration between the read and this write.
            $State.ConcurrentPatternWrites--
            $State.PatternConfigVersion++
        }
        if ($Request['pattern_config_version'] -cne "p$($State.PatternConfigVersion)") { return ConvertTo-StubReply -Status 409 -Body @{ message = 'Conflict' } }
        foreach ($setting in @($Request['custom_pattern_settings'])) {
            $pattern = $State.Patterns | Where-Object { "cp_$($_['id'])" -ceq $setting['token_type'] } | Select-Object -First 1
            if (-not $pattern -or $setting['custom_pattern_version'] -cne (Get-StubPatternVersion -Pattern $pattern)) {
                return ConvertTo-StubReply -Status 422 -Body @{ message = 'Unknown pattern' }
            }
            if (-not $State.PushProtectionIgnored) { $pattern['push_protection_enabled'] = $setting['push_protection_setting'] -ceq 'enabled' }
        }
        $State.PatternConfigVersion++
        $reply = Get-GitHubApiFixture -Name secret-scanning/update-org-pattern-configs
        $reply['pattern_config_version'] = "p$($State.PatternConfigVersion)"
        return ConvertTo-StubReply -Status 200 -Body $reply
    }
    return $notFound
}

Export-ModuleMember -Function Initialize-CodeSecurityStub, Invoke-CodeSecurityStubRequest
