Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')

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
    if ($Path -ceq '/orgs/new/rulesets?per_page=100' -and $Method -ceq 'GET') {
        $reply.Body = '[]'
    }
    elseif ($Path -cmatch "^/orgs/$([regex]::Escape($State.Organization))/rulesets\?per_page=100(?:&page=(?<page>[0-9]+))?$" -and $Method -ceq 'GET') {
        $page = if ($Matches['page']) { [int] $Matches['page'] } else { 1 }
        $items = @($State.Items | Select-Object -Skip ($page - 1) -First 1)
        $reply.Body = ConvertTo-Json -InputObject $items -Depth 50 -Compress
        if ($page -lt $State.Items.Count) { $reply.Link = "<$($State.Origin)/orgs/$($State.Organization)/rulesets?per_page=100&page=$($page + 1)>; rel=`"next`"" }
    }
    elseif ($Path -ceq "/orgs/$($State.Organization)/rulesets" -and $Method -ceq 'POST') {
        $inputBody = ConvertFrom-Json -InputObject $Body -AsHashtable
        $responseBody = ConvertFrom-Json -InputObject $Body -AsHashtable
        $item = Get-GitHubApiFixture -Name repos/create-org-ruleset -Set @{ id = ++$State.NextId; source = $State.Organization }
        foreach ($key in $responseBody.Keys) { $item[$key] = $responseBody[$key] }
        Complete-RulesetResponse -Item $item
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
                $inputBody = ConvertFrom-Json -InputObject $Body -AsHashtable
                $responseBody = ConvertFrom-Json -InputObject $Body -AsHashtable
                foreach ($key in $responseBody.Keys) { $item[$key] = $responseBody[$key] }
                Complete-RulesetResponse -Item $item
                $State.Writes.Add(@{ Method = $Method; Body = $inputBody })
                $reply.Body = ConvertTo-Json -InputObject $item -Depth 50 -Compress
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
