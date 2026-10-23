Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# REST endpoints, API version 2026-03-10:
# https://docs.github.com/en/enterprise-cloud@latest/rest/enterprise-admin/organization-installations
# GraphQL (schema github/docs@3a444c04d005e5d91e29ee0658fd5c9bbeaecf24 src/graphql/data/ghec/schema.docs.graphql):
# https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/queries#enterprise
# https://docs.github.com/en/enterprise-cloud@latest/graphql/reference/mutations#createenterpriseorganization

$script:ApiVersion = '2026-03-10'
# The installation schema documents all and selected; the create operation also accepts none.
$script:RepositorySelections = @('all', 'selected')
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
        [Parameter(Mandatory)][ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string] $Method,
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

function Assert-EnterpriseOrganizationAdoptable {
    <#
    .SYNOPSIS
    Returns the actual login of an existing organization that the module may adopt, $null for a free name, and fails
    for an existing organization without AllowExisting.
    .DESCRIPTION
    The removal guard runs this read-only check before Terraform stores it, so a rejected organization never becomes
    a destroy obligation of the module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [switch] $AllowExisting
    )

    $existing = Find-EnterpriseOrganization -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization
    if ($existing -and -not $AllowExisting) {
        throw "Organization '$existing' already exists in enterprise '$Enterprise'. The module adopts an existing organization only when its name contains the deployment identifier. GitHub retains deleted organization names, so retrying the same name does not help: clean up this deployment and bootstrap a new deployment with a new deployment identifier."
    }
    return $existing
}

function New-EnterpriseOrganization {
    <#
    .SYNOPSIS
    Creates the organization in the enterprise, or adopts it when AllowExisting proves it belongs to this instance.
    .DESCRIPTION
    A taken name fails closed unless AllowExisting is set. The caller sets AllowExisting only when the name contains
    the deployment identifier; it covers a run interrupted after the mutation. A legacy name never adopts.
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
    $existing = Assert-EnterpriseOrganizationAdoptable -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization -AllowExisting:$AllowExisting
    if ($existing) {
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

function Get-OrganizationInstallationRepository {
    <#
    .SYNOPSIS
    Lists the full names of all repositories that the App installation can access.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][object] $InstallationId
    )

    Assert-OrganizationsName -Value $Enterprise -Description 'Enterprise'
    Assert-OrganizationsName -Value $Organization -Description 'Organization'
    Assert-OrganizationsId -Value $InstallationId -Description "The installation in '$Organization'"
    $reply = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method GET -AllPages `
        -Path "/enterprises/$Enterprise/apps/organizations/$Organization/installations/$InstallationId/repositories?per_page=100"
    foreach ($repository in $reply.Body) {
        if ($repository -isnot [System.Collections.IDictionary] -or $repository['full_name'] -isnot [string] -or
            [string]::IsNullOrWhiteSpace($repository['full_name'])) {
            throw "Installation $InstallationId in '$Organization' returned an unreadable repository."
        }
        Assert-OrganizationsId -Value $repository['id'] -Description "Repository '$($repository['full_name'])'"
        $repository['full_name']
    }
}

# security-check: organizations-installation-selection
function Assert-OrganizationInstallationSelection {
    <#
    .SYNOPSIS
    Requires the manifest selection: all repositories, or an empty repository list for none.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Installation,
        [ValidateSet('none', 'all', IgnoreCase = $false)][string] $RepositorySelection = 'none'
    )

    $clientId = $Installation['client_id']
    if ($RepositorySelection -ceq 'all') {
        if ($Installation['repository_selection'] -cne 'all') {
            throw "App '$clientId' in '$Organization' must have access to all repositories; repository_selection is '$($Installation['repository_selection'])'."
        }
        return
    }
    if ($Installation['repository_selection'] -cne 'selected') {
        throw "App '$clientId' is installed in '$Organization' with access to all repositories. The module installs it without repository access; reduce the access or uninstall the App and rerun the apply."
    }
    $repositories = @(Get-OrganizationInstallationRepository -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization `
            -InstallationId $Installation['id'])
    if ($repositories.Count -gt 0) {
        throw "App '$clientId' has access to $($repositories.Count) repositories in '$Organization'. The module installs it without repository access; remove the repositories from the installation and rerun the apply."
    }
}

