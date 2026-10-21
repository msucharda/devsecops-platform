Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Endpoints, API version 2026-03-10:
# https://docs.github.com/en/enterprise-cloud@latest/rest/code-security/configurations
# https://docs.github.com/en/enterprise-cloud@latest/rest/secret-scanning/custom-patterns
# https://docs.github.com/en/enterprise-cloud@latest/rest/secret-scanning/push-protection

$script:ApiVersion = '2026-03-10'
# Statuses that mean a repository is still bound to a configuration.
$script:ActiveAttachmentStatuses = @('attached', 'attaching', 'enforced', 'failed', 'updating', 'enterprise_enforced')
$script:PendingAttachmentStatuses = @('attaching', 'updating')
$script:SuccessfulAttachmentStatuses = @('attached', 'enforced')
# Documented enum of the attachment status; any other value is unreadable state.
$script:AttachmentStatuses = @('attached', 'attaching', 'detached', 'removed', 'enforced', 'failed', 'updating', 'removed_by_enterprise', 'enterprise_enforced')
$script:BypassModes = @('ALWAYS', 'EXEMPT')
$script:PatternConfigAttempts = 5
# Documented defaults of POST /orgs/{org}/secret-scanning/custom-patterns; a null delimiter means the default.
$script:DefaultStartDelimiter = '\A|[^0-9A-Za-z]'
$script:DefaultEndDelimiter = '\z|[^0-9A-Za-z]'

function Assert-CodeSecurityApiUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl)

    $uri = $null
    if (-not [Uri]::TryCreate($ApiUrl, [UriKind]::Absolute, [ref] $uri) -or $uri.AbsolutePath -cne '/' -or $uri.Query -or
        $uri.UserInfo -or -not ($uri.Scheme -ceq 'https' -or ($uri.Scheme -ceq 'http' -and $uri.IsLoopback))) {
        throw "The GitHub API URL '$ApiUrl' must be an HTTPS origin; plain HTTP is only accepted for a loopback test stub."
    }
}

function Assert-CodeSecurityId {
    [CmdletBinding()]
    param([AllowNull()][object] $Value, [Parameter(Mandatory)][string] $Description)

    if ([string] $Value -cnotmatch '^[1-9][0-9]{0,17}$') { throw "$Description has no valid ID." }
}

function Invoke-CodeSecurityApi {
    <#
    .SYNOPSIS
    Sends one GitHub REST request with the job's installation token and follows Link rel="next" on the same origin.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'PATCH', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][object] $Body,
        [switch] $AllPages,
        # With AllPages, reads the page items from this property of an object response instead of a JSON array.
        [string] $ItemsProperty,
        [switch] $AllowNotFound
    )

    Assert-CodeSecurityApiUrl -ApiUrl $ApiUrl
    if (-not $env:REST_API_BEARER) { throw 'REST_API_BEARER is not set; the runner must export the installation token.' }
    $origin = $ApiUrl.TrimEnd('/')
    $headers = @{
        Authorization          = "Bearer $env:REST_API_BEARER"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = $script:ApiVersion
    }
    $uri = "$origin$Path"
    $items = [Collections.Generic.List[object]]::new()
    while ($uri) {
        $request = @{
            Uri = $uri; Method = $Method; Headers = $headers; SkipHttpErrorCheck = $true
            MaximumRetryCount = 0; MaximumRedirection = 0; TimeoutSec = 60
        }
        if ($null -ne $Body) {
            $request.Body = ConvertTo-Json -InputObject $Body -Depth 20 -Compress
            $request.ContentType = 'application/json'
        }
        $reply = Invoke-WebRequest @request
        $status = [int] $reply.StatusCode
        if ($status -eq 404 -and $AllowNotFound) { return $null }
        if ($status -lt 200 -or $status -gt 299) { throw "GitHub returned HTTP $status for $Method $($Path.Split('?')[0])." }
        $content = if ($reply.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($reply.Content) } else { [string] $reply.Content }
        $parsed = if ([string]::IsNullOrWhiteSpace($content)) { $null } else { ConvertFrom-Json -InputObject $content -AsHashtable -Depth 100 -NoEnumerate }
        if ($Method -ceq 'GET' -and $null -eq $parsed) {
            throw "GitHub returned an empty successful GET response for $($Path.Split('?')[0]); only HTTP 404 proves absence."
        }
        if (-not $AllPages) { return , $parsed }
        if ($ItemsProperty) {
            if ($parsed -isnot [System.Collections.IDictionary] -or $parsed[$ItemsProperty] -isnot [array]) {
                throw "GitHub returned no '$ItemsProperty' array for $Method $($Path.Split('?')[0])."
            }
            $pageMeta = $parsed
            $parsed = $parsed[$ItemsProperty]
        }
        elseif ($parsed -isnot [array]) { throw "GitHub returned no JSON array for $Method $($Path.Split('?')[0])." }
        foreach ($item in $parsed) { $items.Add($item) }
        $uri = $null
        foreach ($link in @($reply.Headers['Link'])) {
            foreach ($part in ([string] $link).Split(',')) {
                if ($part -match '^\s*<(?<url>[^>]+)>\s*;\s*rel="next"\s*$') {
                    $next = $Matches['url']
                    if (-not $next.StartsWith("$origin/", [StringComparison]::Ordinal)) {
                        throw "GitHub returned a pagination link outside '$origin'."
                    }
                    $uri = $next
                }
            }
        }
    }
    if ($ItemsProperty) {
        $result = [ordered]@{}
        foreach ($key in $pageMeta.Keys) { $result[$key] = $pageMeta[$key] }
        $result[$ItemsProperty] = $items.ToArray()
        return $result
    }
    return , $items.ToArray()
}

