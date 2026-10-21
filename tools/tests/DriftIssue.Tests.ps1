BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $publisher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Publish-DriftIssue.ps1'
    $marker = '<!-- platform-drift-report -->'

    function Get-ListedIssue {
        [CmdletBinding()]
        param([int] $Number, [string] $Login, [string] $Type, [string] $Body, [switch] $PullRequest)

        $name = if ($PullRequest) { 'issues/list-for-repo' } else { 'issues/list-for-repo.issue' }
        $item = (Get-GitHubApiFixture -Name $name -Set @{ '0.number' = $Number; '0.user.login' = $Login; '0.user.type' = $Type; '0.body' = $Body })[0]
        return , $item
    }
}

Describe 'Drift issue publication' {
    BeforeEach {
        $reportPath = Join-Path $TestDrive "$([guid]::NewGuid()).md"
        [IO.File]::WriteAllText($reportPath, "$marker`n## Infrastructure drift`n")
        $arguments = @{
            ReportPath = $reportPath
            TokensJson = '{"platform":"issue-token"}'
            AppSlug = 'octoapp'
            Repository = 'platform/instance'
            ApiUrl = 'https://api.example.test'
        }
        $listed = @(
            (Get-ListedIssue -Number 5 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nold" -PullRequest)
            (Get-ListedIssue -Number 6 -Login 'mona' -Type 'User' -Body "$marker`nforged")
            (Get-ListedIssue -Number 7 -Login 'other[bot]' -Type 'Bot' -Body "$marker`nforeign App")
            (Get-ListedIssue -Number 8 -Login 'octoapp[bot]' -Type 'Bot' -Body 'Unrelated App issue')
        )
        $created = Get-GitHubApiFixture -Name issues/create -Set @{ number = 41; 'user.login' = 'octoapp[bot]'; 'user.type' = 'Bot' }
        $updated = Get-GitHubApiFixture -Name issues/update -Set @{ number = 9; 'user.login' = 'octoapp[bot]'; 'user.type' = 'Bot' }
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Method -eq 'GET' -and $Uri -eq 'https://api.example.test/repos/platform/instance/issues?state=open&per_page=100&page=1') { return , $listed }
            if ($Method -eq 'GET' -and $Uri -like 'https://api.example.test/repos/platform/instance/issues?state=open&per_page=100&page=*') { return , @() }
            if ($Method -eq 'POST' -and $Uri -eq 'https://api.example.test/repos/platform/instance/issues') { return $created }
            if ($Method -eq 'PATCH' -and $Uri -eq 'https://api.example.test/repos/platform/instance/issues/9') { return $updated }
            throw "Unexpected GitHub API request: $Method $Uri"
        }
    }

    It 'opens a new drift issue when the App has no open drift issue' {
        $result = & $publisher @arguments

        $result.Action | Should -Be 'created'
        $result.Number | Should -Be 41
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Headers['Authorization'] -eq 'Bearer issue-token' -and
            $Headers['X-GitHub-Api-Version'] -eq '2026-03-10' -and $MaximumRetryCount -eq 0 -and
            ($Body | ConvertFrom-Json -AsHashtable).title -eq 'Infrastructure drift detected' -and
            ($Body | ConvertFrom-Json -AsHashtable).body -ceq "$marker`n## Infrastructure drift`n" -and
            @(($Body | ConvertFrom-Json -AsHashtable).Keys).Count -eq 2
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'updates the single open drift issue of the App instead of opening another one' {
        $listed += Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nprevious"

        $result = & $publisher @arguments

        $result.Action | Should -Be 'updated'
        $result.Number | Should -Be 9
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PATCH' -and @(($Body | ConvertFrom-Json -AsHashtable).Keys) -join ',' -eq 'body'
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'recovers from a lost creation response by updating the issue on the next run' {
        Mock Invoke-RestMethod { throw 'connection reset' } -ParameterFilter { $Method -eq 'POST' }

        { & $publisher @arguments } | Should -Throw '*POST /repos/platform/instance/issues failed*connection reset*'

        $listed += Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`ncreated before the response was lost"
        $result = & $publisher @arguments

        $result.Action | Should -Be 'updated'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
    }

    It 'pages through open issues until an empty page before deciding to create one' {
        $fullPage = @(1..100 | ForEach-Object { Get-ListedIssue -Number (100 + $_) -Login 'mona' -Type 'User' -Body 'other' })
        Mock Invoke-RestMethod { return , $fullPage } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*page=1' }
        Mock Invoke-RestMethod { return , @(Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nold") } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*page=2' }

        $result = & $publisher @arguments

        $result.Action | Should -Be 'updated'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*page=3' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -like '*page=4' }
    }

    It 'continues after a short page and finds the drift issue on the next page' {
        Mock Invoke-RestMethod { return , @(Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nold") } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*page=2' }

        $result = & $publisher @arguments

        $result.Action | Should -Be 'updated'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'skips issues whose author is the documented null user' {
        $listed += (Get-GitHubApiFixture -Name issues/list-for-repo.issue -Set @{ '0.number' = 12; '0.user' = $null; '0.body' = "$marker`nghost" })[0]
        $listed += (Get-GitHubApiFixture -Name issues/list-for-repo -Set @{ '0.number' = 13; '0.user' = $null })[0]
        $listed += Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nprevious"

        $result = & $publisher @arguments

        $result.Action | Should -Be 'updated'
        $result.Number | Should -Be 9
    }

    It 'refuses to choose between duplicate drift issues' {
        $listed += Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nfirst"
        $listed += Get-ListedIssue -Number 10 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nsecond"

        { & $publisher @arguments } | Should -Throw '*more than one open drift issue*#9*#10*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
    }

    It 'fails closed when <Case>' -ForEach @(
        @{ Case = 'listing issues fails'; Filter = { $Method -eq 'GET' }; Response = { throw 'list unavailable' }; Error = '*GET /repos/platform/instance/issues*failed*' }
        @{ Case = 'a list item is not an object'; Filter = { $Method -eq 'GET' -and $Uri -like '*page=1' }; Response = { return , @('text') }; Error = '*unknown issue list item*' }
        # Intentionally invalid: a non-null author that is not a simple user object.
        @{ Case = 'an author is not an object'; Filter = { $Method -eq 'GET' -and $Uri -like '*page=1' }; Response = { return , @(@{ number = 3; user = 'octoapp[bot]'; body = 'x' }) }; Error = '*issue author without a readable login and type*' }
        # Intentionally invalid: the documented schema requires the user field.
        @{ Case = 'an item has no user field'; Filter = { $Method -eq 'GET' -and $Uri -like '*page=1' }; Response = { return , @(@{ number = 3; body = 'x' }) }; Error = '*unknown issue list item*' }
        @{ Case = 'the list never ends'; Filter = { $Method -eq 'GET' }; Response = { return , @(Get-ListedIssue -Number 3 -Login 'mona' -Type 'User' -Body 'x') }; Error = '*within 1000 pages*' }
        @{ Case = 'the created item has no issue number'; Filter = { $Method -eq 'POST' }; Response = { Get-GitHubApiFixture -Name issues/create -Set @{ number = 'x' } }; Error = '*POST did not return an open issue*' }
        @{ Case = 'the created issue is closed'; Filter = { $Method -eq 'POST' }; Response = { Get-GitHubApiFixture -Name issues/create -Set @{ number = 41; state = 'closed' } }; Error = '*POST did not return an open issue*' }
    ) {
        Mock Invoke-RestMethod $Response -ParameterFilter $Filter

        { & $publisher @arguments } | Should -Throw $Error
    }

    It 'fails closed when the update response identifies another issue' {
        $listed += Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nprevious"
        $updated.number = 999

        { & $publisher @arguments } | Should -Throw '*PATCH did not return an open issue*'
    }

    It 'fails closed without creating an issue when an author has <Case>' -ForEach @(
        @{ Case = 'no login'; Change = { param($Item) $Item.user.Remove('login') } }
        @{ Case = 'an empty login'; Change = { param($Item) $Item.user.login = '' } }
        @{ Case = 'no type'; Change = { param($Item) $Item.user.Remove('type') } }
        @{ Case = 'an empty type'; Change = { param($Item) $Item.user.type = '' } }
        @{ Case = 'an unreadable type'; Change = { param($Item) $Item.user.type = @{ name = 'Bot' } } }
    ) {
        $item = Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nprevious"
        & $Change $item
        $listed += $item

        { & $publisher @arguments } | Should -Throw '*issue author without a readable login and type*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
    }

    It 'shortens a report above the GitHub issue body limit and points to the run summary' {
        [IO.File]::WriteAllText($reportPath, "$marker`n" + ('x' * 70000))

        $null = & $publisher @arguments

        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and ($Body | ConvertFrom-Json -AsHashtable).body.Length -le 65536 -and
            ($Body | ConvertFrom-Json -AsHashtable).body.StartsWith($marker) -and
            ($Body | ConvertFrom-Json -AsHashtable).body -match 'truncated.*job summary'
        }
    }

    It 'requires <Case> before any API request' -ForEach @(
        @{ Case = 'a token for the instance owner'; Name = 'TokensJson'; Value = '{"other":"token"}' }
        @{ Case = 'a token map'; Name = 'TokensJson'; Value = '' }
        @{ Case = 'a valid App slug'; Name = 'AppSlug'; Value = 'octoapp[bot]' }
        @{ Case = 'an empty App slug'; Name = 'AppSlug'; Value = '' }
        @{ Case = 'the instance repository owner/name'; Name = 'Repository'; Value = 'platform' }
        @{ Case = 'an HTTPS API URL'; Name = 'ApiUrl'; Value = 'http://api.example.test' }
    ) {
        $arguments[$Name] = $Value

        { & $publisher @arguments } | Should -Throw '*Drift issue publication requires*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'requires the marked drift report' {
        [IO.File]::WriteAllText($reportPath, '## Infrastructure drift')

        { & $publisher @arguments } | Should -Throw '*drift report marker*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }
}
