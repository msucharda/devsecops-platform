BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'MutationTesting.psm1') -Force

    function Get-TestFunctionAst {
        param([Parameter(Mandatory)][string] $Text)

        $ast = [System.Management.Automation.Language.Parser]::ParseInput($Text, [ref] $null, [ref] $null)
        return $ast.Find({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true)
    }

    function Initialize-TestRepository {
        param([Parameter(Mandatory)][string] $Content)

        $root = Join-Path $TestDrive ([guid]::NewGuid().ToString('n'))
        New-Item -ItemType Directory -Path (Join-Path $root 'tools/tests') -Force | Out-Null
        Set-Content -LiteralPath (Join-Path $root 'tools/Check.psm1') -Value $Content -NoNewline
        return $root
    }

    function Get-TestConfiguration {
        param([string[]] $Name = @('sample-check'), [object[]] $Exception = @())

        return @{
            Checks = @(foreach ($item in $Name) { @{ Name = $item; Tests = @(@{ Path = 'tools/tests/Sample.Tests.ps1'; FullName = @('*') }) } })
            Exceptions = $Exception
        }
    }

    function Get-TestResult {
        param([string] $Id = 'Sample: condition', [string] $Status = 'Killed')

        return [pscustomobject]@{ Id = $Id; Status = $Status; File = 'tools/Check.psm1'; Line = 3; Detail = '' }
    }
}