function Get-CodeSecurityConfigurationList {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization)

    $configurations = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method GET -AllPages `
        -Path "/orgs/$Organization/code-security/configurations?target_type=all&per_page=100"
    foreach ($configuration in $configurations) {
        Assert-CodeSecurityId -Value $configuration['id'] -Description "A code security configuration in '$Organization'"
    }
    return , $configurations
}

function Get-CodeSecurityConfigurationByName {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Name,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Configurations
    )

    # Global and enterprise configurations may share the name; only an organization configuration belongs to the module.
    $found = @($Configurations | Where-Object { $_['target_type'] -ceq 'organization' -and $_['name'] -ceq $Name })
    if ($found.Count -gt 1) { throw "Organization '$Organization' has $($found.Count) code security configurations named '$Name'." }
    if ($found.Count -eq 0) { return $null }
    return $found[0]
}

function Get-CodeSecurityConfigurationRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][long] $ConfigurationId
    )

    $repositories = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method GET -AllPages `
        -Path "/orgs/$Organization/code-security/configurations/$ConfigurationId/repositories?status=all&per_page=100"
    return , @($repositories | ForEach-Object {
        if ($_ -isnot [System.Collections.IDictionary] -or $_['repository'] -isnot [System.Collections.IDictionary] -or
            -not $_['repository']['full_name']) {
            throw "Configuration $ConfigurationId in '$Organization' returned a repository without full_name."
        }
        Assert-CodeSecurityId -Value $_['repository']['id'] -Description "Repository '$($_['repository']['full_name'])' of configuration $ConfigurationId"
        if ([string] $_['status'] -cnotin $script:AttachmentStatuses) {
            throw "Configuration $ConfigurationId in '$Organization' returned the unknown attachment status '$($_['status'])' for '$($_['repository']['full_name'])'."
        }
        [ordered]@{ id = [string] $_['repository']['id']; repository = [string] $_['repository']['full_name']; status = [string] $_['status'] }
    })
}

function Get-CodeSecurityRepositoryInventory {
    <#
    .SYNOPSIS
    Lists every repository of the organization through the installation, which has access to all repositories.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization)

    # GET /orgs/{org}/repos does not support internal repositories with installation tokens; the installation list does.
    $reply = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method GET -AllPages -ItemsProperty repositories -Path '/installation/repositories?per_page=100'
    if ($reply.Contains('repository_selection') -and [string] $reply['repository_selection'] -cne 'all') {
        throw "The installation in '$Organization' has repository access '$($reply['repository_selection'])'; the module needs all repositories."
    }
    $repositories = @($reply['repositories'])
    if ([string] $reply['total_count'] -cnotmatch '^[0-9]+$' -or [long] $reply['total_count'] -ne $repositories.Count) {
        throw "The installation in '$Organization' reported $($reply['total_count']) repositories but listed $($repositories.Count)."
    }
    return , @($repositories | ForEach-Object {
        if ($_ -isnot [System.Collections.IDictionary] -or -not $_['full_name'] -or $_['owner'] -isnot [System.Collections.IDictionary] -or
            [string] $_['owner']['login'] -ine $Organization) {
            throw "The installation in '$Organization' listed a repository outside the organization."
        }
        Assert-CodeSecurityId -Value $_['id'] -Description "Repository '$($_['full_name'])'"
        [ordered]@{ id = [string] $_['id']; repository = [string] $_['full_name'] }
    })
}

