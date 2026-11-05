BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../ToolDependencies.psm1')
    Import-Module (Get-ToolDependencyPath -Name PSScriptAnalyzer)
    Import-Module (Join-Path $PSScriptRoot '../LocalCiGate.psm1')
    Import-Module (Join-Path $PSScriptRoot '../PowerShellAnalysisCache.psm1') -Force
}

Describe 'PowerShell analysis cache' {
    BeforeEach {
        $source = Join-Path $TestDrive 'source.ps1'
        Set-Content -LiteralPath $source -Value "'valid'" -NoNewline
        $cache = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $parameters = @{
            Path = $source
            CacheDirectory = $cache
            Settings = @{ IncludeDefaultRules = $true }
            AnalyzerVersion = '1.24.0'
            PowerShellVersion = '7.4.0'
        }
        Mock Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache { }
    }

    It 'analyzes a cold file and reuses only its successful result' {
        Invoke-CachedPowerShellAnalysis @parameters
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 1 -Exactly
    }

    It 'reuses equal analyzer settings regardless of dictionary order' {
        $parameters.Settings = [ordered]@{ IncludeDefaultRules = $true; ExcludeRules = @('PSAvoidUsingWriteHost') }
        Invoke-CachedPowerShellAnalysis @parameters
        $parameters.Settings = [ordered]@{ ExcludeRules = @('PSAvoidUsingWriteHost'); IncludeDefaultRules = $true }
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 1 -Exactly
    }

    It 'analyzes again when <Component> changes' -ForEach @(
        @{ Component = 'file content' }
        @{ Component = 'analyzer settings' }
        @{ Component = 'analyzer version' }
        @{ Component = 'PowerShell version' }
        @{ Component = 'file name' }
    ) {
        Invoke-CachedPowerShellAnalysis @parameters
        switch ($Component) {
            'file content' { Set-Content -LiteralPath $source -Value "'changed'" -NoNewline }
            'analyzer settings' { $parameters.Settings.ExcludeRules = @('PSAvoidUsingWriteHost') }
            'analyzer version' { $parameters.AnalyzerVersion = '1.25.0' }
            'PowerShell version' { $parameters.PowerShellVersion = '7.5.0' }
            'file name' {
                $parameters.Path = Join-Path $TestDrive 'renamed.ps1'
                Copy-Item -LiteralPath $source -Destination $parameters.Path
            }
        }
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'analyzes again after a truncated cache write' {
        Invoke-CachedPowerShellAnalysis @parameters
        $entry = Get-ChildItem -LiteralPath $cache -Filter '*.json'
        Set-Content -LiteralPath $entry.FullName -Value '{"Schema":' -NoNewline
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'analyzes again for corrupt receipt <Case>' -ForEach @(
        @{ Case = 'null'; Json = 'null' }
        @{ Case = 'array'; Json = '[]' }
        @{ Case = 'empty object'; Json = '{}' }
        @{ Case = 'missing schema'; Field = 'Schema'; Remove = $true }
        @{ Case = 'string schema'; Field = 'Schema'; Value = '1' }
        @{ Case = 'wrong schema'; Field = 'Schema'; Value = 2 }
        @{ Case = 'missing key'; Field = 'Key'; Remove = $true }
        @{ Case = 'nonstring key'; Field = 'Key'; Value = 1 }
        @{ Case = 'array key'; Field = 'Key'; ArrayKey = $true }
        @{ Case = 'different key'; Field = 'Key'; Value = 'other' }
        @{ Case = 'key casing'; Field = 'Key'; LowerKey = $true }
        @{ Case = 'missing status'; Field = 'Status'; Remove = $true }
        @{ Case = 'nonstring status'; Field = 'Status'; Value = $true }
        @{ Case = 'array status'; Field = 'Status'; Value = @('Passed') }
        @{ Case = 'failed status'; Field = 'Status'; Value = 'Failed' }
        @{ Case = 'empty status'; Field = 'Status'; Value = '' }
        @{ Case = 'status casing'; Field = 'Status'; Value = 'passed' }
        @{ Case = 'missing completion'; Field = 'CompletedAtUtcTicks'; Remove = $true }
        @{ Case = 'string completion'; Field = 'CompletedAtUtcTicks'; StringCompletion = $true }
        @{ Case = 'fractional completion'; Field = 'CompletedAtUtcTicks'; Value = 1.5 }
        @{ Case = 'future completion'; Field = 'CompletedAtUtcTicks'; Future = $true }
        @{ Case = 'expired completion'; Field = 'CompletedAtUtcTicks'; Expired = $true }
        @{ Case = 'oversized entry'; Oversized = $true }
    ) {
        Invoke-CachedPowerShellAnalysis @parameters
        $entry = Get-ChildItem -LiteralPath $cache -Filter '*.json'
        if ($_.ContainsKey('Json')) { $json = $Json }
        else {
            # Deliberately corrupt one field of a real successful receipt.
            $receipt = Get-Content -LiteralPath $entry.FullName -Raw | ConvertFrom-Json -AsHashtable
            if ($_.ContainsKey('Oversized')) { $receipt['Padding'] = 'excess data' }
            elseif ($_.ContainsKey('Remove')) { $receipt.Remove($Field) }
            elseif ($_.ContainsKey('LowerKey')) { $receipt[$Field] = $receipt[$Field].ToLowerInvariant() }
            elseif ($_.ContainsKey('ArrayKey')) { $receipt[$Field] = @($receipt[$Field]) }
            elseif ($_.ContainsKey('StringCompletion')) { $receipt[$Field] = [string] $receipt[$Field] }
            elseif ($_.ContainsKey('Future')) { $receipt[$Field] = [datetime]::UtcNow.AddDays(1).Ticks }
            elseif ($_.ContainsKey('Expired')) { $receipt[$Field] = [datetime]::UtcNow.AddDays(-8).Ticks }
            else { $receipt[$Field] = $Value }
            $json = $receipt | ConvertTo-Json -Compress
            if ($_.ContainsKey('Oversized')) { $json = (' ' * 4097) + $json }
        }
        Set-Content -LiteralPath $entry.FullName -Value $json -NoNewline
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'analyzes an unreadable entry instead of trusting it' {
        Invoke-CachedPowerShellAnalysis @parameters
        $entry = Get-ChildItem -LiteralPath $cache -Filter '*.json'
        $handle = [IO.File]::Open($entry.FullName, 'Open', 'ReadWrite', 'None')
        try { Invoke-CachedPowerShellAnalysis @parameters }
        finally { $handle.Dispose() }
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'does not treat an interrupted pending write as success' {
        Invoke-CachedPowerShellAnalysis @parameters
        $entry = Get-ChildItem -LiteralPath $cache -Filter '*.json'
        Move-Item -LiteralPath $entry.FullName -Destination "$($entry.FullName).pending"
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'never caches analyzer warnings as success and retries the next run' {
        Mock Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache {
            [pscustomobject]@{ RuleName = 'PSAvoidUsingWriteHost'; ScriptName = 'source.ps1'; Line = 1; Message = 'warning' }
        }
        { Invoke-CachedPowerShellAnalysis @parameters } | Should -Throw '*static analysis failed*'
        { Invoke-CachedPowerShellAnalysis @parameters } | Should -Throw '*static analysis failed*'
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
        @(Get-ChildItem -LiteralPath $cache -File).Count | Should -Be 0
    }

    It 'never caches an interrupted analyzer as success' {
        Mock Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache { throw 'analyzer interrupted' }
        { Invoke-CachedPowerShellAnalysis @parameters } | Should -Throw '*analyzer interrupted*'
        Mock Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache { }
        Invoke-CachedPowerShellAnalysis @parameters
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'never caches syntax errors' {
        Set-Content -LiteralPath $source -Value 'function {' -NoNewline
        { Invoke-CachedPowerShellAnalysis @parameters } | Should -Throw '*syntax errors*'
        { Invoke-CachedPowerShellAnalysis @parameters } | Should -Throw '*syntax errors*'
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 0
    }

    It 'rejects a file changed during analysis and analyzes its replacement on retry' {
        Mock Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache {
            Set-Content -LiteralPath $Path -Value "'changed during analysis'" -NoNewline
        }
        { Invoke-CachedPowerShellAnalysis @parameters } | Should -Throw '*changed during analysis*'
        Mock Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache { }
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'bounds cache files including orphaned writes to 256 entries' {
        Invoke-CachedPowerShellAnalysis @parameters
        foreach ($index in 1..260) {
            Set-Content -LiteralPath (Join-Path $cache "$index.pending") -Value 'interrupted'
        }
        Invoke-CachedPowerShellAnalysis @parameters
        @(Get-ChildItem -LiteralPath $cache -File -Force).Count | Should -BeLessOrEqual 256
    }

    It 'analyzes a directory in place of a cache entry without treating it as success' {
        Invoke-CachedPowerShellAnalysis @parameters
        $entry = Get-ChildItem -LiteralPath $cache -Filter '*.json'
        Remove-Item -LiteralPath $entry.FullName
        $null = New-Item -ItemType Directory -Path $entry.FullName
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'analyzes instead of following a cache entry symbolic link' {
        Invoke-CachedPowerShellAnalysis @parameters
        $entry = Get-ChildItem -LiteralPath $cache -Filter '*.json'
        $target = Join-Path $TestDrive 'external-receipt.json'
        Move-Item -LiteralPath $entry.FullName -Destination $target
        $null = New-Item -ItemType SymbolicLink -Path $entry.FullName -Value $target
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
    }

    It 'does not trust or repair a cache directory with a broader Windows ACL' -Skip:(-not $IsWindows) {
        Invoke-CachedPowerShellAnalysis @parameters
        $directory = [IO.DirectoryInfo]::new($cache)
        $acl = Get-Acl -LiteralPath $cache
        $rule = [Security.AccessControl.FileSystemAccessRule]::new(
            [Security.Principal.SecurityIdentifier]::new('S-1-5-11'), [Security.AccessControl.FileSystemRights]::Modify,
            [Security.AccessControl.AccessControlType]::Allow)
        $null = $acl.AddAccessRule($rule)
        [IO.FileSystemAclExtensions]::SetAccessControl($directory, $acl)
        Invoke-CachedPowerShellAnalysis @parameters
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 3 -Exactly
        (Get-Acl -LiteralPath $cache).Access.Count | Should -Be 3
    }

    It 'does not trust or repair a cache directory with broader Unix permissions' -Skip:$IsWindows {
        Invoke-CachedPowerShellAnalysis @parameters
        [IO.File]::SetUnixFileMode($cache, [IO.UnixFileMode] 493)
        Invoke-CachedPowerShellAnalysis @parameters
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 2 -Exactly
        [int] [IO.File]::GetUnixFileMode($cache) | Should -Be 493
    }

    It 'uses the cache through Test-PowerShell only when requested' {
        $driver = Join-Path $PSScriptRoot '../Test-PowerShell.ps1'
        & $driver -Path $source -CacheDirectory $cache
        & $driver -Path $source -CacheDirectory $cache
        & $driver -Path $source
        & $driver -Path $source
        Should -Invoke Invoke-ScriptAnalyzer -ModuleName PowerShellAnalysisCache -Times 3 -Exactly
    }

}

Describe 'Local CI Unix private directory access' {
    It 'accepts a regular directory with mode 0700' {
        { Assert-LocalCiUnixTempAccess -Access @{ Directory = $true; ReparsePoint = $false; Mode = 448 } } |
            Should -Not -Throw
    }

    It 'rejects unsafe directory access <Case>' -ForEach @(
        @{ Case = 'a file'; Field = 'Directory'; Value = $false }
        @{ Case = 'unknown type'; Field = 'Directory'; Value = $null }
        @{ Case = 'string type'; Field = 'Directory'; Value = 'True' }
        @{ Case = 'a symbolic link'; Field = 'ReparsePoint'; Value = $true }
        @{ Case = 'unknown link state'; Field = 'ReparsePoint'; Value = $null }
        @{ Case = 'string link state'; Field = 'ReparsePoint'; Value = 'False' }
        @{ Case = 'broader permissions'; Field = 'Mode'; Value = 493 }
        @{ Case = 'unknown permissions'; Field = 'Mode'; Value = $null }
        @{ Case = 'string permissions'; Field = 'Mode'; Value = '448' }
    ) {
        $access = @{ Directory = $true; ReparsePoint = $false; Mode = 448 }
        $access[$Field] = $Value
        { Assert-LocalCiUnixTempAccess -Access $access } | Should -Throw '*Unsafe CI TEMP*'
    }
}
