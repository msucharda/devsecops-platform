BeforeAll {
    $script:sourceTools = Split-Path $PSScriptRoot -Parent

    function Invoke-BinaryInstallerProcess {
        param([string] $Root, [string] $Boundary = 'None')
        $start = [Diagnostics.ProcessStartInfo]::new((Get-Command pwsh).Source)
        $start.UseShellExecute = $false
        $start.RedirectStandardOutput = $true
        $start.RedirectStandardError = $true
        foreach ($argument in @('-NoProfile', '-NonInteractive', '-File', (Join-Path $Root 'run.ps1'), '-Boundary', $Boundary)) {
            $start.ArgumentList.Add($argument)
        }
        $start.Environment['BINARY_INSTALLER_ROOT'] = $Root
        $start.Environment['RUNNER_TEMP'] = Join-Path $Root 'temp'
        $start.Environment['GITHUB_PATH'] = Join-Path $Root 'github-path'
        $process = [Diagnostics.Process]::new()
        $process.StartInfo = $start
        try {
            $null = $process.Start()
            $stdout = $process.StandardOutput.ReadToEndAsync()
            $stderr = $process.StandardError.ReadToEndAsync()
            if (-not $process.WaitForExit(60000)) {
                Stop-Process -Id $process.Id -Force
                throw 'The binary installer exceeded 60 seconds.'
            }
            return @{ ExitCode = $process.ExitCode; Output = $stdout.GetAwaiter().GetResult(); Error = $stderr.GetAwaiter().GetResult() }
        }
        finally { $process.Dispose() }
    }
}

Describe 'CI binary installation recovery' -Tag Interruption {
    BeforeEach {
        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $tools = Join-Path $root 'tools'
        $null = New-Item -ItemType Directory -Path $tools, (Join-Path $root 'temp')
        Copy-Item (Join-Path $script:sourceTools 'Install-CiBinary.ps1'), (Join-Path $script:sourceTools 'ToolDependencies.psm1') $tools
        $name = if ($IsLinux) { 'Trivy' } else { 'Actionlint' }
        $executable = if ($IsLinux) { 'trivy' } else { 'actionlint.exe' }
        $payload = Join-Path $root 'payload'
        $null = New-Item -ItemType Directory -Path $payload
        Set-Content (Join-Path $payload $executable) 'verified fixture; never executed'
        $archive = Join-Path $root 'fixture'
        if ($IsWindows) { [IO.Compression.ZipFile]::CreateFromDirectory($payload, $archive) }
        else {
            $file = [IO.File]::Create($archive)
            $gzip = [IO.Compression.GZipStream]::new($file, [IO.Compression.CompressionMode]::Compress)
            $writer = [System.Formats.Tar.TarWriter]::new($gzip)
            try { $writer.WriteEntry((Join-Path $payload $executable), $executable) }
            finally { $writer.Dispose(); $gzip.Dispose(); $file.Dispose() }
        }
        $hash = (Get-FileHash $archive).Hash
        $key = if ($IsWindows) { 'WindowsAmd64ArchiveSha256' } else { 'LinuxAmd64ArchiveSha256' }
        Set-Content (Join-Path $tools 'requirements.psd1') "@{ Binaries=@{ $name=@{ Version='0.72.0'; $key='$hash' } } }"
        Set-Content (Join-Path $root 'run.ps1') @'
param([string] $Boundary)
Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'
$root = $env:BINARY_INSTALLER_ROOT
$installer = Join-Path $root 'tools/Install-CiBinary.ps1'
$module = Join-Path $root 'tools/ToolDependencies.psm1'
function Invoke-WebRequest {
    [CmdletBinding()]
    param([string] $Uri, [string] $OutFile, [int] $ConnectionTimeoutSeconds, [int] $OperationTimeoutSeconds)
    Copy-Item -LiteralPath (Join-Path $env:BINARY_INSTALLER_ROOT 'fixture') -Destination $OutFile
}
if ($Boundary -ne 'None') {
    $target = $installer
    $pattern = switch ($Boundary) {
        Downloaded { '^\s*Assert-ToolPackage -Path \$archive ' }
        Verified { '^\s*\$null = Expand-ToolBinary ' }
        Extracting {
            $target = $module
            if ($IsWindows) { '^\s*\$inputStream\.CopyTo\(\$output\)' }
            else { '^\s*\$entry\.DataStream\.CopyTo\(\$output\)' }
        }
        Extracted { '^\s*Add-Content -LiteralPath \$env:GITHUB_PATH ' }
        Published { '^\s*\$published = \$true' }
    }
    $lines = @(Select-String -LiteralPath $target -Pattern $pattern)
    if ($lines.Count -ne 1) { throw "Expected one interruption boundary for $Boundary." }
    # Exit bypasses catch/finally in the real installer without changing its source.
    $null = Set-PSBreakpoint -Script $target -Line $lines[0].LineNumber -Action { [Environment]::Exit(17) }
}
$name = if ($IsLinux) { 'Trivy' } else { 'Actionlint' }
& $installer -Name $name
'@
    }

    It 'resumes after abrupt termination at <Boundary> without publishing incomplete staging' -ForEach @(
        @{ Boundary = 'Downloaded' }
        @{ Boundary = 'Verified' }
        @{ Boundary = 'Extracting' }
        @{ Boundary = 'Extracted' }
        @{ Boundary = 'Published' }
    ) {
        $first = Invoke-BinaryInstallerProcess -Root $root -Boundary $Boundary
        $first.ExitCode | Should -Be 17 -Because $first.Error
        $staging = @(Get-ChildItem (Join-Path $root 'temp') -Directory)
        $staging.Count | Should -Be 1 -Because 'abrupt termination must bypass installer cleanup'
        $pathFile = Join-Path $root 'github-path'
        if ($Boundary -ne 'Published') { Test-Path $pathFile | Should -BeFalse }
        if ($Boundary -eq 'Extracting') {
            (Get-Item (Join-Path $staging[0].FullName $executable)).Length | Should -Be 0
        }
        $second = Invoke-BinaryInstallerProcess -Root $root
        $second.ExitCode | Should -Be 0 -Because $second.Error
        $published = @(Get-Content $pathFile)
        $published.Count | Should -Be $(if ($Boundary -eq 'Published') { 2 } else { 1 })
        foreach ($directory in $published) {
            Get-Content (Join-Path $directory $executable) | Should -BeExactly 'verified fixture; never executed'
        }
        if ($Boundary -ne 'Published') { $published | Should -Not -Contain $staging[0].FullName }
    }
}