function Get-UncoveredRepository {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Inventory,
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Attached
    )

    $covered = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $Attached) { if ($entry['status'] -cin $script:SuccessfulAttachmentStatuses) { $null = $covered.Add($entry['id']) } }
    return , @($Inventory | Where-Object { -not $covered.Contains($_['id']) } | ForEach-Object { $_['repository'] })
}

function Get-CustomPatternByName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization)

    $patterns = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method GET -AllPages -Path "/orgs/$Organization/secret-scanning/custom-patterns"
    # Terraform keys patterns by name case-sensitively; [ordered] would match a differently cased GitHub pattern.
    $byName = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($pattern in $patterns) {
        $name = [string] $pattern['name']
        if (-not $name) { throw "Organization '$Organization' returned a custom pattern without name." }
        Assert-CodeSecurityId -Value $pattern['id'] -Description "Custom pattern '$name' in '$Organization'"
        if ($byName.ContainsKey($name)) { throw "Organization '$Organization' has more than one custom pattern named '$name'." }
        $byName[$name] = $pattern
    }
    return $byName
}

function ConvertTo-CustomPatternContent {
    [CmdletBinding()]
    param([Parameter(Mandatory)][System.Collections.IDictionary] $Pattern)

    [ordered]@{
        pattern         = [string] $Pattern['pattern']
        start_delimiter = if ($null -eq $Pattern['start_delimiter']) { $script:DefaultStartDelimiter } else { [string] $Pattern['start_delimiter'] }
        end_delimiter   = if ($null -eq $Pattern['end_delimiter']) { $script:DefaultEndDelimiter } else { [string] $Pattern['end_delimiter'] }
        must_match      = @($Pattern['must_match'] | Where-Object { $null -ne $_ } | ForEach-Object { [string] $_ })
        must_not_match  = @($Pattern['must_not_match'] | Where-Object { $null -ne $_ } | ForEach-Object { [string] $_ })
    }
}

