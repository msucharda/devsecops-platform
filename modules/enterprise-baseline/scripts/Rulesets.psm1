Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# Reuse the versioned REST transport (including same-origin pagination) of this module.
Import-Module (Join-Path $PSScriptRoot 'CodeSecurity.psm1')

function Invoke-OrganizationRulesetApi {
    [CmdletBinding()]
    param(
        [string] $ApiUrl,
        [string] $Organization,
        [ValidateSet('GET', 'POST', 'PUT', 'DELETE')][string] $Method,
        [string] $Path,
        [AllowNull()][object] $Body,
        [switch] $AllPages
    )

    if ($Organization -cnotmatch '^[A-Za-z0-9][A-Za-z0-9-]*$') { throw 'Invalid ruleset organization name.' }
    $tokens = if ($env:PLATFORM_GITHUB_TOKENS) { $env:PLATFORM_GITHUB_TOKENS | ConvertFrom-Json -AsHashtable } else { $null }
    if ($tokens -isnot [Collections.IDictionary] -or -not $tokens.Contains($Organization) -or
        $tokens[$Organization] -isnot [string] -or [string]::IsNullOrWhiteSpace($tokens[$Organization])) {
        throw "No installation token for rulesets of '$Organization' in PLATFORM_GITHUB_TOKENS."
    }
    $previous = $env:REST_API_BEARER
    try {
        $env:REST_API_BEARER = $tokens[$Organization]
        return , (Invoke-CodeSecurityApi -ApiUrl $ApiUrl -Method $Method -Path $Path -Body $Body -AllPages:$AllPages)
    }
    finally { $env:REST_API_BEARER = $previous }
}

