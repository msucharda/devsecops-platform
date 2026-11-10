BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $modulePath = Join-Path $PSScriptRoot '../PublicationAttestation.psm1'
    $fixturePath = Join-Path $PSScriptRoot 'fixtures/attestation/publication-verification.json'
    function gh { $global:LASTEXITCODE = 0 }
}

Describe 'Retained release attestation bundles' {
    BeforeEach {
        Import-Module $modulePath -Force
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $directory
        $release = Get-GitHubApiFixture -Name repos/get-release-by-tag -Set @{ tag_name = 'v1.2.3'; draft = $false }
        $bundleContent = [Text.Encoding]::UTF8.GetBytes('{"mediaType":"application/vnd.dev.sigstore.bundle.v0.3+json"}')
        $bundleDigest = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($bundleContent)).ToLowerInvariant()
        $release.assets = @(
            Get-GitHubApiFixture -Name repos/upload-release-asset -Set @{
                id = 21; name = 'platform-v1.2.3.provenance.sigstore.json'; state = 'uploaded'; digest = $bundleDigest
            }
            Get-GitHubApiFixture -Name repos/upload-release-asset -Set @{
                id = 22; name = 'platform-v1.2.3.publication.sigstore.json'; state = 'uploaded'; digest = $bundleDigest
            }
        )
        Mock Invoke-WebRequest -ModuleName PublicationAttestation {
            [IO.File]::WriteAllBytes($OutFile, $bundleContent)
        }
    }

    It 'downloads both exact retained bundle assets by API identity without source credentials' {
        $paths = Get-PlatformReleaseEvidence -Release $release -Repository upstream/platform -Tag v1.2.3 -Directory $directory

        [IO.File]::ReadAllBytes($paths.Provenance) | Should -Be $bundleContent
        [IO.File]::ReadAllBytes($paths.Publication) | Should -Be $bundleContent
        Should -Invoke Invoke-WebRequest -ModuleName PublicationAttestation -Times 1 -Exactly -ParameterFilter {
            $Uri -ceq 'https://api.github.com/repos/upstream/platform/releases/assets/21' -and
            $Headers.Accept -ceq 'application/octet-stream' -and -not $Headers.ContainsKey('Authorization')
        }
        Should -Invoke Invoke-WebRequest -ModuleName PublicationAttestation -Times 1 -Exactly -ParameterFilter {
            $Uri -ceq 'https://api.github.com/repos/upstream/platform/releases/assets/22' -and
            $Headers['X-GitHub-Api-Version'] -ceq '2026-03-10' -and -not $Headers.ContainsKey('Authorization')
        }
    }

    It 'reads the already uploaded proof of a partial draft without requiring the other proof' {
        $release.assets = @($release.assets[1])

        $paths = Get-PlatformReleaseEvidence -Release $release -Repository upstream/platform -Tag v1.2.3 `
            -Directory $directory -Kind Publication

        @($paths.get_Keys()) | Should -Be @('Publication')
        [IO.File]::ReadAllBytes($paths.Publication) | Should -Be $bundleContent
        Should -Invoke Invoke-WebRequest -ModuleName PublicationAttestation -Times 1 -Exactly -ParameterFilter {
            $Uri -ceq 'https://api.github.com/repos/upstream/platform/releases/assets/22'
        }
    }

    It 'rejects retained release metadata when <Case>' -ForEach @(
        @{ Case = 'the release tag is different'; Change = { $release.tag_name = 'v9.9.9' } }
        @{ Case = 'the release tag differs in case'; Change = { $release.tag_name = 'V1.2.3' } }
        @{ Case = 'the release tag is numeric'; Change = { $release.tag_name = 123 } }
        @{ Case = 'the release tag is absent'; Change = { $release.Remove('tag_name') } }
        @{ Case = 'the asset inventory is scalar'; Change = { $release.assets = $release.assets[0] } }
        @{ Case = 'the asset inventory is absent'; Change = { $release.Remove('assets') } }
    ) {
        . $Change
        { Get-PlatformReleaseEvidence -Release $release -Repository upstream/platform -Tag v1.2.3 -Directory $directory } |
            Should -Throw '*release identity or asset inventory*'
        Should -Invoke Invoke-WebRequest -ModuleName PublicationAttestation -Times 0
    }

    It 'rejects the <Kind> bundle metadata when <Case>' -ForEach @(
        foreach ($kind in @(@{ Kind = 'provenance'; Index = 0 }, @{ Kind = 'publication'; Index = 1 })) {
            foreach ($variant in @(
                @{ Case = 'the asset is absent'; Field = 'name'; Value = 'unrelated.json'; Error = '*exactly one retained*' }
                @{ Case = 'the asset name differs in case'; Field = 'name'; Value = 'CASE'; Error = '*asset metadata*' }
                @{ Case = 'the ID is zero'; Field = 'id'; Value = 0; Error = '*asset metadata*' }
                @{ Case = 'the ID is negative'; Field = 'id'; Value = -1; Error = '*asset metadata*' }
                @{ Case = 'the ID is a numeric string'; Field = 'id'; Value = '21'; Error = '*asset metadata*' }
                @{ Case = 'the ID is absent'; Field = 'id'; Value = $null; Error = '*asset metadata*' }
                @{ Case = 'the upload is incomplete'; Field = 'state'; Value = 'starter'; Error = '*asset metadata*' }
                @{ Case = 'the state differs in case'; Field = 'state'; Value = 'Uploaded'; Error = '*asset metadata*' }
                @{ Case = 'the state is numeric'; Field = 'state'; Value = 1; Error = '*asset metadata*' }
                @{ Case = 'the state is absent'; Field = 'state'; Value = $null; Error = '*asset metadata*' }
                @{ Case = 'the digest is absent'; Field = 'digest'; Value = $null; Error = '*asset metadata*' }
                @{ Case = 'the digest is numeric'; Field = 'digest'; Value = 1; Error = '*asset metadata*' }
                @{ Case = 'the digest is malformed'; Field = 'digest'; Value = 'sha256:abc'; Error = '*asset metadata*' }
                @{ Case = 'the digest prefix differs in case'; Field = 'digest'; Value = ('SHA256:' + 'a' * 64); Error = '*asset metadata*' }
                @{ Case = 'the digest hex differs in case'; Field = 'digest'; Value = ('sha256:' + 'A' * 64); Error = '*asset metadata*' }
                @{ Case = 'the downloaded bytes differ'; Field = 'digest'; Value = ('sha256:' + 'b' * 64); Error = '*digest mismatch*' }
            )) {
                @{ Kind = $kind.Kind; Index = $kind.Index; Case = $variant.Case; Field = $variant.Field; Value = $variant.Value; Error = $variant.Error }
            }
        }
    ) {
        # Deliberately invalid variants of the documented release asset response.
        if ($Value -is [string] -and $Value -ceq 'CASE') { $Value = $release.assets[$Index].name.ToUpperInvariant() }
        if ($null -eq $Value) { $release.assets[$Index].Remove($Field) }
        else { $release.assets[$Index][$Field] = $Value }

        { Get-PlatformReleaseEvidence -Release $release -Repository upstream/platform -Tag v1.2.3 -Directory $directory } |
            Should -Throw $Error
    }

    It 'rejects ambiguous retained <Kind> assets rather than selecting the latest' -ForEach @(
        @{ Kind = 'provenance'; Index = 0 }; @{ Kind = 'publication'; Index = 1 }
    ) {
        $release.assets += $release.assets[$Index]
        { Get-PlatformReleaseEvidence -Release $release -Repository upstream/platform -Tag v1.2.3 -Directory $directory } |
            Should -Throw '*exactly one retained*'
    }

    It 'rejects a downloaded bundle exceeding the existing 16 MiB limit' {
        Mock Invoke-WebRequest -ModuleName PublicationAttestation {
            [IO.File]::WriteAllBytes($OutFile, [byte[]]::new(16MB + 1))
        }
        { Get-PlatformReleaseEvidence -Release $release -Repository upstream/platform -Tag v1.2.3 -Directory $directory } |
            Should -Throw '*exceeds 16 MiB*'
    }

    It 'does not return partial evidence after a failed second bundle download' {
        Mock Invoke-WebRequest -ModuleName PublicationAttestation { throw 'Injected bundle download failure.' } -ParameterFilter {
            $Uri -like '*/assets/22'
        }
        { Get-PlatformReleaseEvidence -Release $release -Repository upstream/platform -Tag v1.2.3 -Directory $directory } |
            Should -Throw '*Injected bundle download failure*'
    }
}

Describe 'Durable publication attestation' {
    BeforeEach {
        $archive = Join-Path $TestDrive 'platform-v1.2.3.zip'
        [IO.File]::WriteAllBytes($archive, [Text.Encoding]::UTF8.GetBytes('hello'))
        $bundle = Join-Path $TestDrive 'publication.json'
        '{}' | Set-Content -LiteralPath $bundle
        $verification = (Get-Content -LiteralPath $fixturePath -Raw | ConvertFrom-Json -AsHashtable -NoEnumerate).body
        $arguments = @{
            ArchivePath = $archive; BundlePath = $bundle; Repository = 'upstream/platform'
            ArchiveSha256 = '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824'
            Tag = 'v1.2.3'; Commit = 'a' * 40; PublisherAppId = 7
            SignerWorkflow = 'upstream/platform/.github/workflows/release.yml'
        }
    }

    It 'verifies the actual archive with the pinned workflow, tag and both source and signer SHA before reading the predicate' {
        Import-Module $modulePath -Force
        Mock gh -ModuleName PublicationAttestation {
            $global:LASTEXITCODE = 0
            ConvertTo-Json -InputObject $verification -Depth 30
        }

        $result = Get-PlatformPublicationAttestation -ArchivePath $archive `
            -ArchiveSha256 '2cf24dba5fb0a30e26e83b2ac5b9e29e1b161e5c1fa7425e73043362938b9824' -BundlePath $bundle -Repository upstream/platform `
            -Tag v1.2.3 -Commit ('a' * 40) -PublisherAppId 7 -SignerWorkflow upstream/platform/.github/workflows/release.yml

        $result.checkId | Should -Be 9
        $result.receiptSha256 | Should -BeExactly ('b' * 64)
        Should -Invoke gh -ModuleName PublicationAttestation -Times 1 -Exactly -ParameterFilter {
            $args[0] -ceq 'attestation' -and $args[1] -ceq 'verify' -and $args[2] -ceq $archive -and
            $args[[array]::IndexOf($args, '--bundle') + 1] -ceq $bundle -and
            $args[[array]::IndexOf($args, '--repo') + 1] -ceq 'upstream/platform' -and
            $args[[array]::IndexOf($args, '--source-ref') + 1] -ceq 'refs/tags/v1.2.3' -and
            $args[[array]::IndexOf($args, '--source-digest') + 1] -ceq ('a' * 40) -and
            $args[[array]::IndexOf($args, '--signer-digest') + 1] -ceq ('a' * 40) -and
            $args[[array]::IndexOf($args, '--cert-identity') + 1] -ceq 'https://github.com/upstream/platform/.github/workflows/release.yml@refs/tags/v1.2.3' -and
            $args -cnotcontains '--signer-workflow' -and
            $args[[array]::IndexOf($args, '--predicate-type') + 1] -ceq 'https://github.com/msucharda/devsecops-platform/attestations/source-publication/v1' -and
            $args -ccontains '--deny-self-hosted-runners' -and
            $args[[array]::IndexOf($args, '--format') + 1] -ceq 'json'
        }
    }

    It 'rejects a valid signature over bytes different from the pinned archive digest' {
        Import-Module $modulePath -Force
        Mock gh -ModuleName PublicationAttestation {
            $global:LASTEXITCODE = 0
            ConvertTo-Json -InputObject $verification -Depth 30
        }
        $arguments.ArchiveSha256 = 'f' * 64
        { Get-PlatformPublicationAttestation @arguments } |
            Should -Throw '*pinned archive digest*'
    }

    It 'rejects a signed statement bound to <Case>' -Tag AttestationEnvelope -ForEach @(
        @{ Case = 'another statement schema'; Change = { $verification[0].verificationResult.statement._type = 'https://in-toto.io/Statement/v0.1' }; Error = '*statement schema*' }
        @{ Case = 'another predicate type'; Change = { $verification[0].verificationResult.statement.predicateType = 'https://slsa.dev/provenance/v1' }; Error = '*predicate type*' }
        @{ Case = 'another archive digest'; Change = { $verification[0].verificationResult.statement.subject[0].digest.sha256 = 'f' * 64 }; Error = '*archive subject*' }
        @{ Case = 'another asset name'; Change = { $verification[0].verificationResult.statement.subject[0].name = 'another.zip' }; Error = '*archive subject*' }
        @{ Case = 'ambiguous subjects'; Change = { $verification[0].verificationResult.statement.subject += $verification[0].verificationResult.statement.subject[0] }; Error = '*archive subject*' }
        @{ Case = 'no subjects'; Change = { $verification[0].verificationResult.statement.subject = @() }; Error = '*archive subject*' }
    ) {
        Import-Module $modulePath -Force
        . $Change
        Mock gh -ModuleName PublicationAttestation {
            $global:LASTEXITCODE = 0
            ConvertTo-Json -InputObject $verification -Depth 30
        }

        { Get-PlatformPublicationAttestation @arguments } | Should -Throw $Error
    }

    It 'verifies the original build provenance of the same ZIP independently of the publication predicate' {
        Import-Module $modulePath -Force
        $verification[0].verificationResult.statement.predicateType = 'https://slsa.dev/provenance/v1'
        # SLSA v1 buildDefinition/runDetails: https://slsa.dev/spec/v1.1/provenance
        $verification[0].verificationResult.statement.predicate = @{
            buildDefinition = @{
                buildType = 'https://actions.github.io/buildtypes/workflow/v1'
                externalParameters = @{ workflow = @{
                    ref = 'refs/tags/v1.2.3'; repository = 'https://github.com/upstream/platform'
                    path = '.github/workflows/release.yml'
                } }
                resolvedDependencies = @(@{
                    uri = 'git+https://github.com/upstream/platform@refs/tags/v1.2.3'
                    digest = @{ gitCommit = 'a' * 40 }
                })
            }
            runDetails = @{ builder = @{ id = 'https://github.com/actions/runner/github-hosted' } }
        }
        Mock gh -ModuleName PublicationAttestation {
            $global:LASTEXITCODE = 0
            ConvertTo-Json -InputObject $verification -Depth 30
        }
        $provenanceArguments = @{} + $arguments
        $provenanceArguments.Remove('PublisherAppId')

        $statement = Get-PlatformBuildProvenance @provenanceArguments

        $statement.GetProperty('predicateType').GetString() | Should -BeExactly 'https://slsa.dev/provenance/v1'
        Should -Invoke gh -ModuleName PublicationAttestation -Times 1 -Exactly -ParameterFilter {
            $args[[array]::IndexOf($args, '--predicate-type') + 1] -ceq 'https://slsa.dev/provenance/v1' -and
            $args[[array]::IndexOf($args, '--source-digest') + 1] -ceq ('a' * 40) -and
            $args[[array]::IndexOf($args, '--signer-digest') + 1] -ceq ('a' * 40)
        }
    }

    It 'rejects the verified predicate when <Case>' -Tag AttestationPredicate -ForEach @(
        @{ Case = 'the phase is admitted'; Field = 'phase'; Value = 'admitted'; Error = '*not published*' }
        @{ Case = 'the revision is different'; Field = 'commit'; Value = 'cccccccccccccccccccccccccccccccccccccccc'; Error = '*check head_sha*' }
        @{ Case = 'the App is different'; Field = 'publisherAppId'; Value = 8; Error = '*pinned publisher App*' }
        @{ Case = 'the repository is different'; Field = 'repository'; Value = 'other/platform'; Error = '*predicate repository*' }
        @{ Case = 'the ref is different'; Field = 'ref'; Value = 'refs/heads/main'; Error = '*witness ref*' }
        @{ Case = 'the receipt digest is invalid'; Field = 'receiptSha256'; Value = 'short'; Error = '*receiptSha256*' }
        @{ Case = 'the receipt digest differs in case'; Field = 'receiptSha256'; Value = 'BBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBBB'; Error = '*receiptSha256*' }
        @{ Case = 'the external ID describes another receipt'; Field = 'externalId'; Value = 'platform-source-publication/v1:cccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccccc'; Error = '*external_id*' }
        @{ Case = 'the check ID is opaque'; Field = 'checkId'; Value = 'opaque'; Error = '*check id*' }
        @{ Case = 'the context is different'; Field = 'context'; Value = 'CI'; Error = '*check name*' }
        @{ Case = 'the kind is different'; Field = 'kind'; Value = 'development'; Error = '*witness kind*' }
        @{ Case = 'the schema is different'; Field = 'schemaVersion'; Value = 2; Error = '*schemaVersion*' }
    ) {
        Import-Module $modulePath -Force
        $verification[0].verificationResult.statement.predicate[$Field] = $Value
        Mock gh -ModuleName PublicationAttestation {
            $global:LASTEXITCODE = 0
            ConvertTo-Json -InputObject $verification -Depth 30
        }

        { Get-PlatformPublicationAttestation @arguments } | Should -Throw $Error
    }

    It 'rejects malformed verification output: <Case>' -Tag AttestationEnvelope -ForEach @(
        @{ Case = 'a scalar result'; Change = { $verification = $verification[0] }; Error = '*exactly one verified statement*' }
        @{ Case = 'an empty result'; Change = { $verification = @() }; Error = '*exactly one verified statement*' }
        @{ Case = 'ambiguous verified records'; Change = { $verification += $verification[0] }; Error = '*exactly one verified statement*' }
        @{ Case = 'a scalar record'; Change = { $verification = @(1) }; Error = '*verified statement object*' }
        @{ Case = 'a missing verification result'; Change = { $verification[0].Remove('verificationResult') }; Error = '*verified statement object*' }
        @{ Case = 'a scalar verification result'; Change = { $verification[0].verificationResult = 1 }; Error = '*verified statement object*' }
        @{ Case = 'a missing statement'; Change = { $verification[0].verificationResult.Remove('statement') }; Error = '*verified statement object*' }
        @{ Case = 'a scalar statement'; Change = { $verification[0].verificationResult.statement = 1 }; Error = '*verified statement object*' }
        @{ Case = 'a missing statement schema'; Change = { $verification[0].verificationResult.statement.Remove('_type') }; Error = '*statement schema*' }
        @{ Case = 'a numeric statement schema'; Change = { $verification[0].verificationResult.statement._type = 1 }; Error = '*statement schema*' }
        @{ Case = 'a missing predicate type'; Change = { $verification[0].verificationResult.statement.Remove('predicateType') }; Error = '*predicate type*' }
        @{ Case = 'a numeric predicate type'; Change = { $verification[0].verificationResult.statement.predicateType = 1 }; Error = '*predicate type*' }
        @{ Case = 'missing subjects'; Change = { $verification[0].verificationResult.statement.Remove('subject') }; Error = '*archive subject inventory*' }
        @{ Case = 'a scalar subject list'; Change = { $verification[0].verificationResult.statement.subject = $verification[0].verificationResult.statement.subject[0] }; Error = '*archive subject inventory*' }
        @{ Case = 'a scalar subject'; Change = { $verification[0].verificationResult.statement.subject = @(1) }; Error = '*archive subject name or digest*' }
        @{ Case = 'a numeric subject name'; Change = { $verification[0].verificationResult.statement.subject[0].name = 1 }; Error = '*archive subject name or digest*' }
        @{ Case = 'a scalar digest'; Change = { $verification[0].verificationResult.statement.subject[0].digest = 'sha256:invalid' }; Error = '*archive subject name or digest*' }
        @{ Case = 'a numeric digest'; Change = { $verification[0].verificationResult.statement.subject[0].digest.sha256 = 1 }; Error = '*archive subject name or digest*' }
    ) {
        Import-Module $modulePath -Force
        # Deliberately invalid variants of the documented CLI verification output.
        . $Change
        Mock gh -ModuleName PublicationAttestation {
            $global:LASTEXITCODE = 0
            ConvertTo-Json -InputObject $verification -Depth 30
        }

        { Get-PlatformPublicationAttestation @arguments } | Should -Throw $Error
    }

    It 'rejects a failed signature or signer policy even if gh printed a well-formed result' {
        Import-Module $modulePath -Force
        Mock gh -ModuleName PublicationAttestation {
            $global:LASTEXITCODE = 1
            ConvertTo-Json -InputObject $verification -Depth 30
        }

        { Get-PlatformPublicationAttestation @arguments } | Should -Throw '*signature or pinned signer policy*'
    }

    It 'rejects non-JSON verification output after exit zero' {
        Import-Module $modulePath -Force
        Mock gh -ModuleName PublicationAttestation { $global:LASTEXITCODE = 0; 'not a verification result' }

        { Get-PlatformPublicationAttestation @arguments } | Should -Throw '*Invalid attestation verification JSON*'
    }

    It 'rejects <Case> predicate fields' -Tag AttestationPredicate -ForEach @(
        @{ Case = 'missing'; Change = { $verification[0].verificationResult.statement.predicate.Remove('phase') }; Error = '*Missing publication attestation predicate fields*' }
        @{ Case = 'unknown'; Change = { $verification[0].verificationResult.statement.predicate['verified'] = $true }; Error = '*Invalid publication attestation predicate fields*' }
        @{ Case = 'case-folded'; Change = { $p = $verification[0].verificationResult.statement.predicate; $p.Remove('phase'); $p['Phase'] = 'published' }; Error = '*Invalid publication attestation predicate fields*' }
        @{ Case = 'non-object'; Change = { $verification[0].verificationResult.statement.predicate = @() }; Error = '*predicate must be an object*' }
        @{ Case = 'absent'; Change = { $verification[0].verificationResult.statement.Remove('predicate') }; Error = '*predicate must be an object*' }
        @{ Case = 'non-string repository'; Change = { $verification[0].verificationResult.statement.predicate.repository = 1 }; Error = '*predicate repository*' }
        @{ Case = 'case-folded repository'; Change = { $verification[0].verificationResult.statement.predicate.repository = 'Upstream/platform' }; Error = '*predicate repository*' }
    ) {
        Import-Module $modulePath -Force
        # Deliberately malformed signed claims must not become an authenticated publication.
        . $Change
        Mock gh -ModuleName PublicationAttestation {
            $global:LASTEXITCODE = 0
            ConvertTo-Json -InputObject $verification -Depth 30
        }

        { Get-PlatformPublicationAttestation @arguments } | Should -Throw $Error
    }

    It 'rejects a duplicate predicate field without normalizing it away' -Tag AttestationPredicate {
        Import-Module $modulePath -Force
        $duplicateJson = (ConvertTo-Json -InputObject $verification -Depth 30 -Compress).Replace('"phase":"published"', '"phase":"admitted","phase":"published"')
        Mock gh -ModuleName PublicationAttestation { $global:LASTEXITCODE = 0; $duplicateJson }

        { Get-PlatformPublicationAttestation @arguments } | Should -Throw '*Invalid publication attestation predicate fields*'
    }

    It 'keeps verification anonymous and restores all credential routing after <Case>' -ForEach @(
        @{ Case = 'success'; Exit = 0 }; @{ Case = 'a signature failure'; Exit = 1 }
    ) {
        Import-Module $modulePath -Force
        $original = @{}
        foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_HOST', 'GH_CONFIG_DIR')) {
            $original[$name] = [Environment]::GetEnvironmentVariable($name)
            [Environment]::SetEnvironmentVariable($name, "fixture-$name")
        }
        try {
            $observed = @{}
            Mock gh -ModuleName PublicationAttestation {
                foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_HOST', 'GH_CONFIG_DIR')) {
                    $observed[$name] = [Environment]::GetEnvironmentVariable($name)
                }
                $global:LASTEXITCODE = $Exit
                ConvertTo-Json -InputObject $verification -Depth 30
            }
            if ($Exit) { { Get-PlatformPublicationAttestation @arguments } | Should -Throw '*signature or pinned signer policy*' }
            else { $null = Get-PlatformPublicationAttestation @arguments }

            foreach ($name in @('GH_TOKEN', 'GITHUB_TOKEN', 'GH_ENTERPRISE_TOKEN', 'GITHUB_ENTERPRISE_TOKEN', 'GH_HOST')) {
                $observed[$name] | Should -BeNullOrEmpty
            }
            $observed.GH_CONFIG_DIR | Should -Not -BeExactly 'fixture-GH_CONFIG_DIR'
            Test-Path -LiteralPath $observed.GH_CONFIG_DIR | Should -BeFalse
            foreach ($name in $original.get_Keys()) { [Environment]::GetEnvironmentVariable($name) | Should -BeExactly "fixture-$name" }
        }
        finally { foreach ($name in $original.get_Keys()) { [Environment]::SetEnvironmentVariable($name, $original[$name]) } }
    }
}
