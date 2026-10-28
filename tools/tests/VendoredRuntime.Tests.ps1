BeforeAll {
    $script:tools = Split-Path $PSScriptRoot -Parent
}

Describe 'Release cache boundary' {
    BeforeAll {
        Import-Module (Join-Path $tools 'PlatformTools.psm1') -Force
    }

    It 'excludes local development content <Path>' -ForEach @(
        @{ Path = 'tools/.dependencies/Pester/5.7.1/Pester.psm1' }
        @{ Path = 'tools/.dependencies/interrupted/package.nupkg' }
        @{ Path = 'tools\.DEPENDENCIES\vendor-update-guid\module.psm1' }
        @{ Path = '.dependencies' }
        @{ Path = '' }
        @{ Path = ' ' }
        @{ Path = $null }
    ) {
        Test-PlatformReleaseFile -RelativePath $Path | Should -BeFalse
    }

    It 'keeps approved release content <Path>' -ForEach @(
        @{ Path = 'tools/vendor/powershell-yaml/0.4.12/powershell-yaml.psm1' }
        @{ Path = 'tools/vendor/packages/powershell-yaml.0.4.12.nupkg' }
        @{ Path = 'tools/ToolDependencies.psm1' }
        @{ Path = 'docs/dependencies.md' }
        @{ Path = 'tools/.dependencies.txt' }
        @{ Path = 'docs/local.dependencies/example.md' }
    ) {
        Test-PlatformReleaseFile -RelativePath $Path | Should -BeTrue
    }
}

Describe 'Bundled runtime dependencies' {
    It 'checks both release copies before reusing a loaded runtime: <Case>' -ForEach @(
        @{ Case = 'identical payload'; Tamper = 'None'; ExitCode = 0; Expected = 'Released' }
        @{ Case = 'changed requested payload'; Tamper = 'Requested'; ExitCode = 1; Expected = 'SHA256 mismatch' }
        @{ Case = 'changed loaded payload'; Tamper = 'Loaded'; ExitCode = 1; Expected = 'SHA256 mismatch' }
    ) {
        $probe = Join-Path $TestDrive 'release-copy-probe.ps1'
        Set-Content -LiteralPath $probe -Value @'
param([string] $ToolsPath, [string] $CopyPath, [string] $Tamper)
$ErrorActionPreference = 'Stop'
function Copy-Tools([string] $Destination) {
    $null = New-Item -ItemType Directory -Path $Destination
    foreach ($name in @('PlatformTools.psm1', 'ToolDependencies.psm1', 'requirements.psd1', 'vendor')) {
        Copy-Item (Join-Path $ToolsPath $name) $Destination -Recurse
    }
}
$loadedPath = $ToolsPath
if ($Tamper -eq 'Loaded') {
    $loadedPath = "$CopyPath-loaded"
    Copy-Tools $loadedPath
}
Import-Module (Join-Path $loadedPath 'PlatformTools.psm1')
Copy-Tools $CopyPath
if ($Tamper -ne 'None') {
    $target = if ($Tamper -eq 'Requested') { $CopyPath } else { $loadedPath }
    $version = (Import-PowerShellDataFile (Join-Path $ToolsPath 'requirements.psd1')).Runtime['powershell-yaml']
    Add-Content (Join-Path $target "vendor/powershell-yaml/$version/powershell-yaml.psm1") '# unapproved change'
}
Import-Module (Join-Path $CopyPath 'PlatformTools.psm1') -Force
$configuration = Get-PlatformYaml -Path (Join-Path $ToolsPath 'tests/fixtures/instance.yaml')
if (-not $configuration) { throw 'Copied release could not parse YAML.' }
Remove-Item -LiteralPath $CopyPath -Recurse -Force
'Released'
'@
        $output = & pwsh -NoProfile -NonInteractive -File $probe -ToolsPath $tools -CopyPath (Join-Path $TestDrive "release-copy-$Tamper") -Tamper $Tamper 2>&1
        $LASTEXITCODE | Should -Be $ExitCode -Because ($output -join "`n")
        ($output -join "`n") | Should -Match $Expected
    }

    It 'loads YAML from disk in a process without gallery-installed modules' {
        $probe = Join-Path $TestDrive 'runtime-probe.ps1'
        Set-Content -LiteralPath $probe -Value @'
param([string] $ToolsPath)
$ErrorActionPreference = 'Stop'
$env:PSModulePath = Join-Path $PSHOME 'Modules'
Import-Module (Join-Path $ToolsPath 'PlatformTools.psm1')
$configuration = Get-PlatformYaml -Path (Join-Path $ToolsPath 'tests/fixtures/instance.yaml')
if (-not $configuration) { throw 'YAML input was not parsed.' }
(Get-Module powershell-yaml -All).Path
'@
        $output = & pwsh -NoProfile -NonInteractive -File $probe -ToolsPath $tools 2>&1
        $LASTEXITCODE | Should -Be 0 -Because ($output -join "`n")
        ($output -join "`n") | Should -Match '[\\/]vendor[\\/]powershell-yaml[\\/]0\.4\.12[\\/]powershell-yaml\.psm1'
    }

    It 'includes the runtime package and licenses in the release tree' {
        $repo = Split-Path $tools -Parent
        $archive = Join-Path $TestDrive 'release.zip'
        & git -C $repo archive --format=zip "--output=$archive" HEAD
        $LASTEXITCODE | Should -Be 0
        $zip = [IO.Compression.ZipFile]::OpenRead($archive)
        try {
            $paths = @($zip.Entries.FullName)
            $version = (Import-PowerShellDataFile (Join-Path $tools 'requirements.psd1')).Runtime['powershell-yaml']
            foreach ($path in @(
                "tools/vendor/packages/powershell-yaml.$version.nupkg",
                "tools/vendor/powershell-yaml/$version/powershell-yaml.psd1",
                "tools/vendor/powershell-yaml/$version/LICENSE",
                "tools/vendor/powershell-yaml/$version/lib/net47/LICENSE.txt",
                "tools/vendor/powershell-yaml/$version/lib/netstandard2.1/LICENSE.txt"
            )) {
                $paths | Should -Contain $path
                $stream = $zip.GetEntry($path).Open()
                try {
                    [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($stream)) |
                        Should -Be (Get-FileHash (Join-Path $repo $path)).Hash
                }
                finally { $stream.Dispose() }
            }
            @($paths | Where-Object { $_ -like 'tools/.dependencies/*' }).Count | Should -Be 0
        }
        finally { $zip.Dispose() }
    }
}

