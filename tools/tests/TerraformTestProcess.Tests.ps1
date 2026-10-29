BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'TerraformTestProcess.psm1') -Force
    $pwsh = [Environment]::ProcessPath
}

Describe 'Terraform test child cache isolation' {
    BeforeEach {
        $previousXdg = $env:XDG_CACHE_HOME
        $previousAnalysis = $env:PSModuleAnalysisCachePath
        $sharedCache = Join-Path $TestDrive 'shared-cache'
        $cacheRoot = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $null = New-Item -ItemType Directory -Path $sharedCache -Force
        $env:XDG_CACHE_HOME = $sharedCache
        $env:PSModuleAnalysisCachePath = Join-Path $sharedCache 'ModuleAnalysisCache'
    }

    AfterEach {
        $env:XDG_CACHE_HOME = $previousXdg
        $env:PSModuleAnalysisCachePath = $previousAnalysis
    }

    It 'does not pass a failed child cache to the next invocation from the same parent' {
        $failedScript = Join-Path $TestDrive 'failed-child.ps1'
        Set-Content -LiteralPath $failedScript -Value @'
Set-Content -LiteralPath (Join-Path $env:XDG_CACHE_HOME 'poisoned-cache') -Value 'injected invalid runtime cache'
[Console]::Error.WriteLine('injected child failure after writing its cache')
exit 73
'@
        $healthyScript = Join-Path $TestDrive 'healthy-child.ps1'
        Set-Content -LiteralPath $healthyScript -Value @'
if (Test-Path -LiteralPath (Join-Path $env:XDG_CACHE_HOME 'poisoned-cache')) {
    [Console]::Error.WriteLine('previous child cache leaked')
    exit 74
}
Write-Output 'healthy child'
'@
        $failed = Invoke-TerraformTestProcess -Executable $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $failedScript) -CacheRoot $cacheRoot
        $failed.ExitCode | Should -Be 73 -Because $failed.Output
        $failed.Output | Should -Match 'injected child failure after writing its cache'
        $healthy = Invoke-TerraformTestProcess -Executable $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $healthyScript) -CacheRoot $cacheRoot
        $healthy.ExitCode | Should -Be 0 -Because $healthy.Output
        $healthy.Output.Trim() | Should -BeExactly 'healthy child'
        $healthy.CachePath | Should -Not -BeExactly $failed.CachePath
        Test-Path -LiteralPath (Join-Path $failed.CachePath 'poisoned-cache') | Should -BeTrue
        Test-Path -LiteralPath (Join-Path $sharedCache 'poisoned-cache') | Should -BeFalse
        $env:XDG_CACHE_HOME | Should -BeExactly $sharedCache
        $env:PSModuleAnalysisCachePath | Should -BeExactly (Join-Path $sharedCache 'ModuleAnalysisCache')
    }

    It 'passes private caches through a native parent to its pwsh descendant without changing module search paths' {
        $script = Join-Path $TestDrive 'native-parent.ps1'
        Set-Content -LiteralPath $script -Value @'
$output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -Command '[ordered]@{ Xdg = $env:XDG_CACHE_HOME; Analysis = $env:PSModuleAnalysisCachePath; ModulePath = $env:PSModulePath } | ConvertTo-Json -Compress'
Write-Output $output
exit $LASTEXITCODE
'@
        $modulePath = $env:PSModulePath
        $result = Invoke-TerraformTestProcess -Executable $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-File', $script) -CacheRoot $cacheRoot
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $child = $result.Output | ConvertFrom-Json -AsHashtable
        $child.Xdg | Should -BeExactly $result.CachePath
        $child.Analysis | Should -BeExactly $result.AnalysisCachePath
        Split-Path -Parent $child.Analysis | Should -BeExactly $result.CachePath
        foreach ($path in $modulePath.Split([IO.Path]::PathSeparator, [StringSplitOptions]::RemoveEmptyEntries)) {
            $child.ModulePath.Split([IO.Path]::PathSeparator) | Should -Contain $path
        }
        $env:PSModulePath | Should -BeExactly $modulePath
        $env:XDG_CACHE_HOME | Should -BeExactly $sharedCache
        $env:PSModuleAnalysisCachePath | Should -BeExactly (Join-Path $sharedCache 'ModuleAnalysisCache')
    }

    It 'places the actual PowerShell startup profile directory inside the private Unix cache' -Skip:$IsWindows {
        $command = @'
$platform = [psobject].Assembly.GetType('System.Management.Automation.Platform')
$platform.GetField('CacheDirectory', [Reflection.BindingFlags]'Static,NonPublic,Public').GetValue($null)
'@
        $result = Invoke-TerraformTestProcess -Executable $pwsh -ArgumentList @('-NoProfile', '-NonInteractive', '-Command', $command) -CacheRoot $cacheRoot
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $startupCache = $result.Output.Trim()
        $startupCache | Should -BeExactly (Join-Path $result.CachePath 'powershell')
        Test-Path -LiteralPath $startupCache -PathType Container | Should -BeTrue
    }

    It 'restores <Case> cache settings when launching the executable throws' -ForEach @(
        @{ Case = 'defined'; Value = 'original-cache' }
        @{ Case = 'undefined'; Value = $null }
        @{ Case = 'empty'; Value = '' }
    ) {
        $env:XDG_CACHE_HOME = $Value
        $env:PSModuleAnalysisCachePath = $Value
        {
            Invoke-TerraformTestProcess -Executable (Join-Path $TestDrive 'missing-executable') -ArgumentList @('unused') -CacheRoot $cacheRoot
        } | Should -Throw '*missing-executable*'
        [Environment]::GetEnvironmentVariable('XDG_CACHE_HOME') | Should -BeExactly $Value
        [Environment]::GetEnvironmentVariable('PSModuleAnalysisCachePath') | Should -BeExactly $Value
    }
}
