BeforeAll {
    $script:tools = Split-Path $PSScriptRoot -Parent
}

Describe 'CI binary integrity before execution' {
    It 'stops after four failed connections without publishing a binary' {
        Get-Module ToolDependencies -All | Remove-Module -Force
        Import-Module (Join-Path $tools 'ToolDependencies.psm1')
        Mock Start-Sleep {} -ModuleName ToolDependencies
        Mock Invoke-WebRequest {
            Set-Content $OutFile 'partial download'
            throw [Net.Http.HttpRequestException]::new('Connection failed')
        }
        $oldTemp = $env:RUNNER_TEMP
        $oldGitHubPath = $env:GITHUB_PATH
        try {
            $env:RUNNER_TEMP = $TestDrive
            $env:GITHUB_PATH = Join-Path $TestDrive 'failed-github-path'
            { & (Join-Path $tools 'Install-CiBinary.ps1') -Name Actionlint } | Should -Throw '*Connection failed*'
            Should -Invoke Invoke-WebRequest -Times 4 -Exactly
            Should -Invoke Start-Sleep -Times 3 -Exactly -ModuleName ToolDependencies
            Test-Path $env:GITHUB_PATH | Should -BeFalse
            @(Get-ChildItem $TestDrive -Filter 'platform-actionlint-*') | Should -BeNullOrEmpty
        }
        finally { $env:RUNNER_TEMP = $oldTemp; $env:GITHUB_PATH = $oldGitHubPath }
    }

    It 'retries a transient connection failure and verifies the recovered download before publication' {
        $root = Join-Path $TestDrive 'retry-tools'
        $payload = Join-Path $TestDrive 'retry-payload'
        $null = New-Item -ItemType Directory -Path $root, $payload
        Copy-Item (Join-Path $tools 'Install-CiBinary.ps1'), (Join-Path $tools 'ToolDependencies.psm1') $root
        Set-Content (Join-Path $payload 'actionlint') 'verified fixture; never executed'
        $fixtureArchive = Join-Path $TestDrive 'retry.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($payload, $fixtureArchive)
        $hash = (Get-FileHash $fixtureArchive).Hash
        $hashKey = if ($IsWindows) { 'WindowsAmd64ArchiveSha256' } else { 'LinuxAmd64ArchiveSha256' }
        Set-Content (Join-Path $root 'requirements.psd1') "@{ Binaries=@{ Actionlint=@{ Version='1.7.7'; $hashKey='$hash' } } }"
        $state = @{ Attempts = 0 }
        Get-Module ToolDependencies -All | Remove-Module -Force
        Import-Module (Join-Path $root 'ToolDependencies.psm1') -Force
        Mock Start-Sleep {} -ModuleName ToolDependencies
        Mock Invoke-WebRequest {
            $state.Attempts++
            if ($state.Attempts -eq 1) {
                Set-Content $OutFile 'partial download'
                throw [Net.Http.HttpRequestException]::new('Connection failed (curl exit 7 equivalent)')
            }
            Test-Path $OutFile | Should -BeFalse
            Copy-Item $fixtureArchive $OutFile
        }
        & (Join-Path $root 'Install-CiBinary.ps1') -Name Actionlint -Local
        $cached = @(Get-ChildItem (Join-Path $root '.dependencies') -Recurse -File)
        $cached.Count | Should -Be 1
        (Get-FileHash $cached[0].FullName).Hash | Should -BeExactly $hash
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Should -Invoke Start-Sleep -Times 1 -Exactly -ModuleName ToolDependencies
    }

    It 'restores actionlint from a verified cached archive without running or trusting a cached executable' {
        $root = Join-Path $TestDrive 'actionlint-tools'
        $payload = Join-Path $TestDrive 'actionlint-payload'
        $null = New-Item -ItemType Directory -Path $root, $payload
        Copy-Item (Join-Path $tools 'Install-CiBinary.ps1'), (Join-Path $tools 'ToolDependencies.psm1') $root
        $binaryName = if ($IsWindows) { 'actionlint.exe' } else { 'actionlint' }
        Set-Content (Join-Path $payload $binaryName) 'fixture executable; must not run'
        $fixtureArchive = Join-Path $TestDrive $(if ($IsWindows) { 'actionlint.zip' } else { 'actionlint.tar.gz' })
        if ($IsWindows) { [IO.Compression.ZipFile]::CreateFromDirectory($payload, $fixtureArchive) }
        else {
            & tar -czf $fixtureArchive -C $payload $binaryName
            $LASTEXITCODE | Should -Be 0
        }
        $hash = (Get-FileHash $fixtureArchive).Hash
        $hashKey = if ($IsWindows) { 'WindowsAmd64ArchiveSha256' } else { 'LinuxAmd64ArchiveSha256' }
        Set-Content (Join-Path $root 'requirements.psd1') "@{ Binaries=@{ Actionlint=@{ Version='1.7.7'; $hashKey='$hash' } } }"
        Get-Module ToolDependencies -All | Remove-Module -Force
        Import-Module (Join-Path $root 'ToolDependencies.psm1') -Force
        Mock Start-Sleep {} -ModuleName ToolDependencies
        Mock Invoke-WebRequest {
            Set-Content $OutFile 'interrupted download'
            throw 'Download interrupted before publication'
        }
        { & (Join-Path $root 'Install-CiBinary.ps1') -Name Actionlint -Local } | Should -Throw '*Download interrupted*'
        @(Get-ChildItem (Join-Path $root '.dependencies') -Recurse -File) | Should -BeNullOrEmpty
        Mock Invoke-WebRequest { Copy-Item $fixtureArchive $OutFile }
        & (Join-Path $root 'Install-CiBinary.ps1') -Name Actionlint -Local
        Import-Module (Join-Path $root 'ToolDependencies.psm1') -Force
        $package = Get-ToolBinaryPackage -Name Actionlint -ToolsPath $root
        Test-Path $package.CachePath | Should -BeTrue
        $destination = Join-Path $TestDrive 'actionlint-run'
        $binary = Get-ToolBinaryPath -Name Actionlint -ToolsPath $root -DestinationPath $destination
        Get-Content $binary | Should -BeExactly 'fixture executable; must not run'
        Set-Content $binary 'tampered old extraction'
        $fresh = Get-ToolBinaryPath -Name Actionlint -ToolsPath $root -DestinationPath (Join-Path $TestDrive 'actionlint-fresh')
        Get-Content $fresh | Should -BeExactly 'fixture executable; must not run'
        & (Join-Path $root 'Install-CiBinary.ps1') -Name Actionlint -Local
        Should -Invoke Invoke-WebRequest -Times 5 -Exactly
        Set-Content $package.CachePath 'tampered cache'
        { Get-ToolBinaryPath -Name Actionlint -ToolsPath $root -DestinationPath (Join-Path $TestDrive 'rejected') } |
            Should -Throw '*SHA256 mismatch for Actionlint*'
        { & (Join-Path $root 'Install-CiBinary.ps1') -Name Actionlint -Local } |
            Should -Throw '*SHA256 mismatch for Actionlint*'
        Test-Path (Join-Path $TestDrive 'rejected') | Should -BeFalse
    }

    Describe 'Pinned Trivy installation' -Skip:(-not $IsLinux) {
        BeforeEach {
            $oldTemp = $env:RUNNER_TEMP
            $oldGitHubPath = $env:GITHUB_PATH
            $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Path $root
            Copy-Item (Join-Path $tools 'Install-CiBinary.ps1'), (Join-Path $tools 'ToolDependencies.psm1') $root
            $fixtureArchive = Join-Path $root 'fixture.tar.gz'
            $file = [IO.File]::Create($fixtureArchive)
            $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Compress)
            $writer = [System.Formats.Tar.TarWriter]::new($gzip)
            $entry = [System.Formats.Tar.PaxTarEntry]::new([System.Formats.Tar.TarEntryType]::RegularFile, 'trivy')
            $entry.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('verified fixture; never executed'))
            try { $writer.WriteEntry($entry) }
            finally { $entry.DataStream.Dispose(); $writer.Dispose(); $gzip.Dispose(); $file.Dispose() }
            $hash = (Get-FileHash $fixtureArchive).Hash
            Set-Content (Join-Path $root 'requirements.psd1') "@{ Binaries=@{ Trivy=@{ Version='0.72.0'; LinuxAmd64ArchiveSha256='$hash' } } }"
            Get-Module ToolDependencies -All | Remove-Module -Force
            Import-Module (Join-Path $root 'ToolDependencies.psm1') -Force
            Mock Start-Sleep {} -ModuleName ToolDependencies
            Mock Invoke-WebRequest { Copy-Item $fixtureArchive $OutFile }
            $env:RUNNER_TEMP = $root
            $env:GITHUB_PATH = Join-Path $root 'github-path'
        }

        AfterEach {
            $env:RUNNER_TEMP = $oldTemp
            $env:GITHUB_PATH = $oldGitHubPath
        }

        It 'pins the version, release URL and archive SHA256' {
            $package = Get-ToolBinaryPackage -Name Trivy -ToolsPath $tools
            $package.Version | Should -BeExactly '0.72.0'
            $package.Uri | Should -BeExactly 'https://github.com/aquasecurity/trivy/releases/download/v0.72.0/trivy_0.72.0_Linux-64bit.tar.gz'
            $package.Sha256 | Should -BeExactly 'bbb64b9695866ce4a7a8f5c9592002c5961cab378577fa3f8a040df362b9b2ea'
        }

        It 'recovers from a transient DNS failure before publishing a verified executable' {
            $state = @{ Attempts = 0 }
            Mock Invoke-WebRequest {
                $state.Attempts++
                if ($state.Attempts -lt 3) {
                    Set-Content $OutFile 'partial download'
                    throw [Net.Http.HttpRequestException]::new('DNS resolution failed (curl exit 6 equivalent)')
                }
                Test-Path $OutFile | Should -BeFalse
                Copy-Item $fixtureArchive $OutFile
            }
            & (Join-Path $root 'Install-CiBinary.ps1') -Name Trivy
            $directory = (Get-Content $env:GITHUB_PATH -Raw).Trim()
            Get-Content (Join-Path $directory 'trivy') | Should -BeExactly 'verified fixture; never executed'
            Should -Invoke Invoke-WebRequest -Times 3 -Exactly -ParameterFilter {
                $Uri -eq 'https://github.com/aquasecurity/trivy/releases/download/v0.72.0/trivy_0.72.0_Linux-64bit.tar.gz' -and
                $ConnectionTimeoutSeconds -eq 30 -and $OperationTimeoutSeconds -eq 120
            }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ModuleName ToolDependencies -ParameterFilter { $Seconds -eq 15 }
            Should -Invoke Start-Sleep -Times 1 -Exactly -ModuleName ToolDependencies -ParameterFilter { $Seconds -eq 30 }
        }

        It 'fails after four attempts and removes partial downloads without publishing PATH' {
            Mock Invoke-WebRequest {
                Set-Content $OutFile 'partial download'
                throw [Net.Http.HttpRequestException]::new('Connection failed')
            }
            { & (Join-Path $root 'Install-CiBinary.ps1') -Name Trivy } | Should -Throw '*Connection failed*'
            Should -Invoke Invoke-WebRequest -Times 4 -Exactly
            Should -Invoke Start-Sleep -Times 3 -Exactly -ModuleName ToolDependencies
            Test-Path $env:GITHUB_PATH | Should -BeFalse
            @(Get-ChildItem $root -Filter 'platform-trivy-*') | Should -BeNullOrEmpty
        }

        It 'rejects a hash mismatch after a recovered download without retrying integrity errors' {
            $state = @{ Attempts = 0 }
            Mock Invoke-WebRequest {
                $state.Attempts++
                if ($state.Attempts -eq 1) { throw [Net.Http.HttpRequestException]::new('Connection failed') }
                Set-Content $OutFile 'tampered archive'
            }
            { & (Join-Path $root 'Install-CiBinary.ps1') -Name Trivy } | Should -Throw '*SHA256 mismatch for Trivy*'
            Should -Invoke Invoke-WebRequest -Times 2 -Exactly
            Test-Path $env:GITHUB_PATH | Should -BeFalse
            @(Get-ChildItem $root -Filter 'platform-trivy-*') | Should -BeNullOrEmpty
        }
    }

    It 'extracts a regular executable from the Linux tar.gz format without executing it' {
        Import-Module (Join-Path $tools 'ToolDependencies.psm1') -Force
        $payload = Join-Path $TestDrive 'tar-payload'
        Set-Content $payload 'verified tar executable'
        $fixtureArchive = Join-Path $TestDrive 'fixture.tar.gz'
        $file = [IO.File]::Create($fixtureArchive)
        $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Compress)
        $writer = [System.Formats.Tar.TarWriter]::new($gzip)
        try { $writer.WriteEntry($payload, 'actionlint') }
        finally { $writer.Dispose(); $gzip.Dispose(); $file.Dispose() }
        $package = [pscustomobject]@{
            Name = 'Actionlint'; Archive = 'fixture.tar.gz'; Executable = 'actionlint'; Sha256 = (Get-FileHash $fixtureArchive).Hash
        }
        $binary = Expand-ToolBinary -Package $package -ArchivePath $fixtureArchive -DestinationPath (Join-Path $TestDrive 'tar-bin')
        Get-Content $binary | Should -BeExactly 'verified tar executable'
    }

    It 'rejects a correctly hashed archive with <Case>' -ForEach @(
        @{ Case = 'a missing ZIP executable'; Kind = 'Zip'; Names = @('other'); Link = $false; Message = '*exactly one actionlint*' }
        @{ Case = 'duplicate ZIP executables'; Kind = 'Zip'; Names = @('actionlint', 'actionlint'); Link = $false; Message = '*exactly one actionlint*' }
        @{ Case = 'a missing TAR executable'; Kind = 'Tar'; Names = @('other'); Link = $false; Message = '*does not contain actionlint*' }
        @{ Case = 'duplicate TAR executables'; Kind = 'Tar'; Names = @('actionlint', 'actionlint'); Link = $false; Message = '*exactly one regular actionlint*' }
        @{ Case = 'a symbolic-link TAR executable'; Kind = 'Tar'; Names = @('actionlint'); Link = $true; Message = '*exactly one regular actionlint*' }
    ) {
        Import-Module (Join-Path $tools 'ToolDependencies.psm1') -Force
        $archivePath = Join-Path $TestDrive ("bad-$([guid]::NewGuid().ToString('N'))." + $(if ($Kind -eq 'Zip') { 'zip' } else { 'tar.gz' }))
        $file = [IO.File]::Create($archivePath)
        if ($Kind -eq 'Zip') {
            $archive = [IO.Compression.ZipArchive]::new($file, [IO.Compression.ZipArchiveMode]::Create)
            try { foreach ($name in $Names) { $null = $archive.CreateEntry($name) } }
            finally { $archive.Dispose(); $file.Dispose() }
        }
        else {
            $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Compress)
            $writer = [System.Formats.Tar.TarWriter]::new($gzip)
            try {
                foreach ($name in $Names) {
                    $type = if ($Link) { [System.Formats.Tar.TarEntryType]::SymbolicLink } else { [System.Formats.Tar.TarEntryType]::RegularFile }
                    $entry = [System.Formats.Tar.PaxTarEntry]::new($type, $name)
                    if ($Link) { $entry.LinkName = 'other' }
                    else { $entry.DataStream = [IO.MemoryStream]::new([Text.Encoding]::UTF8.GetBytes('executable fixture')) }
                    try { $writer.WriteEntry($entry) }
                    finally { if ($null -ne $entry.DataStream) { $entry.DataStream.Dispose() } }
                }
            }
            finally { $writer.Dispose(); $gzip.Dispose(); $file.Dispose() }
        }
        # Deliberately invalid archive contents, with a matching hash so the structural guard is exercised.
        $package = [pscustomobject]@{
            Name = 'Actionlint'; Archive = [IO.Path]::GetFileName($archivePath); Executable = 'actionlint'; Sha256 = (Get-FileHash $archivePath).Hash
        }
        { Expand-ToolBinary -Package $package -ArchivePath $archivePath -DestinationPath (Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))) } |
            Should -Throw $Message
    }

    It 'rejects a mismatched actionlint archive before extraction or PATH publication' {
        $oldTemp = $env:RUNNER_TEMP
        $oldGitHubPath = $env:GITHUB_PATH
        try {
            $env:RUNNER_TEMP = $TestDrive
            $env:GITHUB_PATH = Join-Path $TestDrive 'actionlint-github-path'
            Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'not the pinned archive' }
            { & (Join-Path $tools 'Install-CiBinary.ps1') -Name Actionlint } | Should -Throw '*SHA256 mismatch for Actionlint*'
            Test-Path $env:GITHUB_PATH | Should -BeFalse
            @(Get-ChildItem -LiteralPath $TestDrive -Filter 'platform-actionlint-*').Count | Should -Be 0
        }
        finally { $env:RUNNER_TEMP = $oldTemp; $env:GITHUB_PATH = $oldGitHubPath }
    }

    It 'rejects a replaced Terraform executable without running it' -Skip:(-not $IsLinux) {
        $directory = Join-Path $TestDrive 'bin'
        $null = New-Item -ItemType Directory -Path $directory
        $marker = Join-Path $TestDrive 'executed'
        $executable = Join-Path $directory 'terraform'
        Set-Content -LiteralPath $executable -Value "#!/bin/sh`ntouch '$marker'"
        & chmod '+x' $executable
        $oldPath = $env:PATH
        try {
            $env:PATH = "$directory$([IO.Path]::PathSeparator)$oldPath"
            { & (Join-Path $tools 'Test-ToolBinary.ps1') } | Should -Throw '*SHA256 mismatch for Terraform*'
            Test-Path $marker | Should -BeFalse
        }
        finally { $env:PATH = $oldPath }
    }

    It 'rejects a mismatched TFLint archive before extraction or PATH publication' -Skip:(-not $IsLinux) {
        $oldTemp = $env:RUNNER_TEMP
        $oldGitHubPath = $env:GITHUB_PATH
        try {
            $env:RUNNER_TEMP = $TestDrive
            $env:GITHUB_PATH = Join-Path $TestDrive 'github-path'
            Mock Invoke-WebRequest { Set-Content -LiteralPath $OutFile -Value 'not the pinned archive' }
            { & (Join-Path $tools 'Install-CiBinary.ps1') } | Should -Throw '*SHA256 mismatch for TFLint*'
            Test-Path $env:GITHUB_PATH | Should -BeFalse
            @(Get-ChildItem -LiteralPath $TestDrive -Filter 'platform-tflint-*').Count | Should -Be 0
        }
        finally { $env:RUNNER_TEMP = $oldTemp; $env:GITHUB_PATH = $oldGitHubPath }
    }

    It 'publishes a matching TFLint archive without executing the downloaded binary' -Skip:(-not $IsLinux) {
        $root = Join-Path $TestDrive 'tools'
        $payload = Join-Path $TestDrive 'payload'
        $null = New-Item -ItemType Directory -Path $root, $payload
        Copy-Item (Join-Path $tools 'Install-CiBinary.ps1'), (Join-Path $tools 'ToolDependencies.psm1') $root
        $marker = Join-Path $TestDrive 'executed'
        Set-Content (Join-Path $payload 'tflint') "#!/bin/sh`ntouch '$marker'"
        $fixtureArchive = Join-Path $TestDrive 'tflint.zip'
        [IO.Compression.ZipFile]::CreateFromDirectory($payload, $fixtureArchive)
        $hash = (Get-FileHash $fixtureArchive).Hash
        Set-Content (Join-Path $root 'requirements.psd1') "@{ Binaries=@{ TFLint=@{ Version='0.60.0'; LinuxAmd64ArchiveSha256='$hash' } } }"
        $oldTemp = $env:RUNNER_TEMP
        $oldGitHubPath = $env:GITHUB_PATH
        try {
            $env:RUNNER_TEMP = $TestDrive
            $env:GITHUB_PATH = Join-Path $TestDrive 'github-path'
            Mock Invoke-WebRequest { Copy-Item $fixtureArchive $OutFile }
            & (Join-Path $root 'Install-CiBinary.ps1')
            $directory = (Get-Content $env:GITHUB_PATH -Raw).Trim()
            Test-Path (Join-Path $directory 'tflint') | Should -BeTrue
            Test-Path $marker | Should -BeFalse
        }
        finally { $env:RUNNER_TEMP = $oldTemp; $env:GITHUB_PATH = $oldGitHubPath }
    }
}