Describe 'Vendored module updates' {
    It 'rejects a mismatched package before changing active requirements or vendor content' {
        $root = Join-Path $TestDrive 'update'
        $null = New-Item -ItemType Directory -Path $root
        Copy-Item (Join-Path $tools 'requirements.psd1') $root
        $before = Get-Content (Join-Path $root 'requirements.psd1') -Raw
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'not the pinned package' }

        { & (Join-Path $tools 'Update-VendoredModule.ps1') -ToolsPath $root -Version 0.4.12 -Sha256 ('0' * 64) } |
            Should -Throw '*SHA256 mismatch*'
        Get-Content (Join-Path $root 'requirements.psd1') -Raw | Should -BeExactly $before
        Test-Path (Join-Path $root 'vendor') | Should -BeFalse
    }

    It 'prepares a verified runtime update and can safely run twice' {
        $root = Join-Path $TestDrive 'update-success'
        $null = New-Item -ItemType Directory -Path $root
        Copy-Item (Join-Path $tools 'requirements.psd1') $root
        $requirements = Import-PowerShellDataFile (Join-Path $tools 'requirements.psd1')
        $version = $requirements.Runtime['powershell-yaml']
        $fixturePackage = Join-Path $tools "vendor/packages/powershell-yaml.$version.nupkg"
        Mock Invoke-WebRequest { Copy-Item $fixturePackage $OutFile }
        1..2 | ForEach-Object {
            & (Join-Path $tools 'Update-VendoredModule.ps1') -ToolsPath $root -Version $version -Sha256 $requirements.Sha256['powershell-yaml']
        }
        Test-Path (Join-Path $root "vendor/powershell-yaml/$version/lib/netstandard2.1/LICENSE.txt") | Should -BeTrue
        Import-Module (Join-Path $tools 'ToolDependencies.psm1')
        Get-ToolDependencyPath -Name powershell-yaml -ToolsPath $root | Should -Be (Join-Path $root "vendor/powershell-yaml/$version/powershell-yaml.psd1")
    }
}
