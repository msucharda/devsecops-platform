BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $scriptRoot = Join-Path (Split-Path (Split-Path $PSScriptRoot -Parent) -Parent) 'modules/organizations/scripts'
    Import-Module (Join-Path $scriptRoot 'Organizations.psm1') -Force

    $apiUrl = 'https://api.example.ghe.com'
    $token = 'test-enterprise-token'
    $enterprise = 'example'
    $target = @{ ApiUrl = $apiUrl; Enterprise = $enterprise }

    function New-OrganizationsStub {
        @{
            Organizations      = [Collections.Generic.List[object]]::new()
            Installations      = @{}
            Requests           = [Collections.Generic.List[object]]::new()
            NextId             = 100
            PageSize           = 100
            EnterpriseVisible  = $true
            # Number of list calls after a mutation before the new organization is listed.
            ListDelay          = 0
            PendingListings    = @{}
            # Operation names whose effect is applied but whose response is lost.
            Drop               = [Collections.Generic.HashSet[string]]::new()
            # Operation name => scriptblock returning @{ Status; Body } instead of the documented response.
            Override           = @{}
        }
    }

    function Add-StubOrganization {
        param([string] $Login, [int] $Id = 0)
        if (-not $Id) { $Id = $stub.NextId++ }
        $stub.Organizations.Add(@{ id = $Id; login = $Login })
        $stub.Installations[$Login.ToLowerInvariant()] = [Collections.Generic.List[object]]::new()
    }

    function Add-StubInstallation {
        param([string] $Organization, [string] $ClientId, [string] $Selection = 'selected')
        $stub.Installations[$Organization.ToLowerInvariant()].Add(@{ id = $stub.NextId++; client_id = $ClientId; repository_selection = $Selection })
    }

    function Get-StubRequest {
        param([string] $Operation)
        , @($stub.Requests | Where-Object { $_.Operation -ceq $Operation })
    }

    function Get-StubPage {
        param([object[]] $Items, [string] $PathAndQuery)
        $page = if ($PathAndQuery -match '[?&]page=(\d+)') { [int] $Matches[1] } else { 1 }
        $slice = @($Items | Select-Object -Skip (($page - 1) * $stub.PageSize) -First $stub.PageSize)
        $link = $null
        if ($Items.Count -gt $page * $stub.PageSize) {
            $base = ($PathAndQuery -replace '[?&]page=\d+', '')
            $separator = if ($base.Contains('?')) { '&' } else { '?' }
            $link = "<$apiUrl$base${separator}page=$($page + 1)>; rel=`"next`""
        }
        @{ Status = 200; Body = (ConvertTo-Json -InputObject $slice -Depth 20 -Compress); Link = $link }
    }

    function Invoke-OrganizationsStub {
        param([string] $Method, [string] $PathAndQuery, [hashtable] $Headers, [AllowNull()][string] $Body)

        $Headers['Authorization'] | Should -BeExactly "Bearer $token"
        $Headers['X-GitHub-Api-Version'] | Should -BeExactly '2026-03-10'
        $Headers['Accept'] | Should -BeExactly 'application/vnd.github+json'
        $path = $PathAndQuery.Split('?')[0]
        $request = if ($Body) { ConvertFrom-Json $Body -AsHashtable } else { $null }
        $operation = switch -Regex ("$Method $path") {
            '^GET /enterprises/[^/]+/apps/installable_organizations$' { 'listOrganizations' }
            '^POST /graphql$' { if ($request.query -match 'createEnterpriseOrganization') { 'createOrganization' } else { 'enterprise' } }
            '^GET /enterprises/[^/]+/apps/organizations/[^/]+/installations$' { 'listInstallations' }
            '^POST /enterprises/[^/]+/apps/organizations/[^/]+/installations$' { 'createInstallation' }
            '^DELETE /enterprises/[^/]+/apps/organizations/[^/]+/installations/\d+$' { 'deleteInstallation' }
            default { throw "Unexpected request $Method $PathAndQuery" }
        }
        $stub.Requests.Add(@{ Operation = $operation; Path = $PathAndQuery; Body = $request })
        if ($stub.Override.Contains($operation)) {
            $reply = & $stub.Override[$operation] $request $PathAndQuery
            return @{ Status = $reply.Status; Body = (ConvertTo-Json -InputObject $reply.Body -Depth 20 -Compress); Link = $null }
        }
        $organization = if ($path -match '/apps/organizations/([^/]+)/') { $Matches[1].ToLowerInvariant() }
        $reply = switch ($operation) {
            'listOrganizations' {
                foreach ($login in @($stub.PendingListings.Keys)) {
                    $stub.PendingListings[$login] -= 1
                    if ($stub.PendingListings[$login] -lt 0) { $stub.PendingListings.Remove($login) }
                }
                $items = @(foreach ($item in $stub.Organizations) {
                        if ($stub.PendingListings.Contains($item.login)) { continue }
                        (Get-GitHubApiFixture -Name enterprise-apps/installable-organizations -Set @{ '0.id' = $item.id; '0.login' = $item.login })[0]
                    })
                Get-StubPage -Items $items -PathAndQuery $PathAndQuery
            }
            'enterprise' {
                $request.variables.slug | Should -BeExactly $enterprise
                $name = if ($stub.EnterpriseVisible) { 'graphql/enterprise' } else { 'graphql/enterprise.not-found' }
                @{ Status = 200; Body = (ConvertTo-Json -InputObject (Get-GitHubApiFixture -Name $name) -Depth 20 -Compress) }
            }
            'createOrganization' {
                $login = $request.variables.input.login
                if (@($stub.Organizations | Where-Object { $_.login -eq $login }).Count) {
                    @{ Status = 200; Body = (ConvertTo-Json -InputObject (Get-GitHubApiFixture -Name graphql/create-enterprise-organization.errors) -Depth 20 -Compress) }
                }
                else {
                    Add-StubOrganization -Login $login
                    if ($stub.ListDelay) { $stub.PendingListings[$login] = $stub.ListDelay }
                    $created = Get-GitHubApiFixture -Name graphql/create-enterprise-organization -Set @{ 'data.createEnterpriseOrganization.organization.login' = $login }
                    @{ Status = 200; Body = (ConvertTo-Json -InputObject $created -Depth 20 -Compress) }
                }
            }
            'listInstallations' {
                if (-not $stub.Installations.Contains($organization)) { @{ Status = 404; Body = '{"message":"Not Found"}' } }
                else {
                    $items = @(foreach ($item in $stub.Installations[$organization]) {
                            (Get-GitHubApiFixture -Name enterprise-apps/organization-installations -Set @{
                                '0.id' = $item.id; '0.client_id' = $item.client_id; '0.repository_selection' = $item.repository_selection
                            })[0]
                        })
                    Get-StubPage -Items $items -PathAndQuery $PathAndQuery
                }
            }
            'createInstallation' {
                $id = $stub.NextId++
                $stub.Installations[$organization].Add(@{ id = $id; client_id = $request.client_id; repository_selection = 'selected' })
                $login = ($stub.Organizations | Where-Object { $_.login -eq $organization }).login
                $created = Get-GitHubApiFixture -Name enterprise-apps/create-installation.account-simple-user -Set @{ id = $id; 'account.login' = $login }
                @{ Status = 201; Body = (ConvertTo-Json -InputObject $created -Depth 20 -Compress) }
            }
            'deleteInstallation' {
                $id = [long] ($path -split '/')[-1]
                $list = $stub.Installations[$organization]
                $item = $list | Where-Object { $_.id -eq $id }
                if ($item) { $null = $list.Remove($item); @{ Status = 204; Body = '' } } else { @{ Status = 404; Body = '{"message":"Not Found"}' } }
            }
        }
        if ($stub.Drop.Contains($operation)) {
            $null = $stub.Drop.Remove($operation)
            throw 'The connection was closed before the response arrived.'
        }
        $reply
    }
}

Describe 'Organizations module against the documented GitHub API' {
    BeforeEach {
        $env:REST_API_BEARER = $token
        $stub = New-OrganizationsStub
        Mock -ModuleName Organizations Start-Sleep {}
        Mock -ModuleName Organizations Invoke-WebRequest {
            $uri = [Uri] $Uri
            "$($uri.Scheme)://$($uri.Authority)" | Should -Be $apiUrl
            $reply = Invoke-OrganizationsStub -Method ([string] $Method).ToUpperInvariant() -PathAndQuery $uri.PathAndQuery -Headers $Headers `
                -Body $PesterBoundParameters['Body']
            [pscustomobject]@{ StatusCode = $reply.Status; Content = $reply.Body; Headers = @{ Link = $reply['Link'] } }
        }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    Context 'Invoke-OrganizationsApi' {
        It 'refuses an API URL that is not an HTTPS origin: <Url>' -ForEach @(
            @{ Url = 'http://api.example.ghe.com' }
            @{ Url = 'https://api.example.ghe.com/api/v3' }
            @{ Url = 'https://user@api.example.ghe.com' }
            @{ Url = 'https://api.example.ghe.com/?x=1' }
            @{ Url = 'api.example.ghe.com' }
        ) {
            { Invoke-OrganizationsApi -ApiUrl $Url -Method GET -Path '/x' } | Should -Throw '*HTTPS origin*'
            Should -Invoke -ModuleName Organizations Invoke-WebRequest -Times 0 -Exactly
        }

        It 'requires the token from the runner' {
            Remove-Item Env:\REST_API_BEARER

            { Get-EnterpriseOrganizationLogin @target } | Should -Throw '*REST_API_BEARER*'
        }

        It 'fails on an undocumented status' {
            $stub.Override['listOrganizations'] = { @{ Status = 403; Body = @{ message = 'Forbidden' } } }

            { Get-EnterpriseOrganizationLogin @target } | Should -Throw '*HTTP 403*installable_organizations*'
        }

        It 'refuses a pagination link outside the API origin' {
            Mock -ModuleName Organizations Invoke-WebRequest {
                [pscustomobject]@{ StatusCode = 200; Content = '[]'; Headers = @{ Link = '<https://evil.example/next>; rel="next"' } }
            }

            { Get-EnterpriseOrganizationLogin @target } | Should -Throw '*outside*'
        }
    }

    Context 'Enterprise organizations' {
        It 'follows pagination of installable organizations' {
            $stub.PageSize = 1
            'demo-a1b2c3-platform', 'demo-a1b2c3-actions', 'other' | ForEach-Object { Add-StubOrganization -Login $_ }

            Get-EnterpriseOrganizationLogin @target | Should -Be @('demo-a1b2c3-platform', 'demo-a1b2c3-actions', 'other')
            (Get-StubRequest listOrganizations).Count | Should -Be 3
        }

        It 'fails closed on an organization with <Case>' -ForEach @(
            @{ Case = 'no id'; Set = @{ '0.id' = $null } }
            @{ Case = 'id zero'; Set = @{ '0.id' = 0 } }
            @{ Case = 'string id'; Set = @{ '0.id' = '1' } }
            @{ Case = 'no login'; Set = @{ '0.login' = $null } }
            @{ Case = 'empty login'; Set = @{ '0.login' = '' } }
            @{ Case = 'login with a path'; Set = @{ '0.login' = 'a/b' } }
        ) {
            $body = Get-GitHubApiFixture -Name enterprise-apps/installable-organizations -Set $Set
            $stub.Override['listOrganizations'] = { @{ Status = 200; Body = $body } }.GetNewClosure()

            { Get-EnterpriseOrganizationLogin @target } | Should -Throw '*organization of enterprise*'
        }

        It 'fails closed on a list that is not a JSON array' {
            # Intentionally invalid: the documented response is an array.
            $stub.Override['listOrganizations'] = { @{ Status = 200; Body = @{ organizations = @() } } }

            { Get-EnterpriseOrganizationLogin @target } | Should -Throw '*no JSON array*'
        }

        It 'finds an organization case-insensitively and returns its actual login' {
            Add-StubOrganization -Login 'Demo-A1B2C3-Actions'

            Find-EnterpriseOrganization @target -Organization 'demo-a1b2c3-actions' | Should -BeExactly 'Demo-A1B2C3-Actions'
            Find-EnterpriseOrganization @target -Organization 'demo-a1b2c3-workloads' | Should -BeNullOrEmpty
        }

        It 'refuses an enterprise listing the organization twice' {
            Add-StubOrganization -Login 'demo-actions'
            Add-StubOrganization -Login 'DEMO-ACTIONS'

            { Find-EnterpriseOrganization @target -Organization 'demo-actions' } | Should -Throw '*more than once*'
        }
    }

    Context 'New-EnterpriseOrganization' {
        BeforeEach {
            $create = @{ Organization = 'demo-a1b2c3-actions'; AdminLogins = @('alice_demo', 'bob_demo'); BillingEmail = 'billing@example.test' }
        }

        It 'creates the organization with the documented mutation input' {
            New-EnterpriseOrganization @target @create | Should -BeExactly 'demo-a1b2c3-actions'

            $mutation = (Get-StubRequest createOrganization)[0].Body
            $mutation.variables.input.enterpriseId | Should -BeExactly 'E_kgDOAAAAAQ'
            $mutation.variables.input.login | Should -BeExactly 'demo-a1b2c3-actions'
            $mutation.variables.input.profileName | Should -BeExactly 'demo-a1b2c3-actions'
            $mutation.variables.input.billingEmail | Should -BeExactly 'billing@example.test'
            $mutation.variables.input.adminLogins | Should -Be @('alice_demo', 'bob_demo')
            $mutation.query | Should -Match 'organization \{ id login \}'
        }

        It 'fails closed on a taken name <Login> without adoption' -ForEach @(
            @{ Login = 'demo-a1b2c3-actions' }
            @{ Login = 'DEMO-A1B2C3-ACTIONS' }
        ) {
            Add-StubOrganization -Login $Login

            { New-EnterpriseOrganization @target @create } | Should -Throw '*already exists*adopt_organizations*new identifier*'
            (Get-StubRequest createOrganization).Count | Should -Be 0
        }

        It 'adopts an existing organization only with AllowExisting' {
            Add-StubOrganization -Login 'demo-a1b2c3-actions'

            New-EnterpriseOrganization @target @create -AllowExisting | Should -BeExactly 'demo-a1b2c3-actions'
            (Get-StubRequest enterprise).Count | Should -Be 0
            (Get-StubRequest createOrganization).Count | Should -Be 0
        }

        It 'recovers when the run ends between the mutation and its response' {
            $null = $stub.Drop.Add('createOrganization')

            { New-EnterpriseOrganization @target @create -AllowExisting } | Should -Throw '*connection was closed*'
            New-EnterpriseOrganization @target @create -AllowExisting | Should -BeExactly 'demo-a1b2c3-actions'

            (Get-StubRequest createOrganization).Count | Should -Be 1
        }

        It 'refuses to create without an owner or billing email: <Case>' -ForEach @(
            @{ Case = 'no owner'; Change = @{ AdminLogins = @() }; Message = '*admin_logins*' }
            @{ Case = 'empty owner'; Change = @{ AdminLogins = @('alice_demo', '') }; Message = '*admin_logins*' }
            @{ Case = 'empty billing email'; Change = @{ BillingEmail = '' }; Message = '*billing_email*' }
        ) {
            foreach ($key in $Change.Keys) { $create[$key] = $Change[$key] }

            { New-EnterpriseOrganization @target @create } | Should -Throw $Message
            Should -Invoke -ModuleName Organizations Invoke-WebRequest -Times 0 -Exactly
        }

        It 'fails closed when the enterprise is not visible to the token' {
            $stub.EnterpriseVisible = $false

            { New-EnterpriseOrganization @target @create } | Should -Throw "*rejected query enterprise*Could not resolve*"
            (Get-StubRequest createOrganization).Count | Should -Be 0
        }

        It 'fails closed on an enterprise without <Case>' -ForEach @(
            @{ Case = 'id'; Value = $null }
            @{ Case = 'non-empty id'; Value = '' }
        ) {
            $body = Get-GitHubApiFixture -Name graphql/enterprise -Set @{ 'data.enterprise.id' = $Value }
            $stub.Override['enterprise'] = { @{ Status = 200; Body = $body } }.GetNewClosure()

            { New-EnterpriseOrganization @target @create } | Should -Throw '*not visible*'
            (Get-StubRequest createOrganization).Count | Should -Be 0
        }

        It 'fails closed on a null enterprise without errors' {
            $body = Get-GitHubApiFixture -Name graphql/enterprise -Set @{ 'data.enterprise' = $null }
            $stub.Override['enterprise'] = { @{ Status = 200; Body = $body } }.GetNewClosure()

            { New-EnterpriseOrganization @target @create } | Should -Throw '*not visible*'
        }

        It 'fails on mutation errors returned with HTTP 200' {
            $stub.Override['createOrganization'] = { @{ Status = 200; Body = (Get-GitHubApiFixture -Name graphql/create-enterprise-organization.errors) } }

            { New-EnterpriseOrganization @target @create } | Should -Throw '*rejected mutation createEnterpriseOrganization*Login has already been taken*'
        }

        It 'fails on <Case> in a GraphQL response' -ForEach @(
            @{ Case = 'an empty errors list'; Set = @{ errors = @() }; Error = '*empty errors list*' }
            @{ Case = 'an error without message'; Set = @{ 'errors.0.message' = $null }; Error = '*unreadable error*' }
            @{ Case = 'no data'; Set = @{ data = $null; errors = $null }; Error = '*no data*' }
        ) {
            $body = Get-GitHubApiFixture -Name graphql/create-enterprise-organization.errors -Set $Set
            $stub.Override['createOrganization'] = { @{ Status = 200; Body = $body } }.GetNewClosure()

            { New-EnterpriseOrganization @target @create } | Should -Throw $Error
        }

        It 'fails when the mutation does not confirm the organization: <Case>' -ForEach @(
            @{ Case = 'null organization'; Set = @{ 'data.createEnterpriseOrganization.organization' = $null } }
            @{ Case = 'null payload'; Set = @{ 'data.createEnterpriseOrganization' = $null } }
            @{ Case = 'other login'; Set = @{ 'data.createEnterpriseOrganization.organization.login' = 'demo-a1b2c3-workloads' } }
            @{ Case = 'empty id'; Set = @{ 'data.createEnterpriseOrganization.organization.id' = '' } }
            @{ Case = 'no login'; Set = @{ 'data.createEnterpriseOrganization.organization.login' = $null } }
        ) {
            $body = Get-GitHubApiFixture -Name graphql/create-enterprise-organization -Set $Set
            $stub.Override['createOrganization'] = { @{ Status = 200; Body = $body } }.GetNewClosure()

            { New-EnterpriseOrganization @target @create } | Should -Throw '*did not confirm*'
        }

        It 'waits until the created organization is listed' {
            $stub.ListDelay = 2

            New-EnterpriseOrganization @target @create | Should -BeExactly 'demo-a1b2c3-actions'
            Should -Invoke -ModuleName Organizations Start-Sleep -Times 2 -Exactly
        }

        It 'fails when the created organization never appears in the enterprise' {
            $stub.ListDelay = 50

            { New-EnterpriseOrganization @target @create -VisibilityAttempts 3 } | Should -Throw '*not listed*'
        }
    }

    Context 'Assert-EnterpriseOrganizationRemoved' {
        It 'passes when the organization does not exist' {
            Add-StubOrganization -Login 'demo-a1b2c3-platform'

            { Assert-EnterpriseOrganizationRemoved @target -Organization 'demo-a1b2c3-actions' } | Should -Not -Throw
        }

        It 'fails while the organization <Login> exists and points to the manual step' -ForEach @(
            @{ Login = 'demo-a1b2c3-actions' }
            @{ Login = 'Demo-A1B2C3-Actions' }
        ) {
            Add-StubOrganization -Login $Login

            { Assert-EnterpriseOrganizationRemoved @target -Organization 'demo-a1b2c3-actions' } |
                Should -Throw '*still exists*delete-instance-organizations*'
        }

        It 'fails when the enterprise cannot be read' {
            $stub.Override['listOrganizations'] = { @{ Status = 401; Body = @{ message = 'Bad credentials' } } }

            { Assert-EnterpriseOrganizationRemoved @target -Organization 'demo-a1b2c3-actions' } | Should -Throw '*HTTP 401*'
        }
    }

    Context 'App installations' {
        BeforeEach {
            Add-StubOrganization -Login 'demo-a1b2c3-actions'
            $install = @{ Organization = 'demo-a1b2c3-actions'; ClientId = 'Iv23liExample01' }
        }

        It 'installs the App without repository access' {
            $installation = Install-OrganizationApp @target @install

            $installation.client_id | Should -BeExactly 'Iv23liExample01'
            $body = (Get-StubRequest createInstallation)[0].Body
            $body.Keys | Sort-Object | Should -Be @('client_id', 'repository_selection')
            $body.client_id | Should -BeExactly 'Iv23liExample01'
            $body.repository_selection | Should -BeExactly 'none'
        }

        It 'does not reinstall an App that is installed with <Selection> access' -ForEach @(
            @{ Selection = 'selected' }
            @{ Selection = 'none' }
        ) {
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01' -Selection $Selection

            (Install-OrganizationApp @target @install).repository_selection | Should -BeExactly $Selection
            (Get-StubRequest createInstallation).Count | Should -Be 0
        }

        It 'refuses an existing installation with access to all repositories' {
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01' -Selection 'all'

            { Install-OrganizationApp @target @install } | Should -Throw '*all repositories*'
        }

        It 'matches the client ID case-sensitively' {
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'IV23LIEXAMPLE01'

            $null = Install-OrganizationApp @target @install
            (Get-StubRequest createInstallation).Count | Should -Be 1
        }

        It 'recovers when the run ends between the installation and its response' {
            $null = $stub.Drop.Add('createInstallation')

            { Install-OrganizationApp @target @install } | Should -Throw '*connection was closed*'
            $null = Install-OrganizationApp @target @install

            (Get-StubRequest createInstallation).Count | Should -Be 1
        }

        It 'refuses the documented enterprise account variant' {
            $stub.Override['createInstallation'] = { @{ Status = 201; Body = (Get-GitHubApiFixture -Name enterprise-apps/create-installation.account-enterprise) } }

            { Install-OrganizationApp @target @install } | Should -Throw '*does not belong to organization*'
        }

        It 'refuses an installation response with <Case>' -ForEach @(
            @{ Case = 'another organization'; Set = @{ 'account.login' = 'other-org' }; Error = '*does not belong*' }
            @{ Case = 'a user account'; Set = @{ 'account.login' = 'demo-a1b2c3-actions'; 'account.type' = 'User' }; Error = '*does not belong*' }
            @{ Case = 'no account'; Set = @{ account = $null }; Error = '*does not belong*' }
            @{ Case = 'a user target'; Set = @{ 'account.login' = 'demo-a1b2c3-actions'; target_type = 'User' }; Error = '*targets*' }
            @{ Case = 'all repositories'; Set = @{ 'account.login' = 'demo-a1b2c3-actions'; repository_selection = 'all' }; Error = '*instead of no repository access*' }
            @{ Case = 'no repository selection'; Set = @{ 'account.login' = 'demo-a1b2c3-actions'; repository_selection = $null }; Error = '*instead of no repository access*' }
            @{ Case = 'no id'; Set = @{ 'account.login' = 'demo-a1b2c3-actions'; id = $null }; Error = '*no valid ID*' }
        ) {
            $body = Get-GitHubApiFixture -Name enterprise-apps/create-installation.account-simple-user -Set $Set
            $stub.Override['createInstallation'] = { @{ Status = 201; Body = $body } }.GetNewClosure()

            { Install-OrganizationApp @target @install } | Should -Throw $Error
        }

        It 'fails when the installation is not listed afterwards' {
            $body = Get-GitHubApiFixture -Name enterprise-apps/create-installation.account-simple-user -Set @{ 'account.login' = 'demo-a1b2c3-actions' }
            $stub.Override['createInstallation'] = { @{ Status = 201; Body = $body } }.GetNewClosure()

            { Install-OrganizationApp @target @install } | Should -Throw '*is not listed*'
        }

        It 'refuses an invalid client ID <ClientId> before any request' -ForEach @(
            @{ ClientId = '' }
            @{ ClientId = 'Iv1/../x' }
            @{ ClientId = "Iv1`n" }
        ) {
            { Install-OrganizationApp @target -Organization 'demo-a1b2c3-actions' -ClientId $ClientId } | Should -Throw '*not valid*'
            Should -Invoke -ModuleName Organizations Invoke-WebRequest -Times 0 -Exactly
        }

        It 'fails closed on a listed installation with <Case>' -ForEach @(
            @{ Case = 'no client_id'; Set = @{ '0.client_id' = $null }; Error = '*no client_id*' }
            @{ Case = 'empty client_id'; Set = @{ '0.client_id' = '' }; Error = '*no client_id*' }
            @{ Case = 'unknown selection'; Set = @{ '0.repository_selection' = 'some' }; Error = '*unknown repository_selection*' }
            @{ Case = 'selection in other case'; Set = @{ '0.repository_selection' = 'Selected' }; Error = '*unknown repository_selection*' }
            @{ Case = 'no selection'; Set = @{ '0.repository_selection' = $null }; Error = '*unknown repository_selection*' }
            @{ Case = 'no id'; Set = @{ '0.id' = $null }; Error = '*no valid ID*' }
        ) {
            $body = Get-GitHubApiFixture -Name enterprise-apps/organization-installations -Set $Set
            $stub.Override['listInstallations'] = { @{ Status = 200; Body = $body } }.GetNewClosure()

            { Install-OrganizationApp @target @install } | Should -Throw $Error
        }

        It 'refuses a duplicate installation of the same App' {
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01'
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01'

            { Install-OrganizationApp @target @install } | Should -Throw '*more than one installation*'
        }

        It 'removes the installation' {
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01'
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liOther0001'

            Uninstall-OrganizationApp @target @install

            (Get-StubRequest deleteInstallation).Count | Should -Be 1
            $stub.Installations['demo-a1b2c3-actions'].client_id | Should -Be @('Iv23liOther0001')
        }

        It 'treats an absent <Case> as removed' -ForEach @(
            @{ Case = 'organization'; Organization = 'demo-a1b2c3-workloads' }
            @{ Case = 'installation'; Organization = 'demo-a1b2c3-actions' }
        ) {
            Uninstall-OrganizationApp @target -Organization $Organization -ClientId 'Iv23liExample01'

            (Get-StubRequest deleteInstallation).Count | Should -Be 0
        }

        It 'treats a documented 404 on removal as removed' {
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01'
            $stub.Override['deleteInstallation'] = {
                $stub.Installations['demo-a1b2c3-actions'].Clear()
                @{ Status = 404; Body = @{ message = 'Not Found' } }
            }

            { Uninstall-OrganizationApp @target @install } | Should -Not -Throw
        }

        It 'fails when removal is <Case>' -ForEach @(
            @{ Case = 'forbidden'; Status = 403; Error = '*HTTP 403*' }
            @{ Case = 'not effective'; Status = 204; Error = '*still installed*' }
        ) {
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01'
            $status = $Status
            $stub.Override['deleteInstallation'] = { @{ Status = $status; Body = $null } }.GetNewClosure()

            { Uninstall-OrganizationApp @target @install } | Should -Throw $Error
        }
    }

    Context 'Get-InstanceOrganizationState' {
        It 'reports an absent organization' {
            $state = Get-InstanceOrganizationState @target -Organization 'demo-a1b2c3-actions'

            $state.exists | Should -BeFalse
            @($state.installations).Count | Should -Be 0
        }

        It 'reports the installed Apps of an existing organization' {
            Add-StubOrganization -Login 'demo-a1b2c3-actions'
            Add-StubInstallation -Organization 'demo-a1b2c3-actions' -ClientId 'Iv23liExample01' -Selection 'none'

            $state = Get-InstanceOrganizationState @target -Organization 'demo-a1b2c3-actions'

            $state.exists | Should -BeTrue
            $state.login | Should -BeExactly 'demo-a1b2c3-actions'
            $state.installations[0].client_id | Should -BeExactly 'Iv23liExample01'
            $state.installations[0].repository_selection | Should -BeExactly 'none'
        }
    }
}

