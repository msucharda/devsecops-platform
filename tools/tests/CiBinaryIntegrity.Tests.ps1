BeforeAll {
    $script:tools = Split-Path $PSScriptRoot -Parent
}

Describe 'CI binary integrity before execution' {
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
