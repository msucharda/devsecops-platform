#Requires -Version 7.4
[Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', 'Mode', Justification = 'Read by the nested control designation guard.')]
[CmdletBinding()]
param(
    [Parameter(Mandatory)][ValidateSet('development', 'standard')][string] $Mode,
    [string] $Repository = $env:GITHUB_REPOSITORY,
    [string] $ServerUrl = $env:GITHUB_SERVER_URL,
    [string] $ApiUrl = $env:GITHUB_API_URL,
    [string] $ReadToken = $env:DEVELOPMENT_READ_TOKEN,
    [string] $RunAttempt = $env:GITHUB_RUN_ATTEMPT,
    [string] $GitHubOutputPath,
    [switch] $AllowNonReference
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
Import-Module (Join-Path $PSScriptRoot 'DevelopmentControl.psm1')

# security-check: development-control-context
function Assert-DevelopmentControlContext {
    param([string] $Name, [string] $Server, [string] $Api, [string] $Token)
    $address = [uri] $Server
    if ($Name -notmatch '^[A-Za-z0-9-]+/[A-Za-z0-9_.-]+\z' -or
        $address.Scheme -ne 'https' -or -not $address.IsDefaultPort -or $address.UserInfo -or
        $address.Query -or $address.Fragment -or $address.AbsolutePath -cne '/' -or
        $Api.TrimEnd('/') -cne "https://api.$($address.DnsSafeHost)" -or
        [string]::IsNullOrWhiteSpace($Token)) {
        throw 'Control inspection requires this repository, its exact HTTPS Cloud API and the read-only workflow token.'
    }
}

# security-check: development-control-designation
function Assert-DevelopmentControlDesignation {
    param([AllowNull()][object] $State, [string] $RepositoryUrl, [string] $Attempt)
    if ($null -eq $State) {
        if ($Mode -eq 'development' -or
            -not [string]::IsNullOrWhiteSpace($env:PLATFORM_REFERENCE_REPOSITORY) -or
            -not [string]::IsNullOrWhiteSpace($env:PLATFORM_DEVELOPMENT_APPROVAL) -or
            -not [string]::IsNullOrWhiteSpace($env:PLATFORM_DEVELOPMENT_DISPOSITION)) {
            throw 'Reference development state requires the protected control ref; environment variables are not an authorization fallback.'
        }
        return
    }
    if ($State.Reference -cne $RepositoryUrl -or $Attempt -cne '1' -or
        $State.Source -cnotmatch '^https://[a-z0-9.-]+/[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+\z') {
        throw 'Control state requires the exact reference, explicit source repository and a fresh dispatch.'
    }
    if ($State.TokenJournalPhase -cnotin @('absent', 'clear', 'retired')) {
        throw 'Unfinished development token blocks candidate, standard adopt and rollback; complete trusted recovery first.'
    }
    if ($Mode -eq 'development' -and $State.ControlVersion -ne 2) {
        throw 'New development authorization requires protected control document v2; legacy v1 is standard-only.'
    }
}

Assert-DevelopmentControlContext -Name $Repository -Server $ServerUrl -Api $ApiUrl -Token $ReadToken
$state = Read-DevelopmentControl -ApiUrl $ApiUrl -Repository $Repository -ReadToken $ReadToken -AllowAbsent:$AllowNonReference
Assert-DevelopmentControlDesignation -State $state -RepositoryUrl "$ServerUrl/$Repository" -Attempt $RunAttempt
if ($GitHubOutputPath) {
    $values = if ($null -eq $state) {
        @{ reference = ''; source = $env:PLATFORM_SOURCE_REPOSITORY; approval = ''; disposition = ''; controlRevision = '' }
    } else {
        @{ reference = $state.Reference; source = $state.Source; approval = $state.Approval
            disposition = $state.Disposition; controlRevision = $state.ControlRevision }
    }
    $lines = [Collections.Generic.List[string]]::new()
    foreach ($key in @('reference', 'source', 'approval', 'disposition', 'controlRevision')) {
        $value = [string] $values[$key]
        if ($key -in @('approval', 'disposition') -and -not [string]::IsNullOrWhiteSpace($value)) {
            $value = [Text.Json.Nodes.JsonNode]::Parse($value).ToJsonString()
        }
        if ($value.Contains("`n") -or $value.Contains("`r")) { throw 'Control outputs must be single-line values.' }
        $lines.Add("$key=$value")
    }
    [IO.File]::AppendAllText([IO.Path]::GetFullPath($GitHubOutputPath), ($lines -join "`n") + "`n", [Text.UTF8Encoding]::new($false))
}
$state
