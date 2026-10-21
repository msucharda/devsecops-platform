#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [string] $TokensJson = $env:PLATFORM_GITHUB_TOKENS,
    [string] $Enterprise = $env:PLATFORM_APP_ENTERPRISE,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

$tokens = $null
if ($TokensJson) {
    try { $tokens = ConvertFrom-Json -InputObject $TokensJson -AsHashtable -ErrorAction Stop } catch { $tokens = $null }
}
if ($tokens -isnot [System.Collections.IDictionary] -or $tokens.PSBase.Count -eq 0 -or -not $Enterprise -or
    -not $ApiUrl -or ([uri] $ApiUrl).Scheme -cne 'https') {
    throw 'Ruleset bypass check requires the ruleset plan installation token map, the App enterprise and an HTTPS API URL.'
}

function Invoke-RulesetRequest {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $Token)

    $arguments = @{
        Uri = "$($ApiUrl.TrimEnd('/'))$Path"
        Headers = @{
            Authorization = "Bearer $Token"
            Accept = 'application/vnd.github+json'
            'X-GitHub-Api-Version' = '2026-03-10'
        }
        MaximumRedirection = 0
        MaximumRetryCount = 0
        TimeoutSec = 60
    }
    try {
        $response = Invoke-RestMethod @arguments
        ConvertTo-Json -InputObject $response -Depth 100 -Compress | ConvertFrom-Json -AsHashtable -NoEnumerate
    }
    catch {
        throw "GitHub ruleset API GET $Path failed; ruleset drift detection is incomplete. $($_.Exception.Message)"
    }
}

$inherited = 0
$verified = 0
foreach ($organization in @($tokens.PSBase.Keys | Sort-Object -CaseSensitive)) {
    $token = [string] $tokens[$organization]
    $escaped = [uri]::EscapeDataString($organization)
    $page = 1
    # A short page does not prove the end of the list; only an empty page does.
    do {
        if ($page -gt 1000) { throw "Ruleset API for '$organization' did not end the ruleset list within 1000 pages." }
        $rules = @(Invoke-RulesetRequest -Path "/orgs/$escaped/rulesets?includes_parents=true&per_page=100&page=$page" -Token $token)
        if ($rules.Count -eq 1 -and $rules[0] -is [System.Collections.IList]) { $rules = @($rules[0]) }
        foreach ($rule in $rules) {
            if ($rule -isnot [System.Collections.IDictionary]) {
                throw "Ruleset API for '$organization' returned an unknown list item."
            }
            $type = if ($rule.Contains('source_type')) { [string] $rule['source_type'] } else { '' }
            $source = if ($rule.Contains('source')) { [string] $rule['source'] } else { '' }
            if ($type -ceq 'Enterprise' -and $source -ceq $Enterprise) {
                $inherited++
                continue
            }
            if ($type -cne 'Organization' -or $source -cne $organization -or [string] $rule['id'] -cnotmatch '^[1-9][0-9]*$') {
                throw "Ruleset API for '$organization' returned unknown or mismatched source metadata."
            }
            $detail = Invoke-RulesetRequest -Path "/orgs/$escaped/rulesets/$($rule['id'])" -Token $token
            if ($detail -isnot [System.Collections.IDictionary] -or [string] $detail['id'] -cne [string] $rule['id']) {
                throw "Ruleset API detail for '$organization' does not match ruleset $($rule['id'])."
            }
            if (-not $detail.Contains('bypass_actors') -or $detail['bypass_actors'] -isnot [System.Collections.IList]) {
                throw "Ruleset API for '$organization' did not expose the complete bypass configuration of ruleset $($rule['id']); a missing field is not a ruleset without bypass."
            }
            $verified++
        }
        $page++
    } while ($rules.Count -gt 0)
}
if ($GitHubOutputPath) {
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath), "inheritedRulesets=$inherited`n", [Text.UTF8Encoding]::new($false))
}
if ($inherited -gt 0) {
    Write-Warning "$inherited inherited enterprise rulesets are not covered by organization ruleset drift detection."
}
[pscustomobject]@{ LocalRulesetsVerified = $verified; InheritedRulesets = $inherited }