Describe 'Security check mutation testing' {
    Context 'markers' {
        It 'finds the function on the line after the marker' {
            $repo = Initialize-TestRepository -Content "function Other { }`n# security-check: sample-check`nfunction Test-Sample { if (`$x) { throw 'no' } }`n"

            $marker = @(Get-SecurityCheckMarker -RepoPath $repo)

            $marker.Count | Should -Be 1
            $marker[0].Name | Should -BeExactly 'sample-check'
            $marker[0].File | Should -BeExactly 'tools/Check.psm1'
            $marker[0].Line | Should -Be 3
            $marker[0].Function | Should -BeExactly 'Test-Sample'
        }

        It 'ignores markers in test files' {
            $repo = Initialize-TestRepository -Content 'function Other { }'
            Set-Content -LiteralPath (Join-Path $repo 'tools/tests/Sample.Tests.ps1') -Value "# security-check: sample-check`nfunction Test-Sample { }"

            @(Get-SecurityCheckMarker -RepoPath $repo).Count | Should -Be 0
        }

        It 'fails closed on a malformed marker' {
            $repo = Initialize-TestRepository -Content "# security-check: bad name`nfunction Test-Sample { }"

            { Get-SecurityCheckMarker -RepoPath $repo } | Should -Throw '*malformed security-check marker*'
        }

        It 'fails closed when the marker is not directly before a function' {
            $repo = Initialize-TestRepository -Content "# security-check: sample-check`n`nfunction Test-Sample { }"

            { Get-SecurityCheckMarker -RepoPath $repo } | Should -Throw '*directly before a function*'
        }
    }

    Context 'mutants' {
        It 'weakens a deny guard and its -or operands to false' {
            $function = Get-TestFunctionAst -Text "function Test-Sample { if (`$a -or `$b) { throw 'no' } }"

            $replacement = @(Get-FunctionMutant -Function $function | ForEach-Object { "$($_.Original)=>$($_.Replacement)" })

            $replacement | Should -Contain '$a -or $b=>($false)'
            $replacement | Should -Contain '$a -or $b=>(-not ($a -or $b))'
            $replacement | Should -Contain '$a=>($false)'
            $replacement | Should -Contain '$b=>($false)'
        }

        It 'weakens an allow return and its -and operands to true' {
            $function = Get-TestFunctionAst -Text 'function Test-Sample { return $a -and $b }'

            $replacement = @(Get-FunctionMutant -Function $function | ForEach-Object { "$($_.Original)=>$($_.Replacement)" })

            $replacement | Should -Contain '$a -and $b=>$true'
            $replacement | Should -Contain '$a=>($true)'
            $replacement | Should -Contain '$b=>($true)'
        }

        It 'weakens the operands of a logical value that a <Case> guard checks' -ForEach @(
            @{ Case = 'negated'; Guard = 'if (-not $ok) { return $false }' }
            @{ Case = 'positive'; Guard = 'if ($ok) { return $true }' }
        ) {
            $function = Get-TestFunctionAst -Text "function Test-Sample { `$ok = (`$id -is [int]) -and `$id -gt 0 -and `$node -ceq 'X'; $Guard; return `$false }"

            $mutants = @(Get-FunctionMutant -Function $function | ForEach-Object { "$($_.Original)=>$($_.Replacement)" })

            $mutants | Should -Contain '($id -is [int])=>($true)'
            $mutants | Should -Contain '$id -gt 0=>($true)'
            $mutants | Should -Contain "`$node -ceq 'X'=>(`$true)"
            $mutants | Should -Contain '-ceq=>-ieq'
        }

        It 'does not weaken a logical value that no guard checks' {
            $function = Get-TestFunctionAst -Text 'function Test-Sample { $ok = $a -and $b; if (-not $c) { return $false }; return $ok }'

            @(Get-FunctionMutant -Function $function | Where-Object { $_.Original -in @('$a', '$b') }) | Should -BeNullOrEmpty
        }

        It 'weakens a parenthesized allow return like an unparenthesized one' {
            $plain = Get-TestFunctionAst -Text 'function Test-Sample { return $a -and $b }'
            $wrapped = Get-TestFunctionAst -Text 'function Test-Sample { return ($a -and $b) }'

            $plainKinds = @(Get-FunctionMutant -Function $plain | ForEach-Object Kind | Sort-Object)
            $wrapped = @(Get-FunctionMutant -Function $wrapped)

            @($wrapped | ForEach-Object Kind | Sort-Object) | Should -Be $plainKinds
            @($wrapped | ForEach-Object { "$($_.Original)=>$($_.Replacement)" }) | Should -Contain '($a -and $b)=>$true'
        }

        It 'does not weaken -and operands of a deny guard' {
            $function = Get-TestFunctionAst -Text "function Test-Sample { if (`$a -and `$b) { throw 'no' } }"

            @(Get-FunctionMutant -Function $function | Where-Object Kind -eq 'operand').Count | Should -Be 0
        }

        It 'flips the polarity under -not' {
            $function = Get-TestFunctionAst -Text "function Test-Sample { if (-not (`$a -and `$b)) { throw 'no' } }"

            $operands = @(Get-FunctionMutant -Function $function | Where-Object Kind -eq 'operand')

            $operands.Original | Should -Be @('$a', '$b')
            $operands.Replacement | Should -Be @('($true)', '($true)')
        }

        It 'makes <Operator> case-insensitive only when it then accepts more values' -ForEach @(
            @{ Operator = '-cne'; Body = "if (`$a -cne 'x') { throw 'no' }"; Expected = '-ine' }
            @{ Operator = '-ceq'; Body = "if (`$a -ceq 'x') { return `$true }"; Expected = '-ieq' }
            @{ Operator = '-ceq'; Body = "if (`$a -ceq 'x') { throw 'no' }"; Expected = $null }
            @{ Operator = '-cne'; Body = "if (`$a -cne 'x') { return `$true }"; Expected = $null }
        ) {
            $function = Get-TestFunctionAst -Text "function Test-Sample { $Body }"

            $case = @(Get-FunctionMutant -Function $function | Where-Object Kind -eq 'case')

            if ($Expected) { $case.Replacement | Should -Be @($Expected) }
            else { $case.Count | Should -Be 0 }
        }

        It 'skips the case mutant of a comparison with a caseless constant' {
            $function = Get-TestFunctionAst -Text "function Test-Sample { if (`$a -cne '42') { throw 'no' } }"

            @(Get-FunctionMutant -Function $function | Where-Object Kind -eq 'case').Count | Should -Be 0
        }

        It 'keeps the case mutant of a <Operator> pattern without letters' -ForEach @(
            @{ Operator = '-cnotmatch'; Pattern = '^(.)\1$' }
            @{ Operator = '-cnotlike'; Pattern = '[!-~]' }
        ) {
            $function = Get-TestFunctionAst -Text "function Test-Sample { if (`$a $Operator '$Pattern') { throw 'no' } }"

            @(Get-FunctionMutant -Function $function | Where-Object Kind -eq 'case').Count | Should -Be 1
        }

        It 'gives every mutant a unique ID' {
            $function = Get-TestFunctionAst -Text "function Test-Sample { if (`$a) { throw 'one' }; if (`$a) { throw 'two' } }"

            $ids = @(Get-FunctionMutant -Function $function).Id

            $ids | Should -Contain "Test-Sample: condition '`$a' -> `$false#1"
            $ids | Should -Contain "Test-Sample: condition '`$a' -> `$false#2"
            @($ids | Sort-Object -Unique).Count | Should -Be $ids.Count
        }

        It 'fails closed when a marked function has no mutable condition' {
            $repo = Initialize-TestRepository -Content "# security-check: sample-check`nfunction Test-Sample { 'no check' }"
            $marker = @(Get-SecurityCheckMarker -RepoPath $repo)

            { Get-SecurityCheckMutant -RepoPath $repo -Marker $marker } | Should -Throw '*has no mutable condition*'
        }

        It 'returns the mutated file text for each mutant' {
            $repo = Initialize-TestRepository -Content "# security-check: sample-check`nfunction Test-Sample { if (`$a) { throw 'no' } }"
            $marker = @(Get-SecurityCheckMarker -RepoPath $repo)

            $mutant = @(Get-SecurityCheckMutant -RepoPath $repo -Marker $marker | Where-Object Kind -eq 'condition')

            $mutant[0].Check | Should -BeExactly 'sample-check'
            $mutant[0].Text | Should -BeExactly "# security-check: sample-check`nfunction Test-Sample { if ((`$false)) { throw 'no' } }"
        }
    }

    Context 'configuration' {
        BeforeAll {
            $script:marker = @([pscustomobject]@{ Name = 'sample-check'; File = 'tools/Check.psm1'; Line = 2; Function = 'Test-Sample' })
            $script:exception = @{ Mutant = 'Sample: condition'; Reason = 'Equivalent.'; Issue = 'https://github.com/msucharda/devsecops-platform/issues/57' }
        }

        It 'accepts a marker configured exactly once with a complete exception' {
            { Assert-SecurityCheckConfiguration -Marker $marker -Configuration (Get-TestConfiguration -Exception @($exception)) } | Should -Not -Throw
        }

        It 'rejects <Case>' -ForEach @(
            @{ Case = 'a marker without configuration'; Name = @(); Message = '*must be configured exactly once*' }
            @{ Case = 'a configuration without marker'; Name = @('sample-check', 'other-check'); Message = '*other-check has no marker*' }
            @{ Case = 'a check configured twice'; Name = @('sample-check', 'sample-check'); Message = '*must be configured exactly once*' }
            @{ Case = 'a check name that differs in case'; Name = @('Sample-Check'); Message = '*Sample-Check has no marker*' }
        ) {
            { Assert-SecurityCheckConfiguration -Marker $marker -Configuration (Get-TestConfiguration -Name $Name) } | Should -Throw $Message
        }

        It 'rejects a check without tests' {
            $configuration = @{ Checks = @(@{ Name = 'sample-check'; Tests = @() }); Exceptions = @() }

            { Assert-SecurityCheckConfiguration -Marker $marker -Configuration $configuration } | Should -Throw '*has no tests*'
        }

        It 'rejects a test without <Key>' -ForEach @(@{ Key = 'Path' }, @{ Key = 'FullName' }) {
            $configuration = Get-TestConfiguration
            $configuration.Checks[0].Tests[0].Remove($Key)

            { Assert-SecurityCheckConfiguration -Marker $marker -Configuration $configuration } | Should -Throw '*test without Path and FullName*'
        }

        It 'rejects a marker used twice' {
            $twice = @($marker[0], [pscustomobject]@{ Name = 'sample-check'; File = 'tools/Other.psm1'; Line = 5; Function = 'Test-Other' })

            { Assert-SecurityCheckConfiguration -Marker $twice -Configuration (Get-TestConfiguration) } | Should -Throw '*marked more than once*'
        }

        It 'rejects an exception without <Key>' -ForEach @(@{ Key = 'Mutant' }, @{ Key = 'Reason' }, @{ Key = 'Issue' }) {
            $incomplete = @{} + $exception
            $incomplete[$Key] = ' '

            { Assert-SecurityCheckConfiguration -Marker $marker -Configuration (Get-TestConfiguration -Exception @($incomplete)) } | Should -Throw "*lacks $Key*"
        }

        It 'rejects an exception whose issue is not a GitHub issue or pull request URL: <Issue>' -ForEach @(
            @{ Issue = '#57' }
            @{ Issue = 'https://example.com/msucharda/devsecops-platform/issues/57' }
            @{ Issue = 'https://github.com/msucharda/devsecops-platform/issues/0' }
        ) {
            $invalid = @{} + $exception
            $invalid.Issue = $Issue

            { Assert-SecurityCheckConfiguration -Marker $marker -Configuration (Get-TestConfiguration -Exception @($invalid)) } | Should -Throw '*must link an issue or pull request URL*'
        }
    }

    Context 'exception selection' {
        BeforeAll {
            $script:Inventory = @(
                [pscustomobject]@{ Id = 'A: one#1'; Check = 'first' }
                [pscustomobject]@{ Id = 'B: two#1'; Check = 'second' }
            )
        }

        It 'keeps the exceptions of the selected check' {
            @(Select-MutationException -Exception @(@{ Mutant = 'A: one#1' }) -Inventory $script:Inventory -Check 'first').Count | Should -Be 1
        }

        It 'drops the exceptions of an unselected check' {
            @(Select-MutationException -Exception @(@{ Mutant = 'B: two#1' }) -Inventory $script:Inventory -Check 'first').Count | Should -Be 0
        }

        It 'keeps a stale exception so that it fails as unmatched' {
            $selected = @(Select-MutationException -Exception @(@{ Mutant = 'A: removed#1' }) -Inventory $script:Inventory -Check 'first')

            $selected.Count | Should -Be 1
            (Resolve-MutationResult -Result @(Get-TestResult -Id 'A: one#1') -Exception $selected).Problems -join ' ' | Should -Match 'matches no mutant'
        }

        It 'keeps an exception whose ID differs only in case' {
            @(Select-MutationException -Exception @(@{ Mutant = 'b: two#1' }) -Inventory $script:Inventory -Check 'first').Count | Should -Be 1
        }
    }

    Context 'results' {
        It 'classifies a worker result as <Expected> when <Case>' -ForEach @(
            @{ Case = 'a test failed'; Result = @{ Passed = 3; Failed = 1; Errors = 0 }; Expected = 'Killed' }
            @{ Case = 'all tests passed'; Result = @{ Passed = 3; Failed = 0; Errors = 0 }; Expected = 'Survived' }
            @{ Case = 'a test failed and a container failed'; Result = @{ Passed = 0; Failed = 1; Errors = 1 }; Expected = 'Error' }
            @{ Case = 'tests passed and a block failed'; Result = @{ Passed = 3; Failed = 0; Errors = 1 }; Expected = 'Error' }
            @{ Case = 'no test ran'; Result = @{ Passed = 0; Failed = 0; Errors = 0 }; Expected = 'Error' }
            @{ Case = 'the counters are missing'; Result = @{}; Expected = 'Error' }
            @{ Case = 'the worker wrote no result'; Result = $null; Expected = 'Error' }
        ) {
            $status, $null = Get-MutationJobStatus -Result $Result

            $status | Should -BeExactly $Expected
        }
        BeforeAll {
            $script:exception = @{ Mutant = 'Sample: condition'; Reason = 'Equivalent.'; Issue = 'https://github.com/msucharda/devsecops-platform/issues/57' }
        }

        It 'accepts killed mutants' {
            (Resolve-MutationResult -Result @(Get-TestResult)).Problems.Count | Should -Be 0
        }

        It 'marks an excepted survivor and accepts it' {
            $resolved = Resolve-MutationResult -Result @(Get-TestResult -Status Survived) -Exception @($exception)

            $resolved.Problems.Count | Should -Be 0
            $resolved.Results[0].Status | Should -BeExactly 'Excepted'
            $resolved.Results[0].Issue | Should -BeExactly $exception.Issue
        }

        It 'reports <Status> as a problem' -ForEach @(
            @{ Status = 'Survived'; Message = '*survived*' }
            @{ Status = 'Error'; Message = '*ended with Error*' }
            @{ Status = ''; Message = '*ended with*' }
        ) {
            $resolved = Resolve-MutationResult -Result @(Get-TestResult -Status $Status)

            $resolved.Problems | Should -HaveCount 1
            $resolved.Problems[0] | Should -BeLike $Message
        }

        It 'does not let an exception hide an error' {
            $resolved = Resolve-MutationResult -Result @(Get-TestResult -Status Error) -Exception @($exception)

            $resolved.Problems[0] | Should -BeLike '*ended with Error*'
        }

        It 'reports an exception that matches no mutant' {
            $resolved = Resolve-MutationResult -Result @(Get-TestResult -Id 'Other') -Exception @($exception)

            $resolved.Problems | Should -Contain "The mutation exception 'Sample: condition' matches no mutant. Remove it."
        }

        It 'reports an exception that matches only by case' {
            $resolved = Resolve-MutationResult -Result @(Get-TestResult -Id 'sample: condition' -Status Survived) -Exception @($exception)

            $resolved.Problems | Should -Contain "The mutation exception 'Sample: condition' matches no mutant. Remove it."
            $resolved.Results[0].Status | Should -BeExactly 'Survived'
            $resolved.Problems | Should -Contain 'tools/Check.psm1:3: sample: condition survived.'
        }

        It 'reports a stale exception of a killed mutant' {
            $resolved = Resolve-MutationResult -Result @(Get-TestResult) -Exception @($exception)

            $resolved.Problems | Should -Contain "The mutation exception 'Sample: condition' is stale: the mutant is killed. Remove it."
        }
    }
}
