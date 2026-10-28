BeforeAll {
    $script:tools = Split-Path $PSScriptRoot -Parent
}

Describe 'CI binary integrity before execution' {
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
        Should -Invoke Invoke-WebRequest -Times 2 -Exactly
        Set-Content $package.CachePath 'tampered cache'
        { Get-ToolBinaryPath -Name Actionlint -ToolsPath $root -DestinationPath (Join-Path $TestDrive 'rejected') } |
            Should -Throw '*SHA256 mismatch for Actionlint*'
        { & (Join-Path $root 'Install-CiBinary.ps1') -Name Actionlint -Local } |
            Should -Throw '*SHA256 mismatch for Actionlint*'
        Test-Path (Join-Path $TestDrive 'rejected') | Should -BeFalse
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
