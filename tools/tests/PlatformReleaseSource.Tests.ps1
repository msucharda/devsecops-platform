BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../PublicationSource.psm1') -Force
    $scriptPath = Join-Path $PSScriptRoot '../Test-PlatformReleaseSource.ps1'
    function git { $global:LASTEXITCODE = 0 }
}

Describe 'Platform release source build boundary' {
    BeforeEach {
        $source = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $source
        $commit = 'a' * 40
        $gitState = @{ Head = $commit; HeadExit = 0; StatusExit = 0; Dirty = @(); MergeExit = 0 }
        Mock git {
            if ($args -contains 'rev-parse') { $global:LASTEXITCODE = $gitState.HeadExit; return $gitState.Head }
            if ($args -contains 'status') { $global:LASTEXITCODE = $gitState.StatusExit; return $gitState.Dirty }
            if ($args -contains 'merge-base') { $global:LASTEXITCODE = $gitState.MergeExit; return }
            throw "Unexpected Git operation: $($args -join ' ')"
        }
    }

    It 'keeps a clean exact checkout without a declaration on the original main ancestry' {
        & $scriptPath -SourcePath $source -Repository upstream/platform -Commit $commit
        Should -Invoke git -Times 1 -Exactly -ParameterFilter {
            $args -contains 'merge-base' -and $args -contains '--is-ancestor' -and $args -contains 'refs/remotes/origin/main'
        }
    }

    It 'rejects <Case> before the release can be archived' -ForEach @(
        @{ Case = 'a failed HEAD read'; Field = 'HeadExit'; Value = 1; Error = '*checkout must match*' }
        @{ Case = 'another checkout'; Field = 'Head'; Value = 'bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb'; Error = '*checkout must match*' }
        @{ Case = 'a case-folded checkout identity'; Field = 'Head'; Value = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA'; Error = '*checkout must match*' }
        @{ Case = 'a non-scalar HEAD'; Field = 'Head'; Value = @('aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa', 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa'); Error = '*checkout must match*' }
        @{ Case = 'an unreadable policy status'; Field = 'StatusExit'; Value = 1; Error = '*declaration must match the committed checkout*' }
        @{ Case = 'a modified declaration'; Field = 'Dirty'; Value = @(' M release-source-policy.json'); Error = '*declaration must match the committed checkout*' }
        @{ Case = 'an untracked declaration'; Field = 'Dirty'; Value = @('?? release-source-policy.json'); Error = '*declaration must match the committed checkout*' }
        @{ Case = 'an ignored declaration'; Field = 'Dirty'; Value = @('!! release-source-policy.json'); Error = '*declaration must match the committed checkout*' }
        @{ Case = 'a commit outside main'; Field = 'MergeExit'; Value = 1; Error = '*original main authority*' }
    ) {
        $gitState[$Field] = $Value
        { & $scriptPath -SourcePath $source -Repository upstream/platform -Commit $commit } | Should -Throw $Error
    }

    It 'rejects invalid or case-folded commit identity before reading Git' -ForEach @(
        @{ Value = 'not-a-commit' }; @{ Value = 'AAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA' }
    ) {
        { & $scriptPath -SourcePath $source -Repository upstream/platform -Commit $Value } | Should -Throw '*Invalid release build commit*'
        Should -Invoke git -Times 0 -Exactly
    }

    It 'checks published source through the same anonymous control instead of falling back to main' {
        '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":7}' |
            Set-Content -LiteralPath (Join-Path $source 'release-source-policy.json')
        $reference = Get-GitHubApiFixture -Name git/get-ref
        Mock Invoke-WebRequest { [pscustomobject]@{ Content = ($reference | ConvertTo-Json -Depth 20) } }
        Mock Assert-PlatformPublishedSource {
            param($Read)
            $readback = & $Read 'git/ref/heads/source-publication/v1'
            $readback['object']['type'] | Should -BeExactly 'commit'
        }
        & $scriptPath -SourcePath $source -Repository upstream/platform -Commit $commit
        Should -Invoke Assert-PlatformPublishedSource -Times 1 -Exactly -ParameterFilter {
            $Repository -ceq 'upstream/platform' -and $Commit -ceq 'aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa' -and $PublisherAppId -eq 7
        }
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -ceq 'https://api.github.com/repos/upstream/platform/git/ref/heads/source-publication/v1' -and
            -not $Headers.ContainsKey('Authorization') -and $Headers['X-GitHub-Api-Version'] -ceq '2026-03-10' -and
            $MaximumRedirection -eq 0
        }
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $args -contains 'merge-base' }
    }

    It 'does not fall back to main after a publication control failure' {
        '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":7}' |
            Set-Content -LiteralPath (Join-Path $source 'release-source-policy.json')
        Mock Assert-PlatformPublishedSource { throw 'Publication witness is not published.' }
        { & $scriptPath -SourcePath $source -Repository upstream/platform -Commit $commit } | Should -Throw '*not published*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $args -contains 'merge-base' }
    }
}
