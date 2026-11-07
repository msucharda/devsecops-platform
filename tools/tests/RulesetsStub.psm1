Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')

function Assert-RulesetRequestValue {
    param([AllowNull()][object] $Value, [hashtable] $Schema, [string] $Path = 'request')

    if ($Schema.Contains('unsupported')) { throw "Unsupported ruleset request variant at $Path." }
    if ($Schema.Contains('oneOf')) {
        if ($Value -isnot [Collections.IDictionary] -or $Value['type'] -isnot [string]) {
            throw "Ruleset request $Path.type must be a string."
        }
        $variants = @($Schema.oneOf | Where-Object { $Value['type'] -cin $_.properties.type.enum })
        if ($variants.Count -ne 1) { throw "Unsupported ruleset request variant at $Path.type." }
        Assert-RulesetRequestValue -Value $Value -Schema $variants[0] -Path $Path
        return
    }
    if ($null -eq $Value -and $Schema.Contains('nullable') -and $Schema.nullable) { return }
    $validType = switch ($Schema.type) {
        object { $Value -is [Collections.IDictionary] }
        array { $Value -is [array] }
        string { $Value -is [string] }
        boolean { $Value -is [bool] }
        integer { $Value -is [int] -or $Value -is [long] }
        default { throw "Unsupported ruleset contract type at $Path." }
    }
    if (-not $validType) { throw "Ruleset request $Path must be $($Schema.type)." }
    if ($Schema.Contains('enum') -and $Value -cnotin $Schema.enum) { throw "Ruleset request $Path has an undocumented enum value." }
    if ($Schema.Contains('minimum') -and $Value -lt $Schema.minimum) { throw "Ruleset request $Path is below the minimum." }
    if ($Schema.Contains('maximum') -and $Value -gt $Schema.maximum) { throw "Ruleset request $Path exceeds the maximum." }
    if ($Schema.type -ceq 'object') {
        if ($Schema.Contains('required')) {
            foreach ($field in $Schema.required) {
                if (@($Value.Keys) -cnotcontains $field) { throw "Ruleset request $Path.$field is required." }
            }
        }
        foreach ($field in $Value.Keys) {
            if (@($Schema.properties.Keys) -cnotcontains $field) { throw "Unsupported ruleset request field $Path.$field." }
            Assert-RulesetRequestValue -Value $Value[$field] -Schema $Schema.properties[$field] -Path "$Path.$field"
        }
    }
    elseif ($Schema.type -ceq 'array') {
        for ($index = 0; $index -lt $Value.Count; $index++) {
            Assert-RulesetRequestValue -Value $Value[$index] -Schema $Schema.items -Path "$Path[$index]"
        }
    }
}

