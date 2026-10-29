#Requires -Version 7.4

# security-check: setup-manual-instance-name
function Assert-SetupManualInstanceName {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Expected, [AllowEmptyString()][string] $Actual, [string] $Context)

    if ($Actual -cne $Expected) {
        throw "The $Context instance name did not match exactly. No manual step was confirmed."
    }
}

function Read-SetupManualProgress {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][string] $InstanceName)

    if (-not (Test-Path -LiteralPath $Path)) { return @{ version = 1; instanceName = $InstanceName; steps = @{} } }
    $schema = @'
{
  "type": "object", "additionalProperties": false,
  "required": ["version", "instanceName", "steps"],
  "properties": {
    "version": { "type": "integer", "const": 1 },
    "instanceName": { "type": "string", "minLength": 1 },
    "steps": {
      "type": "object",
      "additionalProperties": {
        "type": "object", "additionalProperties": false,
        "required": ["binding", "status", "startedAt"],
        "properties": {
          "binding": { "type": "string", "pattern": "^[0-9a-f]{64}$" },
          "status": { "enum": ["Pending", "Confirmed"] },
          "startedAt": { "type": "string", "minLength": 1 },
          "confirmedAt": { "type": "string", "minLength": 1 },
          "method": { "const": "human" },
          "verified": { "const": false }
        },
        "if": { "properties": { "status": { "const": "Confirmed" } } },
        "then": { "required": ["confirmedAt", "method", "verified"] }
      }
    }
  }
}
'@
    try {
        $json = Get-Content -LiteralPath $Path -Raw -ErrorAction Stop
        $valid = Test-Json -Json $json -Schema $schema -ErrorAction Stop
        if (-not $valid) { throw 'The state does not match the progress schema.' }
        $state = ConvertFrom-Json -InputObject $json -AsHashtable -NoEnumerate -ErrorAction Stop
        foreach ($record in $state['steps'].get_Values()) {
            foreach ($field in @('startedAt', 'confirmedAt')) {
                if (-not $record.Contains($field)) { continue }
                if ($record[$field] -is [datetime] -or $record[$field] -is [DateTimeOffset]) { continue }
                $timestamp = [DateTimeOffset]::MinValue
                if (-not [DateTimeOffset]::TryParse([string] $record[$field], [Globalization.CultureInfo]::InvariantCulture,
                        [Globalization.DateTimeStyles]::None, [ref] $timestamp)) { throw "Invalid $field timestamp." }
            }
        }
    }
    catch { throw "Invalid manual-step progress '$Path': $($_.Exception.Message) Restore the progress file before retrying." }
    Assert-SetupManualInstanceName -Expected $InstanceName -Actual $state['instanceName'] -Context 'progress'
    return $state
}

function Save-SetupManualProgress {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)][System.Collections.IDictionary] $State)

    $temporary = "$Path.$([guid]::NewGuid().ToString('N')).tmp"
    try {
        [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $State -Depth 30), [Text.UTF8Encoding]::new($false))
        if ([IO.File]::Exists($Path)) { [IO.File]::Replace($temporary, $Path, [NullString]::Value) }
        else { [IO.File]::Move($temporary, $Path) }
    }
    finally {
        if ([IO.File]::Exists($temporary)) { [IO.File]::Delete($temporary) }
    }
}

function Get-SetupManualBinding {
    [CmdletBinding()]
    [OutputType([string])]
    param(
        [Parameter(Mandatory)][System.Collections.IDictionary] $Instance,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Manifest
    )

    $json = ConvertTo-PlatformCanonicalJson @{ instance = $Instance; manifest = $Manifest }
    return [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($json))).ToLowerInvariant()
}

