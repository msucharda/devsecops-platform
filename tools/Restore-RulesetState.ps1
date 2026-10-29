#Requires -Version 7.4
[CmdletBinding()]
param(
    [Parameter(Mandatory)][string] $TerraformRoot,
    [Parameter(Mandatory)][string] $VariableFile
)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $false
Import-Module (Join-Path $TerraformRoot '../scripts/Rulesets.psm1') -Force
$json = & terraform "-chdir=$TerraformRoot" show -json
if ($LASTEXITCODE -ne 0) { throw 'Cannot read ruleset state before destroy.' }
$state = $json | ConvertFrom-Json -AsHashtable
if (-not $state.Contains('values') -or -not $state['values'].Contains('root_module')) { return }
if (-not $state['values']['root_module'].Contains('resources')) { return }
$resources = @($state['values']['root_module']['resources'])
$intents = @($resources | Where-Object { $_['type'] -ceq 'terraform_data' -and $_['name'] -ceq 'ruleset_intent' })
foreach ($intent in $intents) {
    $inputData = $intent['values']['input']
    $organization = [string] $inputData['organization']
    $address = 'restapi_object.ruleset["' + $organization + '"]'
    $managed = @($resources | Where-Object { $_['address'] -ceq $address })
    if ($managed.Count -gt 1) { throw "Duplicate ruleset state address '$address'." }
    $target = @{ ApiUrl = $inputData['api_url']; Organization = $organization; Name = $inputData['name'] }
    $destroyStarted = $inputData.Contains('destroy_started') -and $inputData['destroy_started'] -eq $true
    if ($managed.Count -eq 1) {
        # Validate the recorded object, even after rename. Never replace its ID with an object of the original name.
        $remoteId = [string] $managed[0]['values']['id']
        if ($remoteId -cnotmatch '^[1-9][0-9]{0,17}$') { throw "Ruleset state '$address' has no valid remote ID." }
        $null = Get-OrganizationRulesetState @target -Id $remoteId
    }
    elseif (-not $destroyStarted) {
        # Adoption is permitted only before teardown starts, never after a completed native deletion.
        $existing = Get-OrganizationRulesetState @target
        if ($null -ne $existing) {
            $remotePath = "/orgs/$organization/rulesets/$($existing['id'])"
            $output = & terraform "-chdir=$TerraformRoot" import -input=false -no-color "-var-file=$VariableFile" '-var=ruleset_destroy_started=true' $address $remotePath 2>&1 | Out-String
            if ($LASTEXITCODE -ne 0) { throw "Cannot restore the remote ID of '$address' before destroy: $output" }
            Write-Information "Restored the remote ID of '$address' before destroy." -InformationAction Continue
        }
    }
    if (-not $destroyStarted) {
        # The native resource depends on this marker, so destroy removes the marker last.
        $checkpoint = & terraform "-chdir=$TerraformRoot" apply -input=false -auto-approve -no-color `
            "-var-file=$VariableFile" '-var=ruleset_destroy_started=true' "-target=$($intent['address'])" 2>&1 | Out-String
        if ($LASTEXITCODE -ne 0) { throw "Cannot persist the ruleset teardown checkpoint: $checkpoint" }
    }
}