function Get-OrganizationRulesetDetail {
    [CmdletBinding()]
    param([string] $ApiUrl, [string] $Organization, [string] $Name)

    # API 2026-03-10: GET /orgs/{org}/rulesets and GET /orgs/{org}/rulesets/{ruleset_id}.
    # https://docs.github.com/en/enterprise-cloud@latest/rest/orgs/rules
    $listed = Invoke-OrganizationRulesetApi -ApiUrl $ApiUrl -Organization $Organization -Method GET `
        -Path "/orgs/$Organization/rulesets?per_page=100" -AllPages
    $found = @(
        foreach ($item in $listed) {
            if ($item -isnot [Collections.IDictionary] -or [string] $item['id'] -cnotmatch '^[1-9][0-9]{0,17}$' -or
                -not $item['name'] -or -not $item['source']) {
                throw "Ruleset list of '$Organization' contains invalid identity metadata."
            }
            if ([string] $item['source_type'] -ceq 'Enterprise') { continue }
            if ([string] $item['source_type'] -cne 'Organization' -or [string] $item['source'] -ine $Organization) {
                throw "Ruleset list of '$Organization' contains unknown or mismatched source metadata."
            }
            if ([string] $item['name'] -ieq $Name) {
                if ([string] $item['name'] -cne $Name) { throw "Ruleset name '$Name' collides with a differently cased name." }
                $item
            }
        }
    )
    if ($found.Count -gt 1) { throw "Organization '$Organization' has duplicate rulesets named '$Name'." }
    if ($found.Count -eq 0) { return $null }
    $id = $found[0]['id']
    $detail = Invoke-OrganizationRulesetApi -ApiUrl $ApiUrl -Organization $Organization -Method GET -Path "/orgs/$Organization/rulesets/$id"
    if ($detail -isnot [Collections.IDictionary] -or [string] $detail['id'] -cne [string] $id -or
        [string] $detail['name'] -cne $Name -or [string] $detail['source_type'] -cne 'Organization' -or
        [string] $detail['source'] -ine $Organization) {
        throw "Ruleset detail of '$Organization' has mismatched identity or source metadata."
    }
    if (-not $detail.Contains('bypass_actors') -or $detail['bypass_actors'] -isnot [array]) {
        throw "Ruleset detail of '$Organization' did not expose bypass_actors as an array; Organization Administration: write is required even for plan."
    }
    return $detail
}

function Get-OrganizationRulesetState {
    <#
    .SYNOPSIS
    Reads the managed organization ruleset, preserving drift and rejecting an unreadable bypass list.
    #>
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization, [Parameter(Mandatory)][string] $Name)

    $detail = Get-OrganizationRulesetDetail @PSBoundParameters
    if ($null -eq $detail) { return $null }
    $state = [ordered]@{}
    foreach ($field in @('name', 'target', 'enforcement', 'bypass_actors', 'conditions', 'rules')) {
        if (-not $detail.Contains($field) -or $null -eq $detail[$field]) { throw "Ruleset detail has no '$field'." }
        $state[$field] = $detail[$field]
    }
    if ($state.rules -isnot [array]) { throw 'Ruleset detail has no rules array.' }
    if ($state.conditions -isnot [Collections.IDictionary] -or -not $state.conditions.Contains('repository_name') -or
        $state.conditions.Contains('repository_id') -or $state.conditions.Contains('repository_property')) {
        throw 'Unsupported organization ruleset conditions: the managed baseline requires repository_name and ref_name.'
    }
    # Rule order is not significant. Preserve unknown fields and rules so the Terraform comparison detects drift.
    foreach ($rule in $state.rules) {
        if ($rule -isnot [Collections.IDictionary] -or -not $rule['type']) { throw 'Ruleset detail has a rule without type.' }
        if ($rule['type'] -ceq 'pull_request' -and $rule['parameters'] -is [Collections.IDictionary]) {
            $parameters = $rule['parameters']
            if ($parameters.Contains('allowed_merge_methods') -and $parameters['allowed_merge_methods'] -is [array]) {
                $parameters['allowed_merge_methods'] = @($parameters['allowed_merge_methods'] | Sort-Object -CaseSensitive)
            }
            # Optional server additions equivalent to the baseline; do not hide enabled restrictions.
            if ($parameters.Contains('required_reviewers') -and $parameters['required_reviewers'] -is [array] -and
                $parameters['required_reviewers'].Count -eq 0) { $parameters.Remove('required_reviewers') }
            if ($parameters.Contains('dismissal_restriction') -and $parameters['dismissal_restriction'] -is [Collections.IDictionary]) {
                $restriction = $parameters['dismissal_restriction']
                if ($restriction['enabled'] -ceq $false -and $restriction.Contains('allowed_actors') -and
                    $restriction['allowed_actors'] -is [array] -and $restriction['allowed_actors'].Count -eq 0 -and
                    $restriction.Count -eq 2) { $parameters.Remove('dismissal_restriction') }
            }
        }
    }
    $state.rules = @($state.rules | Sort-Object { $_['type'] } -CaseSensitive)
    return $state
}

function Set-OrganizationRuleset {
    <#
    .SYNOPSIS
    Upserts by the stable managed name, including after a lost POST or PUT response.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization,
        [Parameter(Mandatory)][Collections.IDictionary] $Ruleset)

    $existing = Get-OrganizationRulesetDetail -ApiUrl $ApiUrl -Organization $Organization -Name $Ruleset['name']
    if ($PSCmdlet.ShouldProcess("$Organization/$($Ruleset['name'])", 'Set organization ruleset')) {
        $path = "/orgs/$Organization/rulesets"
        $method = 'POST'
        if ($existing) { $path += "/$($existing['id'])"; $method = 'PUT' }
        $null = Invoke-OrganizationRulesetApi -ApiUrl $ApiUrl -Organization $Organization -Method $method -Path $path -Body $Ruleset
    }
}

function Remove-OrganizationRuleset {
    <#
    .SYNOPSIS
    Deletes only the named local ruleset; a repeated delete after a lost response finds nothing.
    #>
    [CmdletBinding(SupportsShouldProcess)]
    param([Parameter(Mandatory)][string] $ApiUrl, [Parameter(Mandatory)][string] $Organization, [Parameter(Mandatory)][string] $Name)

    $existing = Get-OrganizationRulesetDetail -ApiUrl $ApiUrl -Organization $Organization -Name $Name
    if ($existing -and $PSCmdlet.ShouldProcess("$Organization/$Name", 'Delete organization ruleset')) {
        $null = Invoke-OrganizationRulesetApi -ApiUrl $ApiUrl -Organization $Organization -Method DELETE -Path "/orgs/$Organization/rulesets/$($existing['id'])"
        if ($null -ne (Get-OrganizationRulesetDetail -ApiUrl $ApiUrl -Organization $Organization -Name $Name)) {
            throw "Ruleset '$Name' in '$Organization' still exists after DELETE."
        }
    }
}

Export-ModuleMember -Function Get-OrganizationRulesetState, Set-OrganizationRuleset, Remove-OrganizationRuleset
