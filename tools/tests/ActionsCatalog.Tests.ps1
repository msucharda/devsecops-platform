BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $scriptRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/actions-catalog/scripts'
    Import-Module (Join-Path $scriptRoot 'ActionsCatalog.psm1') -Force

    $apiUrl = 'https://api.example.ghe.com'
    $token = 'test-installation-token'
    $organization = 'demo-a1b2c3-actions'
    $upstream = 'actions/checkout'
    $repositoryName = 'actions-checkout'
    $securityTeam = 'actions-security'
    $codeOwners = "* @$organization/$securityTeam`n"
    $target = @{ ApiUrl = $apiUrl; Organization = $organization; Upstream = $upstream; SecurityTeam = $securityTeam }
    $repositoryMediaType = 'application/vnd.github.v3.repository+json'

    function Get-StubSha {
        '{0:x40}' -f $stub.NextSha++
    }

    function ConvertTo-StubReply {
        param([int] $Status, [AllowNull()] $Body)
        $content = if ($null -eq $Body) { '' } else { ConvertTo-Json -InputObject $Body -Depth 30 -Compress }
        @{ Status = $Status; Body = $content }
    }

    function Get-StubApprovalRule {
        param([hashtable] $Set = @{})
        $fields = @{ '0.ruleset_source' = $organization }
        foreach ($key in $Set.Keys) { $fields[$key] = $Set[$key] }
        , (Get-GitHubApiFixture -Name repos/get-branch-rules.pull-request -Set $fields)
    }

    function Initialize-CatalogStub {
        $state = @{
            Organization = $organization
            OrganizationDefaultBranch = 'main'
            Teams = [Collections.Generic.HashSet[string]]::new([StringComparer]::OrdinalIgnoreCase)
            Repositories = @{}
            NextSha = 1
            NextId = 1000
            Requests = [Collections.Generic.List[object]]::new()
            # Operation name => scriptblock returning @{ Status; Body } instead of the stub response.
            Override = @{}
        }
        $null = $state.Teams.Add($securityTeam)
        $state
    }

    function Add-StubRepository {
        <# Adds a repository; Files creates a first commit on main. #>
        param([string] $Name = $repositoryName, [hashtable] $Files, [hashtable] $Property = @{}, [string] $Owner = $organization)
        $repository = @{
            id = $stub.NextId++; name = $Name; owner = $Owner; visibility = 'internal'; archived = $false; fork = $false
            default_branch = $stub.OrganizationDefaultBranch; access = 'none'; teams = @{}
            commits = @{}; heads = @{}; tags = @{}
            rules = [Collections.Generic.List[object]]::new()
        }
        foreach ($key in $Property.Keys) { $repository[$key] = $Property[$key] }
        $stub.Repositories[$Name.ToLowerInvariant()] = $repository
        if ($Files) { $null = Add-StubCommit -Name $Name -Files $Files }
        $repository
    }

    function Add-StubCommit {
        <# Adds a commit with the given files on top of main, or on top of Parent without moving main. #>
        param([string] $Name = $repositoryName, [hashtable] $Files = @{}, [string] $Parent, [switch] $Detached)
        $repository = $stub.Repositories[$Name.ToLowerInvariant()]
        if (-not $Parent -and $repository.heads.Contains('main')) { $Parent = $repository.heads['main'] }
        $tree = @{}
        if ($Parent) { foreach ($path in $repository.commits[$Parent].files.Keys) { $tree[$path] = $repository.commits[$Parent].files[$path] } }
        foreach ($path in $Files.Keys) { $tree[$path] = $Files[$path] }
        $sha = Get-StubSha
        $repository.commits[$sha] = @{ parent = $Parent; files = $tree }
        if (-not $Detached) { $repository.heads['main'] = $sha }
        $sha
    }

    function Test-StubAncestor {
        param([hashtable] $Repository, [string] $Ancestor, [string] $Commit)
        for ($current = $Commit; $current; $current = $Repository.commits[$current].parent) {
            if ($current -ceq $Ancestor) { return $true }
        }
        $false
    }

    function Get-StubReceipt {
        param([AllowNull()] $Version = 1, [AllowNull()] $Kind = 'action', [AllowNull()] $Source = $upstream, [AllowNull()] $Tag = 'v4.2.2')
        ConvertTo-Json -Compress -InputObject ([ordered]@{
                version = $Version; kind = $Kind; source = $Source; tag = $Tag; commit = '11bd71901bbe5b1630ceea73d27597364c9af683'
                sha256 = ('a' * 64); asset = 'vendored-action.tar.gz'; attestation = 'https://example.ghe.com/attestations/1'; files = 3
            })
    }

    function Get-StubRequest {
        param([string] $Operation)
        , @($stub.Requests | Where-Object { $_.Operation -ceq $Operation })
    }

    function Get-StubWrite {
        , @($stub.Requests | Where-Object { $_.Method -cne 'GET' })
    }

    function Get-StubRepositoryReply {
        param([string] $FixtureName, [hashtable] $Repository, [int] $Status)
        $body = Get-GitHubApiFixture -Name $FixtureName -Set @{
            id = $Repository.id; name = $Repository.name; full_name = "$($Repository.owner)/$($Repository.name)"
            'owner.login' = $Repository.owner; visibility = $Repository.visibility; private = $Repository.visibility -cne 'public'
            archived = $Repository.archived; fork = $Repository.fork; default_branch = $Repository.default_branch
        }
        ConvertTo-StubReply -Status $Status -Body $body
    }

    function Invoke-CatalogStub {
        param([string] $Method, [string] $PathAndQuery, [hashtable] $Headers, [AllowNull()][string] $Body)

        $Headers['Authorization'] | Should -BeExactly "Bearer $token"
        $Headers['X-GitHub-Api-Version'] | Should -BeExactly '2026-03-10'
        $path = [Uri]::UnescapeDataString($PathAndQuery.Split('?')[0])
        $query = [Web.HttpUtility]::ParseQueryString(([Uri] "$apiUrl$PathAndQuery").Query)
        $request = if ($Body) { ConvertFrom-Json $Body -AsHashtable } else { $null }
        $operation = switch -Regex ("$Method $path") {
            '^GET /repos/[^/]+/[^/]+$' { 'getRepository' }
            '^POST /orgs/[^/]+/repos$' { 'createRepository' }
            '^GET /repos/[^/]+/[^/]+/actions/permissions/access$' { 'getAccess' }
            '^PUT /repos/[^/]+/[^/]+/actions/permissions/access$' { 'setAccess' }
            '^GET /orgs/[^/]+/teams/[^/]+$' { 'getTeam' }
            '^GET /orgs/[^/]+/teams/[^/]+/repos/[^/]+/[^/]+$' { 'checkTeamRepository' }
            '^PUT /orgs/[^/]+/teams/[^/]+/repos/[^/]+/[^/]+$' { 'setTeamRepository' }
            '^GET /repos/[^/]+/[^/]+/git/ref/(heads|tags)/.+$' { 'getRef' }
            '^POST /repos/[^/]+/[^/]+/git/refs$' { 'createRef' }
            '^GET /repos/[^/]+/[^/]+/contents/.+$' { 'getContent' }
            '^PUT /repos/[^/]+/[^/]+/contents/.+$' { 'putContent' }
            '^GET /repos/[^/]+/[^/]+/compare/[^/]+$' { 'compare' }
            '^GET /repos/[^/]+/[^/]+/rules/branches/[^/]+$' { 'getBranchRules' }
            default { throw "Unexpected request $Method $PathAndQuery" }
        }
        $expectedAccept = if ($operation -ceq 'checkTeamRepository') { $repositoryMediaType } else { 'application/vnd.github+json' }
        $Headers['Accept'] | Should -BeExactly $expectedAccept
        $stub.Requests.Add(@{ Operation = $operation; Method = $Method; Path = $PathAndQuery; Body = $request })
        if ($stub.Override.Contains($operation)) {
            $reply = & $stub.Override[$operation] $request $PathAndQuery
            if ($null -ne $reply) { return ConvertTo-StubReply -Status $reply.Status -Body $reply.Body }
        }
        $notFound = ConvertTo-StubReply -Status 404 -Body @{ message = 'Not Found' }
        $segments = $path.TrimStart('/').Split('/')
        $repositoryKey = switch ($operation) {
            { $_ -in 'checkTeamRepository', 'setTeamRepository' } { "$($segments[5])/$($segments[6])"; break }
            { $_ -in 'createRepository', 'getTeam' } { $null; break }
            default { "$($segments[1])/$($segments[2])" }
        }
        $repository = $null
        if ($repositoryKey) {
            $owner, $name = $repositoryKey.Split('/')
            $candidate = $stub.Repositories[$name.ToLowerInvariant()]
            if ($candidate -and $candidate.owner -eq $owner) { $repository = $candidate }
            if (-not $repository) { return $notFound }
        }
        switch ($operation) {
            'getRepository' { return Get-StubRepositoryReply -FixtureName repos/get -Repository $repository -Status 200 }
            'createRepository' {
                $segments[1] | Should -BeExactly $organization
                if ($stub.Repositories.Contains($request.name.ToLowerInvariant())) {
                    return ConvertTo-StubReply -Status 422 -Body @{ message = 'Repository creation failed.'; status = '422' }
                }
                $created = Add-StubRepository -Name $request.name -Property @{ visibility = $request.visibility }
                return Get-StubRepositoryReply -FixtureName repos/create-in-org -Repository $created -Status 201
            }
            'getAccess' {
                return ConvertTo-StubReply -Status 200 -Body (Get-GitHubApiFixture -Name actions/get-workflow-access-to-repository -Set @{ access_level = $repository.access })
            }
            'setAccess' {
                $repository.access = $request.access_level
                return ConvertTo-StubReply -Status 204 -Body $null
            }
            'getTeam' {
                if (-not $stub.Teams.Contains($segments[3])) { return $notFound }
                return ConvertTo-StubReply -Status 200 -Body (Get-GitHubApiFixture -Name teams/get-by-name -Set @{ slug = $segments[3] })
            }
            'checkTeamRepository' {
                $permission = $repository.teams[$segments[3].ToLowerInvariant()]
                if (-not $stub.Teams.Contains($segments[3]) -or -not $permission) { return $notFound }
                $rank = @{ pull = 1; triage = 2; push = 3; maintain = 4; admin = 5 }[$permission]
                $response = Get-GitHubApiFixture -Name teams/check-permissions-for-repo-in-org -Set @{
                    name = $repository.name; full_name = "$($repository.owner)/$($repository.name)"; role_name = $permission
                    'permissions.pull' = $rank -ge 1; 'permissions.triage' = $rank -ge 2; 'permissions.push' = $rank -ge 3
                    'permissions.maintain' = $rank -ge 4; 'permissions.admin' = $rank -ge 5
                }
                return ConvertTo-StubReply -Status 200 -Body $response
            }
            'setTeamRepository' {
                if (-not $stub.Teams.Contains($segments[3])) { return $notFound }
                $repository.teams[$segments[3].ToLowerInvariant()] = $request.permission
                return ConvertTo-StubReply -Status 204 -Body $null
            }
            'getRef' {
                if (-not $repository.commits.Count) { return ConvertTo-StubReply -Status 409 -Body @{ message = 'Git Repository is empty.' } }
                $kind = $segments[5]
                $refName = ($segments[6..($segments.Count - 1)] -join '/')
                $sha = if ($kind -ceq 'heads') { $repository.heads[$refName] } else { $repository.tags[$refName] }
                if (-not $sha) { return $notFound }
                $type = if ($sha -is [hashtable]) { $sha.type } else { 'commit' }
                $objectSha = if ($sha -is [hashtable]) { $sha.sha } else { $sha }
                $response = Get-GitHubApiFixture -Name git/get-ref -Set @{ ref = "refs/$kind/$refName"; 'object.type' = $type; 'object.sha' = $objectSha }
                return ConvertTo-StubReply -Status 200 -Body $response
            }
            'createRef' {
                $request.ref | Should -BeLike 'refs/tags/*'
                $tagName = $request.ref.Substring(10)
                if ($repository.tags.Contains($tagName) -or -not $repository.commits.Contains($request.sha)) {
                    return ConvertTo-StubReply -Status 422 -Body @{ message = 'Reference already exists'; status = '422' }
                }
                $repository.tags[$tagName] = $request.sha
                $response = Get-GitHubApiFixture -Name git/create-ref -Set @{ ref = $request.ref; 'object.type' = 'commit'; 'object.sha' = $request.sha }
                return ConvertTo-StubReply -Status 201 -Body $response
            }
            'getContent' {
                $filePath = ($segments[4..($segments.Count - 1)] -join '/')
                $ref = $query['ref']
                $commit = if ($ref) { $repository.commits[$ref] } else { $repository.commits[$repository.heads['main']] }
                if (-not $commit -or -not $commit.files.Contains($filePath)) { return $notFound }
                $response = Get-GitHubApiFixture -Name repos/get-content.file -Set @{
                    name = Split-Path $filePath -Leaf; path = $filePath; encoding = 'base64'
                    content = [Convert]::ToBase64String([Text.Encoding]::UTF8.GetBytes($commit.files[$filePath])) -replace '(.{60})', "`$1`n"
                }
                return ConvertTo-StubReply -Status 200 -Body $response
            }
            'putContent' {
                $filePath = ($segments[4..($segments.Count - 1)] -join '/')
                if ($repository.commits.Count -and -not $request.Contains('sha')) {
                    if ($repository.commits[$repository.heads['main']].files.Contains($filePath)) {
                        return ConvertTo-StubReply -Status 422 -Body @{ message = 'Invalid request. "sha" wasn''t supplied.'; status = '422' }
                    }
                }
                $text = [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($request.content))
                if (-not $repository.commits.Count) { $repository.heads.Clear() }
                $sha = Add-StubCommit -Name $repository.name -Files @{ $filePath = $text }
                $response = Get-GitHubApiFixture -Name repos/create-or-update-file-contents -Set @{ 'content.path' = $filePath; 'commit.sha' = $sha }
                return ConvertTo-StubReply -Status 201 -Body $response
            }
            'compare' {
                $base, $head = $segments[4].Split('...')
                $head | Should -Match '^[0-9a-f]{40}$'
                $main = $head
                if (-not $repository.commits.Contains($base) -or -not $repository.commits.Contains($main)) { return $notFound }
                $status = if ($base -ceq $main) { 'identical' }
                elseif (Test-StubAncestor -Repository $repository -Ancestor $base -Commit $main) { 'ahead' }
                elseif (Test-StubAncestor -Repository $repository -Ancestor $main -Commit $base) { 'behind' }
                else { 'diverged' }
                return ConvertTo-StubReply -Status 200 -Body (Get-GitHubApiFixture -Name repos/compare-commits -Set @{ status = $status })
            }
            'getBranchRules' {
                $segments[5] | Should -BeExactly 'main'
                return ConvertTo-StubReply -Status 200 -Body ([object[]] @($repository.rules))
            }
        }
    }

    function Add-StubCompliantRepository {
        <# Adds a repository in the state the module converges to; Files adds a commit on top of CODEOWNERS. #>
        param([hashtable] $Files)
        $repository = Add-StubRepository -Files @{ '.github/CODEOWNERS' = $codeOwners }
        $repository.access = 'enterprise'
        $repository.teams[$securityTeam] = 'push'
        $repository.rules.Add((Get-StubApprovalRule)[0])
        if ($Files) { $null = Add-StubCommit -Files $Files }
        $repository
    }
}

