Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# REST endpoints, API version 2026-03-10:
# https://docs.github.com/en/enterprise-cloud@latest/rest/enterprise-admin/organization-installations
# GraphQL (schema github/docs@3a444c04d005e5d91e29ee0658fd5c9bbeaecf24 src/graphql/data/ghec/schema.docs.graphql):
# https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/queries#enterprise
# https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/mutations#createenterpriseorganization

$script:ApiVersion = '2026-03-10'
# The installation schema documents all and selected; the create operation also accepts none.
$script:RepositorySelections = @('all', 'selected', 'none')
$script:RunbookReference = 'modules/organizations/README.md'

function Assert-OrganizationsApiUrl {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl)

    $uri = $null
    if (-not [Uri]::TryCreate($ApiUrl, [UriKind]::Absolute, [ref] $uri) -or $uri.AbsolutePath -cne '/' -or $uri.Query -or
        $uri.UserInfo -or -not ($uri.Scheme -ceq 'https' -or ($uri.Scheme -ceq 'http' -and $uri.IsLoopback))) {
        throw "The GitHub API URL '$ApiUrl' must be an HTTPS origin; plain HTTP is only accepted for a loopback test stub."
    }
}

function Assert-OrganizationsName {
    [CmdletBinding()]
    param([AllowNull()][object] $Value, [Parameter(Mandatory)][string] $Description)

    if ($Value -isnot [string] -or $Value -cnotmatch '^[A-Za-z0-9](?:[A-Za-z0-9-]{0,37}[A-Za-z0-9])?\z') {
        throw "$Description '$Value' is not a valid GitHub login or slug."
    }
}

function Assert-OrganizationsId {
    [CmdletBinding()]
    param([AllowNull()][object] $Value, [Parameter(Mandatory)][string] $Description)

    if (($Value -isnot [int] -and $Value -isnot [long]) -or $Value -lt 1) { throw "$Description has no valid ID." }
}

function Invoke-OrganizationsApi {
    <#
    .SYNOPSIS
    Sends one GitHub request with the job's token and follows Link rel="next" on the same origin.
    .DESCRIPTION
    Returns @{ Status; Body }. Only the listed statuses are accepted; any other status throws.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'DELETE')][string] $Method,
        [Parameter(Mandatory)][string] $Path,
        [AllowNull()][object] $Body,
        [int[]] $AcceptStatus = @(200),
        [switch] $AllPages
    )

    Assert-OrganizationsApiUrl -ApiUrl $ApiUrl
    if (-not $env:REST_API_BEARER) { throw 'REST_API_BEARER is not set; the runner must export the GitHub token.' }
    $origin = $ApiUrl.TrimEnd('/')
    $headers = @{
        Authorization          = "Bearer $env:REST_API_BEARER"
        Accept                 = 'application/vnd.github+json'
        'X-GitHub-Api-Version' = $script:ApiVersion
    }
    $operation = "$Method $($Path.Split('?')[0])"
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
        if ($status -notin $AcceptStatus) { throw "GitHub returned HTTP $status for $operation." }
        $content = if ($reply.Content -is [byte[]]) { [Text.Encoding]::UTF8.GetString($reply.Content) } else { [string] $reply.Content }
        $parsed = if ([string]::IsNullOrWhiteSpace($content)) { $null } else { ConvertFrom-Json -InputObject $content -AsHashtable -Depth 100 -NoEnumerate }
        if (-not $AllPages) { return @{ Status = $status; Body = $parsed } }
        if ($parsed -isnot [array]) { throw "GitHub returned no JSON array for $operation." }
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
    return @{ Status = 200; Body = $items.ToArray() }
}