function ConvertFrom-RulesetStubRequest {
    param([string] $Body, [string] $Method, [hashtable] $ExistingItem)

    $contract = Get-GitHubApiFixtureContract -Name repos/create-org-ruleset
    $schema = $contract.requestContract.schema
    $schema['required'] = $contract.requestContract.requiredByMethod[$Method]
    # This approved observed extension is not part of the pinned OpenAPI projection.
    $pullRequest = @($schema.properties.rules.items.oneOf | Where-Object { $_.properties.type.enum -ccontains 'pull_request' })[0]
    foreach ($field in $contract.ruleParameters.pull_request.observedRequestProperties) {
        $pullRequest.properties.parameters.properties[$field] = @{ type = 'boolean' }
    }
    $request = ConvertFrom-Json -InputObject $Body -AsHashtable -Depth 100
    Assert-RulesetRequestValue -Value $request -Schema $schema
    $submitted = $request
    if ($ExistingItem) {
        $request = @{}
        foreach ($field in $contract.requestProperties) {
            if ($ExistingItem.Contains($field)) { $request[$field] = $ExistingItem[$field] }
        }
        foreach ($field in $submitted.Keys) { $request[$field] = $submitted[$field] }
        Assert-RulesetRequestValue -Value $request -Schema $schema
    }
    $constraints = $contract.requestContract.descriptionConstraints
    if ($request.Contains('target') -and $request.target -cin $constraints.evaluateExcludedTargets -and
        $request.enforcement -ceq 'evaluate') {
        throw 'Ruleset request request.enforcement evaluate is not available for the repository target.'
    }
    if ($request.Contains('rules')) {
        for ($index = 0; $index -lt $request.rules.Count; $index++) {
            $rule = $request.rules[$index]
            if ($rule.type -cin @('pull_request', 'code_scanning') -and -not $rule.Contains('parameters')) {
                throw "Unsupported ruleset request variant at request.rules[$index].parameters: this stub requires parameters."
            }
            if ($rule.type -ceq 'pull_request' -and $rule.parameters.Contains('allowed_merge_methods') -and
                $rule.parameters.allowed_merge_methods.Count -lt $constraints.minimumAllowedMergeMethods) {
                throw "Ruleset request request.rules[$index].parameters.allowed_merge_methods requires at least one option."
            }
        }
    }
    if ($request.Contains('bypass_actors')) {
        for ($index = 0; $index -lt $request.bypass_actors.Count; $index++) {
            $actor = $request.bypass_actors[$index]
            if ($actor.actor_type -cin $constraints.actorIdRequiredFor -and
                (-not $actor.Contains('actor_id') -or $null -eq $actor.actor_id)) {
                throw "Ruleset request request.bypass_actors[$index].actor_id is required for $($actor.actor_type)."
            }
            if ($actor.actor_type -cin $constraints.nullActorIdFor -and $actor.Contains('actor_id') -and $null -ne $actor.actor_id) {
                throw "Ruleset request request.bypass_actors[$index].actor_id must be null for $($actor.actor_type)."
            }
            if ($actor.Contains('bypass_mode') -and $actor.bypass_mode -ceq 'pull_request' -and
                ($actor.actor_type -cin $constraints.pullRequestBypassExcludedFor -or
                    ($request.Contains('target') -and $request.target -cne $constraints.pullRequestBypassTarget))) {
                throw "Ruleset request request.bypass_actors[$index].bypass_mode pull_request requires a branch ruleset and a non-DeployKey actor."
            }
        }
    }
    return $submitted
}

# The GET fixture supplies the response default; the create fixture records separate POST/PUT evidence.
function Complete-RulesetResponse {
    param([hashtable] $Item)

    $observed = Get-GitHubApiFixture -Name repos/get-org-ruleset
    $parameters = $observed.rules[0].parameters
    foreach ($rule in $Item['rules']) {
        if ($rule['type'] -ceq 'pull_request' -and -not $rule['parameters'].Contains('require_extra_approval_for_unattributed_changes')) {
            $rule['parameters']['require_extra_approval_for_unattributed_changes'] = $parameters.require_extra_approval_for_unattributed_changes
        }
    }
}

function Initialize-RulesetsStub {
    [CmdletBinding()]
    param([string] $Origin, [string] $Organization = 'demo', [string] $Token = 'stub-token')

    $defaults = Get-GitHubApiFixture -Name code-security/get-default-configurations
    $defaults[0]['default_for_new_repos'] = 'all'
    $defaults[0]['configuration'] = Get-GitHubApiFixture -Name code-security/get-configuration -Set @{
        id = 42; name = 'platform-baseline'; target_type = 'organization'; enforcement = 'enforced'
        advanced_security = 'enabled'; code_scanning_default_setup = 'enabled'
    }
    return [hashtable]::Synchronized(@{
        Origin = $Origin
        Organization = $Organization
        Token = $Token
        Items = [Collections.Generic.List[object]]::new()
        Requests = [Collections.Generic.List[string]]::new()
        Writes = [Collections.Generic.List[object]]::new()
        DropNext = ''
        FailNext = ''
        NextId = 100
        EmptyDetail = $false
        CodeSecurityDefaults = @($defaults[0])
    })
}