Describe 'Actions catalog module against the documented GitHub API' {
    BeforeEach {
        $env:REST_API_BEARER = $token
        $stub = Initialize-CatalogStub
        Mock -ModuleName ActionsCatalog Invoke-WebRequest {
            $uri = [Uri] $Uri
            "$($uri.Scheme)://$($uri.Authority)" | Should -Be $apiUrl
            $reply = Invoke-CatalogStub -Method ([string] $Method).ToUpperInvariant() -PathAndQuery $uri.PathAndQuery -Headers $Headers `
                -Body $PesterBoundParameters['Body']
            [pscustomobject]@{ StatusCode = $reply.Status; Content = $reply.Body; Headers = @{ Link = $reply['Link'] } }
        }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    Context 'Assert-CatalogInput' {
        It 'accepts a valid input with <Case>' -ForEach @(
            @{ Case = 'no release'; Tag = ''; Commit = '' }
            @{ Case = 'a release'; Tag = 'v4.2.2'; Commit = ('a' * 40) }
            @{ Case = 'a tag with dots and dashes'; Tag = 'v1.0.0-rc.1'; Commit = ('0' * 40) }
        ) {
            { Assert-CatalogInput -Organization $organization -Upstream $upstream -SecurityTeam $securityTeam -Tag $Tag -Commit $Commit } | Should -Not -Throw
        }

        It 'accepts an upstream whose copy name has exactly 100 characters' {
            { Assert-CatalogInput -Organization $organization -Upstream ('actions/' + 'a' * 92) -SecurityTeam $securityTeam } | Should -Not -Throw
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'an organization with a slash'; Field = 'Organization'; Value = 'demo/actions'; Error = '*not a GitHub login*' }
            @{ Case = 'an organization with a leading dash'; Field = 'Organization'; Value = '-demo'; Error = '*not a GitHub login*' }
            @{ Case = 'an upstream without an owner'; Field = 'Upstream'; Value = 'checkout'; Error = '*lowercase owner/repository*' }
            @{ Case = 'an upstream in upper case'; Field = 'Upstream'; Value = 'Actions/checkout'; Error = '*lowercase owner/repository*' }
            @{ Case = 'an upstream with a nested path'; Field = 'Upstream'; Value = 'actions/checkout/sub'; Error = '*lowercase owner/repository*' }
            @{ Case = 'an upstream repository named ..'; Field = 'Upstream'; Value = 'actions/..'; Error = '*lowercase owner/repository*' }
            @{ Case = 'an upstream whose copy name exceeds 100 characters'; Field = 'Upstream'; Value = ('actions/' + 'a' * 93); Error = '*longer than 100 characters*' }
            @{ Case = 'a team slug in upper case'; Field = 'SecurityTeam'; Value = 'Actions-Security'; Error = '*not a team slug*' }
            @{ Case = 'a team slug with a slash'; Field = 'SecurityTeam'; Value = 'org/team'; Error = '*not a team slug*' }
            @{ Case = 'a tag without a commit'; Field = 'Tag'; Value = 'v4.2.2'; Error = '*needs both a tag and a commit*' }
            @{ Case = 'a commit without a tag'; Field = 'Commit'; Value = ('a' * 40); Error = '*needs both a tag and a commit*' }
        ) {
            $arguments = @{ Organization = $organization; Upstream = $upstream; SecurityTeam = $securityTeam }
            $arguments[$Field] = $Value

            { Assert-CatalogInput @arguments } | Should -Throw $Error
        }

        It 'refuses the tag <Tag>' -ForEach @(
            @{ Tag = 'refs/tags/v1' }
            @{ Tag = 'v1..2' }
            @{ Tag = 'v1.lock' }
            @{ Tag = 'v1.' }
            @{ Tag = '-v1' }
            @{ Tag = 'v1 2' }
        ) {
            { Assert-CatalogInput -Organization $organization -Upstream $upstream -SecurityTeam $securityTeam -Tag $Tag -Commit ('a' * 40) } |
                Should -Throw '*not a supported tag name*'
        }

        It 'refuses the commit <Case>' -ForEach @(
            @{ Case = 'in upper case'; Commit = ('A' * 40) }
            @{ Case = 'that is abbreviated'; Commit = ('a' * 7) }
            @{ Case = 'that is a branch'; Commit = 'main' }
        ) {
            { Assert-CatalogInput -Organization $organization -Upstream $upstream -SecurityTeam $securityTeam -Tag 'v1' -Commit $Commit } |
                Should -Throw '*full lowercase commit SHA*'
        }

        It 'maps an upstream to the catalog repository and CODEOWNERS' {
            Get-CatalogRepositoryName -Upstream 'hashicorp/setup-terraform' | Should -BeExactly 'hashicorp-setup-terraform'
            Get-CatalogCodeOwners -Organization $organization -SecurityTeam $securityTeam | Should -BeExactly $codeOwners
        }
    }

    Context 'Invoke-CatalogApi' {
        It 'refuses an API URL that is not an HTTPS origin: <Url>' -ForEach @(
            @{ Url = 'http://api.example.ghe.com' }
            @{ Url = 'https://api.example.ghe.com/api/v3' }
            @{ Url = 'https://user@api.example.ghe.com' }
            @{ Url = 'https://api.example.ghe.com/?x=1' }
            @{ Url = 'api.example.ghe.com' }
        ) {
            { Invoke-CatalogApi -ApiUrl $Url -Method GET -Path '/x' } | Should -Throw '*HTTPS origin*'
            Should -Invoke -ModuleName ActionsCatalog Invoke-WebRequest -Times 0 -Exactly
        }

        It 'requires the token from the runner' {
            Remove-Item Env:\REST_API_BEARER

            { Initialize-CatalogRepository @target } | Should -Throw '*REST_API_BEARER*'
        }

        It 'fails on an undocumented status' {
            $stub.Override['getRepository'] = { @{ Status = 403; Body = @{ message = 'Forbidden' } } }

            { Initialize-CatalogRepository @target } | Should -Throw "*HTTP 403*GET /repos/$organization/$repositoryName*"
        }

        It 'follows pagination of the branch rules' {
            $repository = Add-StubCompliantRepository
            $repository.rules.Clear()
            $stub.Override['getBranchRules'] = {
                param($Request, $PathAndQuery)
                $null = $Request
                if ($PathAndQuery -notmatch 'page=2') { return $null }
                @{ Status = 200; Body = [object[]] @((Get-StubApprovalRule)[0]) }
            }
            Mock -ModuleName ActionsCatalog Invoke-WebRequest -ParameterFilter { ([Uri] $Uri).AbsolutePath -like '*/rules/branches/main' -and ([Uri] $Uri).Query -notmatch 'page=2' } {
                [pscustomobject]@{ StatusCode = 200; Content = '[]'; Headers = @{ Link = "<$apiUrl/repos/$organization/$repositoryName/rules/branches/main?per_page=100&page=2>; rel=`"next`"" } }
            }

            $state = Get-CatalogRepositoryState @target

            $state.approvalRule | Should -BeTrue
        }

        It 'refuses a pagination link outside the API origin' {
            $null = Add-StubCompliantRepository
            Mock -ModuleName ActionsCatalog Invoke-WebRequest -ParameterFilter { ([Uri] $Uri).AbsolutePath -like '*/rules/branches/main' } {
                [pscustomobject]@{ StatusCode = 200; Content = '[]'; Headers = @{ Link = '<https://evil.example/next>; rel="next"' } }
            }

            { Get-CatalogRepositoryState @target } | Should -Throw '*outside*'
        }
    }

    Context 'Initialize-CatalogRepository' {
        It 'creates the internal repository, opens it to the enterprise, grants the team push and writes CODEOWNERS' {
            Initialize-CatalogRepository @target

            $create = (Get-StubRequest createRepository)[0]
            $create.Body.name | Should -BeExactly $repositoryName
            $create.Body.visibility | Should -BeExactly 'internal'
            $create.Body.auto_init | Should -BeFalse
            (Get-StubRequest setAccess)[0].Body.access_level | Should -BeExactly 'enterprise'
            (Get-StubRequest setTeamRepository)[0].Path | Should -BeExactly "/orgs/$organization/teams/$securityTeam/repos/$organization/$repositoryName"
            (Get-StubRequest setTeamRepository)[0].Body.permission | Should -BeExactly 'push'
            $put = (Get-StubRequest putContent)[0]
            $put.Path | Should -BeExactly "/repos/$organization/$repositoryName/contents/.github/CODEOWNERS"
            [Text.Encoding]::UTF8.GetString([Convert]::FromBase64String($put.Body.content)) | Should -BeExactly $codeOwners
            $repository = $stub.Repositories[$repositoryName]
            $repository.commits[$repository.heads['main']].files['.github/CODEOWNERS'] | Should -BeExactly $codeOwners
        }

        It 'makes no change on a repeated run' {
            Initialize-CatalogRepository @target
            $stub.Requests.Clear()

            Initialize-CatalogRepository @target

            (Get-StubWrite).Count | Should -Be 0
        }

        It 'adopts a compliant repository without changes' {
            $null = Add-StubCompliantRepository -Files @{ 'action.yml' = 'name: checkout' }

            Initialize-CatalogRepository @target

            (Get-StubWrite).Count | Should -Be 0
        }

        It 'grants push to a team that has only <Permission>' -ForEach @(
            @{ Permission = 'pull' }
            @{ Permission = 'triage' }
        ) {
            $repository = Add-StubCompliantRepository
            $repository.teams[$securityTeam] = $Permission

            Initialize-CatalogRepository @target

            (Get-StubRequest setTeamRepository).Count | Should -Be 1
            $repository.teams[$securityTeam] | Should -BeExactly 'push'
        }

        It 'keeps a team with <Permission>' -ForEach @(
            @{ Permission = 'maintain' }
            @{ Permission = 'admin' }
        ) {
            $repository = Add-StubCompliantRepository
            $repository.teams[$securityTeam] = $Permission

            Initialize-CatalogRepository @target

            (Get-StubWrite).Count | Should -Be 0
        }

        It 'opens the actions of a repository with access level <Level>' -ForEach @(
            @{ Level = 'none' }
            @{ Level = 'organization' }
        ) {
            $repository = Add-StubCompliantRepository
            $repository.access = $Level

            Initialize-CatalogRepository @target

            $repository.access | Should -BeExactly 'enterprise'
        }

        It 'adopts the repository created by a run whose response was lost' {
            $stub.Override['createRepository'] = {
                param($Request)
                $null = Add-StubRepository -Name $Request.name -Property @{ visibility = $Request.visibility }
                @{ Status = 422; Body = @{ message = 'Repository creation failed.' } }
            }

            Initialize-CatalogRepository @target

            (Get-StubRequest createRepository).Count | Should -Be 1
            (Get-StubRequest getRepository).Count | Should -Be 2
            $stub.Repositories[$repositoryName].access | Should -BeExactly 'enterprise'
        }

        It 'refuses an existing repository that <Case>' -ForEach @(
            @{ Case = 'is public'; Property = @{ visibility = 'public' }; Error = '*is not internal*' }
            @{ Case = 'is private'; Property = @{ visibility = 'private' }; Error = '*is not internal*' }
            @{ Case = 'is archived'; Property = @{ archived = $true }; Error = '*is archived*' }
            @{ Case = 'is a fork'; Property = @{ fork = $true }; Error = '*is a fork*' }
            @{ Case = 'uses the default branch master'; Property = @{ default_branch = 'master' }; Error = '*default branch main*' }
        ) {
            $null = Add-StubRepository -Property $Property

            { Initialize-CatalogRepository @target } | Should -Throw $Error
            (Get-StubWrite).Count | Should -Be 0
        }

        It 'refuses a new repository that GitHub created with the default branch master' {
            $stub.OrganizationDefaultBranch = 'master'

            { Initialize-CatalogRepository @target } | Should -Throw '*default branch main*'
            @(Get-StubWrite | ForEach-Object { $_.Operation }) | Should -Be @('createRepository')
        }

        It 'refuses a repository whose CODEOWNERS on main <Case>' -ForEach @(
            @{ Case = 'names another team'; Text = "* @{org}/other-team`n" }
            @{ Case = 'adds another owner'; Text = "* @{org}/{team}`n/action.yml @someone`n" }
            @{ Case = 'differs in case'; Text = "* @{org}/{TEAM}`n" }
            @{ Case = 'has no trailing newline'; Text = "* @{org}/{team}" }
            @{ Case = 'is empty'; Text = '' }
        ) {
            $repository = Add-StubCompliantRepository
            $repository.access = 'none'
            $text = $Text.Replace('{org}', $organization).Replace('{team}', $securityTeam).Replace('{TEAM}', $securityTeam.ToUpperInvariant())
            $null = Add-StubCommit -Files @{ '.github/CODEOWNERS' = $text }

            { Initialize-CatalogRepository @target } | Should -Throw '*does not name only the security team*'
            (Get-StubRequest putContent).Count | Should -Be 0
            (Get-StubRequest setAccess).Count | Should -Be 0
            $repository.access | Should -BeExactly 'none'
        }

        It 'refuses a repository with commits but no CODEOWNERS on main' {
            $repository = Add-StubRepository -Files @{ 'README.md' = 'readme' }

            { Initialize-CatalogRepository @target } | Should -Throw '*does not name only the security team*'
            (Get-StubRequest putContent).Count | Should -Be 0
            (Get-StubRequest setAccess).Count | Should -Be 0
            $repository.access | Should -BeExactly 'none'
        }

        It 'fails when the security team does not exist' {
            $stub.Teams.Clear()

            { Initialize-CatalogRepository @target } | Should -Throw "*Security team '$organization/$securityTeam' does not exist*"
            (Get-StubRequest setTeamRepository).Count | Should -Be 0
        }

        It 'fails closed on a security team reply with <Case>' -ForEach @(
            @{ Case = 'secret privacy'; Body = 'secret' }
            @{ Case = 'privacy in another case'; Body = 'Closed' }
            @{ Case = 'no privacy'; Body = $null }
            @{ Case = 'an array body'; Body = 'array' }
            @{ Case = 'an empty privacy array'; Body = 'emptyArray' }
            @{ Case = 'a privacy array'; Body = 'closedArray' }
        ) {
            $value = $Body
            $stub.Override['getTeam'] = {
                $team = Get-GitHubApiFixture -Name teams/get-by-name -Set @{ slug = $securityTeam }
                if ($value -ceq 'array') { return @{ Status = 200; Body = @($team) } }
                # Array privacy values are deliberately invalid: -cne on an array filters instead of comparing.
                $team['privacy'] = switch ($value) { 'emptyArray' { , @() } 'closedArray' { , @('closed') } default { $value } }
                @{ Status = 200; Body = $team }
            }.GetNewClosure()

            { Initialize-CatalogRepository @target } | Should -Throw "*Security team '$organization/$securityTeam' is not visible*"
            (Get-StubRequest setTeamRepository).Count | Should -Be 0
        }

        It 'fails closed on a team permission reply without <Case>' -ForEach @(
            @{ Case = 'permissions'; Set = @{ permissions = $null } }
            @{ Case = 'a boolean push'; Set = @{ 'permissions.push' = 'true' } }
        ) {
            $null = Add-StubCompliantRepository
            $set = $Set
            $stub.Override['checkTeamRepository'] = { @{ Status = 200; Body = (Get-GitHubApiFixture -Name teams/check-permissions-for-repo-in-org -Set $set) } }.GetNewClosure()

            { Initialize-CatalogRepository @target } | Should -Throw '*no team permissions*'
            (Get-StubWrite).Count | Should -Be 0
        }

        It 'fails closed on a reference of main that <Case>' -ForEach @(
            @{ Case = 'is not a commit'; Set = @{ 'object.type' = 'tag' } }
            @{ Case = 'names another branch'; Set = @{ ref = 'refs/heads/other' } }
            @{ Case = 'has an abbreviated SHA'; Set = @{ 'object.sha' = 'abc1234' } }
        ) {
            $null = Add-StubCompliantRepository
            $fields = @{ ref = 'refs/heads/main'; 'object.sha' = ('b' * 40); 'object.type' = 'commit' }
            foreach ($key in $Set.Keys) { $fields[$key] = $Set[$key] }
            $stub.Override['getRef'] = { @{ Status = 200; Body = (Get-GitHubApiFixture -Name git/get-ref -Set $fields) } }.GetNewClosure()

            { Initialize-CatalogRepository @target } | Should -Throw '*no commit for the main branch*'
        }
    }

    Context 'Test-CatalogRepositoryAdoptable' {
        BeforeEach {
            $repository = Get-GitHubApiFixture -Name repos/get -Set @{
                name = $repositoryName; 'owner.login' = $organization; visibility = 'internal'; archived = $false; fork = $false; default_branch = 'main'
            }
        }

        It 'accepts an internal active repository of the organization on main' {
            @(Test-CatalogRepositoryAdoptable -Repository $repository -Organization $organization -Name $repositoryName).Count | Should -Be 0
        }

        It 'accepts owner and name that differ only in case' {
            $repository['owner']['login'] = $organization.ToUpperInvariant()
            $repository['name'] = $repositoryName.ToUpperInvariant()

            @(Test-CatalogRepositoryAdoptable -Repository $repository -Organization $organization -Name $repositoryName).Count | Should -Be 0
        }

        It 'refuses a repository with <Case>' -ForEach @(
            @{ Case = 'another owner'; Path = 'owner.login'; Value = 'other-org'; Error = '*not owned by the actions organization*' }
            @{ Case = 'no owner login'; Path = 'owner.login'; Value = $null; Error = '*not owned by the actions organization*' }
            @{ Case = 'an array owner login'; Path = 'owner.login'; Value = 'array'; Error = '*not owned by the actions organization*' }
            @{ Case = 'no owner'; Path = 'owner'; Value = $null; Error = '*not owned by the actions organization*' }
            @{ Case = 'another name'; Path = 'name'; Value = 'actions-checkout-old'; Error = '*not owned by the actions organization*' }
            @{ Case = 'an array name'; Path = 'name'; Value = 'array'; Error = '*not owned by the actions organization*' }
            @{ Case = 'no name'; Path = 'name'; Value = $null; Error = '*not owned by the actions organization*' }
            @{ Case = 'public visibility'; Path = 'visibility'; Value = 'public'; Error = '*is not internal*' }
            @{ Case = 'visibility in upper case'; Path = 'visibility'; Value = 'INTERNAL'; Error = '*is not internal*' }
            @{ Case = 'no visibility'; Path = 'visibility'; Value = $null; Error = '*is not internal*' }
            @{ Case = 'an empty visibility array'; Path = 'visibility'; Value = 'emptyArray'; Error = '*is not internal*' }
            @{ Case = 'a visibility array'; Path = 'visibility'; Value = 'array'; Error = '*is not internal*' }
            @{ Case = 'archived'; Path = 'archived'; Value = $true; Error = '*is archived*' }
            @{ Case = 'a string archived flag'; Path = 'archived'; Value = 'false'; Error = '*is archived*' }
            @{ Case = 'no archived flag'; Path = 'archived'; Value = $null; Error = '*is archived*' }
            @{ Case = 'a fork'; Path = 'fork'; Value = $true; Error = '*is a fork*' }
            @{ Case = 'a string fork flag'; Path = 'fork'; Value = 'false'; Error = '*is a fork*' }
            @{ Case = 'no fork flag'; Path = 'fork'; Value = $null; Error = '*is a fork*' }
            @{ Case = 'the default branch master'; Path = 'default_branch'; Value = 'master'; Error = '*default branch main*' }
            @{ Case = 'the default branch Main'; Path = 'default_branch'; Value = 'Main'; Error = '*default branch main*' }
            @{ Case = 'an empty default branch array'; Path = 'default_branch'; Value = 'emptyArray'; Error = '*default branch main*' }
            @{ Case = 'a default branch array'; Path = 'default_branch'; Value = 'array'; Error = '*default branch main*' }
        ) {
            # An array that holds the expected value is a deliberately invalid shape: -ne on an array filters instead of comparing.
            $expected = @{ name = $repositoryName; 'owner.login' = $organization; visibility = 'internal'; default_branch = 'main' }
            if ($Value -ceq 'array') { $Value = @($expected[$Path]) }
            elseif ($Value -ceq 'emptyArray') { $Value = @() }
            if ($Path -ceq 'owner.login') { $repository['owner']['login'] = $Value } else { $repository[$Path] = $Value }

            $reasons = @(Test-CatalogRepositoryAdoptable -Repository $repository -Organization $organization -Name $repositoryName)

            $reasons.Count | Should -Be 1
            $reasons[0] | Should -BeLike $Error
        }
    }

    Context 'Get-CatalogFile' {
        It 'decodes a base64 file with line breaks' {
            $null = Add-StubCompliantRepository
            $main = $stub.Repositories[$repositoryName].heads['main']

            $text = Get-CatalogFile -ApiUrl $apiUrl -Organization $organization -Repository $repositoryName -Path '.github/CODEOWNERS' -Commit $main

            $text | Should -BeExactly $codeOwners
        }

        It 'reads the file at the given commit, not at main' {
            $null = Add-StubCompliantRepository
            $old = $stub.Repositories[$repositoryName].heads['main']
            $null = Add-StubCommit -Files @{ '.github/CODEOWNERS' = 'changed' }

            Get-CatalogFile -ApiUrl $apiUrl -Organization $organization -Repository $repositoryName -Path '.github/CODEOWNERS' -Commit $old |
                Should -BeExactly $codeOwners
            (Get-StubRequest getContent)[0].Path | Should -BeLike "*ref=$old"
        }

        It 'returns null for a missing file' {
            $null = Add-StubCompliantRepository
            $main = $stub.Repositories[$repositoryName].heads['main']

            Get-CatalogFile -ApiUrl $apiUrl -Organization $organization -Repository $repositoryName -Path '.vendoring.json' -Commit $main | Should -BeNullOrEmpty
        }

        It 'refuses the documented <Variant> variant' -ForEach @(
            @{ Variant = 'directory' }
            @{ Variant = 'symlink' }
            @{ Variant = 'submodule' }
        ) {
            $null = Add-StubCompliantRepository
            $name = "repos/get-content.$Variant"
            $stub.Override['getContent'] = { @{ Status = 200; Body = (Get-GitHubApiFixture -Name $name) } }.GetNewClosure()

            { Get-CatalogFile -ApiUrl $apiUrl -Organization $organization -Repository $repositoryName -Path '.github/CODEOWNERS' -Commit ('a' * 40) } |
                Should -Throw '*is not a regular file*'
        }

        It 'refuses a file reply with <Case>' -ForEach @(
            @{ Case = 'another path'; Set = @{ path = '.github/codeowners' }; Error = '*not a regular file*' }
            @{ Case = 'another encoding'; Set = @{ encoding = 'none' }; Error = '*not a regular file*' }
            @{ Case = 'an empty type array'; Set = @{ type = 'emptyArray' }; Error = '*not a regular file*' }
            @{ Case = 'an empty path array'; Set = @{ path = 'emptyArray' }; Error = '*not a regular file*' }
            @{ Case = 'an empty encoding array'; Set = @{ encoding = 'emptyArray' }; Error = '*not a regular file*' }
            @{ Case = 'no content'; Set = @{ content = $null }; Error = '*not a regular file*' }
            @{ Case = 'invalid base64'; Set = @{ content = '***' }; Error = '*not base64 UTF-8 text*' }
            @{ Case = 'invalid UTF-8'; Set = @{ content = [Convert]::ToBase64String([byte[]] @(0xff, 0xfe)) }; Error = '*not base64 UTF-8 text*' }
        ) {
            $fields = @{ type = 'file'; path = '.github/CODEOWNERS'; encoding = 'base64'; content = 'YQ==' }
            # An empty array is a deliberately invalid shape: -cne on an array filters instead of comparing.
            foreach ($key in $Set.Keys) { $fields[$key] = if ($Set[$key] -ceq 'emptyArray') { , @() } else { $Set[$key] } }
            $null = Add-StubCompliantRepository
            $stub.Override['getContent'] = { @{ Status = 200; Body = (Get-GitHubApiFixture -Name repos/get-content.file -Set $fields) } }.GetNewClosure()

            { Get-CatalogFile -ApiUrl $apiUrl -Organization $organization -Repository $repositoryName -Path '.github/CODEOWNERS' -Commit ('a' * 40) } |
                Should -Throw $Error
        }
    }

    Context 'Test-CatalogApprovalRule' {
        It 'accepts the documented pull request rule' {
            Test-CatalogApprovalRule -Rule (Get-StubApprovalRule) -Organization $organization | Should -BeTrue
        }

        It 'accepts a rule whose organization source differs only in case' {
            $rules = Get-StubApprovalRule -Set @{ '0.ruleset_source' = $organization.ToUpperInvariant() }

            Test-CatalogApprovalRule -Rule $rules -Organization $organization | Should -BeTrue
        }

        It 'accepts a qualifying pull request rule after other rules' {
            $rules = @(Get-GitHubApiFixture -Name repos/get-branch-rules) + (Get-StubApprovalRule -Set @{ '0.parameters.required_approving_review_count' = 2 })

            Test-CatalogApprovalRule -Rule $rules -Organization $organization | Should -BeTrue
        }

        It 'refuses <Case>' -ForEach @(
            @{ Case = 'no rule'; Rules = @() }
            @{ Case = 'the documented rules without a pull request rule'; Fixture = 'repos/get-branch-rules' }
            @{ Case = 'a rule that does not require code owners'; Set = @{ '0.parameters.require_code_owner_review' = $false } }
            @{ Case = 'a string code owner flag'; Set = @{ '0.parameters.require_code_owner_review' = 'true' } }
            @{ Case = 'no code owner flag'; Set = @{ '0.parameters.require_code_owner_review' = $null } }
            @{ Case = 'a rule that keeps stale approvals after a push'; Set = @{ '0.parameters.dismiss_stale_reviews_on_push' = $false } }
            @{ Case = 'a string stale review flag'; Set = @{ '0.parameters.dismiss_stale_reviews_on_push' = 'true' } }
            @{ Case = 'no stale review flag'; Set = @{ '0.parameters.dismiss_stale_reviews_on_push' = $null } }
            @{ Case = 'zero approvals'; Set = @{ '0.parameters.required_approving_review_count' = 0 } }
            @{ Case = 'a string approval count'; Set = @{ '0.parameters.required_approving_review_count' = '1' } }
            @{ Case = 'no approval count'; Set = @{ '0.parameters.required_approving_review_count' = $null } }
            @{ Case = 'no parameters'; Set = @{ '0.parameters' = $null } }
            @{ Case = 'another rule type'; Set = @{ '0.type' = 'required_status_checks' } }
            @{ Case = 'a rule type in upper case'; Set = @{ '0.type' = 'PULL_REQUEST' } }
            @{ Case = 'an empty rule type array'; Set = @{ '0.type' = 'emptyArray' } }
            @{ Case = 'a repository ruleset'; Set = @{ '0.ruleset_source_type' = 'Repository'; '0.ruleset_source' = 'monalisa/my-repo' } }
            @{ Case = 'a source type in lower case'; Set = @{ '0.ruleset_source_type' = 'organization' } }
            @{ Case = 'no source type'; Set = @{ '0.ruleset_source_type' = $null } }
            @{ Case = 'an empty source type array'; Set = @{ '0.ruleset_source_type' = 'emptyArray' } }
            @{ Case = 'a ruleset of another organization'; Set = @{ '0.ruleset_source' = 'other-org' } }
            @{ Case = 'no source'; Set = @{ '0.ruleset_source' = $null } }
            @{ Case = 'an empty source array'; Set = @{ '0.ruleset_source' = 'emptyArray' } }
        ) {
            $rules = if ($_.Contains('Rules')) { $_.Rules }
            elseif ($_.Contains('Fixture')) { Get-GitHubApiFixture -Name $_.Fixture }
            else { Get-StubApprovalRule -Set $_.Set }
            # An empty array is a deliberately invalid shape: -cne on an array filters instead of comparing.
            if ($_.Contains('Set')) {
                foreach ($key in @('type', 'ruleset_source_type', 'ruleset_source')) {
                    if ($_.Set["0.$key"] -ceq 'emptyArray') { $rules[0][$key] = @() }
                }
            }

            Test-CatalogApprovalRule -Rule $rules -Organization $organization | Should -BeFalse
        }
    }

    Context 'New-CatalogReleaseTag' {
        BeforeEach {
            $repository = Add-StubCompliantRepository
            $release = Add-StubCommit -Files @{ '.vendoring.json' = (Get-StubReceipt); 'action.yml' = 'name: checkout' }
            $tagTarget = $target + @{ Tag = 'v4.2.2'; Commit = $release }
        }

        It 'tags the approved import at <Case>' -ForEach @(
            @{ Case = 'the head of main'; Later = $false }
            @{ Case = 'an earlier commit of main'; Later = $true }
        ) {
            if ($Later) { $null = Add-StubCommit -Files @{ 'README.md' = 'later' } }

            New-CatalogReleaseTag @tagTarget

            $create = (Get-StubRequest createRef)[0]
            $create.Path | Should -BeExactly "/repos/$organization/$repositoryName/git/refs"
            $create.Body.ref | Should -BeExactly 'refs/tags/v4.2.2'
            $create.Body.sha | Should -BeExactly $release
            $repository.tags['v4.2.2'] | Should -BeExactly $release
        }

        It 'makes no change when the tag already points to the commit' {
            $repository.tags['v4.2.2'] = $release

            New-CatalogReleaseTag @tagTarget

            (Get-StubWrite).Count | Should -Be 0
        }

        It 'never moves a tag that points to <Case>' -ForEach @(
            @{ Case = 'another commit'; Object = 'other' }
            @{ Case = 'an annotated tag object'; Object = 'annotated' }
        ) {
            $repository.tags['v4.2.2'] = if ($Object -eq 'other') { $repository.commits[$release].parent } else { @{ type = 'tag'; sha = $release } }

            { New-CatalogReleaseTag @tagTarget } | Should -Throw '*never moves a tag*'
            (Get-StubWrite).Count | Should -Be 0
        }

        It 'accepts a tag created by a run whose response was lost' {
            $stub.Override['createRef'] = {
                param($Request)
                $repository.tags[$Request.ref.Substring(10)] = $Request.sha
                @{ Status = 422; Body = @{ message = 'Reference already exists' } }
            }.GetNewClosure()

            New-CatalogReleaseTag @tagTarget

            (Get-StubRequest createRef).Count | Should -Be 1
        }

        It 'fails when GitHub refuses the tag and no tag exists' {
            $stub.Override['createRef'] = { @{ Status = 422; Body = @{ message = 'Reference update failed' } } }

            { New-CatalogReleaseTag @tagTarget } | Should -Throw '*refused tag*'
        }

        It 'refuses a commit that <Case>' -ForEach @(
            @{ Case = 'is not in the repository'; Setup = 'unknown'; Error = '*is not in*' }
            @{ Case = 'is ahead of main on another branch'; Setup = 'ahead'; Error = '*not on the protected main branch*' }
            @{ Case = 'diverged from main'; Setup = 'diverged'; Error = '*not on the protected main branch*' }
            @{ Case = 'has no receipt'; Setup = 'noReceipt'; Error = '*has no .vendoring.json receipt*' }
            @{ Case = 'has a receipt of version 2'; Receipt = @{ Version = 2 }; Error = '*not a version 1 action receipt*' }
            @{ Case = 'has a string receipt version'; Receipt = @{ Version = '1' }; Error = '*not a version 1 action receipt*' }
            @{ Case = 'has no receipt version'; Receipt = @{ Version = $null }; Error = '*not a version 1 action receipt*' }
            @{ Case = 'has a workflow receipt'; Receipt = @{ Kind = 'workflow' }; Error = '*not a version 1 action receipt*' }
            @{ Case = 'has a receipt kind in another case'; Receipt = @{ Kind = 'Action' }; Error = '*not a version 1 action receipt*' }
            @{ Case = 'has a receipt of another source'; Receipt = @{ Source = 'evil/checkout' }; Error = "*records source 'evil/checkout'*" }
            @{ Case = 'has a receipt source in another case'; Receipt = @{ Source = 'Actions/Checkout' }; Error = "*records source 'Actions/Checkout'*" }
            @{ Case = 'has no receipt source'; Receipt = @{ Source = $null }; Error = '*records source*' }
            @{ Case = 'has a receipt of another tag'; Receipt = @{ Tag = 'v4.2.1' }; Error = "*records tag 'v4.2.1'*" }
            @{ Case = 'has a receipt tag in another case'; Receipt = @{ Tag = 'V4.2.2' }; Error = "*records tag 'V4.2.2'*" }
            @{ Case = 'has an empty receipt kind array'; Receipt = @{ Kind = 'emptyArray' }; Error = '*not a version 1 action receipt*' }
            @{ Case = 'has a receipt kind array'; Receipt = @{ Kind = 'array:action' }; Error = '*not a version 1 action receipt*' }
            @{ Case = 'has an empty receipt source array'; Receipt = @{ Source = 'emptyArray' }; Error = '*records source*' }
            @{ Case = 'has a receipt source array'; Receipt = @{ Source = 'array:actions/checkout' }; Error = '*records source*' }
            @{ Case = 'has an empty receipt tag array'; Receipt = @{ Tag = 'emptyArray' }; Error = '*records tag*' }
            @{ Case = 'has a receipt tag array'; Receipt = @{ Tag = 'array:v4.2.2' }; Error = '*records tag*' }
            @{ Case = 'has an invalid receipt'; Setup = 'invalidJson'; Error = '*not a version 1 action receipt*' }
            @{ Case = 'has a receipt wrapped in an array'; Setup = 'arrayReceipt'; Error = '*not a version 1 action receipt*' }
        ) {
            $receiptFields = $_['Receipt']
            $commit = switch ($_['Setup']) {
                'unknown' { 'c' * 40 }
                'ahead' { Add-StubCommit -Files @{ '.vendoring.json' = (Get-StubReceipt) } -Parent $release -Detached }
                'diverged' { Add-StubCommit -Files @{ '.vendoring.json' = (Get-StubReceipt) } -Parent $repository.commits[$release].parent -Detached }
                'noReceipt' { $repository.commits[$release].parent }
                'invalidJson' { Add-StubCommit -Files @{ '.vendoring.json' = '{ not json' } }
                # A singleton array around a valid receipt is a deliberately invalid shape.
                'arrayReceipt' { Add-StubCommit -Files @{ '.vendoring.json' = "[$(Get-StubReceipt)]" } }
                default {
                    $arguments = @{}
                    # Array receipt fields are deliberately invalid: -cne on an array filters instead of comparing.
                    foreach ($key in $receiptFields.Keys) {
                        $field = $receiptFields[$key]
                        $arguments[$key] = if ($field -ceq 'emptyArray') { , @() } elseif ($field -clike 'array:*') { , @($field.Substring(6)) } else { $field }
                    }
                    Add-StubCommit -Files @{ '.vendoring.json' = (Get-StubReceipt @arguments) }
                }
            }
            $tagTarget.Commit = $commit

            { New-CatalogReleaseTag @tagTarget } | Should -Throw $Error
            (Get-StubRequest createRef).Count | Should -Be 0
        }

        It 'refuses to tag a repository <Case>' -ForEach @(
            @{ Case = 'without the approval rule'; Setup = 'rule'; Error = '*no active rule that requires an approving code owner review*' }
            @{ Case = 'whose CODEOWNERS changed on main'; Setup = 'codeOwners'; Error = '*does not name only the security team*' }
            @{ Case = 'where the security team cannot push'; Setup = 'team'; Error = '*cannot push*' }
            @{ Case = 'closed to the enterprise'; Setup = 'access'; Error = '*not accessible to the enterprise*' }
        ) {
            switch ($Setup) {
                'rule' { $repository.rules.Clear() }
                'codeOwners' { $null = Add-StubCommit -Files @{ '.github/CODEOWNERS' = '* @other' } }
                'team' { $repository.teams[$securityTeam] = 'pull' }
                'access' { $repository.access = 'none' }
            }

            { New-CatalogReleaseTag @tagTarget } | Should -Throw $Error
            (Get-StubRequest createRef).Count | Should -Be 0
        }

        It 'refuses the tag when main moves during the release check' {
            $stub.Override['getContent'] = {
                # The stub passes the request body and the path; only the path matters here.
                if ($args[1] -like '*/.vendoring.json*') { $repository.heads['main'] = $repository.commits[$release].parent }
            }.GetNewClosure()

            { New-CatalogReleaseTag @tagTarget } | Should -Throw '*changed during the release check*'
            (Get-StubRequest createRef).Count | Should -Be 0
        }

        It 'refuses a commit that main does not contain after a force push' {
            $repository.heads['main'] = $repository.commits[$release].parent

            { New-CatalogReleaseTag @tagTarget } | Should -Throw '*not on the protected main branch*'
        }

        It 'refuses a comparison with <Case>' -ForEach @(
            @{ Case = 'a status in another case'; Body = 'IDENTICAL' }
            @{ Case = 'an array body'; Body = 'array' }
        ) {
            $value = $Body
            $stub.Override['compare'] = {
                $comparison = Get-GitHubApiFixture -Name repos/compare-commits -Set @{ status = 'identical' }
                if ($value -ceq 'array') { return @{ Status = 200; Body = @($comparison) } }
                $comparison['status'] = $value
                @{ Status = 200; Body = $comparison }
            }.GetNewClosure()

            { New-CatalogReleaseTag @tagTarget } | Should -Throw '*not on the protected main branch*'
            (Get-StubRequest createRef).Count | Should -Be 0
        }
    }

    Context 'Get-CatalogRepositoryState' {
        It 'reads a converged repository without violations' {
            Initialize-CatalogRepository @target
            $stub.Repositories[$repositoryName].rules.Add((Get-StubApprovalRule)[0])
            $release = Add-StubCommit -Files @{ '.vendoring.json' = (Get-StubReceipt) }
            New-CatalogReleaseTag @target -Tag 'v4.2.2' -Commit $release
            $stub.Requests.Clear()

            $state = Get-CatalogRepositoryState @target -Tag 'v4.2.2' -Commit $release
            $violations = @(Get-CatalogStateViolation -State $state -Organization $organization -SecurityTeam $securityTeam -Tag 'v4.2.2' -Commit $release)

            $violations.Count | Should -Be 0
            (Get-StubWrite).Count | Should -Be 0
            $state.exists | Should -BeTrue
            $state.accessLevel | Should -BeExactly 'enterprise'
            $state.teamPush | Should -BeTrue
            $state.codeOwners | Should -BeExactly $codeOwners
            $state.tag.Sha | Should -BeExactly $release
        }

        It 'reports a missing repository' {
            $state = Get-CatalogRepositoryState @target

            $state.exists | Should -BeFalse
            @(Get-CatalogStateViolation -State $state -Organization $organization -SecurityTeam $securityTeam) | Should -Be @("Repository '$organization/$repositoryName' does not exist.")
        }

        It 'reports an empty repository without a main branch' {
            $null = Add-StubRepository

            $state = Get-CatalogRepositoryState @target

            $state.mainSha | Should -BeNullOrEmpty
            @(Get-CatalogStateViolation -State $state -Organization $organization -SecurityTeam $securityTeam) | Should -Contain "Repository '$organization/$repositoryName' has no main branch."
        }

        It 'fails the read when the security team is missing' {
            $null = Add-StubCompliantRepository
            $stub.Teams.Clear()

            { Get-CatalogRepositoryState @target } | Should -Throw '*does not exist*'
        }
    }

    Context 'Get-CatalogStateViolation' {
        BeforeEach {
            $release = 'd' * 40
            $state = [ordered]@{
                repository = $repositoryName; exists = $true; adoption = @(); accessLevel = 'enterprise'; teamPush = $true
                mainSha = ('e' * 40); codeOwners = $codeOwners; approvalRule = $true
                tag = @{ Type = 'commit'; Sha = $release }; release = @()
            }
        }

        It 'reports no violation for the converged state' {
            @(Get-CatalogStateViolation -State $state -Organization $organization -SecurityTeam $securityTeam -Tag 'v4.2.2' -Commit $release).Count | Should -Be 0
        }

        It 'ignores tag fields without a release' {
            $state.Remove('tag'); $state.Remove('release')

            @(Get-CatalogStateViolation -State $state -Organization $organization -SecurityTeam $securityTeam).Count | Should -Be 0
        }

        It 'reports <Case>' -ForEach @(
            @{ Case = 'a missing repository'; Key = 'exists'; Value = $false; Error = '*does not exist*' }
            @{ Case = 'an unknown existence'; Key = 'exists'; Value = 'true'; Error = '*does not exist*' }
            @{ Case = 'an adoption reason'; Key = 'adoption'; Value = @('Repository is a fork.'); Error = 'Repository is a fork.' }
            @{ Case = 'organization access'; Key = 'accessLevel'; Value = 'organization'; Error = '*not accessible to the enterprise*' }
            @{ Case = 'an access level in another case'; Key = 'accessLevel'; Value = 'Enterprise'; Error = '*not accessible to the enterprise*' }
            @{ Case = 'an unknown access level'; Key = 'accessLevel'; Value = $null; Error = '*not accessible to the enterprise*' }
            @{ Case = 'a team without push'; Key = 'teamPush'; Value = $false; Error = '*cannot push*' }
            @{ Case = 'an unknown team push'; Key = 'teamPush'; Value = 'true'; Error = '*cannot push*' }
            @{ Case = 'no main branch'; Key = 'mainSha'; Value = $null; Error = '*has no main branch*' }
            @{ Case = 'other CODEOWNERS'; Key = 'codeOwners'; Value = "* @{org}/other`n"; Error = '*does not name only the security team*' }
            @{ Case = 'CODEOWNERS in another case'; Key = 'codeOwners'; Value = '{CODEOWNERS}'; Error = '*does not name only the security team*' }
            @{ Case = 'missing CODEOWNERS'; Key = 'codeOwners'; Value = $null; Error = '*does not name only the security team*' }
            @{ Case = 'no approval rule'; Key = 'approvalRule'; Value = $false; Error = '*no active rule*' }
            @{ Case = 'an unknown approval rule'; Key = 'approvalRule'; Value = 'true'; Error = '*no active rule*' }
            @{ Case = 'a missing tag'; Key = 'tag'; Value = $null; Error = "*Tag 'v4.2.2' does not exist*" }
            @{ Case = 'a tag of another commit'; Key = 'tag'; Value = @{ Type = 'commit'; Sha = ('f' * 40) }; Error = '*does not point to commit*' }
            @{ Case = 'an annotated tag'; Key = 'tag'; Value = @{ Type = 'tag'; Sha = ('d' * 40) }; Error = '*does not point to commit*' }
            @{ Case = 'a tag type in another case'; Key = 'tag'; Value = @{ Type = 'Commit'; Sha = ('d' * 40) }; Error = '*does not point to commit*' }
            @{ Case = 'a tag SHA in another case'; Key = 'tag'; Value = @{ Type = 'commit'; Sha = ('D' * 40) }; Error = '*does not point to commit*' }
            @{ Case = 'a release reason'; Key = 'release'; Value = @('The receipt records tag v1.'); Error = 'The receipt records tag v1.' }
        ) {
            if ($Value -is [string]) { $Value = $Value.Replace('{org}', $organization).Replace('{CODEOWNERS}', $codeOwners.ToUpperInvariant()) }
            $state[$Key] = $Value

            $violations = @(Get-CatalogStateViolation -State $state -Organization $organization -SecurityTeam $securityTeam -Tag 'v4.2.2' -Commit $release)

            $violations.Count | Should -Be 1
            $violations[0] | Should -BeLike $Error
        }

        It 'reports only the missing repository when it does not exist' {
            $state = @{ repository = $repositoryName; exists = $false }

            @(Get-CatalogStateViolation -State $state -Organization $organization -SecurityTeam $securityTeam -Tag 'v4.2.2' -Commit $release).Count | Should -Be 1
        }
    }

    Context 'ConvertTo-CatalogStateResult' {
        It 'returns the state and violations as JSON strings for the external data source' {
            $result = ConvertTo-CatalogStateResult -State ([ordered]@{ repository = $repositoryName; exists = $false }) -Violation @('a', 'b') | ConvertFrom-Json -AsHashtable

            @($result.Keys | Sort-Object) | Should -Be @('state', 'violations')
            $result.state | Should -BeOfType [string]
            (ConvertFrom-Json $result.violations) | Should -Be @('a', 'b')
        }

        It 'returns an empty violation array' {
            $result = ConvertTo-CatalogStateResult -State ([ordered]@{ exists = $true }) -Violation @() | ConvertFrom-Json -AsHashtable

            $result.violations | Should -BeExactly '[]'
        }
    }
}

