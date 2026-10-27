BeforeAll {
    $prepare = Join-Path (Split-Path $PSScriptRoot -Parent) 'ConvertTo-VendoredSource.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/vendoring'
}

Describe 'Vendored source preparation through the public command' {
    It 'excludes platform caches only for release preparation: <Kind>' -ForEach @(
        @{ Kind = 'release'; Prefix = 'platform/'; IncludesCache = $false }
        @{ Kind = 'action'; Prefix = ''; IncludesCache = $true }
    ) {
        $source = Join-Path $TestDrive "source-$Kind"
        Copy-Item (Join-Path $fixtures $Kind) $source -Recurse
        $cache = Join-Path $source 'tools/.dependencies/interrupted'
        $vendor = Join-Path $source 'tools/vendor'
        $null = New-Item -ItemType Directory -Path $cache, $vendor -Force
        Set-Content (Join-Path $cache 'unverified.nupkg') 'unverified download'
        Set-Content (Join-Path $vendor 'approved.txt') 'bundled content'
        $output = Join-Path $TestDrive "output-$Kind"

        & $prepare -SourcePath $source -OutputPath $output -CatalogPath (Join-Path $fixtures 'catalog.json') `
            -ActionsOrganization customer-actions -Kind $Kind

        Test-Path (Join-Path $output "${Prefix}tools/.dependencies/interrupted/unverified.nupkg") | Should -Be $IncludesCache
        Get-Content (Join-Path $output "${Prefix}tools/vendor/approved.txt") | Should -Be 'bundled content'
    }

    It 'matches the complete owner and repository without case sensitivity and preserves subpath case' -Tag 'VendoringCase' {
        $source = Join-Path $TestDrive 'mixed-case'
        $workflow = Join-Path $source 'templates/instance/.github/workflows'
        $null = New-Item -ItemType Directory -Path $workflow -Force
        'jobs: {build: {steps: [{uses: Actions/Checkout/SubPath@v4}]}}' |
            Set-Content -LiteralPath (Join-Path $workflow 'deploy.yml')
        $output = Join-Path $TestDrive 'mixed-output'

        & $prepare -SourcePath $source -OutputPath $output -CatalogPath (Join-Path $fixtures 'catalog.json') `
            -ActionsOrganization customer-actions -Kind release

        Get-Content -LiteralPath (Join-Path $output 'platform/templates/instance/.github/workflows/deploy.yml') -Raw |
            Should -Match "uses: 'customer-actions/actions-checkout/SubPath@1111111111111111111111111111111111111111'"
    }

    It 'rejects a different action identity <Reference>' -Tag 'VendoringCase' -ForEach @(
        @{ Reference = 'Other/Checkout@v4' }
        @{ Reference = 'Actions/Other@v4' }
    ) {
        $source = Join-Path $TestDrive 'different-action'
        $null = New-Item -ItemType Directory -Path $source -Force
        "runs: {using: composite, steps: [{uses: $Reference}]}" | Set-Content -LiteralPath (Join-Path $source 'action.yml')
        $output = Join-Path $TestDrive 'different-output'
        { & $prepare -SourcePath $source -OutputPath $output -CatalogPath (Join-Path $fixtures 'catalog.json') `
            -ActionsOrganization customer-actions -Kind action } | Should -Throw '*is missing from the catalog*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

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

    It 'checks the annotated release pin tag against the catalog: <Case>' -ForEach @(
        @{ Case = 'matching tag'; Tag = 'v7.0.1'; Allowed = $true }
        @{ Case = 'older tag'; Tag = 'v4.4.0'; Allowed = $false }
        @{ Case = 'different case'; Tag = 'V7.0.1'; Allowed = $false }
        @{ Case = 'empty tag'; Tag = ''; Allowed = $false }
        @{ Case = 'missing tag'; Tag = '__missing__'; Allowed = $false }
        @{ Case = 'null tag'; Tag = $null; Allowed = $false }
        @{ Case = 'non-string tag'; Tag = 7; Allowed = $false }
        @{ Case = 'array tag'; Tag = @('v7.0.1'); Allowed = $false }
    ) {
        $caseId = $Case.Replace(' ', '-')
        $source = Join-Path $TestDrive "tagged-release-$caseId"
        $workflow = Join-Path $source 'templates/instance/.github/workflows'
        $null = New-Item -ItemType Directory -Path $workflow -Force
        @'
jobs:
  build:
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
'@ | Set-Content (Join-Path $workflow 'deploy.yml')
        $catalogPath = Join-Path $TestDrive "tagged-catalog-$caseId.json"
        $catalog = Get-Content (Join-Path $fixtures 'catalog.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($Tag -cne '__missing__') { $catalog.actions['actions/checkout']['tag'] = $Tag }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content $catalogPath
        $output = Join-Path $TestDrive "tagged-output-$caseId"

        if ($Allowed) {
            & $prepare -SourcePath $source -OutputPath $output -CatalogPath $catalogPath `
                -ActionsOrganization customer-actions -Kind release
            Get-Content (Join-Path $output 'platform/templates/instance/.github/workflows/deploy.yml') -Raw |
                Should -Match "customer-actions/actions-checkout@1111111111111111111111111111111111111111' # v7.0.1"
        }
        else {
            { & $prepare -SourcePath $source -OutputPath $output -CatalogPath $catalogPath `
                    -ActionsOrganization customer-actions -Kind release } |
                Should -Throw "*Catalog tag for 'actions/checkout' must match release pin tag 'v7.0.1'*"
            Test-Path $output | Should -BeFalse
        }
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