Describe 'Organizations Terraform programs' {
    BeforeAll {
        $change = Join-Path $scriptRoot 'Invoke-OrganizationChange.ps1'
        $read = Join-Path $scriptRoot 'Read-OrganizationState.ps1'
    }

    AfterEach {
        Remove-Item Env:\ORGANIZATIONS_INPUT -ErrorAction SilentlyContinue
    }

    It 'fails the provisioner without <Case>' -ForEach @(
        @{ Case = 'input'; ResourceInput = $null; Error = '*ORGANIZATIONS_INPUT is not set*' }
        @{ Case = 'admin_logins'; ResourceInput = @{ api_url = 'https://api.example.ghe.com'; enterprise = 'example'; organization = 'demo-actions'; billing_email = 'b@example.test'; allow_existing = $false }; Error = "*no 'admin_logins'*" }
        @{ Case = 'billing_email'; ResourceInput = @{ api_url = 'https://api.example.ghe.com'; enterprise = 'example'; organization = 'demo-actions'; admin_logins = @('a_demo'); allow_existing = $false }; Error = "*no 'billing_email'*" }
        @{ Case = 'boolean allow_existing'; ResourceInput = @{ api_url = 'https://api.example.ghe.com'; enterprise = 'example'; organization = 'demo-actions'; admin_logins = @('a_demo'); billing_email = 'b@example.test'; allow_existing = 'true' }; Error = "*boolean 'allow_existing'*" }
    ) {
        if ($ResourceInput) { $env:ORGANIZATIONS_INPUT = ConvertTo-Json $ResourceInput -Compress }

        $output = pwsh -NoProfile -NonInteractive -File $change -Action CreateOrganization 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike $Error
    }

    It 'fails the App provisioner without a client_id' {
        $env:ORGANIZATIONS_INPUT = ConvertTo-Json @{ api_url = 'https://api.example.ghe.com'; enterprise = 'example'; organization = 'demo-actions' } -Compress

        $output = pwsh -NoProfile -NonInteractive -File $change -Action InstallApp 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike "*no 'client_id'*"
    }

    It 'fails the state reader without <Key>' -ForEach @(
        @{ Key = 'api_url' }
        @{ Key = 'enterprise' }
        @{ Key = 'organization' }
    ) {
        $query = @{ api_url = 'https://api.example.ghe.com'; enterprise = 'example'; organization = 'demo-actions' }
        $query.Remove($Key)

        $output = ConvertTo-Json $query -Compress | pwsh -NoProfile -NonInteractive -File $read 2>&1
        $LASTEXITCODE | Should -Be 1
        ($output -join "`n") | Should -BeLike "*no '$Key'*"
    }
}
