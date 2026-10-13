BeforeAll {
    $prepare = Join-Path (Split-Path $PSScriptRoot -Parent) 'ConvertTo-VendoredSource.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/vendoring'
}

Describe 'Vendored source preparation through the public command' {
    It 'rewrites composite and local manifests to catalog SHA pins without touching script text or comments' {
        $output = Join-Path $TestDrive 'prepared'
        & $prepare -SourcePath (Join-Path $fixtures 'action') -OutputPath $output `
            -CatalogPath (Join-Path $fixtures 'catalog.json') -ActionsOrganization customer-actions -Kind action

        $content = Get-Content -LiteralPath (Join-Path $output 'action.yml') -Raw
        $content | Should -Match "uses: 'customer-actions/actions-checkout@1111111111111111111111111111111111111111' # Keep this comment."
        $content | Should -Match "uses: 'customer-actions/example-tool/subaction@2222222222222222222222222222222222222222'"
        $content | Should -Match 'uses: ./local'
        $content | Should -Match 'echo "uses: actions/not-an-action@v1"'
        Get-Content -LiteralPath (Join-Path $output 'local/action.yaml') -Raw |
            Should -Match 'customer-actions/actions-checkout@1111111111111111111111111111111111111111'
    }

    It 'names the missing catalog action and leaves no partially prepared output' {
        $catalog = Join-Path $TestDrive 'missing.json'
        $incomplete = Get-Content -LiteralPath (Join-Path $fixtures 'catalog.json') -Raw | ConvertFrom-Json -AsHashtable
        $incomplete.actions.Remove('actions/checkout')
        $incomplete | ConvertTo-Json -Depth 10 | Set-Content -LiteralPath $catalog
        $output = Join-Path $TestDrive 'missing-output'
        { & $prepare -SourcePath (Join-Path $fixtures 'action') -OutputPath $output `
            -CatalogPath $catalog -ActionsOrganization customer-actions -Kind action } |
            Should -Throw "*Action 'actions/checkout' is missing*"
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'places a release and its rewritten workflow templates under platform without changing live workflows' {
        $output = Join-Path $TestDrive 'release'
        & $prepare -SourcePath (Join-Path $fixtures 'release') -OutputPath $output `
            -CatalogPath (Join-Path $fixtures 'catalog.json') -ActionsOrganization customer-actions -Kind release

        Test-Path -LiteralPath (Join-Path $output 'platform/README.md') | Should -BeTrue
        Get-Content -LiteralPath (Join-Path $output 'platform/templates/instance/.github/workflows/deploy.yml') -Raw |
            Should -Match 'customer-actions/actions-checkout@1111111111111111111111111111111111111111'
        Test-Path -LiteralPath (Join-Path $output 'instance.yaml') | Should -BeFalse
        Test-Path -LiteralPath (Join-Path $output '.github/workflows') | Should -BeFalse
    }

    It 'rejects dynamic references with an explicit error and no prepared files' {
        $source = Join-Path $TestDrive 'dynamic'
        $null = New-Item -ItemType Directory -Path $source
        'runs: {using: composite, steps: [{uses: "${{ inputs.action }}"}]}' |
            Set-Content -LiteralPath (Join-Path $source 'action.yml')
        $output = Join-Path $TestDrive 'dynamic-output'
        { & $prepare -SourcePath $source -OutputPath $output -CatalogPath (Join-Path $fixtures 'catalog.json') `
            -ActionsOrganization customer-actions -Kind action } | Should -Throw '*Unsupported uses*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects YAML anchors rather than leaving unresolved or unrewritten action aliases' {
        $source = Join-Path $TestDrive 'anchors'
        $null = New-Item -ItemType Directory -Path $source
        @'
runs:
  using: composite
  steps:
    - uses: &checkout actions/checkout@v4
    - uses: *checkout
'@ | Set-Content -LiteralPath (Join-Path $source 'action.yml')
        $output = Join-Path $TestDrive 'anchor-output'
        { & $prepare -SourcePath $source -OutputPath $output -CatalogPath (Join-Path $fixtures 'catalog.json') `
            -ActionsOrganization customer-actions -Kind action } | Should -Throw '*YAML anchors*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'emits an explicit executable manifest for every prepared file outside the source tree' {
        $output = Join-Path $TestDrive 'with-modes'
        $modeManifest = Join-Path $TestDrive 'prepared-modes.json'
        & $prepare -SourcePath (Join-Path $fixtures 'action') -OutputPath $output `
            -CatalogPath (Join-Path $fixtures 'catalog.json') -ActionsOrganization customer-actions -Kind action -ModeManifestPath $modeManifest

        $manifest = Get-Content -LiteralPath $modeManifest -Raw | ConvertFrom-Json -AsHashtable
        $manifest.version | Should -Be 1
        @($manifest.files.Keys | Sort-Object) | Should -Be @('action.yml', 'local/action.yaml')
        foreach ($flag in $manifest.files.Values) { $flag | Should -BeOfType bool }
    }
}
