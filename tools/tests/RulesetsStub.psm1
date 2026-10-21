Set-StrictMode -Version Latest
Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')

function Initialize-RulesetsStub {
    [CmdletBinding()]
    param([string] $Origin)

    return [hashtable]::Synchronized(@{
        Origin = $Origin
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
    if ($Headers['Authorization'] -cne 'Bearer stub-token' -or $Headers['X-GitHub-Api-Version'] -cne '2026-03-10') {
        $reply.Status = 401
        return $reply
    }
    if ($Path -ceq '/orgs/new/rulesets?per_page=100' -and $Method -ceq 'GET') {
        $reply.Body = '[]'
    }
    elseif ($Path -cmatch '^/orgs/demo/rulesets\?per_page=100(?:&page=(?<page>[0-9]+))?$' -and $Method -ceq 'GET') {
        $page = if ($Matches['page']) { [int] $Matches['page'] } else { 1 }
        $items = @($State.Items | Select-Object -Skip ($page - 1) -First 1)
        $reply.Body = ConvertTo-Json -InputObject $items -Depth 50 -Compress
        if ($page -lt $State.Items.Count) { $reply.Link = "<$($State.Origin)/orgs/demo/rulesets?per_page=100&page=$($page + 1)>; rel=`"next`"" }
    }
    elseif ($Path -ceq '/orgs/demo/rulesets' -and $Method -ceq 'POST') {
        $inputBody = ConvertFrom-Json -InputObject $Body -AsHashtable
        $item = Get-GitHubApiFixture -Name repos/create-org-ruleset -Set @{ id = ++$State.NextId; source = 'demo' }
        foreach ($key in $inputBody.Keys) { $item[$key] = $inputBody[$key] }
        $State.Items.Add($item)
        $State.Writes.Add(@{ Method = $Method; Body = $inputBody })
        $reply.Status = 201
        $reply.Body = ConvertTo-Json -InputObject $item -Depth 50 -Compress
    }
    elseif ($Path -cmatch '^/orgs/demo/rulesets/(?<id>[1-9][0-9]*)$') {
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
                foreach ($key in $inputBody.Keys) { $item[$key] = $inputBody[$key] }
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
        $reply.Status = 503
        $reply.Body = ''
    }
    return $reply
}

Export-ModuleMember -Function Initialize-RulesetsStub, Invoke-RulesetsStubRequest
