function Invoke-TerraformTestProcess {
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Executable,
        [Parameter(Mandatory)][string[]] $ArgumentList,
        [Parameter(Mandatory)][string] $CacheRoot
    )

    $cachePath = Join-Path $CacheRoot ([guid]::NewGuid().ToString('N'))
    $null = New-Item -ItemType Directory -Path $cachePath -Force -ErrorAction Stop
    $analysisCachePath = Join-Path $cachePath 'ModuleAnalysisCache'
    $previousXdg = $env:XDG_CACHE_HOME
    $previousAnalysis = $env:PSModuleAnalysisCachePath
    try {
        # -NoProfile does not disable the startup JIT profile shared by Unix pwsh processes.
        $env:XDG_CACHE_HOME = $cachePath
        $env:PSModuleAnalysisCachePath = $analysisCachePath
        $output = & $Executable @ArgumentList 2>&1 | Out-String
        [pscustomobject]@{
            ExitCode = $LASTEXITCODE
            Output = $output
            CachePath = $cachePath
            AnalysisCachePath = $analysisCachePath
        }
    }
    finally {
        $env:XDG_CACHE_HOME = $previousXdg
        $env:PSModuleAnalysisCachePath = $previousAnalysis
    }
}

Export-ModuleMember -Function Invoke-TerraformTestProcess
