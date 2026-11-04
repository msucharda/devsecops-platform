BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $publisher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Publish-DriftIssue.ps1'
    $marker = '<!-- platform-drift-report -->'
    $workflowRef = 'platform/instance/.github/workflows/drift.yml@refs/heads/main'

    function Get-TestDriftReport {
        param([string] $RunNumber = '20', [string] $Revision = ('a' * 40),
            [string] $Workflow = $workflowRef, [string] $Message = 'previous')

        return "$marker`n<!-- platform-drift-run:$Workflow|$RunNumber -->`nRevision: ``$Revision```n$Message`n"
    }

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
            ContentsToken = 'read-token'
            WorkflowRef = $workflowRef
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
            if ($Method -eq 'PATCH' -and $Uri -eq 'https://api.example.test/repos/platform/instance/issues/9') { return , $updated }
            throw "Unexpected GitHub API request: $Method $Uri"
        }
        Mock Invoke-RestMethod { return , @() } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/issues?state=closed&*' }
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

    It 'comments on the clean result before closing the single open drift issue of the App' {
        $listed += Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body (Get-TestDriftReport)
        [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 21 -Message 'No drift detected in the automatically planned resources.'))
        Mock Invoke-RestMethod { Get-GitHubApiFixture -Name git/get-ref -Set @{ ref = 'refs/heads/main'; 'object.sha' = ('a' * 40) } } `
            -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/git/ref/heads/main' }
        $updated.state = 'closed'
        $writes = [Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod { return , @() } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/issues/9/comments?*' }
        Mock Invoke-RestMethod {
            $writes.Add('comment')
            Get-GitHubApiFixture -Name issues/create-comment -Set @{ body = ($Body | ConvertFrom-Json -AsHashtable).body }
        } -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/issues/9/comments' }
        Mock Invoke-RestMethod {
            $writes.Add('close')
            $updated
        } -ParameterFilter { $Method -eq 'PATCH' }

        $result = & $publisher @arguments -Outcome Clean

        $result.Action | Should -Be 'closed'
        $result.Number | Should -Be 9
        $writes -join ',' | Should -BeExactly 'comment,close'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and $Uri -like '*/issues/9/comments' -and
            ($Body | ConvertFrom-Json -AsHashtable).body -match 'No drift detected'
        }
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'PATCH' -and ($Body | ConvertFrom-Json -AsHashtable).state -ceq 'closed' -and
            ($Body | ConvertFrom-Json -AsHashtable).state_reason -ceq 'completed' -and
            -not ($Body | ConvertFrom-Json -AsHashtable).Contains('body')
        }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/issues' }
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
        $listed += (Get-GitHubApiFixture -Name issues/list-for-repo.issue -Set @{ '0.number' = 12; '0.user' = $null; '0.body' = 'Unrelated issue' })[0]
        $listed += (Get-GitHubApiFixture -Name issues/list-for-repo -Set @{ '0.number' = 13; '0.user' = $null })[0]
        $listed += Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body "$marker`nprevious"

        $result = & $publisher @arguments

        $result.Action | Should -Be 'updated'
        $result.Number | Should -Be 9
    }

    It 'fails closed on a marker-bearing open issue with the documented null author' -Tag 'ReviewTwo' {
        $listed += (Get-GitHubApiFixture -Name issues/list-for-repo.issue -Set @{ '0.user' = $null; '0.body' = "$marker`nghost" })[0]

        { & $publisher @arguments } | Should -Throw '*Cannot verify the author*drift issue*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
    }

    It 'rejects a singleton array masquerading as an issue author login' {
        $issue = Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body (Get-TestDriftReport)
        # Deliberately invalid: Simple User login is a scalar string.
        $issue.user.login = @('octoapp[bot]')
        $listed += $issue

        { & $publisher @arguments } | Should -Throw '*issue author without a readable login and type*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
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
    ) {
        Mock Invoke-RestMethod $Response -ParameterFilter $Filter

        { & $publisher @arguments } | Should -Throw $Error
    }

    It 'fails closed when the created response is not an open issue: <Case>' -ForEach @(
        @{ Case = 'no issue number'; Response = { Get-GitHubApiFixture -Name issues/create -Set @{ number = 'x' } } }
        @{ Case = 'a closed issue'; Response = { Get-GitHubApiFixture -Name issues/create -Set @{ number = 41; state = 'closed' } } }
        @{ Case = 'a state in another case'; Response = { Get-GitHubApiFixture -Name issues/create -Set @{ number = 41; state = 'OPEN' } } }
        # Intentionally invalid: the documented response is an issue object, not a list.
        @{ Case = 'not an object'; Response = { return , @(41) } }
        @{ Case = 'a pull request'; Response = { $issue = Get-GitHubApiFixture -Name issues/create -Set @{ number = 41 }; $issue.pull_request = @{ url = 'https://api.example.ghe.com/repos/platform/instance/pulls/41' }; $issue } }
    ) {
        Mock Invoke-RestMethod $Response -ParameterFilter { $Method -eq 'POST' }

        { & $publisher @arguments } | Should -Throw '*POST did not return an open issue*'
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

    It 'rejects an invalid outcome before any API request: <Value>' -ForEach @(
        @{ Value = '' }, @{ Value = 'clean' }, @{ Value = 'unknown' }
    ) {
        { & $publisher @arguments -Outcome $Value } | Should -Throw '*Outcome*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    Context 'Resolved report recovery' -Tag 'ResolvedDrift' {
        BeforeEach {
            $resolved = Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body (Get-TestDriftReport)
            $resolved.state = 'closed'
            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($resolved.body))).ToLowerInvariant()
            $resolutionMarker = "<!-- platform-drift-clean:${digest}:21:$('a' * 40) -->"
            $resolvedComments = Get-GitHubApiFixture -Name issues/list-comments -Set @{
                '0.body' = "$resolutionMarker`n$(Get-TestDriftReport -RunNumber 21)"
                '0.user.login' = 'octoapp[bot]'; '0.user.type' = 'Bot'
            }
            Mock Invoke-RestMethod { return , @($resolved) } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/issues?state=closed&*page=1' }
            Mock Invoke-RestMethod {
                if ($Uri -like '*page=1') { return , $resolvedComments }
                return , @()
            } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/issues/9/comments?*' }
        }

        It 'does not recreate a report already resolved by run 21: <RunNumber>' -ForEach @(
            @{ RunNumber = '20' }, @{ RunNumber = '21' }
        ) {
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber $RunNumber))
            { & $publisher @arguments } | Should -Throw '*report was already resolved*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'allows a new drift run after the recorded clean resolution' {
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))
            (& $publisher @arguments).Action | Should -BeExactly 'created'
        }

        It 'allows a new report after a manually closed legacy issue' {
            $resolved.body = "$marker`nlegacy"
            $resolvedComments = @()
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))
            (& $publisher @arguments).Action | Should -BeExactly 'created'
        }

        It 'allows a legacy report after a manually closed legacy issue without resolution evidence' {
            $resolved.body = "$marker`nlegacy"
            $resolvedComments = @()

            (& $publisher @arguments).Action | Should -BeExactly 'created'
        }

        It 'does not recreate a manually closed report in the same run' {
            $resolvedComments = @()
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 20))
            { & $publisher @arguments } | Should -Throw '*report was already resolved*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'does not trust a resolution marker posted by another App' {
            $resolvedComments[0].user.login = 'other[bot]'
            $resolvedComments[0].body = "<!-- platform-drift-clean:${digest}:99:$('a' * 40) -->`nother"
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))
            (& $publisher @arguments).Action | Should -BeExactly 'created'
        }

        It 'ignores malformed resolution metadata from a known non-App author: <Login>' -Tag 'ReviewTwo' -ForEach @(
            @{ Login = 'other[bot]'; Type = 'Bot' }
            @{ Login = 'mona'; Type = 'User' }
        ) {
            $resolvedComments[0].user.login = $Login
            $resolvedComments[0].user.type = $Type
            $resolvedComments[0].body = "<!-- platform-drift-clean:${digest}:invalid:$('a' * 40) -->`nother"
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))

            (& $publisher @arguments).Action | Should -BeExactly 'created'
        }

        It 'fails closed on a marker-bearing closed issue with the documented null author' -Tag 'ReviewTwo' {
            $resolved.user = $null
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))

            { & $publisher @arguments } | Should -Throw '*Cannot verify the author*drift issue*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'preserves the newer resolution counter after editing the resolved body' -Tag 'ReviewTwo' {
            $resolvedComments[0].body = "<!-- platform-drift-clean:${digest}:30:$('a' * 40) -->`n$(Get-TestDriftReport -RunNumber 30)"
            $resolved.body += "`nOperator note."
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))

            { & $publisher @arguments } | Should -Throw '*report was already resolved*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'preserves resolution evidence after removing metadata from the resolved body' -Tag 'CheckpointFour' {
            $resolvedComments[0].body = "<!-- platform-drift-clean:${digest}:30:$('a' * 40) -->`n$(Get-TestDriftReport -RunNumber 30)"
            $resolved.body = "$marker`nOperator replaced the old report."
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))

            { & $publisher @arguments } | Should -Throw '*report was already resolved*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'rejects a legacy incoming report when only a clean comment retains resolution evidence' {
            $resolved.body = "$marker`nOperator replaced the old report."

            { & $publisher @arguments } | Should -Throw '*Uncorrelated resolved-run evidence*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'rejects uncorrelated resolution comment metadata: <Case>' -ForEach @(
            @{ Case = 'missing'; Report = 'No metadata.' }
            @{ Case = 'other workflow'; Report = "<!-- platform-drift-report -->`n<!-- platform-drift-run:other/workflow|21 -->`n" }
            @{ Case = 'workflow case'; Report = "<!-- platform-drift-report -->`n<!-- platform-drift-run:platform/instance/.github/workflows/Drift.yml@refs/heads/main|21 -->`n" }
            @{ Case = 'different counter'; Report = "<!-- platform-drift-report -->`n<!-- platform-drift-run:platform/instance/.github/workflows/drift.yml@refs/heads/main|22 -->`n" }
        ) {
            $resolvedComments[0].body = "$resolutionMarker`n$Report"
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))

            { & $publisher @arguments } | Should -Throw '*Uncorrelated resolved-run evidence*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'does not post without correlatable incoming metadata after a modern resolution' {
            { & $publisher @arguments } | Should -Throw '*uncorrelated resolved-run evidence*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'rejects uncorrelated closed-workflow evidence: <Workflow>' -ForEach @(
            @{ Workflow = 'platform/instance/.github/workflows/other.yml@refs/heads/main' }
            @{ Workflow = 'platform/instance/.github/workflows/Drift.yml@refs/heads/main' }
        ) {
            $resolved.body = Get-TestDriftReport -Workflow $Workflow
            $resolvedComments = @()
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))
            { & $publisher @arguments } | Should -Throw '*uncorrelated resolved-run evidence*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'rejects unreadable closed-issue lists rather than creating a duplicate' {
            # Deliberately invalid: the list endpoint must return an array, not one issue object.
            Mock Invoke-RestMethod { return , $resolved } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/issues?state=closed&*' }
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))
            { & $publisher @arguments } | Should -Throw '*unknown issue list*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'refuses a resolution with a matching marker and null author' {
            $resolvedComments[0].user = $null
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))
            { & $publisher @arguments } | Should -Throw '*Cannot verify the author*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'rejects malformed matching resolution metadata: <Counter>' -ForEach @(
            @{ Counter = 'x' }, @{ Counter = '0' }, @{ Counter = '9223372036854775808' }
        ) {
            $resolvedComments[0].body = "<!-- platform-drift-clean:${digest}:${Counter}:$('a' * 40) -->`nclean"
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))
            { & $publisher @arguments } | Should -Throw '*Unreadable resolved-run evidence*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }
        It 'rejects unreadable resolution comment bodies: <Case>' -ForEach @(
            # Missing optional body is unsupported evidence; arrays/null are deliberately invalid field types.
            @{ Case = 'missing'; Change = { param($c) $c.Remove('body') } }
            @{ Case = 'null'; Change = { param($c) $c.body = $null } }
            @{ Case = 'array'; Change = { param($c) $c.body = @($c.body) } }
        ) {
            & $Change $resolvedComments[0]
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 22))
            { & $publisher @arguments } | Should -Throw '*Unreadable resolved-run evidence in a comment body*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

    }

    Context 'Clean reconciliation' -Tag 'CleanDrift' {
        BeforeEach {
            $arguments.Outcome = 'Clean'
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 21 -Message 'No drift detected.'))
            $current = Get-ListedIssue -Number 9 -Login 'octoapp[bot]' -Type 'Bot' -Body (Get-TestDriftReport)
            $listed += $current
            $updated.state = 'closed'
            $digest = [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData([Text.Encoding]::UTF8.GetBytes($current.body))).ToLowerInvariant()
            $cleanMarker = "<!-- platform-drift-clean:${digest}:21:$('a' * 40) -->"
            $mainRef = Get-GitHubApiFixture -Name git/get-ref -Set @{ ref = 'refs/heads/main'; 'object.sha' = ('a' * 40) }
            Mock Invoke-RestMethod { return , $mainRef } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/git/ref/heads/main' }
            $comments = @()
            Mock Invoke-RestMethod {
                if ($Uri -like '*page=1') { return , $comments }
                return , @()
            } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/issues/9/comments?*' }
            Mock Invoke-RestMethod {
                Get-GitHubApiFixture -Name issues/create-comment -Set @{ body = ($Body | ConvertFrom-Json -AsHashtable).body }
            } -ParameterFilter { $Method -eq 'POST' -and $Uri -like '*/issues/9/comments' }
        }

        It 'does not create or close anything when no matching open issue exists' {
            $listed = @($listed | Where-Object { $_.number -ne 9 })

            $result = & $publisher @arguments

            $result.Action | Should -BeExactly 'unchanged'
            $result.Number | Should -BeNullOrEmpty
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'closes matching reports from a custom workflow filename: <Filename>' -Tag 'ReviewTwo' -ForEach @(
            @{ Filename = 'explicit-drift.yml' }
            @{ Filename = 'nightly-drift.yaml' }
        ) {
            $customWorkflow = "platform/instance/.github/workflows/$Filename@refs/heads/main"
            $current.body = Get-TestDriftReport -Workflow $customWorkflow
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 21 -Workflow $customWorkflow))

            (& $publisher @arguments -WorkflowRef $customWorkflow).Action | Should -BeExactly 'closed'
        }

        It 'rejects an invalid current workflow context: <Case>' -ForEach @(
            @{ Case = 'empty'; CurrentWorkflow = '' }
            @{ Case = 'other repository'; CurrentWorkflow = 'other/instance/.github/workflows/drift.yml@refs/heads/main' }
            @{ Case = 'repository case'; CurrentWorkflow = 'Platform/instance/.github/workflows/drift.yml@refs/heads/main' }
            @{ Case = 'other ref'; CurrentWorkflow = 'platform/instance/.github/workflows/drift.yml@refs/heads/other' }
            @{ Case = 'nested path'; CurrentWorkflow = 'platform/instance/.github/workflows/sub/drift.yml@refs/heads/main' }
            @{ Case = 'other extension'; CurrentWorkflow = 'platform/instance/.github/workflows/drift.txt@refs/heads/main' }
        ) {
            $arguments.WorkflowRef = $CurrentWorkflow
            if ($CurrentWorkflow) {
                $current.body = Get-TestDriftReport -Workflow $CurrentWorkflow
                [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 21 -Workflow $CurrentWorkflow))
            }
            { & $publisher @arguments } | Should -Throw '*uncorrelated clean-run evidence*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'reuses a clean comment from this App after a lost response even if the run URL changes' {
            $comments = Get-GitHubApiFixture -Name issues/list-comments -Set @{
                '0.body' = "$cleanMarker`nNo drift detected in a previous clean run."
                '0.user.login' = 'octoapp[bot]'
                '0.user.type' = 'Bot'
            }
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 21 -Message 'No drift detected. Run: https://github.example.test/runs/99'))

            $result = & $publisher @arguments

            $result.Action | Should -BeExactly 'closed'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }

        It 'does not reuse a comment when <Case>' -ForEach @(
            @{ Case = 'the login belongs to another App'; Change = { param($c) $c.user.login = 'other[bot]' } }
            @{ Case = 'the login differs in case'; Change = { param($c) $c.user.login = 'Octoapp[bot]' } }
            @{ Case = 'the author is a user'; Change = { param($c) $c.user.type = 'User' } }
            @{ Case = 'the author type differs in case'; Change = { param($c) $c.user.type = 'bot' } }
            @{ Case = 'the body is missing'; Change = { param($c) $c.Remove('body') } }
            @{ Case = 'the body is not text'; Change = { param($c) $c.body = @('text') } }
            @{ Case = 'the body is empty'; Change = { param($c) $c.body = '' } }
            @{ Case = 'the marker belongs to an older drift report'; Change = { param($c) $c.body = "<!-- platform-drift-clean:$('0' * 64) -->`nclean" } }
            @{ Case = 'the marker is not a prefix'; Change = { param($c) $c.body = "text`n$($c.body)" } }
            @{ Case = 'the marker differs in case'; Change = { param($c) $c.body = $c.body.Replace('platform-drift-clean', 'PLATFORM-DRIFT-CLEAN') } }
        ) {
            $comments = Get-GitHubApiFixture -Name issues/list-comments -Set @{
                '0.body' = "$cleanMarker`nNo drift detected."
                '0.user.login' = 'octoapp[bot]'
                '0.user.type' = 'Bot'
            }
            # Missing required fields and wrong types intentionally exercise unsupported API responses.
            & $Change $comments[0]

            $result = & $publisher @arguments

            $result.Action | Should -BeExactly 'closed'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }

        It 'continues beyond a short comment page before posting a clean comment' {
            $comments = Get-GitHubApiFixture -Name issues/list-comments
            $later = Get-GitHubApiFixture -Name issues/list-comments -Set @{
                '0.body' = "$cleanMarker`nNo drift detected."
                '0.user.login' = 'octoapp[bot]'
                '0.user.type' = 'Bot'
            }

            Mock Invoke-RestMethod { return , $later } -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/comments?*page=2' }

            $result = & $publisher @arguments

            $result.Action | Should -BeExactly 'closed'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -like '*/comments?*page=3' }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
        }

        It 'leaves recovery ambiguous without duplicating a matching comment when <Case>' -ForEach @(
            @{ Case = 'the documented author is null'; Change = { param($c) $c.user = $null } }
            # Missing fields and wrong types intentionally exercise unreadable author identities.
            @{ Case = 'the author is missing'; Change = { param($c) $c.Remove('user') } }
            @{ Case = 'the author is not an object'; Change = { param($c) $c.user = 'octoapp[bot]' } }
            @{ Case = 'the login is empty'; Change = { param($c) $c.user.login = '' } }
            @{ Case = 'the login is an array'; Change = { param($c) $c.user.login = @('octoapp[bot]') } }
            @{ Case = 'the login is missing'; Change = { param($c) $c.user.Remove('login') } }
            @{ Case = 'the author type is empty'; Change = { param($c) $c.user.type = '' } }
            @{ Case = 'the author type is an array'; Change = { param($c) $c.user.type = @('Bot') } }
            @{ Case = 'the author type is missing'; Change = { param($c) $c.user.Remove('type') } }
        ) {
            $comments = Get-GitHubApiFixture -Name issues/list-comments -Set @{
                '0.body' = "$cleanMarker`nNo drift detected."
                '0.user.login' = 'octoapp[bot]'
                '0.user.type' = 'Bot'
            }
            & $Change $comments[0]

            { & $publisher @arguments } | Should -Throw '*Cannot verify the author of an existing clean-result comment*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'leaves the issue open when <Case>' -ForEach @(
            @{ Case = 'listing comments fails'; Response = { throw 'comments unavailable' }; Error = '*GET*/comments failed*' }
            # Intentionally invalid: the list endpoint must return an array of objects.
            @{ Case = 'the comment list is an object'; Response = { return @{ id = 1 } }; Error = '*unknown comment list*' }
            @{ Case = 'a comment is not an object'; Response = { return , @('text') }; Error = '*unknown comment list item*' }
        ) {
            Mock Invoke-RestMethod $Response -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/comments?*' }

            { & $publisher @arguments } | Should -Throw $Error
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'leaves the issue open when the clean comment cannot be posted' {
            Mock Invoke-RestMethod { throw 'comment unavailable' } -ParameterFilter { $Method -eq 'POST' }

            { & $publisher @arguments } | Should -Throw '*POST*/comments failed*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'rejects a created clean comment with <Case>' -ForEach @(
            @{ Case = 'no ID'; Change = { param($c) $c.Remove('id'); return , $c } }
            @{ Case = 'an empty ID'; Change = { param($c) $c.id = ''; return , $c } }
            @{ Case = 'an invalid ID'; Change = { param($c) $c.id = 'x'; return , $c } }
            @{ Case = 'a zero ID'; Change = { param($c) $c.id = 0; return , $c } }
            @{ Case = 'a negative ID'; Change = { param($c) $c.id = -1; return , $c } }
            @{ Case = 'an array-valued ID'; Change = { param($c) $c.id = @(1); return , $c } }
            @{ Case = 'a string-valued ID'; Change = { param($c) $c.id = '1'; return , $c } }
            @{ Case = 'no body'; Change = { param($c) $c.Remove('body'); return , $c } }
            @{ Case = 'another body'; Change = { param($c) $c.body = 'other'; return , $c } }
            @{ Case = 'an array containing the expected body'; Change = { param($c) $c.body = @($c.body); return , $c } }
            @{ Case = 'a body differing in case'; Change = { param($c) $c.body = $c.body.Replace('platform-drift-clean', 'PLATFORM-DRIFT-CLEAN'); return , $c } }
            @{ Case = 'an array instead of an object'; Change = { param($c) return , @($c) } }
        ) {
            Mock Invoke-RestMethod {
                $comment = Get-GitHubApiFixture -Name issues/create-comment -Set @{ body = ($Body | ConvertFrom-Json -AsHashtable).body }
                # Intentionally invalid API response, changed one field at a time.
                & $Change $comment
            } -ParameterFilter { $Method -eq 'POST' }

            { & $publisher @arguments } | Should -Throw '*did not return the clean-result comment*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'accepts the documented null author in the created comment response' {
            Mock Invoke-RestMethod {
                Get-GitHubApiFixture -Name issues/create-comment -Set @{ body = ($Body | ConvertFrom-Json -AsHashtable).body; user = $null }
            } -ParameterFilter { $Method -eq 'POST' }

            (& $publisher @arguments).Action | Should -BeExactly 'closed'
        }

        It 'rejects a close response with <Case>' -ForEach @(
            @{ Case = 'an open state'; Change = { param($i) $i.state = 'open'; return , $i } }
            @{ Case = 'a state differing in case'; Change = { param($i) $i.state = 'CLOSED'; return , $i } }
            @{ Case = 'an empty state'; Change = { param($i) $i.state = ''; return , $i } }
            @{ Case = 'an array containing the closed state'; Change = { param($i) $i.state = @('closed'); return , $i } }
            @{ Case = 'a missing state'; Change = { param($i) $i.Remove('state'); return , $i } }
            @{ Case = 'another issue number'; Change = { param($i) $i.number = 999; return , $i } }
            @{ Case = 'a missing issue number'; Change = { param($i) $i.Remove('number'); return , $i } }
            @{ Case = 'an array-valued issue number'; Change = { param($i) $i.number = @(9); return , $i } }
            @{ Case = 'a pull request'; Change = { param($i) $i.pull_request = @{ url = 'https://api.example.test/pulls/9' }; return , $i } }
            @{ Case = 'an array instead of an object'; Change = { param($i) return , @($i) } }
        ) {
            # Missing required fields and wrong types intentionally exercise unsupported API responses.
            $updated = & $Change $updated

            { & $publisher @arguments } | Should -Throw '*PATCH did not return an closed issue*'
        }

        It 'reports a failure to close after posting the clean comment' {
            Mock Invoke-RestMethod { throw 'close unavailable' } -ParameterFilter { $Method -eq 'PATCH' }

            { & $publisher @arguments } | Should -Throw '*PATCH /repos/platform/instance/issues/9 failed*'
        }

        It 'rejects an unreadable matching issue before writing: <Case>' -ForEach @(
            @{ Case = 'missing number'; Change = { param($i) $i.Remove('number') } }
            @{ Case = 'invalid number'; Change = { param($i) $i.number = '../10' } }
            @{ Case = 'zero number'; Change = { param($i) $i.number = 0 } }
            @{ Case = 'negative number'; Change = { param($i) $i.number = -1 } }
            @{ Case = 'array-valued number'; Change = { param($i) $i.number = @(9) } }
            @{ Case = 'closed state'; Change = { param($i) $i.state = 'closed' } }
            @{ Case = 'missing state'; Change = { param($i) $i.Remove('state') } }
        ) {
            # Intentionally invalid list item; required number/state must remain readable.
            & $Change $current

            { & $publisher @arguments } | Should -Throw '*GET did not return an open issue*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'preserves the recovery marker when truncating a clean comment' {
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 21 -Message ('x' * 70000)))

            $null = & $publisher @arguments

            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and ($Body | ConvertFrom-Json -AsHashtable).body.Length -le 65536 -and
                ($Body | ConvertFrom-Json -AsHashtable).body.StartsWith("$cleanMarker`n", [StringComparison]::Ordinal) -and
                ($Body | ConvertFrom-Json -AsHashtable).body -match 'truncated.*job summary'
            }
        }

        It 'rejects stale clean evidence from a report-job rerun: <RunNumber>' -Tag 'DriftFreshness' -ForEach @(
            @{ RunNumber = '19' }, @{ RunNumber = '20' }
        ) {
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber $RunNumber))

            { & $publisher @arguments } | Should -Throw '*must be newer than the last drift report*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'rejects an all-jobs rerun planned against an older main revision' -Tag 'DriftFreshness' {
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber 21 -Revision ('b' * 40)))

            { & $publisher @arguments } | Should -Throw '*main is unreadable or no longer matches*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'rechecks main after the comment before closing the issue' -Tag 'DriftFreshness' {
            Mock Invoke-RestMethod {
                $mainRef.object.sha = 'b' * 40
                Get-GitHubApiFixture -Name issues/create-comment -Set @{ body = ($Body | ConvertFrom-Json -AsHashtable).body }
            } -ParameterFilter { $Method -eq 'POST' }

            { & $publisher @arguments } | Should -Throw '*main is unreadable or no longer matches*'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' }
        }

        It 'uses the existing read-only token only for the two main-reference checks' -Tag 'DriftFreshness' {
            (& $publisher @arguments).Action | Should -BeExactly 'closed'
            Should -Invoke Invoke-RestMethod -Times 2 -Exactly -ParameterFilter {
                $Uri -like '*/git/ref/heads/main' -and $Headers.Authorization -ceq 'Bearer read-token' -and
                $Headers['X-GitHub-Api-Version'] -ceq '2026-03-10'
            }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter {
                $Uri -like '*/issues*' -and $Headers.Authorization -ceq 'Bearer read-token'
            }
        }

        It 'requires a contents token before checking modern clean evidence' -Tag 'DriftFreshness' {
            $arguments.ContentsToken = ''
            { & $publisher @arguments } | Should -Throw '*requires the existing contents:read token*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'does not close when the main reference is unreadable: <Case>' -Tag 'DriftFreshness' -ForEach @(
            # Deliberately invalid responses derived from the documented git-ref fixture.
            @{ Case = 'missing ref'; Change = { param($r) $r.Remove('ref'); return , $r } }
            @{ Case = 'another ref'; Change = { param($r) $r.ref = 'refs/heads/other'; return , $r } }
            @{ Case = 'ref case'; Change = { param($r) $r.ref = 'refs/heads/Main'; return , $r } }
            @{ Case = 'array ref'; Change = { param($r) $r.ref = @('refs/heads/main'); return , $r } }
            @{ Case = 'missing object'; Change = { param($r) $r.Remove('object'); return , $r } }
            @{ Case = 'missing type'; Change = { param($r) $r.object.Remove('type'); return , $r } }
            @{ Case = 'tag object'; Change = { param($r) $r.object.type = 'tag'; return , $r } }
            @{ Case = 'type case'; Change = { param($r) $r.object.type = 'Commit'; return , $r } }
            @{ Case = 'array type'; Change = { param($r) $r.object.type = @('commit'); return , $r } }
            @{ Case = 'missing SHA'; Change = { param($r) $r.object.Remove('sha'); return , $r } }
            @{ Case = 'array SHA'; Change = { param($r) $r.object.sha = @('a' * 40); return , $r } }
            @{ Case = 'SHA case'; Change = { param($r) $r.object.sha = 'A' * 40; return , $r } }
            @{ Case = 'array root'; Change = { param($r) return , @($r) } }
        ) {
            $mainRef = & $Change $mainRef
            { & $publisher @arguments } | Should -Throw '*main is unreadable or no longer matches*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'rejects unreadable clean-run evidence: <Case>' -Tag 'DriftFreshness' -ForEach @(
            @{ Case = 'missing metadata'; Body = { "$marker`nRevision: ``$('a' * 40)```n" } }
            @{ Case = 'duplicate metadata'; Body = { "$(Get-TestDriftReport -RunNumber 21)$(Get-TestDriftReport -RunNumber 21)" } }
            @{ Case = 'one valid and one malformed metadata marker'; Body = { "$(Get-TestDriftReport -RunNumber 21)<!-- platform-drift-run:invalid -->`n" } }
            @{ Case = 'invalid counter'; Body = { Get-TestDriftReport -RunNumber 'x' } }
            @{ Case = 'zero counter'; Body = { Get-TestDriftReport -RunNumber '0' } }
            @{ Case = 'overflow counter'; Body = { Get-TestDriftReport -RunNumber '9223372036854775808' } }
            @{ Case = 'another workflow'; Body = { Get-TestDriftReport -RunNumber 21 -Workflow 'platform/instance/.github/workflows/other.yml@refs/heads/main' } }
            @{ Case = 'wrong workflow case'; Body = { Get-TestDriftReport -RunNumber 21 -Workflow 'platform/instance/.github/workflows/Drift.yml@refs/heads/main' } }
            @{ Case = 'missing revision'; Body = { (Get-TestDriftReport -RunNumber 21).Replace("Revision: ``$('a' * 40)```n", '') } }
            @{ Case = 'invalid revision'; Body = { Get-TestDriftReport -RunNumber 21 -Revision 'x' } }
        ) {
            [IO.File]::WriteAllText($reportPath, (& $Body))
            { & $publisher @arguments } | Should -Throw '*clean-run evidence*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'leaves a legacy issue open with a deduplicated manual-closure comment' -Tag 'DriftFreshness' {
            $current.body = "$marker`nlegacy drift without run_number"
            $arguments.ContentsToken = ''
            $manualComments = [Collections.Generic.List[object]]::new()
            Mock Invoke-RestMethod { return , @($manualComments.ToArray()) } `
                -ParameterFilter { $Method -eq 'GET' -and $Uri -like '*/issues/9/comments?*page=1' }
            Mock Invoke-RestMethod {
                $savedComment = Get-GitHubApiFixture -Name issues/create-comment -Set @{
                    body = ($Body | ConvertFrom-Json -AsHashtable).body
                    'user.login' = 'octoapp[bot]'; 'user.type' = 'Bot'
                }
                $manualComments.Add($savedComment)
                return , $savedComment
            } -ParameterFilter { $Method -eq 'POST' }

            (& $publisher @arguments).Action | Should -BeExactly 'manual'
            (& $publisher @arguments).Action | Should -BeExactly 'manual'
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and ($Body | ConvertFrom-Json -AsHashtable).body -match 'no run_number.*close this issue manually'
            }
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'PATCH' -or $Uri -like '*/git/ref/*' }
        }

        It 'rejects a last drift report from a different workflow: <Workflow>' -Tag 'DriftFreshness' -ForEach @(
            @{ Workflow = 'platform/instance/.github/workflows/other.yml@refs/heads/main' }
            @{ Workflow = 'platform/instance/.github/workflows/Drift.yml@refs/heads/main' }
        ) {
            $current.body = Get-TestDriftReport -Workflow $Workflow
            { & $publisher @arguments } | Should -Throw '*uncorrelated clean-run evidence*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'does not downgrade the last drift evidence: <Case>' -Tag 'DriftFreshness' -ForEach @(
            @{ Case = 'older report rerun'; Body = { Get-TestDriftReport -RunNumber 19 } }
            @{ Case = 'report without run metadata'; Body = { "$marker`nlegacy" } }
            @{ Case = 'report from another workflow'; Body = { Get-TestDriftReport -RunNumber 21 -Workflow 'other/workflow' } }
            @{ Case = 'workflow differs in case'; Body = { Get-TestDriftReport -RunNumber 21 -Workflow 'platform/instance/.github/workflows/Drift.yml@refs/heads/main' } }
        ) {
            $arguments.Outcome = 'Report'
            [IO.File]::WriteAllText($reportPath, (& $Body))
            { & $publisher @arguments } | Should -Throw '*Refusing an older or uncorrelated drift report*'
            Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -ne 'GET' }
        }

        It 'accepts a current correlated drift update: <RunNumber>' -Tag 'DriftFreshness' -ForEach @(
            @{ RunNumber = '20' }, @{ RunNumber = '21' }
        ) {
            $arguments.Outcome = 'Report'
            $updated.state = 'open'
            [IO.File]::WriteAllText($reportPath, (Get-TestDriftReport -RunNumber $RunNumber))
            (& $publisher @arguments).Action | Should -BeExactly 'updated'
        }
    }
}
