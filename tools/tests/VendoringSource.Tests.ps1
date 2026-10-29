BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $download = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-VendoringSource.ps1'
    function gh { $global:LASTEXITCODE = 0 }
    function ConvertTo-SnappyLiteral([string] $Text) {
        # Minimal valid snappy block: varint length, then one literal element (lengths up to 60 bytes).
        $bytes = [Text.Encoding]::UTF8.GetBytes($Text)
        return [byte[]] (@([byte] $bytes.Length, [byte] (($bytes.Length - 1) -shl 2)) + $bytes)
    }
    function Get-AttestationList([string[]] $BundleUrl) {
        $list = Get-GitHubApiFixture -Name repos/list-attestations
        $template = $list.attestations[0]
        $list.attestations = [Collections.Generic.List[object]]::new()
        foreach ($url in $BundleUrl) { $item = @{} + $template; $item.bundle_url = $url; $list.attestations.Add($item) }
        return $list
    }
    function Set-MockedSourceResponseHeaders([string] $Name, $Link) {
        for ($scope = 1; $scope -le 16; $scope++) {
            $variable = Get-Variable -Name $Name -Scope $scope -ErrorAction SilentlyContinue
            if ($null -eq $variable) { continue }
            $variable.Value = @{ Link = $Link }
            return
        }
        throw "Cannot find source response-header variable '$Name' in the request scope."
    }
    $snappyAst = [Management.Automation.Language.Parser]::ParseFile($download, [ref] $null, [ref] $null)
    $snappyFunction = $snappyAst.Find({ param($node) $node -is [Management.Automation.Language.FunctionDefinitionAst] -and $node.Name -ceq 'ConvertFrom-SnappyBlock' }, $true)
    . ([scriptblock]::Create($snappyFunction.Extent.Text))
}

Describe 'Snappy attestation bundle decoding' {
    It 'decodes literals and back-references' {
        $decoded = ConvertFrom-SnappyBlock -Data ([byte[]] (9, 0x08, 0x61, 0x62, 0x63, 0x09, 0x03))
        [Text.Encoding]::ASCII.GetString($decoded) | Should -Be 'abcabcabc'
    }

    It 'decodes two-byte offset copies' {
        $decoded = ConvertFrom-SnappyBlock -Data ([byte[]] (6, 0x08, 0x61, 0x62, 0x63, 0x0A, 0x03, 0x00))
        [Text.Encoding]::ASCII.GetString($decoded) | Should -Be 'abcabc'
    }

    It 'rejects <Case>' -ForEach @(
        @{ Case = 'a copy before any output'; Data = [byte[]] (4, 0x01, 0x01) }
        @{ Case = 'a copy offset beyond the output'; Data = [byte[]] (7, 0x08, 0x61, 0x62, 0x63, 0x09, 0x04) }
        @{ Case = 'a shorter content than declared'; Data = [byte[]] (5, 0x08, 0x61, 0x62, 0x63) }
        @{ Case = 'a longer content than declared'; Data = [byte[]] (2, 0x08, 0x61, 0x62, 0x63) }
        @{ Case = 'a truncated literal'; Data = [byte[]] (3, 0x08, 0x61) }
        @{ Case = 'a declared length over 16 MiB'; Data = [byte[]] (0x81, 0x80, 0x80, 0x08) }
        @{ Case = 'an empty input'; Data = [byte[]] @() }
    ) {
        { ConvertFrom-SnappyBlock -Data $Data } | Should -Throw
    }
}

