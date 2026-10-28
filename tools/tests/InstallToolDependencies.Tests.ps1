BeforeAll {
    $script:sourceTools = Split-Path $PSScriptRoot -Parent
    function Get-PSRepository {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Offline package transport stub.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Matches the public PowerShellGet command.')]
        [CmdletBinding()]
        param([string] $Name)
        throw 'Unexpected network access.'
    }
    function Save-Module {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSAvoidOverwritingBuiltInCmdlets', '', Justification = 'Offline package transport stub.')]
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSReviewUnusedParameter', '', Justification = 'Matches the public PowerShellGet command.')]
        [CmdletBinding()]
        param([string] $Name, [string] $RequiredVersion, [string] $Repository, [string] $Path, [switch] $Force)
        throw 'Unexpected network access.'
    }

    function New-InstallerFixture {
        [Diagnostics.CodeAnalysis.SuppressMessageAttribute('PSUseShouldProcessForStateChangingFunctions', '', Justification = 'Creates isolated Pester TestDrive fixtures only.')]
        [CmdletBinding()]
        param([string] $Root)
        $null = New-Item -ItemType Directory -Path $Root -Force
        Copy-Item (Join-Path $script:sourceTools 'Install-ToolDependencies.ps1'), (Join-Path $script:sourceTools 'ToolDependencies.psm1') $Root
        $payload = Join-Path $Root 'payload'
        $null = New-Item -ItemType Directory -Path $payload
        Set-Content (Join-Path $payload 'Pester.psd1') "@{ ModuleVersion = '5.7.1'; RootModule = 'Pester.psm1' }"
        Set-Content (Join-Path $payload 'Pester.psm1') "throw 'The installer must never import downloaded modules.'"
        # NuGet packages are ZIP archives; transport metadata is not installed module content.
        # https://learn.microsoft.com/nuget/reference/nuspec
        $archiveContent = Join-Path $Root 'archive-content'
        Copy-Item $payload $archiveContent -Recurse
        $null = New-Item -ItemType Directory -Path (Join-Path $archiveContent '_rels'), (Join-Path $archiveContent 'package')
        Set-Content (Join-Path $archiveContent '_rels/.rels') '<Relationships/>'
        Set-Content (Join-Path $archiveContent 'package/metadata') 'metadata'
        Set-Content -LiteralPath (Join-Path $archiveContent '[Content_Types].xml') -Value '<Types/>'
        Set-Content (Join-Path $archiveContent 'Pester.nuspec') '<package/>'
        $package = Join-Path $Root 'fixture.nupkg'
        [IO.Compression.ZipFile]::CreateFromDirectory($archiveContent, $package)
        $hash = (Get-FileHash $package).Hash.ToLowerInvariant()
        Set-Content (Join-Path $Root 'requirements.psd1') "@{ Runtime = @{}; Development = @{ Pester = '5.7.1' }; Sha256 = @{ Pester = '$hash' } }"
        return @{ Root = $Root; Payload = $payload; Package = $package; Hash = $hash; Installer = Join-Path $Root 'Install-ToolDependencies.ps1' }
    }
}

Describe 'Tool dependency installer process errors' {
    BeforeAll {
        Import-Module (Join-Path $PSScriptRoot 'InstallToolDependenciesStub.psm1') -Force
    }

    It 'fails closed on a nonterminating <Failure> error' -ForEach @(
        @{ Failure = 'Download' }, @{ Failure = 'Save' }
    ) {
        $state = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $state
        $result = Invoke-InstallerStub -StatePath $state -WorkingPath $TestDrive -Failure $Failure
        $result.ExitCode | Should -Be 1
        $result.Error | Should -Match "Nonterminating $($Failure.ToLowerInvariant()) failure"
        Test-Path (Join-Path $state 'tools/.dependencies/Pester/5.7.1') | Should -BeFalse
    }
}

