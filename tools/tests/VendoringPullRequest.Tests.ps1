BeforeAll {
    $publisher = Join-Path (Split-Path $PSScriptRoot -Parent) 'Publish-VendoringPullRequest.ps1'
    $gitExecutable = (Get-Command git -CommandType Application | Select-Object -First 1).Source
    function git {
        [CmdletBinding()]
        param([Parameter(ValueFromRemainingArguments)][string[]] $Arguments)
        & $gitExecutable @Arguments
    }
}

Describe 'Vendoring diff and pull request publication' {
    BeforeEach {
        $target = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $prepared = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $target, $prepared
        & $gitExecutable -C $target init --quiet --initial-branch=main
        & $gitExecutable -C $target config user.name fixture
        & $gitExecutable -C $target config user.email fixture@example.test
        'original' | Set-Content -LiteralPath (Join-Path $target 'action.yml')
        'obsolete' | Set-Content -LiteralPath (Join-Path $target 'old.js')
        '{"version":1,"kind":"action","files":["action.yml","old.js"]}' |
            Set-Content -LiteralPath (Join-Path $target '.vendoring.json')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m fixture
        'updated' | Set-Content -LiteralPath (Join-Path $prepared 'action.yml')
        $receipt = Join-Path $TestDrive 'receipt.json'
        '{"Repository":"upstream/action","Tag":"v1","Commit":"3333333333333333333333333333333333333333","Sha256":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","Attestation":"not-present","Asset":""}' |
            Set-Content -LiteralPath $receipt
        $savedToken = $env:GH_TOKEN
        $savedMap = $env:PLATFORM_GITHUB_TOKENS
        $env:GH_TOKEN = 'ghs_fixture'
        $env:PLATFORM_GITHUB_TOKENS = '{"customer-actions":"ghs_fixture"}'
        Mock git {
            if ($Arguments -contains 'push') { $global:LASTEXITCODE = 0; return }
            & $gitExecutable @Arguments
        }
        Mock Invoke-RestMethod {
            param($Uri, $Method)
            if ($Uri -like '*/installation/repositories*') {
                return @{ total_count = 1; repositories = @(@{ full_name = 'customer-actions/upstream-action' }) }
            }
            if ($Uri -like '*/pulls' -and $Method -eq 'POST') { return @{ html_url = 'https://example.ghe.com/customer-actions/upstream-action/pull/1' } }
            throw "Unexpected publishing API: $Method $Uri"
        }
    }

    AfterEach {
        $env:GH_TOKEN = $savedToken
        $env:PLATFORM_GITHUB_TOKENS = $savedMap
    }

    It 'opens an App PR containing updated files and deletion of obsolete vendored files' {
        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture

        $result.PullRequest | Should -Be 'https://example.ghe.com/customer-actions/upstream-action/pull/1'
        Get-Content -LiteralPath (Join-Path $target 'action.yml') -Raw | Should -Match 'updated'
        Test-Path -LiteralPath (Join-Path $target 'old.js') | Should -BeFalse
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'POST' -and ($Body | ConvertFrom-Json).base -ceq 'main' -and
            ($Body | ConvertFrom-Json).body -like '*NOT PERFORMED*'
        }
    }

    It 'does not open another PR when the vendored source and provenance are unchanged' {
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture
        & $gitExecutable -C $target branch -f main HEAD
        & $gitExecutable -C $target switch --quiet main

        $result = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier second
        $result.HasChanges | Should -BeFalse
        $result.PullRequest | Should -BeNullOrEmpty
        Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'rejects target workflows as prepared action content before creating any PR' {
        $workflow = Join-Path $prepared '.github/workflows/unsafe.yml'
        $null = New-Item -ItemType Directory -Path (Split-Path $workflow -Parent) -Force
        'name: unsafe' | Set-Content -LiteralPath $workflow
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture } |
            Should -Throw '*outside the action vendoring boundary*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
        Should -Invoke Invoke-RestMethod -Times 0 -Exactly -ParameterFilter { $Method -eq 'POST' }
    }

    It 'preserves instance configuration and live workflows while replacing only the release tree' {
        $null = New-Item -ItemType Directory -Path (Join-Path $target 'platform'), (Join-Path $target '.github/workflows')
        'configured instance' | Set-Content -LiteralPath (Join-Path $target 'instance.yaml')
        'trusted deployment' | Set-Content -LiteralPath (Join-Path $target '.github/workflows/deploy.yml')
        'old release' | Set-Content -LiteralPath (Join-Path $target 'platform/obsolete.txt')
        & $gitExecutable -C $target add .
        & $gitExecutable -C $target commit --quiet -m instance
        Remove-Item -LiteralPath (Join-Path $prepared 'action.yml')
        $null = New-Item -ItemType Directory -Path (Join-Path $prepared 'platform')
        'new release' | Set-Content -LiteralPath (Join-Path $prepared 'platform/README.md')

        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind release `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture
        Get-Content -LiteralPath (Join-Path $target 'instance.yaml') -Raw | Should -Match 'configured instance'
        Get-Content -LiteralPath (Join-Path $target '.github/workflows/deploy.yml') -Raw | Should -Match 'trusted deployment'
        Test-Path -LiteralPath (Join-Path $target 'platform/obsolete.txt') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $target 'platform/README.md') | Should -BeTrue
    }

    It 'restores executable bits from the prepared manifest after artifact transfer has flattened permissions' {
        'entrypoint' | Set-Content -LiteralPath (Join-Path $prepared 'entrypoint.sh')
        $modeManifest = Join-Path $TestDrive 'modes.json'
        '{"version":1,"files":{"action.yml":false,"entrypoint.sh":true}}' | Set-Content -LiteralPath $modeManifest
        $null = & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture -ModeManifestPath $modeManifest

        & $gitExecutable -C $target ls-files --stage entrypoint.sh | Should -Match '^100755 '
        & $gitExecutable -C $target ls-files --stage action.yml | Should -Match '^100644 '
    }

    It 'rejects an executable manifest containing paths outside the prepared inventory' {
        $modeManifest = Join-Path $TestDrive 'invalid-modes.json'
        '{"version":1,"files":{"../escape.sh":true}}' | Set-Content -LiteralPath $modeManifest
        { & $publisher -PreparedPath $prepared -TargetPath $target -ReceiptPath $receipt -Kind action `
            -Repository customer-actions/upstream-action -ApiUrl https://api.example.ghe.com -RunIdentifier fixture -ModeManifestPath $modeManifest } |
            Should -Throw '*Mode manifest has no boolean executable flag*'
        Should -Invoke git -Times 0 -Exactly -ParameterFilter { $Arguments -contains 'push' }
    }
}
