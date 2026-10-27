#Requires -Version 7.4

function Invoke-StepAcceptanceInput {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    $path = Join-Path $Setup.WorkPath 'instance.yaml'
    if (-not (Test-Path -LiteralPath $path)) {
        Exit-SetupStage -Status Missing -Message 'Run the prerequisite wizard first; the verified issue #10 instance.yaml is missing.'
    }
    Import-Module (Join-Path $Setup.RepoPath 'tools/PlatformTools.psm1')
    $config = Get-PlatformYaml -Path $path
    Assert-PlatformManualPrerequisite -Instance $config
    $Setup.Acceptance['sourceConfiguration'] = $config
    $Setup.Settings = @{} + $config['bootstrap'] + @{ name = $config['instance']['name'] }
    return 'Verified prerequisite configuration loaded without changing the issue #10 files.'
}

function Invoke-StepAcceptanceAzure {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    if (-not (Confirm-SetupAction -Prompt 'Create or reconcile Azure state containers, phase identities and their scoped roles for this acceptance?')) {
        Exit-SetupStage -Status Missing -Message 'Azure provisioning was declined. No Azure resources were changed.'
    }
    $Setup.Acceptance['azure'] = & (Join-Path $Setup.Acceptance['releasePath'] 'tools/Invoke-Bootstrap.ps1') `
        -InstancePath $Setup.InstancePath -ModulesPath $Setup.ModulesPath -AllowUnboundApps
    Write-SetupAcceptanceJson -Path (Join-Path $Setup.Acceptance['directory'] 'azure-bootstrap.json') -Value $Setup.Acceptance['azure']
    return 'Azure bootstrap completed for the acceptance manifests.'
}

function Write-SetupAcceptanceJson {
    [CmdletBinding()]
    param([Parameter(Mandatory)][string] $Path, [Parameter(Mandatory)] $Value)

    $temporary = "$Path.tmp"
    [IO.File]::WriteAllText($temporary, (ConvertTo-Json -InputObject $Value -Depth 100) + "`n", [Text.UTF8Encoding]::new($false))
    [IO.File]::Move($temporary, $Path, $true)
}

function Get-SetupAcceptanceFileHash {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][string] $Path)

    $hashes = @{}
    foreach ($file in Get-ChildItem -LiteralPath $Path -Recurse -Force -File) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint) { throw 'Acceptance files must not be symbolic links.' }
        $relative = [IO.Path]::GetRelativePath($Path, $file.FullName)
        if ($relative -eq 'bootstrap-acceptance.json') { continue }
        $hashes[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
    }
    return $hashes
}

function Get-SetupAcceptanceBootstrapArgument {
    [CmdletBinding()]
    [OutputType([hashtable])]
    param([Parameter(Mandatory)][hashtable] $Setup)

    return @{
        InstancePath = $Setup.InstancePath; AzureBootstrap = $Setup.Acceptance['azure']
        ReleasePath = $Setup.Acceptance['releasePath']; ReleaseVersion = $Setup.Acceptance['releaseVersion']
        InventoryPath = Join-Path $Setup.Acceptance['directory'] 'bootstrap-resources.json'
        AcceptanceOnly = $true; AuthorizationApp = 'authorization'
        AppKeysPath = Join-Path $Setup.Acceptance['directory'] 'keys.json'
    }
}

function Get-SetupAcceptanceOrganization {
    [CmdletBinding()]
    [OutputType([string])]
    param([Parameter(Mandatory)][hashtable] $Setup)

    $inventoryPath = (Get-SetupAcceptanceBootstrapArgument -Setup $Setup)['InventoryPath']
    if (-not (Test-Path -LiteralPath $inventoryPath)) { throw 'Complete G4 GitHub preparation before using the platform organization.' }
    $repository = [string] (Get-Content -LiteralPath $inventoryPath -Raw | ConvertFrom-Json -AsHashtable)['repository']
    $organization = $repository.Split('/')[0]
    if ($repository -cne "$organization/instance" -or
        $organization -cnotmatch "^$([regex]::Escape($Setup.Settings['name']))(-[a-z0-9]{6})?-platform$") {
        throw 'The acceptance bootstrap inventory does not name the platform organization of this instance.'
    }
    return $organization
}

function Invoke-StepAcceptanceResource {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    if (-not (Confirm-SetupAction -Prompt 'Create or reconcile the platform organization, repository, reviewer environments and Azure federation for this acceptance?')) {
        Exit-SetupStage -Status Missing -Message 'GitHub preparation was declined.'
    }
    Add-SetupGitHubScope -Setup $Setup -Scope @('admin:enterprise', 'admin:org', 'repo', 'workflow') -Purpose 'GitHub bootstrap acceptance'
    $arguments = Get-SetupAcceptanceBootstrapArgument -Setup $Setup
    $result = & (Join-Path $Setup.Acceptance['releasePath'] 'tools/Invoke-GitHubBootstrap.ps1') @arguments -ResourcesOnly
    if ($result.CredentialsConfigured) { throw 'Resources-only preparation unexpectedly reported configured credentials.' }
    return 'Resources prepared. A newly initialized repository still has Actions disabled and no instance workflow.'
}