function Invoke-RulesetsStubRequest {
    [CmdletBinding()]
    param([hashtable] $State, [string] $Method, [string] $Path, [hashtable] $Headers, [string] $Body)

    $State.Requests.Add("$Method $Path")
    $reply = @{ Status = 200; Body = $null; Drop = $false; Link = $null }
    if ($Headers['Authorization'] -cne "Bearer $($State.Token)" -or $Headers['X-GitHub-Api-Version'] -cne '2026-03-10') {
        $reply.Status = 401
        return $reply
    }
    if ($Path -cmatch "^/orgs/($([regex]::Escape($State.Organization))|new)/code-security/configurations/defaults$" -and $Method -ceq 'GET') {
        $reply.Body = ConvertTo-Json -InputObject $State.CodeSecurityDefaults -Depth 100 -Compress
    }
    elseif ($Path -ceq '/orgs/new/rulesets?per_page=100' -and $Method -ceq 'GET') {
        $reply.Body = '[]'
    }
    elseif ($Path -cmatch "^/orgs/$([regex]::Escape($State.Organization))/rulesets\?per_page=100(?:&page=(?<page>[0-9]+))?$" -and $Method -ceq 'GET') {
        $page = if ($Matches['page']) { [int] $Matches['page'] } else { 1 }
        $items = @($State.Items | Select-Object -Skip ($page - 1) -First 1)
        $reply.Body = ConvertTo-Json -InputObject $items -Depth 50 -Compress
        if ($page -lt $State.Items.Count) { $reply.Link = "<$($State.Origin)/orgs/$($State.Organization)/rulesets?per_page=100&page=$($page + 1)>; rel=`"next`"" }
    }
    elseif ($Path -ceq "/orgs/$($State.Organization)/rulesets" -and $Method -ceq 'POST') {
        try { $inputBody = ConvertFrom-RulesetStubRequest -Body $Body -Method $Method }
        catch {
            $reply.Status = 422
            $reply.Body = ConvertTo-Json -InputObject @{ message = $_.Exception.Message } -Compress
            return $reply
        }
        $responseBody = ConvertFrom-Json -InputObject $Body -AsHashtable
        $item = Get-GitHubApiFixture -Name repos/create-org-ruleset -Set @{ id = ($State.NextId + 1); source = $State.Organization }
        foreach ($key in $responseBody.Keys) { $item[$key] = $responseBody[$key] }
        Complete-RulesetResponse -Item $item
        $State.NextId++
        $State.Items.Add($item)
        $State.Writes.Add(@{ Method = $Method; Body = $inputBody })
        $reply.Status = 201
        $reply.Body = ConvertTo-Json -InputObject $item -Depth 50 -Compress
    }
    elseif ($Path -cmatch "^/orgs/$([regex]::Escape($State.Organization))/rulesets/(?<id>[1-9][0-9]*)$") {
        $id = $Matches['id']
        $item = @($State.Items | Where-Object { [string] $_['id'] -ceq $id })
        if ($item.Count -eq 0) { $reply.Status = 404; return $reply }
        $item = $item[0]
        switch ($Method) {
            GET {
                $reply.Body = if ($State.EmptyDetail) { 'null' } else { ConvertTo-Json -InputObject $item -Depth 50 -Compress }
            }
            PUT {
                try { $inputBody = ConvertFrom-RulesetStubRequest -Body $Body -Method $Method -ExistingItem $item }
                catch {
                    $reply.Status = 422
                    $reply.Body = ConvertTo-Json -InputObject @{ message = $_.Exception.Message } -Compress
                    return $reply
                }
                $responseBody = ConvertFrom-Json -InputObject $Body -AsHashtable
                $updated = ConvertFrom-Json -InputObject (ConvertTo-Json -InputObject $item -Depth 50) -AsHashtable
                foreach ($key in $responseBody.Keys) { $updated[$key] = $responseBody[$key] }
                Complete-RulesetResponse -Item $updated
                $State.Items[$State.Items.IndexOf($item)] = $updated
                $State.Writes.Add(@{ Method = $Method; Body = $inputBody })
                $reply.Body = ConvertTo-Json -InputObject $updated -Depth 50 -Compress
            }
            DELETE { $null = $State.Items.Remove($item); $reply.Status = 204 }
            default { $reply.Status = 405 }
        }
    }
    else { $reply.Status = 404 }
    if ($State.DropNext -and "$Method $Path" -cmatch $State.DropNext) {
        $State.DropNext = ''
        $reply.Drop = $true
    }
    if ($State.FailNext -and "$Method $Path" -cmatch $State.FailNext) {
        $State.FailNext = ''
        # This fault must interrupt the run, not be healed by the transient retry policy.
        $reply.Status = 500
        $reply.Body = ''
    }
    return $reply
}

Export-ModuleMember -Function Initialize-RulesetsStub, Invoke-RulesetsStubRequest
