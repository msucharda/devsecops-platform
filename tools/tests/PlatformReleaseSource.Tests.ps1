BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../PublicationSource.psm1') -Force
    $scriptPath = Join-Path $PSScriptRoot '../Test-PlatformReleaseSource.ps1'
    function git { $global:LASTEXITCODE = 0 }
}

Describe 'Retained release workflow contract' {
    It 'signs the validated publication predicate and passes both retained bundles to the publisher' {
        $workflow = Get-Content -LiteralPath (Join-Path $PSScriptRoot '../../.github/workflows/release.yml') -Raw | ConvertFrom-Yaml
        $steps = @($workflow.jobs.release.steps)
        $provenance = @($steps | Where-Object { $_['id'] -ceq 'provenance' })
        $publication = @($steps | Where-Object { $_['id'] -ceq 'publication' })

        $provenance.Count | Should -Be 1
        $publication.Count | Should -Be 1
        $publication[0].uses | Should -BeExactly $provenance[0].uses
        $publication[0].with['subject-path'] | Should -BeExactly '${{ steps.build.outputs.asset }}'
        $publication[0].with['predicate-path'] | Should -BeExactly 'artifacts/publication-predicate.json'
        $publication[0].with['predicate-type'] |
            Should -BeExactly 'https://github.com/msucharda/devsecops-platform/attestations/source-publication/v1'
        $publication[0]['if'] | Should -BeExactly "steps.build.outputs.publication == 'true'"
        $publishStep = $steps[-1]
        $publishStep.env.PROVENANCE_BUNDLE | Should -BeExactly '${{ steps.provenance.outputs.bundle-path }}'
        $publishStep.env.PUBLICATION_BUNDLE | Should -BeExactly '${{ steps.publication.outputs.bundle-path }}'
        $publishStep.env.SOURCE_PUBLICATION | Should -BeExactly '${{ steps.build.outputs.publication }}'
        $steps.IndexOf($publication[0]) | Should -BeGreaterThan $steps.IndexOf($provenance[0])
    }
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

    It 'retries a rate-limited anonymous publication read without changing its request' -Tag PublicationRateLimit {
        '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":7}' |
            Set-Content -LiteralPath (Join-Path $source 'release-source-policy.json')
        $reference = Get-GitHubApiFixture -Name git/get-ref
        $attempts = @{ Count = 0 }
        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
        $null = $response.Headers.TryAddWithoutValidation('retry-after', '7')
        $failure = [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limited', $response)
        Mock Start-Sleep { }
        Mock Invoke-WebRequest {
            $attempts.Count++
            if ($attempts.Count -eq 1) { throw $failure }
            [pscustomobject]@{ Content = ($reference | ConvertTo-Json -Depth 20) }
        }
        Mock Assert-PlatformPublishedSource {
            param($Read)
            (& $Read 'git/ref/heads/source-publication/v1').object.type | Should -BeExactly 'commit'
        }
        { & $scriptPath -SourcePath $source -Repository upstream/platform -Commit $commit } | Should -Not -Throw
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly -ParameterFilter {
            $Uri -ceq 'https://api.github.com/repos/upstream/platform/git/ref/heads/source-publication/v1' -and
            -not $Headers.ContainsKey('Authorization') -and $MaximumRedirection -eq 0
        }
    }

    It 'rejects <Case> without waiting or falling back to main' -Tag PublicationRateLimit -ForEach @(
        @{ Case = 'a non-rate-limit forbidden response'; Status = 403; RetryAfter = $null; Error = '*publication read denied*' }
        @{ Case = 'a missing publication resource'; Status = 404; RetryAfter = $null; Error = '*publication read denied*' }
        @{ Case = 'a rate-limit wait exceeding 300 seconds'; Status = 429; RetryAfter = '301'; Error = '*rate limit for the source is exhausted*' }
    ) {
        '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":7}' |
            Set-Content -LiteralPath (Join-Path $source 'release-source-policy.json')
        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode] $Status)
        if ($RetryAfter) { $null = $response.Headers.TryAddWithoutValidation('retry-after', $RetryAfter) }
        $failure = [Microsoft.PowerShell.Commands.HttpResponseException]::new('publication read denied', $response)
        Mock Start-Sleep { }
        Mock Invoke-WebRequest { throw $failure }
        Mock Assert-PlatformPublishedSource {
            param($Read)
            & $Read 'git/ref/heads/source-publication/v1'
        }
        { & $scriptPath -SourcePath $source -Repository upstream/platform -Commit $commit } | Should -Throw $Error
        Should -Invoke Start-Sleep -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -ceq 'https://api.github.com/repos/upstream/platform/git/ref/heads/source-publication/v1' -and
            -not $Headers.ContainsKey('Authorization') -and $MaximumRedirection -eq 0
        }
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $args -contains 'merge-base' }
    }

    It 'reports an exhausted anonymous rate limit without recommending a credential' -Tag PublicationRateLimit {
        '{"schemaVersion":1,"line":"ghe-publication","publisherAppId":7}' |
            Set-Content -LiteralPath (Join-Path $source 'release-source-policy.json')
        $response = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::TooManyRequests)
        $null = $response.Headers.TryAddWithoutValidation('retry-after', '301')
        $failure = [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limited', $response)
        Mock Invoke-WebRequest { throw $failure }
        Mock Assert-PlatformPublishedSource {
            param($Read)
            & $Read 'git/ref/heads/source-publication/v1'
        }
        $failureMessage = $null
        try { & $scriptPath -SourcePath $source -Repository upstream/platform -Commit $commit }
        catch { $failureMessage = $_.Exception.Message }
        $failureMessage | Should -Match 'rate limit.*exhausted.*301 s'
        $failureMessage | Should -Not -Match '(?i)token|credential|private source'
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            -not $Headers.ContainsKey('Authorization')
        }
    }
}