function Invoke-StepAcceptanceApp {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    $directory = $Setup.Acceptance['directory']
    $keyManifestPath = Join-Path $directory 'keys.json'
    $keys = if (Test-Path $keyManifestPath) { Get-Content $keyManifestPath -Raw | ConvertFrom-Json -AsHashtable } else { @{} }
    $config = Get-PlatformYaml -Path $Setup.InstancePath
    $state = $Setup.State['acceptance']
    if (-not $state.Contains('apps')) { $state['apps'] = @{} }
    $organization = Get-SetupAcceptanceOrganization -Setup $Setup
    $config['modules']['enterprise-baseline']['parameters'] = @{ target_organizations = @($organization) }
    $appSetup = $Setup.Clone()
    $appSetup.WorkPath = $directory
    $null = [IO.Directory]::CreateDirectory((Join-Path $directory 'keys'))
    $contracts = @(
        @{ alias = 'authorization'; permissions = @{ members = 'read' }; phase = '' }
        @{ alias = 'reader'; permissions = @{ organization_administration = 'read' }; phase = 'plan' }
        @{ alias = 'writer'; permissions = @{ organization_administration = 'write' }; phase = 'apply' }
        @{ alias = 'rulesets'; permissions = @{ organization_administration = 'write' }; phase = 'rulesetPlan' }
    )
    foreach ($contract in $contracts) {
        $alias = $contract.alias
        if (-not $state['apps'].Contains($alias)) { $state['apps'][$alias] = @{} }
        $app = Get-SetupProbeApp -Setup $appSetup -Role $alias -Permission $contract.permissions `
            -Selection none -Organization $organization `
            -AppName "$($Setup.Settings['name'])-bootstrap-$alias" -RegistrationState $state['apps'][$alias]
        $resources = @{ organizations = @($organization); repositories = @{} }
        $config['githubApps'][$alias] = @{
            appId = $app.AppId; installationId = $app.InstallationId; enterprise = $Setup.Settings['enterprise']
            permissions = $contract.permissions; resources = $resources
        }
        if ($contract.phase) { $config['credentials']['enterprise-baseline'][$contract.phase]['githubApp'] = $alias }
        [IO.File]::WriteAllText($Setup.InstancePath, (ConvertTo-Yaml $config).Replace("`r", ''), [Text.UTF8Encoding]::new($false))
        $rsa = [Security.Cryptography.RSA]::Create()
        try {
            $rsa.ImportFromPem((Get-Content $app.KeyPath -Raw))
            $fingerprint = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($rsa.ExportSubjectPublicKeyInfo())).ToLowerInvariant()
        }
        finally { $rsa.Dispose() }
        if (-not $keys.Contains($alias) -or $keys[$alias]['fingerprint'] -cne $fingerprint) {
            $date = Read-SetupValue -Prompt "Actual creation timestamp of the $alias key (ISO 8601 with UTC offset)" -Validate {
                param($text)
                $parsed = [DateTimeOffset]::MinValue
                if ($text -notmatch '(Z|[+-][0-9]{2}:[0-9]{2})$' -or -not [DateTimeOffset]::TryParse($text, [ref] $parsed) -or
                    $parsed -gt [DateTimeOffset]::UtcNow -or $parsed.AddDays(90) -le [DateTimeOffset]::UtcNow) {
                    'Supply the actual creation time with timezone, in the past and less than 90 days ago.'
                }
            }
            $created = [DateTimeOffset]::Parse($date)
            $keys[$alias] = @{
                privateKeyPath = $app.KeyPath; owner = 'platform'; fingerprint = $fingerprint
                createdAt = $created.ToString('o'); rotateBy = $created.AddDays(90).ToString('o')
            }
            Write-SetupAcceptanceJson -Path $keyManifestPath -Value $keys
        }
    }
    $null = Get-PlatformInstance -Path $Setup.InstancePath -Modules (Get-PlatformModuleGraph $Setup.ModulesPath)
    return 'Four enterprise-owned App registrations and exact credential contracts captured. Keys remain only in the external work directory.'
}

function Invoke-StepAcceptanceComplete {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    if (-not (Confirm-SetupAction -Prompt 'Verify Apps, publish the acceptance candidate, protect main, upload encrypted environment keys and enable only acceptance workflows?')) {
        Exit-SetupStage -Status Missing -Message 'Credential publication was declined.'
    }
    $arguments = Get-SetupAcceptanceBootstrapArgument -Setup $Setup
    $result = & (Join-Path $Setup.Acceptance['releasePath'] 'tools/Invoke-GitHubBootstrap.ps1') @arguments
    if (-not $result.CredentialsConfigured) { throw 'Bootstrap did not configure the acceptance credentials.' }
    $Setup.Acceptance['repository'] = $result.Repository
    return 'Acceptance repository initialized with protected main; production deploy.yml is disabled.'
}

function Invoke-StepAcceptanceRepeat {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    if (-not (Confirm-SetupAction -Prompt 'Repeat both bootstraps to verify zero persistent resource changes (trial App tokens are issued and revoked)?')) {
        Exit-SetupStage -Status Missing -Message 'Idempotency verification was declined.'
    }
    $azure = & (Join-Path $Setup.Acceptance['releasePath'] 'tools/Invoke-Bootstrap.ps1') -InstancePath $Setup.InstancePath -ModulesPath $Setup.ModulesPath
    if ($azure.HasChanges) { throw 'The repeated Azure bootstrap changed resources; idempotency has not passed.' }
    $arguments = Get-SetupAcceptanceBootstrapArgument -Setup $Setup
    $result = & (Join-Path $Setup.Acceptance['releasePath'] 'tools/Invoke-GitHubBootstrap.ps1') @arguments
    if ($result.HasChanges -or -not $result.CredentialsConfigured) { throw 'The repeated GitHub bootstrap was not an unchanged configured instance.' }
    return 'Both repeated bootstrap runs report HasChanges: false.'
}