function Get-CodeSecurityState {
    <#
    .SYNOPSIS
    Reads the configuration, defaults, attachments, and custom patterns of one organization.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $ConfigurationName
    )

    $configurations = Get-CodeSecurityConfigurationList -ApiUrl $ApiUrl -Organization $Organization
    $listed = Get-CodeSecurityConfigurationByName -Organization $Organization -Name $ConfigurationName -Configurations $configurations
    $configuration = $null
    $repositories = @()
    if ($listed) {
        $configuration = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method GET `
            -Path "/orgs/$Organization/code-security/configurations/$($listed['id'])"
        if ($configuration -isnot [System.Collections.IDictionary] -or [string] $configuration['id'] -cne [string] $listed['id']) {
            throw "Configuration '$ConfigurationName' in '$Organization' returned a different ID."
        }
        $repositories = Get-CodeSecurityConfigurationRepository -ApiUrl $ApiUrl -Organization $Organization -ConfigurationId $listed['id']
    }

    $foreign = [Collections.Generic.List[object]]::new()
    foreach ($other in $configurations) {
        if ($listed -and [string] $other['id'] -ceq [string] $listed['id']) { continue }
        foreach ($entry in (Get-CodeSecurityConfigurationRepository -ApiUrl $ApiUrl -Organization $Organization -ConfigurationId $other['id'])) {
            if ($entry['status'] -cin $script:ActiveAttachmentStatuses) {
                $foreign.Add([ordered]@{ configuration = [string] $other['name']; repository = $entry['repository']; status = $entry['status'] })
            }
        }
    }
    $uncovered = Get-UncoveredRepository -Inventory (Get-CodeSecurityRepositoryInventory -ApiUrl $ApiUrl -Organization $Organization) -Attached $repositories

    if ($configuration) {
        # mode is optional with the documented default ALWAYS; a present value must be a documented mode.
        $options = $configuration['secret_scanning_delegated_bypass_options']
        if ($options -is [System.Collections.IDictionary] -and $options['reviewers'] -is [array]) {
            foreach ($reviewer in $options['reviewers']) {
                if ($reviewer -isnot [System.Collections.IDictionary]) { throw "Configuration '$ConfigurationName' in '$Organization' returned an invalid bypass reviewer." }
                if (-not $reviewer.Contains('mode')) { $reviewer['mode'] = 'ALWAYS' }
                elseif ([string] $reviewer['mode'] -cnotin $script:BypassModes) {
                    throw "Configuration '$ConfigurationName' in '$Organization' returned the unknown bypass mode '$($reviewer['mode'])'."
                }
            }
        }
    }

    $defaults = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method GET -Path "/orgs/$Organization/code-security/configurations/defaults"
    if ($defaults -isnot [array]) { throw "Organization '$Organization' returned no array of default configurations." }
    $defaultEntries = @(foreach ($default in $defaults) {
        if (-not $default['default_for_new_repos'] -or $default['configuration'] -isnot [System.Collections.IDictionary]) {
            throw "Organization '$Organization' returned a default configuration without visibility or configuration."
        }
        Assert-CodeSecurityId -Value $default['configuration']['id'] -Description "A default configuration in '$Organization'"
        [ordered]@{ default_for_new_repos = [string] $default['default_for_new_repos']; configuration_id = [string] $default['configuration']['id'] }
    })

    $patterns = [Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($entry in (Get-CustomPatternByName -ApiUrl $ApiUrl -Organization $Organization).GetEnumerator()) {
        $content = ConvertTo-CustomPatternContent -Pattern $entry.Value
        $content['slug'] = [string] $entry.Value['slug']
        $content['state'] = [string] $entry.Value['state']
        $content['push_protection_enabled'] = $entry.Value['push_protection_enabled'] -eq $true
        $patterns[$entry.Key] = $content
    }

    return [ordered]@{
        configuration       = $configuration
        defaults            = $defaultEntries
        repositories        = @($repositories)
        foreign_attachments = @($foreign)
        uncovered_repositories = @($uncovered)
        custom_patterns     = $patterns
    }
}

function Wait-CodeSecurityAttachment {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][long] $ConfigurationId,
        [int] $TimeoutSeconds = 600,
        [int] $IntervalSeconds = 10
    )

    $deadline = [DateTime]::UtcNow.AddSeconds($TimeoutSeconds)
    while ($true) {
        $repositories = Get-CodeSecurityConfigurationRepository -ApiUrl $ApiUrl -Organization $Organization -ConfigurationId $ConfigurationId
        $pending = @($repositories | Where-Object { $_['status'] -cin $script:PendingAttachmentStatuses })
        $uncovered = @()
        if ($pending.Count -eq 0) {
            $unsuccessful = @($repositories | Where-Object { $_['status'] -cnotin $script:SuccessfulAttachmentStatuses } | ForEach-Object { "$($_['repository']) ($($_['status']))" })
            if ($unsuccessful.Count -gt 0) {
                throw "Configuration $ConfigurationId in '$Organization' did not attach to: $($unsuccessful -join ', ')."
            }
            # The attach is asynchronous (HTTP 202); a repository without a record yet may still appear, so keep polling until the deadline.
            $uncovered = Get-UncoveredRepository -Inventory (Get-CodeSecurityRepositoryInventory -ApiUrl $ApiUrl -Organization $Organization) -Attached $repositories
            if ($uncovered.Count -eq 0) { return }
        }
        if ([DateTime]::UtcNow -ge $deadline) {
            if ($pending.Count -gt 0) {
                throw "Configuration $ConfigurationId in '$Organization' still has $($pending.Count) repositories attaching or updating."
            }
            throw "Configuration $ConfigurationId in '$Organization' is not attached to: $($uncovered -join ', ')."
        }
        Start-Sleep -Seconds $IntervalSeconds
    }
}

function Set-CodeSecurityConfiguration {
    <#
    .SYNOPSIS
    Creates or updates the configuration by name, makes it the default for new repositories and attaches it to all repositories.
    Every step is idempotent, so an interrupted run converges when Terraform repeats it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration,
        [int] $AttachmentTimeoutSeconds = 600,
        [int] $AttachmentIntervalSeconds = 10
    )

    $name = [string] $Configuration['name']
    if (-not $name) { throw 'The configuration has no name.' }
    if (-not $PSCmdlet.ShouldProcess("$Organization/$name", 'Write code security configuration')) { return }
    $configurations = Get-CodeSecurityConfigurationList -ApiUrl $ApiUrl -Organization $Organization
    $existing = Get-CodeSecurityConfigurationByName -Organization $Organization -Name $name -Configurations $configurations
    if ($existing) {
        $id = [long] $existing['id']
        $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method PATCH -Path "/orgs/$Organization/code-security/configurations/$id" -Body $Configuration
    }
    else {
        $created = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method POST -Path "/orgs/$Organization/code-security/configurations" -Body $Configuration
        if ($created -isnot [System.Collections.IDictionary]) { throw "GitHub did not return configuration '$name'." }
        Assert-CodeSecurityId -Value $created['id'] -Description "Created configuration '$name'"
        $id = [long] $created['id']
    }
    $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method PUT -Path "/orgs/$Organization/code-security/configurations/$id/defaults" `
        -Body @{ default_for_new_repos = 'all' }
    $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method POST -Path "/orgs/$Organization/code-security/configurations/$id/attach" `
        -Body @{ scope = 'all' }
    Wait-CodeSecurityAttachment -ApiUrl $ApiUrl -Organization $Organization -ConfigurationId $id `
        -TimeoutSeconds $AttachmentTimeoutSeconds -IntervalSeconds $AttachmentIntervalSeconds
}

