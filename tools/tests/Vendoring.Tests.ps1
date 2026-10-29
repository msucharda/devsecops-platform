BeforeAll {
    $prepare = Join-Path (Split-Path $PSScriptRoot -Parent) 'ConvertTo-VendoredSource.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/vendoring'
}

Describe 'Vendored source preparation through the public command' {
    It 'prepares a raw release marker alongside the transformed platform tree for <Version>' -Tag 'DeploymentRelease' -ForEach @(
        @{ Version = '1.2.3' }
        @{ Version = '1.2.3-rc.1' }
    ) {
        $markerPath = Join-Path $TestDrive 'old-marker.json'
        '{"instance":"demo","releaseVersion":"1.0.0","files":{}}' | Set-Content $markerPath
        $output = Join-Path $TestDrive "marked-release-$Version"
        & $prepare -SourcePath (Join-Path $fixtures 'release') -OutputPath $output `
            -CatalogPath (Join-Path $fixtures 'catalog.json') -ActionsOrganization customer-actions -Kind release `
            -ReleaseMarkerPath $markerPath -ReleaseVersion $Version

        $marker = Get-Content (Join-Path $output '.platform-bootstrap.json') -Raw | ConvertFrom-Json -AsHashtable
        $marker.instance | Should -BeExactly 'demo'
        $marker.releaseVersion | Should -BeExactly $Version
        $marker.files['README.md'] | Should -BeExactly (Get-FileHash (Join-Path $fixtures 'release/README.md')).Hash.ToLowerInvariant()
        $marker.files['templates/instance/.github/workflows/deploy.yml'] | Should -Not -BeExactly `
            (Get-FileHash (Join-Path $output 'platform/templates/instance/.github/workflows/deploy.yml')).Hash.ToLowerInvariant()
    }

    It 'rejects release marker preparation for <Case>' -Tag 'DeploymentRelease' -ForEach @(
        @{ Case = 'action import'; Kind = 'action'; Version = '1.2.3'; Change = {}; Message = '*Only release preparation*' }
        @{ Case = 'empty version'; Kind = 'release'; Version = ''; Change = {}; Message = '*SemVer version without v*' }
        @{ Case = 'tag instead of version'; Kind = 'release'; Version = 'v1.2.3'; Change = {}; Message = '*SemVer version without v*' }
        @{ Case = 'invalid version'; Kind = 'release'; Version = '1.2'; Change = {}; Message = '*SemVer version without v*' }
        @{ Case = 'release candidate with different case'; Kind = 'release'; Version = '1.2.3-RC.1'; Change = {}; Message = '*SemVer version without v*' }
        @{ Case = 'non-object marker'; Kind = 'release'; Version = '1.2.3'; Change = { $marker = 'invalid' }; Message = '*marker must be an object*' }
        @{ Case = 'missing instance'; Kind = 'release'; Version = '1.2.3'; Change = { $marker.Remove('instance') }; Message = '*must identify the instance*' }
        @{ Case = 'null instance'; Kind = 'release'; Version = '1.2.3'; Change = { $marker.instance = $null }; Message = '*must identify the instance*' }
        @{ Case = 'non-string instance'; Kind = 'release'; Version = '1.2.3'; Change = { $marker.instance = 123 }; Message = '*must identify the instance*' }
        @{ Case = 'empty instance'; Kind = 'release'; Version = '1.2.3'; Change = { $marker.instance = '' }; Message = '*must identify the instance*' }
        @{ Case = 'whitespace instance'; Kind = 'release'; Version = '1.2.3'; Change = { $marker.instance = ' ' }; Message = '*must identify the instance*' }
    ) {
        $markerPath = Join-Path $TestDrive 'invalid-marker.json'
        $marker = @{ instance = 'demo'; releaseVersion = '1.0.0'; files = @{} }
        . $Change
        $marker | ConvertTo-Json -Depth 10 | Set-Content $markerPath
        $output = Join-Path $TestDrive 'invalid-marker-output'
        { & $prepare -SourcePath (Join-Path $fixtures $Kind) -OutputPath $output `
            -CatalogPath (Join-Path $fixtures 'catalog.json') -ActionsOrganization customer-actions -Kind $Kind `
            -ReleaseMarkerPath $markerPath -ReleaseVersion $Version } | Should -Throw $Message
        Test-Path $output | Should -BeFalse
    }

    It 'rejects release marker preparation for array-wrapped marker' -Tag 'DeploymentRelease', 'MarkerArrayBoundary' {
        $markerPath = Join-Path $TestDrive 'array-marker.json'
        '[{"instance":"demo","releaseVersion":"1.0.0","files":{}}]' | Set-Content $markerPath
        $output = Join-Path $TestDrive 'array-marker-output'
        { & $prepare -SourcePath (Join-Path $fixtures 'release') -OutputPath $output `
                -CatalogPath (Join-Path $fixtures 'catalog.json') -ActionsOrganization customer-actions -Kind release `
                -ReleaseMarkerPath $markerPath -ReleaseVersion '1.2.3' } | Should -Throw '*marker must be an object*'
        Test-Path $output | Should -BeFalse
    }

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
        'jobs: {build: {steps: [{uses: Actions/Checkout/SubPath@3d3c42e5aac5ba805825da76410c181273ba90b1}]}}' |
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
            $expectedError = if ($Case -ceq 'null tag') {
                "*Invalid catalog entry 'actions/checkout'*"
            }
            else {
                "*Catalog tag for 'actions/checkout' must match release pin tag 'v7.0.1'*"
            }
            { & $prepare -SourcePath $source -OutputPath $output -CatalogPath $catalogPath `
                    -ActionsOrganization customer-actions -Kind release } |
                Should -Throw $expectedError
            Test-Path $output | Should -BeFalse
        }
    }

    It 'checks a release pin against its catalog upstream commit: <Case>' -ForEach @(
        @{ Case = 'same commit'; Pin = '3d3c42e5aac5ba805825da76410c181273ba90b1'; Allowed = $true }
        @{ Case = 'different commit with same tag'; Pin = ('a' * 40); Allowed = $false }
        @{ Case = 'uppercase commit'; Pin = '3D3C42E5AAC5BA805825DA76410C181273BA90B1'; Allowed = $false }
        @{ Case = 'abbreviated commit'; Pin = '3d3c42e'; Allowed = $false }
        @{ Case = 'tag'; Pin = 'v7.0.1'; Allowed = $false }
        @{ Case = 'branch'; Pin = 'main'; Allowed = $false }
    ) {
        $caseId = $Case.Replace(' ', '-')
        $source = Join-Path $TestDrive "wrong-commit-$caseId"
        $workflow = Join-Path $source 'templates/instance/.github/workflows'
        $null = New-Item -ItemType Directory -Path $workflow -Force
        @"
jobs:
  reuse:
    uses: actions/checkout/SubPath/workflow.yml@$Pin # v7.0.1
  build:
    steps:
      - uses: actions/checkout@3d3c42e5aac5ba805825da76410c181273ba90b1 # v7.0.1
"@ | Set-Content (Join-Path $workflow 'deploy.yml')
        $catalogPath = Join-Path $TestDrive "wrong-commit-$caseId.json"
        $catalog = Get-Content (Join-Path $fixtures 'catalog.json') -Raw | ConvertFrom-Json -AsHashtable
        $catalog.actions['actions/checkout']['upstreamCommit'] = '3d3c42e5aac5ba805825da76410c181273ba90b1'
        $catalog.actions['actions/checkout']['tag'] = 'v7.0.1'
        $catalog | ConvertTo-Json -Depth 10 | Set-Content $catalogPath
        $output = Join-Path $TestDrive "wrong-commit-output-$caseId"
        $modes = Join-Path $TestDrive "wrong-commit-modes-$caseId.json"
        if ($Allowed) {
            & $prepare -SourcePath $source -OutputPath $output -CatalogPath $catalogPath `
                -ActionsOrganization customer-actions -Kind release -ModeManifestPath $modes
            Get-Content (Join-Path $output 'platform/templates/instance/.github/workflows/deploy.yml') -Raw |
                Should -Match 'customer-actions/actions-checkout/SubPath/workflow.yml@1111111111111111111111111111111111111111'
        }
        else {
            { & $prepare -SourcePath $source -OutputPath $output -CatalogPath $catalogPath `
                    -ActionsOrganization customer-actions -Kind release -ModeManifestPath $modes } |
                Should -Throw "*Upstream commit for 'actions/checkout' must match release pin*"
            Test-Path $output | Should -BeFalse
            Test-Path $modes | Should -BeFalse
        }
    }

    It 'rejects a catalog upstream commit with <Case> before output: <Kind>' -ForEach @(
        foreach ($kind in @('action', 'release')) {
            foreach ($case in @(
                @{ Case = 'missing field'; Value = '__missing__' }
                @{ Case = 'null'; Value = $null }
                @{ Case = 'empty string'; Value = '' }
                @{ Case = 'uppercase'; Value = '3D3C42E5AAC5BA805825DA76410C181273BA90B1' }
                @{ Case = 'short SHA'; Value = '3d3c42e' }
                @{ Case = 'trailing newline'; Value = "3d3c42e5aac5ba805825da76410c181273ba90b1`n" }
                @{ Case = 'number'; Value = 1 }
                @{ Case = 'array'; Value = @('3d3c42e5aac5ba805825da76410c181273ba90b1') }
                @{ Case = 'empty array'; Value = @() }
            )) { $case + @{ Kind = $kind } }
        }
    ) {
        $catalogPath = Join-Path $TestDrive 'invalid-upstream.json'
        $catalog = Get-Content (Join-Path $fixtures 'catalog.json') -Raw | ConvertFrom-Json -AsHashtable
        if ($Case -ceq 'missing field') { $catalog.actions['actions/checkout'].Remove('upstreamCommit') }
        else { $catalog.actions['actions/checkout']['upstreamCommit'] = $Value }
        $catalog | ConvertTo-Json -Depth 10 | Set-Content $catalogPath
        $output = Join-Path $TestDrive 'invalid-upstream-output'
        { & $prepare -SourcePath (Join-Path $fixtures $Kind) -OutputPath $output -CatalogPath $catalogPath `
                -ActionsOrganization customer-actions -Kind $Kind } |
            Should -Throw "*Catalog upstreamCommit for 'actions/checkout' must be a full lowercase commit SHA*"
        Test-Path $output | Should -BeFalse
    }

    It 'rejects an array-wrapped catalog before output: <Kind>' -ForEach @(
        @{ Kind = 'action' }
        @{ Kind = 'release' }
    ) {
        $catalogPath = Join-Path $TestDrive "array-catalog-$Kind.json"
        $catalogJson = Get-Content (Join-Path $fixtures 'catalog.json') -Raw
        # Deliberately invalid: the catalog root must be an object, not a single-element array.
        "[$catalogJson]" | Set-Content $catalogPath
        $output = Join-Path $TestDrive "array-output-$Kind"
        $modes = Join-Path $TestDrive "array-modes-$Kind.json"
        { & $prepare -SourcePath (Join-Path $fixtures $Kind) -OutputPath $output -CatalogPath $catalogPath `
                -ActionsOrganization customer-actions -Kind $Kind -ModeManifestPath $modes } |
            Should -Throw '*must declare version 2 and an actions mapping*'
        Test-Path $output | Should -BeFalse
        Test-Path $modes | Should -BeFalse
    }

    It 'rejects an unmigrated catalog before output' {
        $catalogPath = Join-Path $TestDrive 'version-1.json'
        $catalog = Get-Content (Join-Path $fixtures 'catalog.json') -Raw | ConvertFrom-Json -AsHashtable
        $catalog.version = 1
        $catalog | ConvertTo-Json -Depth 10 | Set-Content $catalogPath
        $output = Join-Path $TestDrive 'version-1-output'
        { & $prepare -SourcePath (Join-Path $fixtures 'release') -OutputPath $output -CatalogPath $catalogPath `
                -ActionsOrganization customer-actions -Kind release } | Should -Throw '*must declare version 2*'
        Test-Path $output | Should -BeFalse
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