function Assert-OrganizationAppAdoptable {
    <#
    .SYNOPSIS
    Returns an existing installation of the App that the module may adopt, or $null. An existing installation with
    repository access fails.
    .DESCRIPTION
    The installation guard runs this read-only check before Terraform stores it, so a rejected installation is never
    uninstalled by the module.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ClientId,
        [ValidateSet('none', 'all', IgnoreCase = $false)][string] $RepositorySelection = 'none'
    )

    if ($ClientId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.]{0,63}\z') { throw "App client ID '$ClientId' is not valid." }
    $existing = Find-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization -ClientId $ClientId
    if ($existing) {
        Assert-OrganizationInstallationSelection -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization `
            -Installation $existing -RepositorySelection $RepositorySelection
    }
    return $existing
}

function Install-OrganizationApp {
    <#
    .SYNOPSIS
    Installs a GitHub App with the manifest's repository selection. Repeating the call is idempotent.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][AllowEmptyString()][string] $ClientId,
        [ValidateSet('none', 'all', IgnoreCase = $false)][string] $RepositorySelection = 'none'
    )

    $existing = Assert-OrganizationAppAdoptable -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization `
        -ClientId $ClientId -RepositorySelection $RepositorySelection
    if ($existing) { return $existing }

    # Request body of POST .../installations; 'none' needs an App without repository permissions.
    $reply = Invoke-OrganizationsApi -ApiUrl $ApiUrl -Method POST -AcceptStatus @(200, 201) `
        -Path "/enterprises/$Enterprise/apps/organizations/$Organization/installations" `
        -Body @{ client_id = $ClientId; repository_selection = $RepositorySelection }
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
    $acceptedSelections = if ($RepositorySelection -ceq 'all') { @('all') } else { @('selected', 'none') }
    if ($installation['repository_selection'] -isnot [string] -or $installation['repository_selection'] -cnotin $acceptedSelections) {
        $expected = if ($RepositorySelection -ceq 'all') { 'all repositories' } else { 'no repository access' }
        throw "The installation of App '$ClientId' in '$Organization' has repository_selection '$($installation['repository_selection'])' instead of $expected."
    }
    $listed = Find-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization -ClientId $ClientId
    if (-not $listed -or $listed.id -ne $installation['id']) {
        throw "The installation of App '$ClientId' is not listed in '$Organization'."
    }
    Assert-OrganizationInstallationSelection -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization `
        -Installation $listed -RepositorySelection $RepositorySelection
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
    .DESCRIPTION
    For a 'selected' installation of an App in ClientId, the state lists the accessible repositories.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][string] $Organization,
        [AllowEmptyCollection()][string[]] $ClientId = @()
    )

    $existing = Find-EnterpriseOrganization -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $Organization
    if (-not $existing) { return [ordered]@{ exists = $false; login = $null; installations = @() } }
    $installations = @(@(Get-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $existing) |
            ForEach-Object {
                $item = [ordered]@{ client_id = $_.client_id; repository_selection = $_.repository_selection }
                if ($_.repository_selection -cin @('selected', 'none') -and $ClientId -ccontains $_.client_id) {
                    $item.repositories = @(Get-OrganizationInstallationRepository -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $existing `
                            -InstallationId $_.id)
                }
                $item
            })
    return [ordered]@{ exists = $true; login = $existing; installations = $installations }
}