function Invoke-OrganizationsGraphQL {
    <#
    .SYNOPSIS
    Sends one GraphQL operation and returns its data; any GraphQL error fails the call.
    .DESCRIPTION
    GraphQL reports rejected operations with HTTP 200 and an errors list (https://spec.graphql.org/October2021/#sec-Errors).
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Query,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Variables,
        [Parameter(Mandatory)][string] $Operation
    )

    $reply = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method POST -Path '/graphql' -Body @{ query = $Query; variables = $Variables }
    $response = $reply.Body
    if ($response -isnot [System.Collections.IDictionary]) { throw "GitHub GraphQL returned no JSON object for $Operation." }
    if ($response.Contains('errors') -and $null -ne $response['errors']) {
        $messages = @(foreach ($item in @($response['errors'])) {
                if ($item -is [System.Collections.IDictionary] -and $item['message'] -is [string]) { $item['message'] } else { 'unreadable error' }
            })
        if ($messages.Count -eq 0) { $messages = @('empty errors list') }
        throw "GitHub GraphQL rejected $Operation`: $($messages -join '; ')"
    }
    if ($response['data'] -isnot [System.Collections.IDictionary]) { throw "GitHub GraphQL returned no data for $Operation." }
    return $response['data']
}

function Get-EnterpriseOrganizationLogin {
    <#
    .SYNOPSIS
    Lists the logins of all organizations owned by the enterprise.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Enterprise)

    Assert-OrganizationsName -Value $Enterprise -Description 'Enterprise'
    $reply = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method GET -AllPages `
        -Path "/enterprises/$Enterprise/apps/installable_organizations?per_page=100"
    foreach ($organization in $reply.Body) {
        if ($organization -isnot [System.Collections.IDictionary]) { throw "Enterprise '$Enterprise' returned an unreadable organization." }
        Assert-OrganizationsId -Value $organization['id'] -Description "An organization of enterprise '$Enterprise'"
        Assert-OrganizationsName -Value $organization['login'] -Description "An organization of enterprise '$Enterprise'"
        $organization['login']
    }
}

function Find-EnterpriseOrganization {
    <#
    .SYNOPSIS
    Returns the actual login of an enterprise organization, or $null. GitHub logins are case-insensitive.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization
    )

    Assert-OrganizationsName -Value $Organization -Description 'Organization'
    $matched = @(@(Get-EnterpriseOrganizationLogin -ApiUrl $ApiUrl -Enterprise $Enterprise) |
            Where-Object { [string]::Equals($_, $Organization, [StringComparison]::OrdinalIgnoreCase) })
    if ($matched.Count -gt 1) { throw "Enterprise '$Enterprise' lists organization '$Organization' more than once." }
    if ($matched.Count -eq 1) { return $matched[0] }
    return $null
}

function New-EnterpriseOrganization {
    <#
    .SYNOPSIS
    Creates the organization in the enterprise, or adopts it when AllowExisting proves it belongs to this instance.
    .DESCRIPTION
    A taken name fails closed unless AllowExisting is set. AllowExisting covers a run interrupted after the mutation
    (the name contains the deployment identifier) and an explicit adoption in the instance configuration.
    Owners and the billing email apply only when the organization is created.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][AllowEmptyCollection()][AllowEmptyString()][string[]] $AdminLogins,
        [Parameter(Mandatory)][AllowEmptyString()][string] $BillingEmail,
        [switch] $AllowExisting,
        [ValidateRange(1, 60)][int] $VisibilityAttempts = 10,
        [ValidateRange(0, 60)][int] $VisibilityDelaySeconds = 3
    )

    if ($AdminLogins.Count -eq 0 -or @($AdminLogins | Where-Object { [string]::IsNullOrWhiteSpace($_) }).Count -gt 0) {
        throw 'The organization needs at least one owner in admin_logins, and no owner login may be empty.'
    }
    if ([string]::IsNullOrWhiteSpace($BillingEmail)) { throw 'The organization needs billing_email.' }
    $existing = Find-EnterpriseOrganization -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization
    if ($existing) {
        if (-not $AllowExisting) {
            throw "Organization '$existing' already exists in enterprise '$Enterprise'. The module adopts an existing organization only with a deployment identifier or adopt_organizations. Delete it, add its kind to adopt_organizations, or bootstrap a new deployment with a new identifier."
        }
        Write-Information "Organization '$existing' already exists in enterprise '$Enterprise'; the module adopts it."
        return $existing
    }

    $enterpriseData = Invoke-OrganizationsGraphQL -ApiUrl $ApiUrl -Operation "query enterprise(slug: $Enterprise)" `
        -Query 'query($slug: String!) { enterprise(slug: $slug) { id } }' -Variables @{ slug = $Enterprise }
    $enterpriseId = if ($enterpriseData['enterprise'] -is [System.Collections.IDictionary]) { $enterpriseData['enterprise']['id'] }
    if ($enterpriseId -isnot [string] -or [string]::IsNullOrWhiteSpace($enterpriseId)) {
        throw "Enterprise '$Enterprise' is not visible to the token."
    }
    $mutation = 'mutation($input: CreateEnterpriseOrganizationInput!) { createEnterpriseOrganization(input: $input) { organization { id login } } }'
    $data = Invoke-OrganizationsGraphQL -ApiUrl $ApiUrl -Operation "mutation createEnterpriseOrganization($Organization)" -Query $mutation -Variables @{
        input = @{
            enterpriseId = $enterpriseId
            login        = $Organization
            profileName  = $Organization
            billingEmail = $BillingEmail
            adminLogins  = @($AdminLogins)
        }
    }
    $payload = $data['createEnterpriseOrganization']
    $created = if ($payload -is [System.Collections.IDictionary]) { $payload['organization'] }
    if ($created -isnot [System.Collections.IDictionary] -or $created['id'] -isnot [string] -or [string]::IsNullOrWhiteSpace($created['id']) -or
        $created['login'] -isnot [string] -or -not [string]::Equals($created['login'], $Organization, [StringComparison]::OrdinalIgnoreCase)) {
        throw "GitHub GraphQL did not confirm organization '$Organization' in createEnterpriseOrganization."
    }
    for ($attempt = 1; $attempt -le $VisibilityAttempts; $attempt++) {
        $listed = Find-EnterpriseOrganization -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization
        if ($listed) { return $listed }
        if ($attempt -lt $VisibilityAttempts) { Start-Sleep -Seconds $VisibilityDelaySeconds }
    }
    throw "Organization '$Organization' was created but is not listed in enterprise '$Enterprise'. Rerun the apply after the organization appears."
}

