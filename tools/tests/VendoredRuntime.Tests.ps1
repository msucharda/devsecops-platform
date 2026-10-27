BeforeAll {
    $script:tools = Split-Path $PSScriptRoot -Parent
}

Describe 'Bundled runtime dependencies' {
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
            )) { $paths | Should -Contain $path }
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