Describe 'Actions catalog Terraform programs' {
    BeforeAll {
        $change = Join-Path $scriptRoot 'Invoke-CatalogChange.ps1'
        $read = Join-Path $scriptRoot 'Read-CatalogState.ps1'
        $resourceInput = @{ api_url = 'https://api.example.ghe.com'; organization = 'demo-actions'; upstream = 'actions/checkout'; security_team = 'actions-security' }
    }

    AfterEach {
        Remove-Item Env:\CATALOG_INPUT -ErrorAction SilentlyContinue
    }

    It 'fails the provisioner without input' {
        $output = pwsh -NoProfile -NonInteractive -File $change -Action InitializeRepository 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike '*CATALOG_INPUT is not set*'
    }

    It 'fails the <Action> provisioner without <Key>' -ForEach @(
        @{ Action = 'InitializeRepository'; Key = 'api_url' }
        @{ Action = 'InitializeRepository'; Key = 'organization' }
        @{ Action = 'InitializeRepository'; Key = 'upstream' }
        @{ Action = 'InitializeRepository'; Key = 'security_team' }
        @{ Action = 'CreateReleaseTag'; Key = 'tag' }
        @{ Action = 'CreateReleaseTag'; Key = 'commit' }
    ) {
        $value = $resourceInput.Clone()
        $value.tag = 'v4.2.2'; $value.commit = ('a' * 40)
        $value.Remove($Key)
        $env:CATALOG_INPUT = ConvertTo-Json $value -Compress

        $output = pwsh -NoProfile -NonInteractive -File $change -Action $Action 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike "*no '$Key'*"
    }

    It 'fails the provisioner on an invalid name before any request' {
        $value = $resourceInput.Clone()
        $value.upstream = 'Actions/Checkout'
        $env:CATALOG_INPUT = ConvertTo-Json $value -Compress
        $env:REST_API_BEARER = 'unused'

        try { $output = pwsh -NoProfile -NonInteractive -File $change -Action InitializeRepository 2>&1 }
        finally { Remove-Item Env:\REST_API_BEARER }
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike '*lowercase owner/repository*'
    }

    It 'fails the state reader without <Key>' -ForEach @(
        @{ Key = 'api_url'; Error = "*no 'api_url'*" }
        @{ Key = 'organization'; Error = "*no 'organization'*" }
        @{ Key = 'upstream'; Error = "*no 'upstream'*" }
        @{ Key = 'security_team'; Error = "*no 'security_team'*" }
        @{ Key = 'tag'; Error = "*no string 'tag'*" }
        @{ Key = 'commit'; Error = "*no string 'commit'*" }
    ) {
        $query = $resourceInput.Clone()
        $query.tag = ''; $query.commit = ''
        $query.Remove($Key)

        $output = ConvertTo-Json $query -Compress | pwsh -NoProfile -NonInteractive -File $read 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike $Error
    }

    It 'fails the state reader on a query that is not an object' {
        $output = '[]' | pwsh -NoProfile -NonInteractive -File $read 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike '*not a JSON object*'
    }

    It 'fails the state reader on a tag without a commit' {
        $query = $resourceInput.Clone()
        $query.tag = 'v4.2.2'; $query.commit = ''

        $output = ConvertTo-Json $query -Compress | pwsh -NoProfile -NonInteractive -File $read 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike '*needs both a tag and a commit*'
    }
}
