#Requires -Version 7.4
[CmdletBinding()]
[OutputType([pscustomobject])]
param(
    [Parameter(Mandatory)][ValidatePattern('^[A-Za-z0-9][A-Za-z0-9-]*/[A-Za-z0-9_.-]+$')][string] $SourceRepository,
    [Parameter(Mandatory)][ValidatePattern('^[^\s]+$')][string] $Tag,
    [Parameter(Mandatory)][string] $InstancePath,
    [Parameter(Mandatory)][string] $PlatformOrganization,
    [string] $GitHubOutputPath
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'PlatformTools.psm1') -Force

# security-check: action-import-catalog
function Assert-ActionImportCatalog {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [Parameter(Mandatory)][string] $Source
    )

    if (-not $Instance.Contains('modules') -or -not $Instance['modules'].Contains('actions-catalog')) {
        throw 'Action import requires the actions-catalog module in instance.yaml.'
    }
    $module = $Instance['modules']['actions-catalog']
    # Match modules/actions-catalog/variables.tf when the instance does not override the default.
    $catalog = @('actions/checkout', 'actions/upload-artifact', 'actions/download-artifact',
        'actions/create-github-app-token', 'azure/login', 'hashicorp/setup-terraform')
    if ($module.Contains('parameters') -and $module['parameters'].Contains('catalog')) {
        $catalog = $module['parameters']['catalog']
    }
    if ($catalog -isnot [System.Collections.IList] -or $catalog.Count -eq 0) {
        throw 'The actions-catalog catalog must be a nonempty list.'
    }
    $targets = [Collections.Generic.HashSet[string]]::new([StringComparer]::Ordinal)
    foreach ($entry in $catalog) {
        if ($entry -isnot [string] -or
            $entry -cnotmatch '^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?/[a-z0-9_.-]{1,100}$' -or
            $entry -cmatch '/\.\.?$' -or $entry.Length -gt 100) {
            throw 'The actions-catalog catalog must contain canonical lowercase owner/repository identities.'
        }
        if (-not $targets.Add($entry.Replace('/', '-'))) {
            throw 'Two actions-catalog entries map to the same target repository.'
        }
    }
    if ($Source -notin $catalog) {
        throw "The upstream '$Source' is not in the actions-catalog catalog."
    }
}

$instance = Get-PlatformYaml -Path $InstancePath
$organizations = Get-PlatformInstanceOrganization -InstanceName $instance['instance']['name'] -PlatformOrganization $PlatformOrganization
$source = $SourceRepository.ToLowerInvariant()
Assert-ActionImportCatalog -Instance $instance -Source $source
$result = [pscustomobject] @{
    SourceRepository = $source
    Tag = $Tag
    ActionsOrganization = $organizations['actions']
    TargetRepository = "$($organizations['actions'])/$($source.Replace('/', '-'))"
}
if ($GitHubOutputPath) {
    Add-Content -LiteralPath $GitHubOutputPath -Value @(
        "source-repository=$($result.SourceRepository)"
        "target-repository=$($result.TargetRepository)"
        "actions-organization=$($result.ActionsOrganization)"
    )
}
return $result