function Get-SetupAcceptanceList {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Setup,
        [Parameter(Mandatory)][string] $Uri,
        [string] $Property
    )

    $page = 1
    do {
        $separator = if ($Uri.Contains('?')) { '&' } else { '?' }
        $response = Invoke-SetupApi -Setup $Setup -Uri "$Uri${separator}per_page=100&page=$page"
        if ($response.Status -ne 'Ok') { $null = Assert-SetupResponse -Action 'Reading acceptance resource collection' -Response $response }
        $items = $response.Data
        if ($Property) { $items = $items[$Property] }
        if ($items -isnot [Collections.IList]) { throw 'The acceptance API did not return a resource collection.' }
        foreach ($item in $items) { $item }
        $page++
    } while ($items.Count -eq 100)
}

function Invoke-StepAcceptanceRuleset {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    $organization = Get-SetupAcceptanceOrganization -Setup $Setup
    $api = "https://api.$($Setup.Settings['githubHost'])"
    $rules = @(Get-SetupAcceptanceList -Setup $Setup -Uri "$api/orgs/$organization/rulesets")
    $probeRules = @($rules | Where-Object { $_['name'] -ceq 'bootstrap-acceptance-probe' })
    if ($probeRules.Count -gt 1) { throw 'Duplicate acceptance probe rulesets.' }
    if (-not $probeRules.Count) {
        if (-not (Confirm-SetupAction -Prompt 'Create a disabled organization ruleset with an OrganizationAdmin bypass actor solely to test complete ruleset reads?')) {
            Exit-SetupStage -Status Missing -Message 'The ruleset detail probe was declined.'
        }
        $rule = Assert-SetupResponse -Action 'Creating the disabled acceptance probe ruleset' -Response (
            Invoke-SetupApi -Setup $Setup -Uri "$api/orgs/$organization/rulesets" -Method POST -NoRetry -Body @{
                name = 'bootstrap-acceptance-probe'; target = 'branch'; enforcement = 'disabled'
                bypass_actors = @(@{ actor_id = 1; actor_type = 'OrganizationAdmin'; bypass_mode = 'always' })
                conditions = @{ ref_name = @{ include = @('~DEFAULT_BRANCH'); exclude = @() }; repository_name = @{ include = @('~ALL'); exclude = @() } }
                rules = @(@{ type = 'deletion' })
            })
    }
    else {
        $rule = Assert-SetupResponse -Action 'Reading the existing acceptance probe ruleset' -Response (
            Invoke-SetupApi -Setup $Setup -Uri "$api/orgs/$organization/rulesets/$($probeRules[0]['id'])")
    }
    if (-not $rule['id'] -or $rule['enforcement'] -cne 'disabled' -or $rule['name'] -cne 'bootstrap-acceptance-probe' -or
        @($rule['bypass_actors'] | Where-Object { $_['actor_type'] -ceq 'OrganizationAdmin' -and $_['bypass_mode'] -ceq 'always' }).Count -ne 1) {
        throw 'The acceptance probe must be the named disabled ruleset with its real OrganizationAdmin bypass.'
    }
    $inventoryPath = (Get-SetupAcceptanceBootstrapArgument -Setup $Setup)['InventoryPath']
    $inventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json -AsHashtable
    $resource = "/orgs/$organization/rulesets/$($rule['id'])"
    if ($resource -cnotin $inventory['resources']) {
        $inventory['resources'] += $resource
        Write-SetupAcceptanceJson -Path $inventoryPath -Value $inventory
    }
    return 'Disabled probe ruleset recorded for removal; the workflow must read its real bypass actors.'
}

