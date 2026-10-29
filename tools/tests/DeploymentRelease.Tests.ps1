BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $tools = Split-Path $PSScriptRoot -Parent
    $preflight = Join-Path $tools 'Test-DeploymentRelease.ps1'
    function gh { $global:LASTEXITCODE = 0 }
}

Describe 'Deployment release preflight' -Tag 'DeploymentRelease' {
    BeforeEach {
        $candidate = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path "$candidate/platform", "$candidate/vendoring" -Force
        "instance:`n  name: demo" | Set-Content "$candidate/instance.yaml"
        '{"version":2,"actions":{}}' | Set-Content "$candidate/vendoring/actions.json"
        [IO.File]::WriteAllText("$candidate/platform/README.md", 'approved')
        # SHA256 of the literal ASCII string "approved", independent of the verifier.
        $hash = '2687f86ed6784b8a5fca36e6c468e12aa44dc3c7e8137e3160d1a95079bdcd02'
        $marker = @{ instance = 'demo'; releaseVersion = '1.2.3'; files = @{ 'README.md' = $hash } }
        $sourceRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path "$sourceRoot/templates/instance/.github/workflows" -Force
        [IO.File]::WriteAllText("$sourceRoot/README.md", 'approved')
        $null = New-Item -ItemType Directory -Path "$sourceRoot/tools/.dependencies" -Force
        [IO.File]::WriteAllText("$sourceRoot/tools/.dependencies/cache.txt", 'excluded cache')
        $rawWorkflow = 'jobs: {build: {steps: [{uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1}]}}'
        $vendoredWorkflow = "jobs: {build: {steps: [{uses: 'demo-actions/actions-checkout@1111111111111111111111111111111111111111'}]}}"
        foreach ($name in @('deploy.yml', 'vendor.yml')) {
            $relative = "templates/instance/.github/workflows/$name"
            [IO.File]::WriteAllText((Join-Path $sourceRoot $relative), $rawWorkflow)
            $marker.files[$relative] = (Get-FileHash (Join-Path $sourceRoot $relative)).Hash.ToLowerInvariant()
            $destination = Join-Path "$candidate/platform" $relative
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            $content = if ((Get-Variable Mode -ErrorAction SilentlyContinue) -and $Mode -ceq 'transformed') { $vendoredWorkflow } else { $rawWorkflow }
            [IO.File]::WriteAllText($destination, $content)
        }
        '{"version":2,"actions":{"actions/checkout":{"repository":"demo-actions/actions-checkout","sha":"1111111111111111111111111111111111111111","upstreamCommit":"3d3c42e5aac5ba805825da76410c181273ba90b1","tag":"v7.0.1"}}}' |
            Set-Content "$candidate/vendoring/actions.json"
        if ($IsWindows) {
            $directory = Get-Item "$sourceRoot/templates/instance/.github" -Force
            $directory.Attributes = $directory.Attributes -bor [IO.FileAttributes]::Hidden
        }
        $marker | ConvertTo-Json -Depth 10 | Set-Content "$candidate/.platform-bootstrap.json"
        $api = @{ attested = $true; exitCode = 0 }
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') {
                return Get-GitHubApiFixture -Name git/get-ref -Set @{ 'object.type' = 'commit'; 'object.sha' = '3333333333333333333333333333333333333333' }
            }
            if ($Uri -like '*/compare/main...*') {
                return Get-GitHubApiFixture -Name repos/compare-commits -Set @{ status = 'behind'; 'merge_base_commit.sha' = '3333333333333333333333333333333333333333' }
            }
            if ($Uri -like '*/releases/tags/v1.2.3') {
                return Get-GitHubApiFixture -Name repos/get-release-by-tag -Set @{ 'assets.0.name' = 'platform-v1.2.3.zip' }
            }
            if ($Uri -like '*/attestations/sha256:*') {
                $response = Get-GitHubApiFixture -Name repos/list-attestations
                $response.attestations = @(if ($api.attested) { $response.attestations[0] })
                return $response
            }
            throw "Unexpected source API: $Uri"
        }
        Mock Invoke-WebRequest {
            param($Uri, $OutFile)
            if ($Uri -like '*/releases/assets/*') {
                $archive = [IO.Compression.ZipFile]::Open($OutFile, [IO.Compression.ZipArchiveMode]::Create)
                try {
                    $null = $archive.CreateEntry('release/')
                    foreach ($file in Get-ChildItem $sourceRoot -Recurse -Force -File) {
                        $relative = [IO.Path]::GetRelativePath($sourceRoot, $file.FullName).Replace('\', '/')
                        $null = [IO.Compression.ZipFileExtensions]::CreateEntryFromFile($archive, $file.FullName, "release/$relative")
                    }
                }
                finally { $archive.Dispose() }
            }
            else {
                $bytes = [Text.Encoding]::UTF8.GetBytes('{"mediaType":"sigstore-bundle"}')
                [IO.File]::WriteAllBytes($OutFile, [byte[]] (@([byte] $bytes.Length, [byte] (($bytes.Length - 1) -shl 2)) + $bytes))
            }
        }
        Mock gh {
            ($args -join ' ') | Should -Match '--signer-workflow upstream/platform/\.github/workflows/release\.yml'
            ($args -join ' ') | Should -Match '--source-ref refs/tags/v1\.2\.3 --source-digest 3{40} --deny-self-hosted-runners'
            $global:LASTEXITCODE = $api.exitCode
        }
        $arguments = @{ CandidatePath = $candidate; WorkPath = $work; SourceRepository = 'upstream/platform'; PlatformOrganization = 'demo-platform' }
    }

    It 'accepts the exact attested <Mode> release without using source credentials' -Tag 'ReleaseArchiveBoundary' -ForEach @(
        @{ Mode = 'raw' }
        @{ Mode = 'transformed' }
    ) {
        if ($Mode -ceq 'raw') { '{"version":2,"actions":{}}' | Set-Content "$candidate/vendoring/actions.json" }
        else { '{"version":1,"kind":"release"}' | Set-Content "$candidate/platform/.vendoring.json" }
        { & $preflight @arguments } | Should -Not -Throw
        Should -Invoke Invoke-RestMethod -ParameterFilter { $Headers.ContainsKey('Authorization') } -Times 0
    }

    It 'rejects an extra receipt beside the untransformed raw release' -Tag 'ReceiptBoundary' -ForEach @(@{ Mode = 'raw' }) {
        '{"version":1,"kind":"release"}' | Set-Content "$candidate/platform/.vendoring.json"
        { & $preflight @arguments } | Should -Throw '*Candidate hash differs*'
    }

    It 'rejects an array-wrapped release marker before source requests' -Tag 'MarkerArrayBoundary' {
        $json = Get-Content "$candidate/.platform-bootstrap.json" -Raw
        "[$json]" | Set-Content "$candidate/.platform-bootstrap.json"
        { & $preflight @arguments } | Should -Throw '*Release marker must be an object*'
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'rejects marker instance as <Case> before source requests' -Tag 'MarkerInstanceBoundary' -ForEach @(
        @{ Case = 'matching single-element array'; Identity = @('demo') }
        @{ Case = 'empty array'; Identity = @() }
    ) {
        $marker.instance = $Identity
        $marker | ConvertTo-Json -Depth 10 | Set-Content "$candidate/.platform-bootstrap.json"
        { & $preflight @arguments } | Should -Throw '*Release marker instance differs*'
        Should -Invoke Invoke-RestMethod -Times 0
    }

    It 'rejects a symbolic link in <Location>' -Skip:$IsWindows -ForEach @(
        @{ Location = 'release tree' }
        @{ Location = 'marker' }
    ) {
        if ($Location -ceq 'marker') {
            $external = Join-Path $TestDrive 'external-marker.json'
            Move-Item "$candidate/.platform-bootstrap.json" $external
            $null = New-Item -ItemType SymbolicLink -Path "$candidate/.platform-bootstrap.json" -Target $external
        }

        else {
            $external = Join-Path $TestDrive 'external-file'
            [IO.File]::WriteAllText($external, 'approved')
            Remove-Item "$candidate/platform/README.md"
            $null = New-Item -ItemType SymbolicLink -Path "$candidate/platform/README.md" -Target $external
        }
        { & $preflight @arguments } | Should -Throw '*symbolic link*'
    }

    It 'rejects a marker reported as a reparse point before reading its content' {
        Mock Get-Item {
            # Filesystem boundary: the existing marker differs only in the reported reparse attribute.
            [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint }
        } -ParameterFilter { $LiteralPath -eq (Join-Path $candidate '.platform-bootstrap.json') }
        { & $preflight @arguments } | Should -Throw '*Release marker must not be a symbolic link*'
    }

    It 'rejects a directory link at <Location>' -ForEach @(
        @{ Location = 'platform root'; LinkRelative = 'platform' }
        @{ Location = 'nested directory'; LinkRelative = 'platform/templates' }
    ) {
        $path = Join-Path $candidate $LinkRelative
        $external = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        Move-Item $path $external
        $linkType = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $null = New-Item -ItemType $linkType -Path $path -Target $external
        { & $preflight @arguments } | Should -Throw '*Release tree contains symbolic link*'
    }

    It 'rejects <Case> in <Mode> mode' -ForEach @(
        foreach ($mode in @('raw', 'transformed')) {
        foreach ($case in @(
        @{ Case = 'modified file'; Change = { [IO.File]::WriteAllText("$candidate/platform/README.md", 'tampered') }; Error = '*Candidate hash differs*' }
        @{ Case = 'added file'; Change = { Set-Content "$candidate/platform/extra.ps1" 'unapproved' }; Error = '*Candidate file set differs*' }
        @{ Case = 'added candidate cache'; Change = {
            $null = New-Item -ItemType Directory -Path "$candidate/platform/tools/.dependencies" -Force
            Set-Content "$candidate/platform/tools/.dependencies/extra.ps1" 'unapproved'
        }; Error = '*Candidate file set differs*' }
        @{ Case = 'missing file'; Change = { Remove-Item "$candidate/platform/README.md" }; Error = '*Candidate file set differs*' }
        @{ Case = 'modified marker hash'; Change = { $marker.files['README.md'] = '0' * 64 }; Error = '*Marker hash differs*' }
        @{ Case = 'non-string marker hash'; Change = { $marker.files['README.md'] = @($hash) }; Error = '*Marker hash*must be a string*' }
        @{ Case = 'case changed marker hash'; Change = { $marker.files['README.md'] = $hash.ToUpperInvariant() }; Error = '*Marker hash differs*' }
        @{ Case = 'case changed marker path'; Change = { $marker.files.Remove('README.md'); $marker.files['readme.md'] = $hash }; Error = '*Marker is missing*' }
        @{ Case = 'extra marker file'; Change = { $marker.files['extra.ps1'] = $hash }; Error = '*Marker file set differs*' }
        @{ Case = 'empty marker files'; Change = { $marker.files = @{} }; Error = '*Marker file set differs*' }
        @{ Case = 'missing marker files'; Change = { $marker.Remove('files') }; Error = '*marker must declare*' }
        @{ Case = 'non-object marker'; Change = { $marker = @('invalid') }; Error = '*marker must be an object*' }
        @{ Case = 'extra marker property'; Change = { $marker.extra = 'invalid' }; Error = '*marker must declare exactly*' }
        @{ Case = 'invalid marker files type'; Change = { $marker.files = 'invalid' }; Error = '*marker must declare a files mapping*' }
        @{ Case = 'non-string version'; Change = { $marker.releaseVersion = 123 }; Error = '*marker version must be a string*' }
        @{ Case = 'wrong instance'; Change = { $marker.instance = 'other' }; Error = '*marker instance*' }
        @{ Case = 'case changed instance'; Change = { $marker.instance = 'DEMO' }; Error = '*marker instance*' }
        @{ Case = 'empty version'; Change = { $marker.releaseVersion = '' }; Error = '*Release tag*' }
        @{ Case = 'unattested release'; Change = { $api.attested = $false }; Error = '*requires a verified attestation*' }
        @{ Case = 'invalid signature'; Change = { $api.exitCode = 1 }; Error = '*Invalid or unverifiable source attestation*' }
        @{ Case = 'empty attested release'; Change = {
            Get-ChildItem $sourceRoot -Recurse -Force -File | Remove-Item -Force
            Get-ChildItem "$candidate/platform" -Recurse -Force -File | Remove-Item -Force
            $marker.files = @{}
        }; Error = '*Marker has no release files*' }
        @{ Case = 'mixed workflows'; Change = {
            $content = if ($Mode -ceq 'raw') { $vendoredWorkflow } else { $rawWorkflow }
            [IO.File]::WriteAllText("$candidate/platform/templates/instance/.github/workflows/vendor.yml", $content)
        }; Error = '*Candidate hash differs*' }
        )) { $case + @{ Mode = $mode } }
        }
    ) {
        . $Change
        $marker | ConvertTo-Json -Depth 10 | Set-Content "$candidate/.platform-bootstrap.json"
        { & $preflight @arguments } | Should -Throw $Error
    }
}
