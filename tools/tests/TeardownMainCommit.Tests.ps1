BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1')
    $script = Join-Path (Split-Path $PSScriptRoot -Parent) 'Assert-TeardownMainCommit.ps1'
    $sha = 'aa218f56b14c9653891f9e74264a383fa43fefbd'
    $arguments = @{ Repository = 'demo-platform/instance'; Sha = $sha; ApiUrl = 'https://api.contoso.ghe.com' }
}

Describe 'Teardown main commit check' {
    BeforeEach {
        $env:TEARDOWN_MAIN_TOKEN = 'ghs_workflowtoken'
        $mainCheck = @{
            Reference = Get-GitHubApiFixture -Name git/get-ref -Set @{ ref = 'refs/heads/main'; 'object.sha' = $sha }
            Status = 200
            Content = $null
            Requests = [System.Collections.Generic.List[object]]::new()
            Throw = $false
        }
        Mock Invoke-WebRequest {
            $mainCheck.Requests.Add([pscustomobject]@{ Uri = $Uri; Method = $Method; Headers = $Headers; MaximumRedirection = $MaximumRedirection })
            if ($mainCheck.Throw) { throw 'Simulated transport failure' }
            $body = if ($null -ne $mainCheck.Content) { $mainCheck.Content } else { ConvertTo-Json -InputObject $mainCheck.Reference -Depth 10 }
            [pscustomobject]@{ StatusCode = $mainCheck.Status; Content = $body }
        }
    }

    AfterEach {
        Remove-Item Env:TEARDOWN_MAIN_TOKEN -ErrorAction SilentlyContinue
    }

    It 'passes when main still points to the dispatched commit' {
        { & $script @arguments } | Should -Not -Throw
        $mainCheck.Requests.Count | Should -Be 1
        $mainCheck.Requests[0].Uri | Should -BeExactly 'https://api.contoso.ghe.com/repos/demo-platform/instance/git/ref/heads/main'
        $mainCheck.Requests[0].Method | Should -Be ([Microsoft.PowerShell.Commands.WebRequestMethod]::Get)
        $mainCheck.Requests[0].Headers['Authorization'] | Should -BeExactly ('Bearer ' + 'ghs_workflowtoken')
        $mainCheck.Requests[0].Headers['X-GitHub-Api-Version'] | Should -BeExactly '2026-03-10'
        $mainCheck.Requests[0].MaximumRedirection | Should -Be 0
    }

    It 'fails when main <Label>' -ForEach @(
        @{ Label = 'moved to another commit'; Field = 'object.sha'; Value = 'bb218f56b14c9653891f9e74264a383fa43fefbd'; Message = '*no longer points*' }
        @{ Label = 'differs only in case'; Field = 'object.sha'; Value = 'AA218F56B14C9653891F9E74264A383FA43FEFBD'; Message = '*no longer points*' }
        @{ Label = 'points to a tag object'; Field = 'object.type'; Value = 'tag'; Message = '*did not return a commit*' }
        @{ Label = 'is returned for another ref'; Field = 'ref'; Value = 'refs/heads/mainline'; Message = '*did not return a commit*' }
    ) {
        $path = $Field.Split('.')
        if ($path.Count -eq 2) { $mainCheck.Reference[$path[0]][$path[1]] = $Value } else { $mainCheck.Reference[$Field] = $Value }

        { & $script @arguments } | Should -Throw $Message
    }

    It 'fails closed when the reference <Label>' -ForEach @(
        @{ Label = 'has no object'; Remove = 'object' }
        @{ Label = 'has no object sha'; Remove = 'object.sha' }
        @{ Label = 'has no object type'; Remove = 'object.type' }
        @{ Label = 'has no ref'; Remove = 'ref' }
    ) {
        # Intentionally invalid response: the documented git-ref schema requires these fields.
        $path = $Remove.Split('.')
        if ($path.Count -eq 2) { $mainCheck.Reference[$path[0]].Remove($path[1]) } else { $mainCheck.Reference.Remove($Remove) }

        { & $script @arguments } | Should -Throw '*did not return a commit*'
    }

    It 'fails closed when GitHub answers HTTP <Status>' -ForEach @(@{ Status = 301 }, @{ Status = 302 }, @{ Status = 404 }, @{ Status = 403 }, @{ Status = 500 }) {
        $mainCheck.Status = $Status
        $mainCheck.Content = '{"message":"Not Found"}'

        { & $script @arguments } | Should -Throw "*HTTP $Status*"
    }

    It 'fails closed when GitHub returns <Label>' -ForEach @(
        @{ Label = 'invalid JSON'; Content = '{"ref":' }
        @{ Label = 'an empty body'; Content = '' }
        @{ Label = 'a JSON array'; Content = '[]' }
    ) {
        # Intentionally invalid response bodies.
        $mainCheck.Content = $Content

        { & $script @arguments } | Should -Throw '*did not return a commit*'
    }

    It 'refuses to run without <Label>' -ForEach @(
        @{ Label = 'a full commit SHA'; Name = 'Sha'; Value = 'aa218f5' }
        @{ Label = 'a repository'; Name = 'Repository'; Value = '' }
        @{ Label = 'an API URL'; Name = 'ApiUrl'; Value = '' }
    ) {
        $invalid = $arguments.Clone()
        $invalid[$Name] = $Value

        { & $script @invalid } | Should -Throw
        $mainCheck.Requests.Count | Should -Be 0
    }

    It 'fails closed when the request to GitHub fails' {
        $mainCheck.Throw = $true

        { & $script @arguments } | Should -Throw '*Simulated transport failure*'
    }

    It 'refuses to run without a workflow token' {
        Remove-Item Env:TEARDOWN_MAIN_TOKEN

        { & $script @arguments } | Should -Throw '*TEARDOWN_MAIN_TOKEN*'
        $mainCheck.Requests.Count | Should -Be 0
    }
}