# security-check: acceptance-run-evidence
function Test-SetupAcceptanceRunEvidence {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Setup,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Run,
        [string[]] $Phases = @('plan', 'rulesetPlan', 'wrongSubject', 'apply')
    )

    $directory = Join-Path $Setup.Acceptance['directory'] "evidence/$($Run['id'])-$($Run['run_attempt'])"
    $keys = Get-Content (Join-Path $Setup.Acceptance['directory'] 'keys.json') -Raw | ConvertFrom-Json -AsHashtable
    $download = Join-Path $directory "downloads/$([guid]::NewGuid().ToString('N'))"
    $null = [IO.Directory]::CreateDirectory($download)
    & gh run download $Run['id'] --repo "https://$($Setup.Settings['githubHost'])/$($Setup.Acceptance['repository'])" `
        --pattern 'bootstrap-acceptance-*' --dir $download
    if ($LASTEXITCODE -ne 0) { throw 'Downloading acceptance evidence failed; successful job status alone is not proof.' }
    $records = @{}
    foreach ($phase in $Phases) {
        $path = Join-Path $download "bootstrap-acceptance-$phase/result.json"
        if (-not (Test-Path $path)) { throw "The run has no evidence for $phase." }
        $record = Get-Content $path -Raw | ConvertFrom-Json -AsHashtable
        if ($record['version'] -ne 1 -or $record['passed'] -isnot [bool] -or -not $record['passed'] -or $record['phase'] -cne $phase -or
            $record['revision'] -cne $Run['head_sha'] -or [string] $record['runId'] -cne [string] $Run['id'] -or
            [string] $record['runAttempt'] -cne [string] $Run['run_attempt']) {
            throw "The $phase evidence does not belong to this successful immutable run."
        }
        if ($phase -ne 'wrongSubject') {
            $alias = switch ($phase) { plan { 'reader' }; apply { 'writer' }; rulesetPlan { 'rulesets' } }
            if ($record['keyFingerprint'] -cne $keys[$alias]['fingerprint'] -or
                $record['authorizationFingerprint'] -cne $keys['authorization']['fingerprint']) {
                throw "The $phase evidence tested another App key. Rerun the workflow with the current keys."
            }
        }
        $required = if ($phase -eq 'wrongSubject') { @('wrongSubjectRejected') }
        elseif ($phase -eq 'rulesetPlan') { @('rulesetBypassRead', 'phaseIdentityVerified', 'otherModuleStateDenied') }
        else { @('organizationApisRead', 'phaseIdentityVerified', 'otherModuleStateDenied') }
        foreach ($check in $required) {
            if ($record['checks'][$check] -isnot [bool] -or -not $record['checks'][$check]) { throw "The $phase evidence did not verify $check." }
        }
        $records[$phase] = $record
    }
    foreach ($phase in $Phases) {
        $folder = Join-Path $directory "bootstrap-acceptance-$phase"
        $null = [IO.Directory]::CreateDirectory($folder)
        Write-SetupAcceptanceJson -Path (Join-Path $folder 'result.json') -Value $records[$phase]
    }
}

function Invoke-StepAcceptanceWorkflow {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    $state = $Setup.State['acceptance']
    $repository = $Setup.Acceptance['repository']
    $api = "https://api.$($Setup.Settings['githubHost'])"
    $head = Assert-SetupResponse -Action 'Reading protected main' -Response (Invoke-SetupApi -Setup $Setup -Uri "$api/repos/$repository/git/ref/heads/main")
    $revision = $head['object']['sha']
    $keyHash = (Get-FileHash (Join-Path $Setup.Acceptance['directory'] 'keys.json')).Hash
    $binding = "$revision/$keyHash"
    if (-not $state['run'] -or $state['run']['binding'] -cne $binding) {
        if (-not (Confirm-SetupAction -Prompt 'Dispatch the read-only acceptance workflow, including platform and security approval of the apply-identity probe?')) {
            Exit-SetupStage -Status Missing -Message 'Live workflow verification was declined.'
        }
        $state['run'] = @{ evidenceId = [guid]::NewGuid().ToString('N'); binding = $binding; revision = $revision }
        Save-SetupState -Setup $Setup
    }
    $request = $state['run']
    $findRun = {
        if (-not $request['runId']) {
            $listed = @(Get-SetupAcceptanceList -Setup $Setup `
                -Uri "$api/repos/$repository/actions/workflows/bootstrap-acceptance.yml/runs?event=workflow_dispatch&branch=main" -Property workflow_runs)
            $runCandidates = @($listed | Where-Object { $_['display_title'] -ceq "Bootstrap acceptance $($request['evidenceId'])" })
            if ($runCandidates.Count -gt 1) { throw 'Multiple runs match this acceptance dispatch; inspect them before continuing.' }
            if (-not $runCandidates.Count) { return $false }
            $request['runId'] = $runCandidates[0]['id']
            Save-SetupState -Setup $Setup
            Show-SetupMessage -Kind Action -Message "Approve platform, then security, at https://$($Setup.Settings['githubHost'])/$repository/actions/runs/$($request['runId'])."
        }
        return $true
    }
    if (-not $request['dispatched']) {
        if (& $findRun) { $request['dispatched'] = $true }
        elseif (-not $request['dispatchAttempted']) {
            $request['dispatchAttempted'] = $true
            Save-SetupState -Setup $Setup
            $null = Assert-SetupResponse -Action 'Dispatching acceptance workflow' -Response (
                Invoke-SetupApi -Setup $Setup -Uri "$api/repos/$repository/actions/workflows/bootstrap-acceptance.yml/dispatches" `
                    -Method POST -NoRetry -Body @{ ref = 'main'; inputs = @{ mode = 'apply'; evidence_id = $request['evidenceId'] } })
            $request['dispatched'] = $true
        }
        Save-SetupState -Setup $Setup
    }
    $ready = Wait-SetupCondition -Activity 'Waiting for the acceptance workflow (approve both gates in GitHub)' -TimeoutSeconds 600 -IntervalSeconds 10 -Condition {
        if (-not (& $findRun)) { return $false }
        $run = Assert-SetupResponse -Action 'Reading acceptance run status' -Response (
            Invoke-SetupApi -Setup $Setup -Uri "$api/repos/$repository/actions/runs/$($request['runId'])")
        if ($run['head_sha'] -cne $revision -or $run['head_branch'] -cne 'main' -or $run['event'] -cne 'workflow_dispatch' -or
            $run['display_title'] -cne "Bootstrap acceptance $($request['evidenceId'])") {
            throw 'The acceptance run does not match the requested main revision, event and dispatch identifier.'
        }
        $Setup.Acceptance['run'] = $run
        return $run['status'] -ceq 'completed'
    }
    if (-not $ready) {
        if (-not $request['dispatched'] -and -not $request['runId']) {
            Show-SetupMessage -Kind Action -Message "Dispatch outcome is unknown. Inspect Bootstrap acceptance $($request['evidenceId']) in GitHub before retrying."
            if (Confirm-SetupAction -Prompt 'Have you verified that no run exists, and do you approve one new dispatch on the next retry?') {
                $request['dispatchAttempted'] = $false
                Save-SetupState -Setup $Setup
            }
        }
        Exit-SetupStage -Status Missing -Message 'The run is missing or pending. Resolve the dispatch or approve the two gates, then retry; pending runs are retained.'
    }
    $run = $Setup.Acceptance['run']
    if ($run['conclusion'] -cne 'success') {
        Exit-SetupStage -Status Error -Message 'The acceptance run failed. Fix the failure and rerun that run in GitHub, then retry this step.'
    }
    Test-SetupAcceptanceRunEvidence -Setup $Setup -Run $run
    $state['proofBinding'] = $binding
    Save-SetupState -Setup $Setup
    return 'Live plan, ruleset, apply-identity and wrong-subject checks passed with evidence from the exact main revision.'
}

function Invoke-StepAcceptanceNightly {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    $repository = $Setup.Acceptance['repository']
    $api = "https://api.$($Setup.Settings['githubHost'])"
    $revision = $Setup.Acceptance['run']['head_sha']
    $listed = @(Get-SetupAcceptanceList -Setup $Setup `
        -Uri "$api/repos/$repository/actions/workflows/bootstrap-acceptance.yml/runs?event=schedule&branch=main" -Property workflow_runs)
    $runs = @($listed | Where-Object {
        $_['head_sha'] -ceq $revision -and $_['head_branch'] -ceq 'main' -and $_['event'] -ceq 'schedule' -and
        $_['status'] -ceq 'completed' -and $_['conclusion'] -ceq 'success'
    } | Sort-Object -Property created_at -Descending)
    if (-not $runs.Count) {
        Exit-SetupStage -Status Missing -Message 'No successful real scheduled run exists for this main revision. Wait for 02:17 UTC, then retry; workflow_dispatch is not a nightly test.'
    }
    Test-SetupAcceptanceRunEvidence -Setup $Setup -Run $runs[0] -Phases @('plan', 'rulesetPlan', 'wrongSubject')
    $jobs = @(Get-SetupAcceptanceList -Setup $Setup -Uri "$api/repos/$repository/actions/runs/$($runs[0]['id'])/attempts/$($runs[0]['run_attempt'])/jobs" -Property 'jobs')
    foreach ($name in @('authorize', 'probe-plan', 'probe-rulesetPlan', 'wrong_subject', 'approve_apply', 'apply-probe')) {
        $found = @($jobs | Where-Object { $_['name'] -ceq $name })
        $expected = if ($name -cin @('approve_apply', 'apply-probe')) { 'skipped' } else { 'success' }
        if ($found.Count -ne 1 -or $found[0]['conclusion'] -cne $expected) {
            throw "The scheduled attempt did not prove $name was $expected."
        }
    }
    return 'A real scheduled run passed ordinary and ruleset drift probes without entering apply.'
}

function Invoke-StepAcceptanceWitness {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    $state = $Setup.State['acceptance']
    if (-not $state.Contains('witnesses')) { $state['witnesses'] = @{} }
    $binding = $state['proofBinding']
    $inventoryPath = (Get-SetupAcceptanceBootstrapArgument -Setup $Setup)['InventoryPath']
    $inventory = Get-Content $inventoryPath -Raw | ConvertFrom-Json -AsHashtable
    $rotated = @($inventory['apps'].Values | Where-Object { @($_['previousKeys']).Count -gt 0 })
    $items = @(
        @{ id = 'reviews'; instruction = 'Verify rejected direct push and a PR requiring platform CODEOWNER plus security approval for credential changes. Record the PR URL and observed approval requirements.' }
        @{ id = 'origins'; instruction = 'Verify an authorized platform PR runs trusted probes without review, an unauthorized/fork/App PR gets no credentials, and a non-main ref cannot enter protected environments. Record the run URLs.' }
        @{ id = 'resume'; instruction = 'Interrupt an initial preparation or key upload in a controlled way, rerun with the same inventory and verify retained resources. Record the observed failure and successful recovery.' }
        @{ id = 'rotation'; instruction = 'Verify a replacement key in the live workflow before revoking the old key in enterprise App settings. Retain the original creation time; record the run URL and the revocation result.' }
    )
    foreach ($item in $items) {
        $known = $state['witnesses'][$item.id]
        if ($known -and $known['binding'] -ceq $binding -and -not $Setup.Reconfirm) { continue }
        Show-SetupMessage -Kind Action -Message $item.instruction
        if ($item.id -eq 'rotation' -and -not $rotated.Count) {
            Exit-SetupStage -Status Missing -Message 'No replacement key is recorded yet.' -Guidance @(
                'Generate a new key of one acceptance App, preserve the old key, replace its PEM in github-acceptance/keys, then rerun the wizard.',
                'The wizard asks for the actual new creation time, uploads the replacement and requires a new successful workflow before the old key may be revoked.'
            )
        }
        if (-not (Confirm-SetupAction -Prompt "Have you completed and observed the $($item.id) check for the current acceptance revision?")) {
            Exit-SetupStage -Status Missing -Message "The $($item.id) check is not accepted; it remains a human evidence requirement."
        }
        $evidence = Read-SetupValue -Prompt "Local evidence for $($item.id) (URL and observed result; no tokens or private keys)" -Validate {
            param($text)
            if ($text -notmatch '^https://\S+ .{10,}$') { 'Supply an HTTPS evidence URL followed by the observed result.' }
        }
        if ($evidence -match 'BEGIN.*PRIVATE KEY|gh[oprsu]_[A-Za-z0-9_]+') { throw 'Do not place credential material in an acceptance record.' }
        if ($item.id -eq 'rotation') {
            foreach ($app in $rotated) {
                foreach ($previous in $app['previousKeys']) {
                    if (-not $previous['revocationRequired']) { continue }
                    if (-not (Confirm-SetupAction -Prompt "Have you revoked App $($previous['appId']) key $($previous['fingerprint']) after this successful run?")) {
                        Exit-SetupStage -Status Missing -Message 'A specific previous App key has not been confirmed revoked.'
                    }
                    $previous['revocationRequired'] = $false
                    $previous['revokedAt'] = [DateTimeOffset]::UtcNow.ToString('o')
                    Write-SetupAcceptanceJson -Path $inventoryPath -Value $inventory
                }
            }
        }
        $state['witnesses'][$item.id] = @{ binding = $binding; evidence = $evidence; confirmedAt = [DateTimeOffset]::UtcNow.ToString('o'); method = 'human' }
        Save-SetupState -Setup $Setup
    }
    return 'Human-only review, PR origin, recovery and rotation evidence recorded separately from automated checks.'
}

function Invoke-StepAcceptanceRelease {
    [CmdletBinding()]
    param([Parameter(Mandatory)][hashtable] $Setup)

    $acceptance = $Setup.Acceptance
    $source = $acceptance['releasePath']
    if (-not $source) { $source = Read-SetupValue -Prompt 'Approved source release directory' -Default $Setup.RepoPath }
    $source = (Resolve-Path -LiteralPath $source).Path
    $version = $acceptance['releaseVersion']
    if (-not $version) {
        $version = Read-SetupValue -Prompt 'Acceptance candidate SemVer (not a production release)' -Default '0.0.0-bootstrap.11' -Validate {
            param($text)
            if ($text -cnotmatch '^[0-9]+\.[0-9]+\.[0-9]+(-[0-9A-Za-z.-]+)?$') { 'Use SemVer without the v prefix.' }
        }
    }
    $destination = Join-Path $acceptance['directory'] 'release'
    if ($source.StartsWith($acceptance['directory'], [StringComparison]::OrdinalIgnoreCase)) {
        throw 'The source release must be outside the acceptance work directory.'
    }
    $sourceScript = Join-Path $source 'tools/Invoke-GitHubBootstrap.ps1'
    if ((Get-FileHash $sourceScript).Hash -cne (Get-FileHash (Join-Path $Setup.RepoPath 'tools/Invoke-GitHubBootstrap.ps1')).Hash) {
        throw 'Run the wizard and bootstrap from the same source release.'
    }
    if (Test-Path (Join-Path $source '.git')) {
        $dirty = & git -C $source status --porcelain --untracked-files=all
        if ($LASTEXITCODE -ne 0 -or $dirty) { throw 'The source checkout must be clean before preparing an acceptance candidate.' }
    }
    $sourceFiles = @(Get-ChildItem -LiteralPath $source -Recurse -Force -File | Where-Object {
        $relative = [IO.Path]::GetRelativePath($source, $_.FullName)
        $relative -notmatch '^(\.git|modules|artifacts|node_modules|\.terraform)([\\/]|$)' -and
        (Test-PlatformReleaseFile -RelativePath $relative)
    })
    $hashes = [ordered]@{}
    foreach ($file in $sourceFiles) {
        if ($file.Attributes -band [IO.FileAttributes]::ReparsePoint -or $file.Extension -in @('.pem', '.pfx', '.tfstate') -or
            $file.Name -in @('.env', 'keys.json', 'bootstrap-resources.json') -or $file.Name -like '*.tfstate.*') {
            throw "Source release contains unsupported runtime data: $($file.Name)."
        }
        $hashes[[IO.Path]::GetRelativePath($source, $file.FullName)] = (Get-FileHash $file.FullName).Hash
    }
    $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData(
        [Text.Encoding]::UTF8.GetBytes((ConvertTo-PlatformCanonicalJson $hashes)))).ToLowerInvariant()
    $approval = "$version/$digest"
    $state = $Setup.State['acceptance']
    if ($state['sourceApproval'] -cne $approval -or $Setup.Reconfirm) {
        Show-SetupMessage -Message "Acceptance candidate $version, source SHA-256 $digest. It replaces production manifests with two probe contracts and is not a production release."
        if (-not (Confirm-SetupAction -Prompt 'Approve this isolated acceptance candidate and the supplied source provenance?')) {
            Exit-SetupStage -Status Missing -Message 'The acceptance candidate has not been approved.'
        }
        if ($state['sourceApproval'] -and $state['sourceApproval'] -cne $approval) {
            throw 'This acceptance session is pinned to another candidate. Use a new work directory; protected instance updates require a PR.'
        }
        $state['sourceApproval'] = $approval
        Save-SetupState -Setup $Setup
    }
    if (-not (Test-Path -LiteralPath $destination)) {
        $preparing = Join-Path $acceptance['directory'] 'release-preparing'
        $null = [IO.Directory]::CreateDirectory($preparing)
        foreach ($file in $sourceFiles) {
            $target = Join-Path $preparing ([IO.Path]::GetRelativePath($source, $file.FullName))
            $null = [IO.Directory]::CreateDirectory((Split-Path $target -Parent))
            Copy-Item -LiteralPath $file.FullName -Destination $target
        }
        Copy-Item -LiteralPath (Join-Path $source 'tools/acceptance/github/modules') -Destination $preparing -Recurse -Force
        $workflow = Join-Path $source 'tools/acceptance/github/bootstrap-acceptance.yml'
        Copy-Item -LiteralPath $workflow -Destination (Join-Path $preparing 'templates/instance/.github/workflows/bootstrap-acceptance.yml')
        & (Join-Path $preparing 'tools/Generate-DeploymentWorkflow.ps1') -ModulesPath (Join-Path $preparing 'modules') `
            -OutputPath (Join-Path $preparing 'templates/instance/.github/workflows/deploy.yml')
        $files = Get-SetupAcceptanceFileHash -Path $preparing
        $expectedFiles = @{} + $hashes
        foreach ($file in Get-ChildItem -LiteralPath (Join-Path $source 'tools/acceptance/github/modules') -Recurse -File) {
            $relative = Join-Path 'modules' ([IO.Path]::GetRelativePath((Join-Path $source 'tools/acceptance/github/modules'), $file.FullName))
            $expectedFiles[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
        }
        $expectedFiles[(Join-Path 'templates' 'instance/.github/workflows/bootstrap-acceptance.yml')] = (Get-FileHash $workflow).Hash
        $deploymentPath = Join-Path 'templates' 'instance/.github/workflows/deploy.yml'
        $expectedFiles[$deploymentPath] = $files[$deploymentPath]
        $driftPath = Join-Path 'templates' 'instance/.github/workflows/drift.yml'
        $expectedFiles[$driftPath] = $files[$driftPath]
        if ((ConvertTo-PlatformCanonicalJson $files) -cne (ConvertTo-PlatformCanonicalJson $expectedFiles)) {
            throw 'Preparation contains files outside the approved source and probe contracts. Inspect release-preparing before retrying.'
        }
        $state['candidateFiles'] = $files
        Write-SetupAcceptanceJson -Path (Join-Path $preparing 'bootstrap-acceptance.json') -Value @{
            kind = 'github-bootstrap-acceptance'; version = $version; sourceHash = $digest; files = $files
        }
        Save-SetupState -Setup $Setup
        [IO.Directory]::Move($preparing, $destination)
    }
    else {
        $marker = Get-Content (Join-Path $destination 'bootstrap-acceptance.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($marker['kind'] -cne 'github-bootstrap-acceptance' -or $marker['sourceHash'] -cne $digest -or
            $marker['version'] -cne $version -or
            (ConvertTo-PlatformCanonicalJson $marker['files']) -cne (ConvertTo-PlatformCanonicalJson $state['candidateFiles'])) {
            throw 'The prepared acceptance release differs from the approved candidate.'
        }
    }
    $actualFiles = ConvertTo-PlatformCanonicalJson (Get-SetupAcceptanceFileHash -Path $destination)
    if (-not $state['candidateFiles'] -or $actualFiles -cne (ConvertTo-PlatformCanonicalJson $state['candidateFiles'])) {
        throw 'The prepared acceptance release files changed after approval. Restore the approved candidate before provisioning.'
    }
    Import-Module (Join-Path $Setup.RepoPath 'tools/PlatformTools.psm1') -Force
    $Setup.ModulesPath = Join-Path $destination 'modules'
    $Setup.InstancePath = Join-Path $acceptance['directory'] 'instance.yaml'
    if (-not (Test-Path $Setup.InstancePath)) {
        $config = Copy-SetupData $acceptance['sourceConfiguration']
        # G5 adds target_organizations after G4 records the platform organization name in the inventory.
        $config['modules'] = @{ 'enterprise-baseline' = @{ parameters = @{} } }
        $config['credentials'] = @{
            'enterprise-baseline' = @{
                plan = @{ environment = 'enterprise-baseline-plan' }
                apply = @{ environment = 'enterprise-baseline-apply' }
                rulesetPlan = @{ environment = 'enterprise-baseline-ruleset-plan' }
            }
        }
        $config['githubApps'] = @{}
        [IO.File]::WriteAllText($Setup.InstancePath, (ConvertTo-Yaml $config).Replace("`r", ''), [Text.UTF8Encoding]::new($false))
    }
    $null = Get-PlatformInstance -Path $Setup.InstancePath -Modules (Get-PlatformModuleGraph $Setup.ModulesPath) -AllowUnboundApps
    $acceptance['releasePath'] = $destination
    $acceptance['releaseVersion'] = $version
    return 'Approved acceptance copy and separate instance.yaml prepared; original configuration unchanged.'
}