function Remove-CodeSecurityConfiguration {
    <#
    .SYNOPSIS
    Removes the default role of the configuration and deletes it. A missing configuration is already removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Name
    )

    $configurations = Get-CodeSecurityConfigurationList -ApiUrl $ApiUrl -Organization $Organization
    $existing = Get-CodeSecurityConfigurationByName -Organization $Organization -Name $Name -Configurations $configurations
    if (-not $existing) { return }
    $id = [long] $existing['id']
    if ($PSCmdlet.ShouldProcess("$Organization/$Name", 'Delete code security configuration')) {
        $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method PUT -Path "/orgs/$Organization/code-security/configurations/$id/defaults" `
            -Body @{ default_for_new_repos = 'none' } -AllowNotFound
        $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method DELETE -Path "/orgs/$Organization/code-security/configurations/$id" -AllowNotFound
    }
}

function Set-CustomPattern {
    <#
    .SYNOPSIS
    Creates or updates one custom pattern by name and enables push protection for it.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Pattern
    )

    $name = [string] $Pattern['name']
    $desired = ConvertTo-CustomPatternContent -Pattern $Pattern
    if (-not $name -or -not $desired.pattern -or -not $desired.start_delimiter -or -not $desired.end_delimiter) {
        throw 'The custom pattern needs a name, a pattern and both delimiters.'
    }
    if (-not $PSCmdlet.ShouldProcess("$Organization/$name", 'Write custom pattern')) { return }
    $existing = (Get-CustomPatternByName -ApiUrl $ApiUrl -Organization $Organization)[$name]
    if (-not $existing) {
        $body = [ordered]@{ name = $name }
        foreach ($key in $desired.Keys) { $body[$key] = $desired[$key] }
        $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method POST -Path "/orgs/$Organization/secret-scanning/custom-patterns" `
            -Body @{ patterns = @($body) }
    }
    elseif ((ConvertTo-Json -InputObject (ConvertTo-CustomPatternContent -Pattern $existing) -Compress) -cne (ConvertTo-Json -InputObject $desired -Compress)) {
        # The list schema makes custom_pattern_version optional; the pattern configuration always carries it.
        $version = $existing['custom_pattern_version']
        if (-not $version) { $version = (Get-CustomPatternOverride -ApiUrl $ApiUrl -Organization $Organization -Pattern $existing).Override['custom_pattern_version'] }
        if (-not $version) { throw "Custom pattern '$name' in '$Organization' has no custom_pattern_version." }
        $body = [ordered]@{ custom_pattern_version = $version }
        foreach ($key in $desired.Keys) { $body[$key] = $desired[$key] }
        $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method PATCH `
            -Path "/orgs/$Organization/secret-scanning/custom-patterns/$($existing['id'])" -Body $body
    }

    $current = (Get-CustomPatternByName -ApiUrl $ApiUrl -Organization $Organization)[$name]
    if (-not $current) { throw "Custom pattern '$name' is missing in '$Organization' after it was written." }
    if ($current['push_protection_enabled'] -eq $true) { return }
    # pattern_config_version guards the organization-wide configuration; Terraform writes patterns in parallel, so a 409 means re-read and retry.
    for ($attempt = 1; ; $attempt++) {
        $found = Get-CustomPatternOverride -ApiUrl $ApiUrl -Organization $Organization -Pattern $current
        if (-not $found.Override -or -not $found.Override['token_type'] -or -not $found.Version) {
            throw "Custom pattern '$name' in '$Organization' has no push protection setting; it is in state '$($current['state'])'. Publish the pattern and rerun the apply."
        }
        $setting = [ordered]@{ token_type = $found.Override['token_type'] }
        if ($found.Override['custom_pattern_version']) { $setting['custom_pattern_version'] = $found.Override['custom_pattern_version'] }
        $setting['push_protection_setting'] = 'enabled'
        try {
            $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method PATCH -Path "/orgs/$Organization/secret-scanning/pattern-configurations" -Body ([ordered]@{
                    pattern_config_version  = $found.Version
                    custom_pattern_settings = @($setting)
                })
            break
        }
        catch {
            if ($attempt -ge $script:PatternConfigAttempts -or $_.Exception.Message -cnotlike '*HTTP 409*') { throw }
            Start-Sleep -Seconds (Get-Random -Minimum 1 -Maximum 4)
        }
    }
    $verified = (Get-CustomPatternByName -ApiUrl $ApiUrl -Organization $Organization)[$name]
    if (-not $verified -or $verified['push_protection_enabled'] -ne $true) {
        throw "Custom pattern '$name' in '$Organization' does not report push protection after it was enabled."
    }
}

function Get-CustomPatternOverride {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Pattern
    )

    $configuration = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method GET -Path "/orgs/$Organization/secret-scanning/pattern-configurations"
    if ($configuration -isnot [System.Collections.IDictionary]) { throw "Organization '$Organization' returned no pattern configuration." }
    $slug = [string] $Pattern['slug']
    $overrides = @($configuration['custom_pattern_overrides'] | Where-Object { $null -ne $_ -and $slug -and [string] $_['slug'] -ceq $slug })
    if ($overrides.Count -gt 1) { throw "Organization '$Organization' returned $($overrides.Count) pattern settings for slug '$slug'." }
    return [pscustomobject]@{
        Version  = [string] $configuration['pattern_config_version']
        Override = if ($overrides.Count -eq 1) { $overrides[0] } else { $null }
    }
}

function Remove-CustomPattern {
    <#
    .SYNOPSIS
    Deletes one custom pattern by name and resolves its alerts. A missing pattern is already removed.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $Name
    )

    $existing = (Get-CustomPatternByName -ApiUrl $ApiUrl -Organization $Organization)[$Name]
    if (-not $existing) { return }
    if ($PSCmdlet.ShouldProcess("$Organization/$Name", 'Delete custom pattern')) {
        $item = [ordered]@{ pattern_id = [long] $existing['id'] }
        if ($existing['custom_pattern_version']) { $item['custom_pattern_version'] = $existing['custom_pattern_version'] }
        $null = Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method DELETE -Path "/orgs/$Organization/secret-scanning/custom-patterns" -Body @{
            patterns           = @($item)
            post_delete_action = 'resolve_alerts'
        }
    }
}

Export-ModuleMember -Function Invoke-CodeSecurityApi, Get-CodeSecurityState, Set-CodeSecurityConfiguration,
    Remove-CodeSecurityConfiguration, Set-CustomPattern, Remove-CustomPattern
