BeforeAll {
    $download = Join-Path (Split-Path $PSScriptRoot -Parent) 'Get-VendoringSource.ps1'
    function gh { $global:LASTEXITCODE = 0 }
}

Describe 'Tagged vendoring source and attestation policy' {
    BeforeEach {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $fakeAttestations = @()
        $verifyExitCode = 0
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return @{ object = @{ type = 'commit'; sha = '3333333333333333333333333333333333333333' } } }
            if ($Uri -like '*/attestations/sha256:*') { return @{ attestations = $fakeAttestations } }
            throw "Unexpected source API: $Uri"
        }
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
        }
        Mock gh { $global:LASTEXITCODE = $verifyExitCode }
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
        $fakeAttestations = @(@{ bundle_url = 'https://example.test/bundle' })
        $verifyExitCode = 1
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*Invalid or unverifiable source attestation*import stopped*'
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
        Should -Invoke gh -Times 1 -Exactly
    }

    It 'records successful provenance verification rather than treating presence as verification' {
        $fakeAttestations = @(@{ bundle_url = 'https://example.test/bundle' })
        $result = & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work
        $result.Attestation | Should -Be 'verified'
        Should -Invoke gh -Times 1 -Exactly
    }

    It 'does not interpret attestation API errors as absence' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return @{ object = @{ type = 'commit'; sha = '3333333333333333333333333333333333333333' } } }
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
        }
        { & $download -Repository upstream/action -Tag v1.2.3 -ApiUrl https://api.github.com -WorkPath $work } |
            Should -Throw '*Unsafe or duplicate archive entry*'
        Test-Path -LiteralPath (Join-Path $work 'extracted') | Should -BeFalse
    }

    It 'accepts digest 404 only after confirming the GitHub.com repository is public' {
        Mock Invoke-RestMethod {
            param($Uri)
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return @{ object = @{ type = 'commit'; sha = '3333333333333333333333333333333333333333' } } }
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
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return @{ object = @{ type = 'commit'; sha = '3333333333333333333333333333333333333333' } } }
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
            if ($Uri -like '*/git/ref/tags/v1.2.3') { return @{ object = @{ type = 'tag'; sha = '4444444444444444444444444444444444444444' } } }
            if ($Uri -like '*/git/tags/4444444444444444444444444444444444444444') { return @{ object = @{ type = 'commit'; sha = '3333333333333333333333333333333333333333' } } }
            if ($Uri -like '*/releases/tags/v1.2.3') { return @{ assets = @(@{ id = 17; name = 'platform.zip' }) } }
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