# security-check: organizations-installation-scope
function Get-OrganizationAppScopeViolation {
    <#
    .SYNOPSIS
    Reads all enterprise organizations and reports managed Apps installed outside their manifest scope.
    An existing installation with the wrong repository selection fails the read.
    Missing installations are planned creations, not scope violations.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][string] $ApiUrl,
        [Parameter(Mandatory)][string] $Enterprise,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Installation
    )

    foreach ($clientId in $Installation.Keys) {
        if ($clientId -cnotmatch '^[A-Za-z0-9][A-Za-z0-9.]{0,63}\z') { throw "App client ID '$clientId' is not valid." }
        $desired = $Installation[$clientId]
        if ($desired -isnot [System.Collections.IDictionary]) { throw "App '$clientId' has no installation contract." }
        if ($desired['organizations'] -isnot [array] -or $desired['organizations'].Count -eq 0) {
            throw "App '$clientId' must declare its target organizations."
        }
        foreach ($organization in $desired['organizations']) {
            Assert-OrganizationsName -Value $organization -Description "A target organization of App '$clientId'"
        }
        if ($desired['repository_selection'] -cnotin @('none', 'all')) {
            throw "App '$clientId' must declare repository_selection none or all."
        }
    }
    $violations = [Collections.Generic.List[string]]::new()
    foreach ($organization in @(Get-EnterpriseOrganizationLogin -ApiUrl $ApiUrl -Enterprise $Enterprise)) {
        foreach ($actual in @(Get-OrganizationAppInstallation -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $organization)) {
            if (@($Installation.Keys) -cnotcontains $actual.client_id) { continue }
            $desired = $Installation[$actual.client_id]
            $matches = @($desired['organizations'] | Where-Object {
                    [string]::Equals($_, $organization, [StringComparison]::OrdinalIgnoreCase)
                })
            if ($matches.Count -eq 0) {
                $violations.Add("App '$($actual.client_id)' is installed in unexpected organization '$organization'.")
            }
            else {
                Assert-OrganizationInstallationSelection -ApiUrl $ApiUrl -Enterprise $Enterprise -Organization $organization `
                    -Installation $actual -RepositorySelection $desired['repository_selection']
            }
        }
    }
    return $violations.ToArray()
}

function Get-OrganizationStateViolation {
    <#
    .SYNOPSIS
    Lists the differences between the read organization state and the module state; an empty list means compliant.
    #>
    [CmdletBinding()]
    [OutputType([string[]])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $State,
        [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $ClientId
    )

    if ($State['exists'] -isnot [bool]) { throw "The state of organization '$Organization' is unreadable." }
    if (-not $State['exists']) { return , [string[]] @("Organization '$Organization' does not exist in the enterprise.") }
    $violations = [Collections.Generic.List[string]]::new()
    $installed = @($State['installations'] | ForEach-Object { $_['client_id'] })
    foreach ($id in $ClientId) {
        if ($installed -cnotcontains $id) { $violations.Add("App '$id' is not installed in organization '$Organization'.") }
    }
    foreach ($installation in @($State['installations'])) {
        # Apps outside the module are not checked; their repository access is not part of the module contract.
        if ($ClientId -cnotcontains $installation['client_id']) { continue }
        $selection = $installation['repository_selection']
        if ($selection -cnotin @('selected', 'none')) {
            $violations.Add("App '$($installation['client_id'])' has access to all repositories of organization '$Organization'.")
        }
        else {
            if (-not $installation.Contains('repositories') -or $installation['repositories'] -isnot [array]) {
                throw "The repositories of App '$($installation['client_id'])' in organization '$Organization' are unreadable."
            }
            if ($installation['repositories'].Count -gt 0) {
                $violations.Add("App '$($installation['client_id'])' has access to $($installation['repositories'].Count) repositories of organization '$Organization'.")
            }
        }
    }
    return , [string[]] $violations.ToArray()
}

function ConvertTo-OrganizationStateResult {
    <#
    .SYNOPSIS
    Serializes the state and its violations into the string map of the Terraform external data source.
    .DESCRIPTION
    The external data source accepts only string values, so both values are JSON documents. The violations are a
    flat JSON array of messages; an empty array means compliant.
    #>
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $State,
        [Parameter(Mandatory)][AllowEmptyCollection()][string[]] $Violation
    )

    ConvertTo-Json -Compress -InputObject @{
        state      = ConvertTo-Json -InputObject $State -Depth 10 -Compress
        # -InputObject keeps an empty or single-item array as an array; -AsArray would nest it once more.
        violations = ConvertTo-Json -InputObject ([string[]] $Violation) -Compress
    }
}

Export-ModuleMember -Function Invoke-OrganizationsApi, Invoke-OrganizationsGraphQL, Get-EnterpriseOrganizationLogin,
Find-EnterpriseOrganization, Assert-EnterpriseOrganizationAdoptable, New-EnterpriseOrganization, Assert-EnterpriseOrganizationRemoved, Get-OrganizationAppInstallation,
Find-OrganizationAppInstallation, Get-OrganizationInstallationRepository, Assert-OrganizationAppAdoptable, Install-OrganizationApp, Uninstall-OrganizationApp,
Get-InstanceOrganizationState, Get-OrganizationAppScopeViolation, Get-OrganizationStateViolation, ConvertTo-OrganizationStateResult
