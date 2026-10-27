BeforeAll {
    $script:tools = Split-Path $PSScriptRoot -Parent
}

Describe 'Vendored runtime update recovery' -Tag Interruption {
    It 'preserves an importable version and resumes after publishing <Boundary>' -ForEach @(
        @{ Boundary = 'Module' }, @{ Boundary = 'Package' }, @{ Boundary = 'Pin' }
    ) {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $root
        Copy-Item (Join-Path $tools 'requirements.psd1') $root
        Copy-Item (Join-Path $tools 'vendor') (Join-Path $root 'vendor') -Recurse
        $old = Import-PowerShellDataFile (Join-Path $root 'requirements.psd1')
        $oldVersion = $old.Runtime['powershell-yaml']
        $payload = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        Copy-Item (Join-Path $tools "vendor/powershell-yaml/$oldVersion") $payload -Recurse
        # Deliberately synthetic next-version package; no claim that this is a published upstream release.
        $nextVersion = '99.0.0'
        $manifest = Join-Path $payload 'powershell-yaml.psd1'
        $text = (Get-Content $manifest -Raw).Replace("ModuleVersion = '$oldVersion'", "ModuleVersion = '$nextVersion'")
        Set-Content -LiteralPath $manifest -Value $text
        $null = New-Item -ItemType Directory -Path (Join-Path $payload '_rels'), (Join-Path $payload 'package')
        Set-Content (Join-Path $payload '_rels/.rels') '<Relationships/>'
        Set-Content (Join-Path $payload 'package/metadata') 'metadata'
        Set-Content -LiteralPath (Join-Path $payload '[Content_Types].xml') -Value '<Types/>'
        $fixturePackage = Join-Path $TestDrive "$([guid]::NewGuid().ToString('N')).nupkg"
        [IO.Compression.ZipFile]::CreateFromDirectory($payload, $fixturePackage)
        $hash = (Get-FileHash $fixturePackage).Hash
        Mock Invoke-WebRequest { Copy-Item $fixturePackage $OutFile }
        $state = @{ Interrupted = $false }
        Mock Move-Item {
            Microsoft.PowerShell.Management\Move-Item -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
            $published = if ($Destination -like '*.nupkg') { 'Package' }
                elseif ($Destination -like '*requirements.psd1') { 'Pin' }
                else { 'Module' }
            if (-not $state.Interrupted -and $published -eq $Boundary) {
                $state.Interrupted = $true
                throw "Interrupted after $Boundary."
            }
        }

        { & (Join-Path $tools 'Update-VendoredModule.ps1') -ToolsPath $root -Version $nextVersion -Sha256 $hash } |
            Should -Throw "*Interrupted after $Boundary*"
        Import-Module (Join-Path $tools 'ToolDependencies.psm1')
        $active = Get-ToolDependencyPath -Name powershell-yaml -ToolsPath $root
        Test-Path -LiteralPath $active | Should -BeTrue
        $pin = (Import-PowerShellDataFile (Join-Path $root 'requirements.psd1')).Runtime['powershell-yaml']
        $pin | Should -Be $(if ($Boundary -eq 'Pin') { $nextVersion } else { $oldVersion })

        & (Join-Path $tools 'Update-VendoredModule.ps1') -ToolsPath $root -Version $nextVersion -Sha256 $hash
        Get-ToolDependencyPath -Name powershell-yaml -ToolsPath $root |
            Should -Be (Join-Path $root "vendor/powershell-yaml/$nextVersion/powershell-yaml.psd1")
    }
}