function Invoke-SetupGitHubAcceptance {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][hashtable] $Setup,
        [string] $ReleasePath,
        [string] $ReleaseVersion
    )

    $directory = Join-Path $Setup.WorkPath 'github-acceptance'
    $null = [IO.Directory]::CreateDirectory($directory)
    $Setup.Acceptance = @{ directory = $directory; releasePath = $ReleasePath; releaseVersion = $ReleaseVersion }
    $Setup.StatePath = Join-Path $directory 'setup-state.json'
    if (Test-Path -LiteralPath $Setup.StatePath) {
        $null = Get-Content -LiteralPath $Setup.StatePath -Raw | ConvertFrom-Json -AsHashtable -ErrorAction Stop
    }
    $Setup.State = Read-SetupState -Path $Setup.StatePath
    if (-not $Setup.State.Contains('acceptance')) { $Setup.State['acceptance'] = @{} }
    $plan = @(
        @{ Id = 'acceptance-inputs'; Step = 'G1'; Title = 'Verified prerequisites'; Handler = 'AcceptanceInput'; Requires = @() }
        @{ Id = 'acceptance-release'; Step = 'G2'; Title = 'Isolated acceptance candidate'; Handler = 'AcceptanceRelease'; Requires = @('acceptance-inputs') }
        @{ Id = 'acceptance-azure'; Step = 'G3'; Title = 'Azure bootstrap'; Handler = 'AcceptanceAzure'; Requires = @('acceptance-release') }
        @{ Id = 'acceptance-resources'; Step = 'G4'; Title = 'GitHub preparation'; Handler = 'AcceptanceResource'; Requires = @('acceptance-azure') }
        @{ Id = 'acceptance-apps'; Step = 'G5'; Title = 'Enterprise Apps and key ownership'; Handler = 'AcceptanceApp'; Requires = @('acceptance-resources') }
        @{ Id = 'acceptance-complete'; Step = 'G6'; Title = 'Credential verification and publication'; Handler = 'AcceptanceComplete'; Requires = @('acceptance-apps') }
        @{ Id = 'acceptance-repeat'; Step = 'G7'; Title = 'Idempotent repeat'; Handler = 'AcceptanceRepeat'; Requires = @('acceptance-complete') }
        @{ Id = 'acceptance-ruleset'; Step = 'G8'; Title = 'Disabled ruleset API probe'; Handler = 'AcceptanceRuleset'; Requires = @('acceptance-repeat') }
        @{ Id = 'acceptance-workflow'; Step = 'G9'; Title = 'Live workflow and OIDC evidence'; Handler = 'AcceptanceWorkflow'; Requires = @('acceptance-ruleset') }
        @{ Id = 'acceptance-nightly'; Step = 'G10'; Title = 'Actual nightly run'; Handler = 'AcceptanceNightly'; Requires = @('acceptance-workflow') }
        @{ Id = 'acceptance-witnesses'; Step = 'G11'; Title = 'Human-only acceptance evidence'; Handler = 'AcceptanceWitness'; Requires = @('acceptance-workflow') }
    )
    try {
        foreach ($stage in $plan) {
            Invoke-SetupStage -Setup $Setup -Id $stage.Id -Step $stage.Step -Title $stage.Title -Handler "Invoke-Step$($stage.Handler)" -Requires $stage.Requires
        }
    }
    catch {
        if (-not (Get-SetupFailure -ErrorRecord $_).Quit) { throw }
    }
    finally {
        Save-SetupState -Setup $Setup
        try { Revoke-SetupGitHubScope -Setup $Setup }
        catch { Write-Warning -Message "Removing the temporary gh scopes failed: $($_.Exception.Message)" }
    }
    $reportPath = Join-Path $directory 'acceptance.json'
    $passed = $Setup.Stages.Count -eq $plan.Count -and @($Setup.Stages.Values | Where-Object Status -ne 'Ok').Count -eq 0
    $report = @{
        version = 1; passed = $passed; checkedAt = [DateTimeOffset]::UtcNow.ToString('o'); stages = @($Setup.Stages.Values)
        witnesses = $Setup.State['acceptance']['witnesses']; candidate = $Setup.State['acceptance']['sourceApproval']
        scope = 'bootstrap-only acceptance; production modules require their own API and deployment acceptance'
    }
    [IO.File]::WriteAllText($reportPath, (ConvertTo-Json $report -Depth 20), [Text.UTF8Encoding]::new($false))
    $summaryPath = Join-Path $directory 'issue-11-summary.md'
    $summary = Get-Content (Join-Path $Setup.RepoPath 'tools/acceptance/github/issue-summary.md') -Raw
    $summary = $summary.Replace('{{date}}', [DateTimeOffset]::UtcNow.ToString('yyyy-MM-dd')).Replace('{{passed}}', $passed.ToString().ToLowerInvariant())
    $lines = @()
    foreach ($stage in $plan) {
        $status = if ($Setup.Stages.Contains($stage.Id)) { $Setup.Stages[$stage.Id].Status } else { 'NotRun' }
        $lines += "- $($stage.Step): $status."
    }
    $summary = $summary.Replace('{{stages}}', ($lines -join "`n"))
    [IO.File]::WriteAllText($summaryPath, $summary.Replace("`r", ''), [Text.UTF8Encoding]::new($false))
    Show-SetupTable -Row @($Setup.Stages.Values)
    Show-SetupMessage -Kind $(if ($passed) { 'Ok' } else { 'Warning' }) -Message "AcceptancePassed: $passed. Local evidence: $reportPath. Redacted issue draft: $summaryPath. Nothing was deleted or posted."
    return [pscustomobject]@{
        Stages = @($Setup.Stages.Values); AcceptancePassed = $passed; ReportPath = $reportPath
        SummaryPath = $summaryPath; InstancePath = $Setup.InstancePath
    }
}