Describe 'Tool dependency installation' {
    BeforeEach {
        $fixture = New-InstallerFixture -Root (Join-Path $TestDrive ([guid]::NewGuid().ToString('N')))
        Mock Invoke-WebRequest { Copy-Item -LiteralPath $fixture.Package -Destination $OutFile }
        Mock Save-Module {
            $destination = Join-Path $Path "$Name/$RequiredVersion"
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item -LiteralPath $fixture.Payload -Destination $destination -Recurse
            [pscustomobject]@{ Name = $Name; Version = [version]$RequiredVersion } | Export-Clixml (Join-Path $destination 'PSGetModuleInfo.xml')
        }
        Mock Start-Sleep { }
        Mock Get-PSRepository { [pscustomobject]@{ Name = 'PSGallery' } }
    }

    It 'publishes a verified development module without importing it' {
        & $fixture.Installer -Development
        Test-Path (Join-Path $fixture.Root '.dependencies/Pester/5.7.1/Pester.psd1') | Should -BeTrue
        Test-Path (Join-Path $fixture.Root '.dependencies/Pester/5.7.1/PSGetModuleInfo.xml') | Should -BeTrue
        Should -Invoke Save-Module -Times 1 -Exactly -ParameterFilter {
            $Name -eq 'Pester' -and $RequiredVersion -eq '5.7.1' -and $Repository -eq 'PSGallery' -and $ErrorAction -eq 'Stop'
        }
    }

    It 'rejects a package with a different SHA256 before Save-Module' {
        Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile 'changed package' }
        { & $fixture.Installer -Development } | Should -Throw '*SHA256 mismatch for Pester*'
        Should -Invoke Save-Module -Times 0
        Test-Path (Join-Path $fixture.Root '.dependencies/Pester/5.7.1') | Should -BeFalse
    }

    It 'rejects an invalid SHA256 pin <Pin>' -ForEach @(
        @{ Pin = '' }, @{ Pin = 'abcd' }, @{ Pin = 'z' * 64 }
    ) {
        Set-Content (Join-Path $fixture.Root 'requirements.psd1') "@{ Runtime=@{}; Development=@{ Pester='5.7.1' }; Sha256=@{ Pester='$Pin' } }"
        { & $fixture.Installer -Development } | Should -Throw '*Invalid SHA256 pin for Pester*'
        Should -Invoke Save-Module -Times 0
    }

    It 'rejects Save-Module content that differs from the verified archive' {
        Mock Save-Module {
            $destination = Join-Path $Path "$Name/$RequiredVersion"
            $null = New-Item -ItemType Directory -Path $destination -Force
            Copy-Item (Join-Path $fixture.Payload '*') $destination
            [pscustomobject]@{ Name = $Name; Version = [version]$RequiredVersion } | Export-Clixml (Join-Path $destination 'PSGetModuleInfo.xml')
            Set-Content (Join-Path $destination 'Pester.psm1') 'changed module'
        }
        { & $fixture.Installer -Development } | Should -Throw '*SHA256 mismatch for Pester.psm1*'
        Test-Path (Join-Path $fixture.Root '.dependencies/Pester/5.7.1') | Should -BeFalse
    }

    It 'rejects a missing payload file' {
        Mock Save-Module { $null = New-Item -ItemType Directory -Path (Join-Path $Path "$Name/$RequiredVersion") -Force }
        { & $fixture.Installer -Development } | Should -Throw '*Module payload is missing*'
    }

    It 'rejects an extra payload file even when all expected files match' {
        Mock Save-Module {
            $destination = Join-Path $Path "$Name/$RequiredVersion"
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item $fixture.Payload $destination -Recurse
            [pscustomobject]@{ Name = $Name; Version = [version]$RequiredVersion } | Export-Clixml (Join-Path $destination 'PSGetModuleInfo.xml')
            Set-Content (Join-Path $destination 'unexpected.psm1') 'untrusted'
        }
        { & $fixture.Installer -Development } | Should -Throw '*unexpected files*'
    }

    It 'revalidates cached module content without contacting PSGallery' {
        & $fixture.Installer -Development
        & $fixture.Installer -Development
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
        Should -Invoke Save-Module -Times 1 -Exactly
        Set-Content (Join-Path $fixture.Root '.dependencies/Pester/5.7.1/Pester.psm1') 'tampered'
        { & $fixture.Installer -Development } | Should -Throw '*SHA256 mismatch*'
    }

    It 'retries transient downloads with the existing linear delays' {
        $state = @{ Attempts = 0 }
        Mock Invoke-WebRequest {
            $state.Attempts++
            if ($state.Attempts -lt 3) { throw 'Transient download failure' }
            Copy-Item $fixture.Package $OutFile
        }
        & $fixture.Installer -Development
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 15 }
        Should -Invoke Start-Sleep -Times 1 -Exactly -ParameterFilter { $Seconds -eq 30 }
    }

    It 'stops after the configured download attempt limit' {
        Mock Invoke-WebRequest { throw 'Persistent download failure' }
        { & $fixture.Installer -Development -MaxAttempts 2 -RetryDelaySeconds 0 } | Should -Throw '*Persistent download failure*'
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Save-Module -Times 0
    }

    It 'retries Save-Module without treating integrity mismatches as transient errors' {
        $state = @{ Attempts = 0 }
        Mock Save-Module {
            $state.Attempts++
            if ($state.Attempts -lt 2) { throw 'Transient Save-Module failure' }
            $destination = Join-Path $Path "$Name/$RequiredVersion"
            $null = New-Item -ItemType Directory -Path (Split-Path $destination -Parent) -Force
            Copy-Item $fixture.Payload $destination -Recurse
            [pscustomobject]@{ Name = $Name; Version = [version]$RequiredVersion } | Export-Clixml (Join-Path $destination 'PSGetModuleInfo.xml')
        }
        & $fixture.Installer -Development -RetryDelaySeconds 0
        Should -Invoke Save-Module -Times 2 -Exactly
        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }

    It 'does not access PSGallery for runtime dependencies' {
        & (Join-Path $sourceTools 'Install-ToolDependencies.ps1')
        Should -Invoke Invoke-WebRequest -Times 0
        Should -Invoke Save-Module -Times 0
    }

    It 'rejects invalid retry parameters' -ForEach @(
        @{ Arguments = @{ MaxAttempts = 0 } }, @{ Arguments = @{ RetryDelaySeconds = -1 } }
    ) {
        { & $fixture.Installer @Arguments } | Should -Throw '*Cannot validate argument*'
    }
}