function Assert-EnterpriseOrganizationRemoved {
    <#
    .SYNOPSIS
    Fails while the organization still exists. Deleting an organization is a manual step of the platform team.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization
    )

    $existing = Find-EnterpriseOrganization -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization
    if ($existing) {
        throw "Organization '$existing' still exists in enterprise '$Enterprise'. Deleting an organization is the manual step delete-instance-organizations ($script:RunbookReference). Delete it and rerun the destroy."
    }
}

function Get-OrganizationAppInstallation {
    <#
    .SYNOPSIS
    Lists the GitHub App installations of an enterprise organization as @{ id; client_id; repository_selection }.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization
    )

    Assert-OrganizationsName -Value $Enterprise -Description 'Enterprise'
    Assert-OrganizationsName -Value $Organization -Description 'Organization'
    $reply = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method GET -AllPages `
        -Path "/enterprises/$Enterprise/apps/organizations/$Organization/installations?per_page=100"
    foreach ($installation in $reply.Body) {
        if ($installation -isnot [System.Collections.IDictionary]) { throw "Organization '$Organization' returned an unreadable installation." }
        Assert-OrganizationsId -Value $installation['id'] -Description "An installation in '$Organization'"
        if ($installation['client_id'] -isnot [string] -or [string]::IsNullOrWhiteSpace($installation['client_id'])) {
            throw "Installation $($installation['id']) in '$Organization' has no client_id."
        }
        if ($installation['repository_selection'] -isnot [string] -or $installation['repository_selection'] -cnotin $script:RepositorySelections) {
            throw "Installation $($installation['id']) in '$Organization' has unknown repository_selection '$($installation['repository_selection'])'."
        }
        @{ id = $installation['id']; client_id = $installation['client_id']; repository_selection = $installation['repository_selection'] }
    }
}

function Find-OrganizationAppInstallation {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $ClientId
    )

    $matched = @(@(Get-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization) |
            Where-Object { $_.client_id -ceq $ClientId })
    if ($matched.Count -gt 1) { throw "Organization '$Organization' has more than one installation of App '$ClientId'." }
    if ($matched.Count -eq 1) { return $matched[0] }
    return $null
}

function Install-OrganizationApp {
    <#
    .SYNOPSIS
    Installs a GitHub App into the organization without repository access. Repeating the call is idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ClientId
    )

    if ($ClientId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.]{0,63}\z') { throw "App client ID '$ClientId' is not valid." }
    $existing = Find-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization -ClientId $ClientId
    if ($existing) {
        if ($existing.repository_selection -ceq 'all') {
            throw "App '$ClientId' is installed in '$Organization' with access to all repositories. The module installs it without repository access; reduce the access or uninstall the App and rerun the apply."
        }
        return $existing
    }

    # Request body of POST .../installations; 'none' needs an App without repository permissions.
    $reply = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method POST -AcceptStatus @(200, 201) `
        -Path "/enterprises/$Enterprise/apps/organizations/$Organization/installations" `
        -Body @{ client_id = $ClientId; repository_selection = 'none' }
    $installation = $reply.Body
    if ($installation -isnot [System.Collections.IDictionary]) { throw "GitHub returned no installation for App '$ClientId' in '$Organization'." }
    Assert-OrganizationsId -Value $installation['id'] -Description "The installation of App '$ClientId' in '$Organization'"
    if ($installation['target_type'] -cne 'Organization') {
        throw "The installation of App '$ClientId' targets '$($installation['target_type'])', not an organization."
    }
    $account = $installation['account']
    # The schema allows a Simple User or an Enterprise account; only an organization login matches the target.
    if ($account -isnot [System.Collections.IDictionary] -or $account['type'] -cne 'Organization' -or $account['login'] -isnot [string] -or
        -not [string]::Equals($account['login'], $Organization, [StringComparison]::OrdinalIgnoreCase)) {
        throw "The installation of App '$ClientId' does not belong to organization '$Organization'."
    }
    if ($installation['repository_selection'] -isnot [string] -or $installation['repository_selection'] -cnotin @('selected', 'none')) {
        throw "The installation of App '$ClientId' in '$Organization' has repository_selection '$($installation['repository_selection'])' instead of no repository access."
    }
    $listed = Find-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization -ClientId $ClientId
    if (-not $listed -or $listed.id -ne $installation['id']) {
        throw "The installation of App '$ClientId' is not listed in '$Organization'."
    }
    return $listed
}

function Uninstall-OrganizationApp {
    <#
    .SYNOPSIS
    Removes the App installation. An absent organization or installation is already the target state.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][string] $ClientId
    )

    $existingOrganization = Find-EnterpriseOrganization -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization
    if (-not $existingOrganization) { return }
    $installation = Find-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $existingOrganization -ClientId $ClientId
    if (-not $installation) { return }
    $null = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method DELETE -AcceptStatus @(204, 404) `
        -Path "/enterprises/$Enterprise/apps/organizations/$existingOrganization/installations/$($installation.id)"
    if (Find-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $existingOrganization -ClientId $ClientId) {
        throw "App '$ClientId' is still installed in '$existingOrganization' after removal."
    }
}

function Get-InstanceOrganizationState {
    <#
    .SYNOPSIS
    Reads whether the organization exists and which Apps it has installed.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization
    )

    $existing = Find-EnterpriseOrganization -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization
    if (-not $existing) { return [ordered]@{ exists = $false; login = $null; installations = @() } }
    $installations = @(@(Get-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $existing) |
            ForEach-Object { [ordered]@{ client_id = $_.client_id; repository_selection = $_.repository_selection } })
    return [ordered]@{ exists = $true; login = $existing; installations = $installations }
}

Export-ModuleMember -Function Invoke-OrganizationsApi, Invoke-OrganizationsGraphQL, Get-EnterpriseOrganizationLogin,
Find-EnterpriseOrganization, New-EnterpriseOrganization, Assert-EnterpriseOrganizationRemoved, Get-OrganizationAppInstallation,
Find-OrganizationAppInstallation, Install-OrganizationApp, Uninstall-OrganizationApp, Get-InstanceOrganizationState