Describe 'Tagged vendoring source and attestation policy' {
    BeforeEach {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $fakeAttestations = @{ attestations = @() }
        $verifyExitCodes = @(0)
        $verifyCalls = [Collections.Generic.List[object]]::new()
        $bundleBytes = ConvertTo-SnappyLiteral '{"mediaType":"sigstore-bundle"}'
        $comparison = Get-GitHubApiFixture -Name repos/compare-commits -Set @{ status = 'behind'; 'merge_base_commit.sha' = '3333333333333333333333333333333333333333' }
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' } }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
            if ($Uri -like '*/attestations/sha256:*') { return $fakeAttestations }
            throw "Unexpected source API: $Uri"
        }
        Mock Invoke-WebRequest {
            param($OutFile)
            [IO.File]::WriteAllBytes($OutFile, $bundleBytes)
        } -ParameterFilter { $Uri -like 'https://bundles.test/*' }
        Mock Invoke-WebRequest {
            param($OutFile)
            $archive = [IO.Compression.ZipFile]::Open($OutFile, [IO.Compression.ZipArchiveMode]::Create)
            try {
                $entry = $archive.CreateEntry('upstream-commit/action.yml')
                $writer = [IO.StreamWriter]::new($entry.Open())
                $writer.Write("name: fixture`ndescription: fixture`nruns:`n  using: node20`n  main: index.js`n")
                $writer.Dispose()
            }
            finally { $archive.Dispose() }
        } -ParameterFilter { $Uri -notlike 'https://bundles.test/*' }
        Mock gh {
            $bundleIndex = [array]::IndexOf($args, '--bundle')
            $verifyCalls.Add([pscustomobject] @{
                Arguments = @($args)
                Bundle = if ($bundleIndex -ge 0) { Get-Content -LiteralPath $args[$bundleIndex + 1] -Raw } else { $null }
                Token = $env:GH_TOKEN
            })
            $global:LASTEXITCODE = $verifyExitCodes[[Math]::Min($verifyCalls.Count - 1, $verifyExitCodes.Count - 1)]
        }
    }

    It 'resolves the exact tag to a commit before downloading and records absent attestations explicitly' {
        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work
        $result.Commit | Should -Be '3333333333333333333333333333333333333333'
        $result.Attestation | Should -Be 'not-present'
        Test-Path -LiteralPath (Join-Path $result.SourcePath 'action.yml') | Should -BeTrue
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/upstream/action/zipball/3333333333333333333333333333333333333333'
        }
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'stops an invalid attestation before extracting any source' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $verifyExitCodes = @(1)
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*Invalid or unverifiable source attestation*import stopped*'
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
        Should -Invoke gh -Times 1 -Exactly
    }

    It 'records successful provenance verification rather than treating presence as verification' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work
        $result.Attestation | Should -Be 'verified'
        Should -Invoke gh -Times 1 -Exactly
    }

    It 'verifies the decompressed bundle offline against the full tag, commit and hosted-runner policy' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $null = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml
        $call = $verifyCalls[0]
        $call.Bundle | Should -BeExactly '{"mediaType":"sigstore-bundle"}'
        $call.Token | Should -BeNullOrEmpty
        $text = $call.Arguments -join ' '
        $text | Should -Match '^attestation verify \S+source\.zip --bundle \S+\.json '
        $text | Should -Match '--repo upstream/action --hostname github\.com '
        $text | Should -Match '--source-ref refs/tags/v1\.2\.3 --source-digest 3{40} --deny-self-hosted-runners'
        $text | Should -Match '--signer-workflow upstream/action/\.github/workflows/release\.yml$'
    }

    It 'does not send the GitHub credential to the pre-signed bundle URL' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $null = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work -InstallationToken ghs_installation
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter { $Uri -like 'https://bundles.test/*' -and $null -eq $Headers }
    }

    It 'accepts provenance when one of several attestations satisfies the policy' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn', 'https://bundles.test/2.json.sn'
        $verifyExitCodes = @(1, 0)
        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work
        $result.Attestation | Should -Be 'verified'
        Should -Invoke gh -Times 2 -Exactly
    }

    It 'verifies a matching attestation on the next cursor page after 30 unrelated attestations' -Tag AttestationPagination {
        $firstPage = Get-AttestationList @(1..30 | ForEach-Object { "https://bundles.test/$($_).json.sn" })
        $secondPage = Get-AttestationList 'https://bundles.test/31.json.sn'
        $verifyExitCodes = @(1..30 | ForEach-Object { 1 }) + @(0)
        Mock Invoke-RestMethod {
            param($Uri, $ResponseHeadersVariable)
            if ($Uri -like '*/git/ref/tags/v1.2.3') {
                return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' }
            }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
            if ($Uri -match '/attestations/sha256:[a-f0-9]{64}\?after=cursor-two$') { return $secondPage }
            if ($Uri -match '/attestations/sha256:[a-f0-9]{64}$') {
                if ($ResponseHeadersVariable) {
                    Set-MockedSourceResponseHeaders -Name $ResponseHeadersVariable `
                        -Link "<${Uri}?after=cursor-two>; rel=`"next`", <${Uri}?after=cursor-two>; rel=`"last`""
                }
                return $firstPage
            }
            throw "Unexpected source API: $Uri"
        }

        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main

        $result.Attestation | Should -BeExactly 'verified'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -match '/attestations/sha256:[a-f0-9]{64}\?after=cursor-two$' }
        Should -Invoke gh -Times 31 -Exactly
        ($verifyCalls[30].Arguments -join ' ') | Should -Match '--source-ref refs/tags/v1\.2\.3 --source-digest 3{40} --deny-self-hosted-runners --signer-workflow upstream/action/\.github/workflows/release\.yml$'
    }

    It 'rejects unsafe attestation pagination with <Case>' -Tag AttestationPagination -ForEach @(
        @{ Case = 'an empty Link collection'; Link = @(); ErrorPattern = '*Unreadable source attestation pagination Link*' }
        @{ Case = 'an empty Link value'; Link = ''; ErrorPattern = '*Unreadable source attestation pagination Link*' }
        @{ Case = 'a whitespace Link value'; Link = '   '; ErrorPattern = '*Unreadable source attestation pagination Link*' }
        @{ Case = 'a malformed Link header'; Link = '<{digest}?after=one; rel="next"'; ErrorPattern = '*Unreadable source attestation pagination Link*' }
        @{ Case = 'duplicate next relations'; Link = '<{digest}?after=one>; rel="next", <{digest}?after=two>; rel="next"'; ErrorPattern = '*Multiple next-page links*' }
        @{ Case = 'a foreign API origin'; Link = '<https://other.invalid/repos/upstream/action/attestations/sha256:abc?after=one>; rel="next"'; ErrorPattern = '*outside the digest endpoint*' }
        @{ Case = 'a different digest path'; Link = '<{otherDigest}?after=one>; rel="next"'; ErrorPattern = '*outside the digest endpoint*' }
        @{ Case = 'a URL fragment'; Link = '<{digest}?after=one#fragment>; rel="next"'; ErrorPattern = '*outside the digest endpoint*' }
        @{ Case = 'no cursor'; Link = '<{digest}>; rel="next"'; ErrorPattern = '*no cursor*' }
        @{ Case = 'only per_page without a cursor'; Link = '<{digest}?per_page=30>; rel="next"'; ErrorPattern = '*Invalid source attestation pagination cursor*' }
        @{ Case = 'an uppercase cursor key'; Link = '<{digest}?After=one>; rel="next"'; ErrorPattern = '*Invalid source attestation pagination cursor*' }
        @{ Case = 'a cursor with an extra query field'; Link = '<{digest}?after=one&access_token=secret>; rel="next"'; ErrorPattern = '*Invalid source attestation pagination cursor*' }
        @{ Case = 'duplicate cursor fields'; Link = '<{digest}?after=one&after=two>; rel="next"'; ErrorPattern = '*Invalid source attestation pagination cursor*' }
    ) {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $verifyExitCodes = @(1)
        $requests = [Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            param($Uri, $ResponseHeadersVariable)
            if ($Uri -like '*/git/ref/tags/v1.2.3') {
                return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' }
            }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
            $requests.Add([string] $Uri)
            if ($requests.Count -gt 3) { throw 'Pagination mock stopped an unbounded request loop.' }
            if ($Uri -match '/attestations/sha256:[a-f0-9]{64}$') {
                if ($ResponseHeadersVariable) {
                    $otherDigest = $Uri -replace '[a-f0-9]{64}$', ('a' * 64)
                    $linkValue = $Link
                    if ($Link -is [string]) { $linkValue = $Link.Replace('{digest}', $Uri).Replace('{otherDigest}', $otherDigest) }
                    Set-MockedSourceResponseHeaders -Name $ResponseHeadersVariable `
                        -Link $linkValue
                }
                return $fakeAttestations
            }
            throw "Unexpected source API: $Uri"
        }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -InstallationToken ghs_installation -SignerWorkflow upstream/action/.github/workflows/release.yml `
            -RequireAttestation -ProtectedBranch main } | Should -Throw $ErrorPattern
        $requests.Count | Should -Be 1
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'rejects a cyclic attestation next link to <Case> without repeating a request' -Tag AttestationPagination -ForEach @(
        @{ Case = 'the current page'; Cycle = 'self'; RequestCount = 2 }
        @{ Case = 'a previously visited page'; Cycle = 'prior'; RequestCount = 3 }
    ) {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $verifyExitCodes = @(1)
        $requests = [Collections.Generic.List[string]]::new()
        Mock Invoke-RestMethod {
            param($Uri, $ResponseHeadersVariable)
            if ($Uri -like '*/git/ref/tags/v1.2.3') {
                return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' }
            }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
            $requests.Add([string] $Uri)
            if ($requests.Count -gt 4) { throw 'Pagination mock stopped an unbounded request loop.' }
            if ($Uri -match '/attestations/sha256:[a-f0-9]{64}(\?after=(one|two))?$') {
                if ($ResponseHeadersVariable) {
                    if ($Uri -match '\?after=two$') { $next = $Uri -replace 'after=two$', 'after=one' }
                    elseif ($Uri -match '\?after=one$' -and $Cycle -eq 'prior') { $next = $Uri -replace 'after=one$', 'after=two' }
                    elseif ($Uri -match '\?after=one$') { $next = $Uri }
                    else { $next = "${Uri}?after=one" }
                    Set-MockedSourceResponseHeaders -Name $ResponseHeadersVariable -Link "<$next>; rel=`"next`""
                }
                return $fakeAttestations
            }
            throw "Unexpected source API: $Uri"
        }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main } |
            Should -Throw '*Cyclic source attestation pagination link*'
        $requests.Count | Should -Be $RequestCount
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'does not treat a later attestation page 404 as public absence' -Tag AttestationPagination {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $verifyExitCodes = @(1)
        Mock Invoke-RestMethod {
            param($Uri, $ResponseHeadersVariable)
            if ($Uri -like '*/git/ref/tags/v1.2.3') {
                return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' }
            }
            if ($Uri -match '/compare/main\.\.\.3{40}\?per_page=1$') { return $comparison }
            if ($Uri -match '\?after=one$') {
                $httpResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
                throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Later page not found', $httpResponse)
            }
            if ($Uri -match '/attestations/sha256:[a-f0-9]{64}$') {
                if ($ResponseHeadersVariable) {
                    Set-MockedSourceResponseHeaders -Name $ResponseHeadersVariable -Link "<${Uri}?after=one>; rel=`"next`""
                }
                return $fakeAttestations
            }
            throw "Unexpected source API: $Uri"
        }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main } |
            Should -Throw '*Later page not found*'
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Uri -match '/attestations/sha256:[a-f0-9]{64}\?after=one$' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Uri -eq 'https://api.github.com/repos/upstream/action' }
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'stops when no attestation of several satisfies the policy' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn', 'https://bundles.test/2.json.sn'
        $verifyExitCodes = @(1, 1)
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*Invalid or unverifiable source attestation*'
        Should -Invoke gh -Times 2 -Exactly
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'rejects a bundle URL that is <Case>' -ForEach @(
        @{ Case = 'plain HTTP'; Url = 'http://bundles.test/1.json.sn' }
        @{ Case = 'relative'; Url = '/attestations/1.json.sn' }
        @{ Case = 'carrying user info'; Url = 'https://user:secret@bundles.test/1.json.sn' }
        @{ Case = 'empty'; Url = '' }
    ) {
        $fakeAttestations = Get-AttestationList $Url
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*no HTTPS bundle_url*'
        Should -Invoke gh -Times 0 -Exactly
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly -ParameterFilter { $Uri -like '*bundles.test*' -or $Uri -like '/attestations*' }
    }

    It 'rejects an attestation without bundle_url' {
        # Deliberately invalid: the documented schema does not require bundle_url, so its absence must fail closed.
        $fakeAttestations = @{ attestations = @(@{ repository_id = 1; initiator = 'user' }) }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*no HTTPS bundle_url*'
        Should -Invoke gh -Times 0 -Exactly
    }

    It 'accepts a required attestation verified against the pinned signer workflow' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main
        $result.Attestation | Should -Be 'verified'
    }

    It 'stops a required-attestation import when the digest has no attestation' {
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main } |
            Should -Throw '*requires a verified attestation from a pinned signer workflow*'
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'stops a required-attestation import without a pinned signer workflow' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work -RequireAttestation -ProtectedBranch main } |
            Should -Throw '*requires a verified attestation from a pinned signer workflow*'
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'stops a required-attestation import without a protected source branch before downloading' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation } |
            Should -Throw '*needs the protected source branch*'
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'accepts a release commit that is <Case> the protected branch' -ForEach @(
        @{ Case = 'behind'; Status = 'behind' }
        @{ Case = 'identical to'; Status = 'identical' }
    ) {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $comparison = Get-GitHubApiFixture -Name repos/compare-commits -Set @{ status = $Status; 'merge_base_commit.sha' = '3333333333333333333333333333333333333333' }
        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main
        $result.Attestation | Should -Be 'verified'
    }

    It 'stops a release commit off the protected branch when <Case>' -ForEach @(
        @{ Case = 'the commit is ahead'; Status = 'ahead'; MergeBase = '3333333333333333333333333333333333333333' }
        @{ Case = 'the commit diverged'; Status = 'diverged'; MergeBase = '3333333333333333333333333333333333333333' }
        @{ Case = 'status differs in case'; Status = 'Behind'; MergeBase = '3333333333333333333333333333333333333333' }
        @{ Case = 'status is empty'; Status = ''; MergeBase = '3333333333333333333333333333333333333333' }
        @{ Case = 'the merge base is another commit'; Status = 'behind'; MergeBase = '4444444444444444444444444444444444444444' }
        @{ Case = 'the merge base is an abbreviated SHA'; Status = 'identical'; MergeBase = '3333333' }
        @{ Case = 'the merge base is empty'; Status = 'behind'; MergeBase = '' }
    ) {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $comparison = Get-GitHubApiFixture -Name repos/compare-commits -Set @{ status = $Status; 'merge_base_commit.sha' = $MergeBase }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main } |
            Should -Throw "*not on the protected branch 'main'*"
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'stops a release commit off the protected branch when the merge base differs only in case' {
        $tagCommit = 'abcdef0123456789abcdef0123456789abcdef01'
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = $tagCommit } }
            if ($Uri -like "*/compare/main...${tagCommit}?per_page=1") {
                return Get-GitHubApiFixture -Name repos/compare-commits -Set @{ status = 'identical'; 'merge_base_commit.sha' = $tagCommit.ToUpperInvariant() }
            }
            throw "Unexpected source API: $Uri"
        }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main } |
            Should -Throw "*not on the protected branch 'main'*"
        Should -Invoke Invoke-WebRequest -Times 0 -Exactly
    }

    It 'stops a required-attestation import after a public 404 instead of accepting unverified provenance' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' } }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
            if ($Uri -eq 'https://api.github.com/repos/upstream/action') { return Get-GitHubApiFixture -Name repos/get -Set @{ full_name = 'upstream/action'; private = $false } }
            $httpResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $httpResponse)
        }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work `
            -SignerWorkflow upstream/action/.github/workflows/release.yml -RequireAttestation -ProtectedBranch main 3>$null } |
            Should -Throw '*requires a verified attestation*'
    }

    Context 'rate-limited source API' {
        BeforeEach {
            Mock Start-Sleep { }
            $failures = [Collections.Generic.Queue[object]]::new()
            function Get-RateLimitError([int] $Status, [hashtable] $Header, [string] $Body = '{"message":"API rate limit exceeded"}') {
                $httpResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode] $Status)
                foreach ($name in $Header.Keys) { $null = $httpResponse.Headers.TryAddWithoutValidation($name, [string] $Header[$name]) }
                $exception = [Microsoft.PowerShell.Commands.HttpResponseException]::new('rate limited', $httpResponse)
                $record = [Management.Automation.ErrorRecord]::new($exception, 'RateLimited', 'InvalidOperation', $null)
                $record.ErrorDetails = [Management.Automation.ErrorDetails]::new($Body)
                return $record
            }
            Mock Invoke-RestMethod {
                param($Uri)
                if ($failures.Count -gt 0) { throw $failures.Dequeue() }
                if ($Uri -like '*/git/ref/tags/v1.2.3') { return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' } }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
                if ($Uri -like '*/attestations/sha256:*') { return $fakeAttestations }
                throw "Unexpected source API: $Uri"
            }
        }

        It 'waits for the primary limit reset and retries the same request' {
            $reset = [DateTimeOffset]::UtcNow.AddSeconds(30).ToUnixTimeSeconds()
            $failures.Enqueue((Get-RateLimitError 403 @{ 'x-ratelimit-remaining' = '0'; 'x-ratelimit-reset' = "$reset" }))
            $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work 3>$null
            $result.Commit | Should -Be '3333333333333333333333333333333333333333'
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -ge 1 -and $Seconds -le 31 }
        }

        It 'stops with a clear error when the primary limit resets after the allowed wait' {
            $reset = [DateTimeOffset]::UtcNow.AddMinutes(30).ToUnixTimeSeconds()
            $failures.Enqueue((Get-RateLimitError 429 @{ 'x-ratelimit-remaining' = '0'; 'x-ratelimit-reset' = "$reset" }))
            { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
                Should -Throw '*rate limit for the source is exhausted (HTTP 429)*'
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }

        It 'honours retry-after for a secondary limit' {
            $failures.Enqueue((Get-RateLimitError 429 @{ 'retry-after' = '7' }))
            $null = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work 3>$null
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 7 }
        }

        It 'backs off exponentially on a secondary limit without headers and gives up after three retries' {
            1..4 | ForEach-Object { $failures.Enqueue((Get-RateLimitError 403 @{} '{"message":"You have exceeded a secondary rate limit."}')) }
            { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work -MaxRateLimitWaitSeconds 3600 3>$null } |
                Should -Throw '*rate limit for the source is exhausted (HTTP 403)*'
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 60 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 120 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 240 }
            Should -Invoke Start-Sleep -Times 3 -Exactly
        }

        It 'does not retry a 403 that is not a rate limit' {
            $failures.Enqueue((Get-RateLimitError 403 @{ 'x-ratelimit-remaining' = '42' } '{"message":"Resource not accessible by integration"}'))
            { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
                Should -Throw '*Cannot read source tag*'
            Should -Invoke Start-Sleep -Times 0 -Exactly
        }
    }

    It 'stops on a corrupt compressed bundle before verification and extraction' {
        $fakeAttestations = Get-AttestationList 'https://bundles.test/1.json.sn'
        $bundleBytes = [byte[]] (9, 0x08, 0x61)
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*snappy*'
        Should -Invoke gh -Times 0 -Exactly
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'does not interpret attestation API errors as absence' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' } }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
            throw 'Attestation API unavailable (403)'
        }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*Attestation API unavailable*'
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'rejects personal source credentials before making an API request' {
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work -InstallationToken ghp_personal } |
            Should -Throw '*installation token*not a personal PAT or OAuth*'
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly
    }

    It 'rejects archive path traversal before creating extracted files' {
        Mock Invoke-WebRequest {
            param($OutFile)
            $archive = [IO.Compression.ZipFile]::Open($OutFile, [IO.Compression.ZipArchiveMode]::Create)
            $null = $archive.CreateEntry('root/../../outside.txt')
            $archive.Dispose()
        } -ParameterFilter { $Uri -notlike 'https://bundles.test/*' }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*Unsafe or duplicate archive entry*'
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'accepts digest 404 only after confirming the GitHub.com repository is public' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' } }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
            if ($Uri -eq 'https://api.github.com/repos/upstream/action') { return @{ full_name = 'upstream/action'; private = $false } }
            $httpResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $httpResponse)
        }
        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work 3>$null
        $result.Attestation | Should -Be 'not-present'
    }

    It 'does not interpret private repository attestation 404 as proven absence' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' } }
            if ($Uri -like '*/compare/main...3333333333333333333333333333333333333333?per_page=1') { return $comparison }
            if ($Uri -eq 'https://api.github.com/repos/upstream/action') { return @{ full_name = 'upstream/action'; private = $true } }
            $httpResponse = [Net.Http.HttpResponseMessage]::new([Net.HttpStatusCode]::NotFound)
            throw [Microsoft.PowerShell.Commands.HttpResponseException]::new('Not Found', $httpResponse)
        }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*Cannot prove attestation absence*manual import*'
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'resolves annotated tags and downloads a named ZIP asset from that release' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'tag'; 'object.sha' = '4444444444444444444444444444444444444444' } }
            if ($Uri -like '*/git/tags/4444444444444444444444444444444444444444') { return Get-GitHubApiFixture -Name git/get-tag -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' } }
            if ($Uri -like '*/releases/tags/v1.2.3') { return Get-GitHubApiFixture -Name repos/get-release-by-tag -Set @{ 'assets.0.id' = 17; 'assets.0.name' = 'platform.zip' } }
            if ($Uri -like '*/attestations/sha256:*') { return @{ attestations = @() } }
            throw "Unexpected source API: $Uri"
        }
        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work -AssetName platform.zip
        $result.Commit | Should -Be '3333333333333333333333333333333333333333'
        $result.Asset | Should -Be platform.zip
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Uri -eq 'https://api.github.com/repos/upstream/action/releases/assets/17' -and $Headers.Accept -ceq 'application/octet-stream'
        }
    }
}