function Invoke-SetupManualSteps {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup, [string] $ManualStep)

    Import-Module (Join-Path $Setup.RepoPath 'tools/PlatformTools.psm1')
    $modules = Get-PlatformModuleGraph -ModulesPath $Setup.ModulesPath
    $instance = Get-PlatformInstance -Path $Setup.InstancePath -Modules $modules -AllowUnboundApps
    $steps = [ordered]@{}
    foreach ($name in (Get-PlatformModuleSelection -Instance $instance -Modules $modules)) {
        foreach ($step in $modules[$name]['manualSteps']) {
            $id = "$name/$($step['id'])"
            $steps[$id] = [pscustomobject]@{
                Id = $id; Module = $name; Description = $step['description']
                Owner = $(if ($step.Contains('owner')) { $step['owner'] } else { 'platform' })
                Limitations = $(if ($step.Contains('limitations')) { $step['limitations'] } else { $null })
                Binding = Get-SetupManualBinding -Instance $instance -Manifest $modules[$name]
                Status = 'Pending'; Verified = $false
            }
        }
    }
    if ($ManualStep -and $ManualStep -cnotin @($steps.get_Keys())) {
        throw "Manual step '$ManualStep' does not belong to the selected modules."
    }
    $path = Join-Path $Setup.WorkPath 'manual-steps-state.json'
    try { $lease = [IO.File]::Open("$path.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None) }
    catch [IO.IOException] { throw "Cannot exclusively open manual-step progress '$path'. Another wizard may be using it. $($_.Exception.Message)" }
    try {
        $state = Read-SetupManualProgress -Path $path -InstanceName $instance['instance']['name']
        foreach ($id in $steps.get_Keys()) {
            $record = $state['steps'][$id]
            if ($record -and $record['binding'] -ceq $steps[$id].Binding -and $record['status'] -ceq 'Confirmed') {
                $steps[$id].Status = 'Confirmed'
            }
            elseif ($record) { Show-SetupMessage -Kind Warning -Message "$id is pending or its configuration or manifest changed; no previous confirmation is reused." }
        }
        Show-SetupMessage -Kind Title -Message 'Module manual steps (human declarations, not API verification)'
        Show-SetupMessage -Message "Runbook: $(Join-Path $Setup.RepoPath 'docs/reference-instance.md')"
        Show-SetupMessage -Kind Warning -Message 'Choose only the step required at your current deployment or teardown stage. The wizard never performs it for you.'
        if ($steps.Count -eq 0) { Show-SetupMessage -Message 'The selected modules declare no manual steps.' }
        while ($steps.Count -gt 0) {
            $id = $ManualStep
            if (-not $id) {
                $choices = [ordered]@{}
                foreach ($key in $steps.get_Keys()) { $choices[$key] = "$($steps[$key].Status): $($steps[$key].Owner)" }
                $choices['q'] = 'Stop and retain progress'
                $pending = @($steps.get_Keys() | Where-Object { $steps[$_].Status -cne 'Confirmed' })
                $default = if ($pending.Count -gt 0) { $pending[0] } else { 'q' }
                $id = Read-SetupChoice -Prompt 'Manual step (module/id)' -Choice $choices -Default $default
                if ($id -ceq 'q') { break }
            }
            $step = $steps[$id]
            if ($step.Status -ceq 'Confirmed' -and -not $Setup.Reconfirm) {
                Show-SetupMessage -Message "$id already has a human confirmation for this configuration and manifest. Use -Reconfirm to review it again."
                if ($ManualStep) { break }
                continue
            }
            $step.Status = 'Pending'
            $state['steps'][$id] = @{ binding = $step.Binding; status = 'Pending'; startedAt = [DateTimeOffset]::UtcNow.ToString('o') }
            Save-SetupManualProgress -Path $path -State $state
            $name = $instance['instance']['name']
            $answer = [string] (Read-Host -Prompt "Before starting or reviewing $id, type the exact instance name '$name'")
            Assert-SetupManualInstanceName -Expected $name -Actual $answer -Context 'typed'
            Show-SetupMessage -Kind Action -Message "$($step.Id) [$($step.Owner)]: $($step.Description)"
            $modulePath = Join-Path $Setup.ModulesPath $step.Module
            $documentation = Join-Path $modulePath 'README.md'
            if (-not (Test-Path -LiteralPath $documentation -PathType Leaf)) { $documentation = Join-Path $modulePath 'module.yaml' }
            Show-SetupGuidance -Line @(
                "Module instructions: $documentation"
                'Follow the runbook prerequisites and approval order. This confirmation does not replace them.'
                'After an interruption, check what already happened. Do not repeat an irreversible operation blindly.'
            )
            if ($step.Limitations) {
                foreach ($area in @('plan', 'drift', 'teardown')) { Show-SetupGuidance -Line @("${area}: $($step.Limitations[$area])") }
            }
            if (-not (Confirm-SetupAction -Prompt 'Have you completed this step according to the runbook (human declaration only)?')) { break }
            $currentModules = Get-PlatformModuleGraph -ModulesPath $Setup.ModulesPath
            $currentInstance = Get-PlatformInstance -Path $Setup.InstancePath -Modules $currentModules -AllowUnboundApps
            $currentBinding = Get-SetupManualBinding -Instance $currentInstance -Manifest $currentModules[$step.Module]
            if ($currentBinding -cne $step.Binding) { throw 'The instance configuration or module manifest changed during the manual step. Review it before confirming again.' }
            $state['steps'][$id]['status'] = 'Confirmed'
            $state['steps'][$id]['confirmedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
            $state['steps'][$id]['method'] = 'human'
            $state['steps'][$id]['verified'] = $false
            Save-SetupManualProgress -Path $path -State $state
            $step.Status = 'Confirmed'
            if ($ManualStep) { break }
        }
        Show-SetupMessage -Message 'instance.yaml was not changed. Record the applicable manualSteps confirmations through a reviewed instance PR; this progress file is not deployment authorization.'
        return [pscustomobject]@{
            Phase = 'ManualSteps'; ManualSteps = @($steps.Values); InstancePath = $Setup.InstancePath; ProgressPath = $path
            Completed = @($steps.Values | Where-Object { $_.Status -cne 'Confirmed' }).Count -eq 0
        }
    }
    finally { $lease.Dispose() }
}
