Set-StrictMode -Version Latest

$script:MarkerPattern = '^\s*#\s*security-check:\s*(?<name>[A-Za-z0-9][A-Za-z0-9-]*)\s*$'

# Case-insensitive variants of the positive operators accept more values; those of the negated operators accept fewer.
$script:CaseInsensitive = @{
    Ceq = @{ Text = '-ieq'; Positive = $true }
    Cmatch = @{ Text = '-imatch'; Positive = $true }
    Clike = @{ Text = '-ilike'; Positive = $true }
    Ccontains = @{ Text = '-icontains'; Positive = $true }
    Cin = @{ Text = '-iin'; Positive = $true }
    Cne = @{ Text = '-ine'; Positive = $false }
    Cnotmatch = @{ Text = '-inotmatch'; Positive = $false }
    Cnotlike = @{ Text = '-inotlike'; Positive = $false }
    Cnotcontains = @{ Text = '-inotcontains'; Positive = $false }
    Cnotin = @{ Text = '-inotin'; Positive = $false }
}

function Get-SecurityCheckMarker {
    <#
    .SYNOPSIS
    Finds the functions marked with '# security-check: <name>' on the line before the function.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $RepoPath,
        [string[]] $Include = @('tools')
    )

    foreach ($folder in $Include) {
        $root = Join-Path $RepoPath $folder
        $files = Get-ChildItem -LiteralPath $root -Recurse -File -Include '*.ps1', '*.psm1' |
            Where-Object { $_.FullName -notmatch '[\\/]tests[\\/]' } | Sort-Object FullName
        foreach ($file in $files) {
            $relative = [IO.Path]::GetRelativePath($RepoPath, $file.FullName).Replace('\', '/')
            $tokens = $null
            $errors = $null
            $ast = [System.Management.Automation.Language.Parser]::ParseFile($file.FullName, [ref] $tokens, [ref] $errors)
            $functions = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] }, $true))
            foreach ($token in @($tokens | Where-Object { $_.Kind -eq 'Comment' })) {
                $match = [regex]::Match($token.Text, $script:MarkerPattern)
                if (-not $match.Success) {
                    if ($token.Text -match '^#\s*security-check\b') {
                        throw "${relative}:$($token.Extent.StartLineNumber): malformed security-check marker '$($token.Text)'."
                    }
                    continue
                }
                $function = @($functions | Where-Object { $_.Extent.StartLineNumber -eq $token.Extent.StartLineNumber + 1 })
                if ($function.Count -ne 1) {
                    throw "${relative}:$($token.Extent.StartLineNumber): the security-check marker must be on the line directly before a function."
                }
                [pscustomobject]@{
                    Name = $match.Groups['name'].Value
                    File = $relative
                    Line = $function[0].Extent.StartLineNumber
                    Function = $function[0].Name
                }
            }
        }
    }
}

function ConvertTo-MutantRecord {
    param($Extent, [string] $Replacement, [string] $Kind, [string] $Description)

    [pscustomobject]@{
        Start = $Extent.StartOffset
        End = $Extent.EndOffset
        Line = $Extent.StartLineNumber
        Original = $Extent.Text
        Replacement = $Replacement
        Kind = $Kind
        Description = $Description -replace '\s+', ' '
    }
}

function Get-ChainOperand {
    param($Expression, [System.Management.Automation.Language.TokenKind] $Operator)

    if ($Expression -is [System.Management.Automation.Language.BinaryExpressionAst] -and $Expression.Operator -eq $Operator) {
        Get-ChainOperand -Expression $Expression.Left -Operator $Operator
        Get-ChainOperand -Expression $Expression.Right -Operator $Operator
        return
    }
    $Expression
}

function Get-InnerExpression {
    param($Node)

    while ($true) {
        if ($Node -is [System.Management.Automation.Language.CommandExpressionAst]) { $Node = $Node.Expression; continue }
        $pipeline = if ($Node -is [System.Management.Automation.Language.ParenExpressionAst]) { $Node.Pipeline }
        elseif ($Node -is [System.Management.Automation.Language.PipelineAst]) { $Node }
        else { return $Node }
        if ($pipeline -isnot [System.Management.Automation.Language.PipelineAst] -or $pipeline.PipelineElements.Count -ne 1 -or
            $pipeline.PipelineElements[0] -isnot [System.Management.Automation.Language.CommandExpressionAst]) {
            return $Node
        }
        $Node = $pipeline.PipelineElements[0].Expression
    }
}

function Get-ExpressionMutant {
    <#
    .SYNOPSIS
    Returns the mutants that make a condition pass more often. Allow means a true value grants access; Deny means a true value refuses it.
    #>
    param($Expression, [ValidateSet('Allow', 'Deny')][string] $Polarity)

    $node = Get-InnerExpression -Node $Expression
    $flip = if ($Polarity -eq 'Allow') { 'Deny' } else { 'Allow' }
    if ($node -is [System.Management.Automation.Language.UnaryExpressionAst] -and
        $node.TokenKind -in @([System.Management.Automation.Language.TokenKind]::Not, [System.Management.Automation.Language.TokenKind]::Exclaim)) {
        Get-ExpressionMutant -Expression $node.Child -Polarity $flip
        return
    }
    if ($node -is [System.Management.Automation.Language.BinaryExpressionAst]) {
        $operator = $node.Operator
        if ($operator -in @([System.Management.Automation.Language.TokenKind]::And, [System.Management.Automation.Language.TokenKind]::Or)) {
            $weakened = if ($operator -eq [System.Management.Automation.Language.TokenKind]::And) { 'Allow' } else { 'Deny' }
            foreach ($operand in @(Get-ChainOperand -Expression $node -Operator $operator)) {
                if ($Polarity -eq $weakened) {
                    $value = if ($Polarity -eq 'Allow') { '$true' } else { '$false' }
                    ConvertTo-MutantRecord -Extent $operand.Extent -Replacement "($value)" -Kind 'operand' -Description "operand '$($operand.Extent.Text)' -> $value"
                }
                Get-ExpressionMutant -Expression $operand -Polarity $Polarity
            }
            return
        }
        $variant = $script:CaseInsensitive[[string] $operator]
        # Regex and wildcard patterns without letters can still match letters (backreferences, ranges), so only literal
        # comparisons with a letterless constant are equivalent under the case-insensitive operator.
        $literal = [string] $operator -notmatch 'match|like'
        $caseless = $literal -and @($node.Left, $node.Right | Where-Object {
                $_ -is [System.Management.Automation.Language.StringConstantExpressionAst] -and $_.Value -ceq $_.Value.ToUpperInvariant() -and $_.Value -ceq $_.Value.ToLowerInvariant()
            }).Count -gt 0
        # A comparison with a constant that has no letters ignores case anyway; its case-insensitive mutant is equivalent.
        if ($variant -and -not $caseless -and ($variant.Positive -eq ($Polarity -eq 'Allow'))) {
            $operatorExtent = $node.ErrorPosition
            ConvertTo-MutantRecord -Extent $operatorExtent -Replacement $variant.Text -Kind 'case' -Description "operator '$($operatorExtent.Text)' -> $($variant.Text) in '$($node.Extent.Text)'"
        }
    }
}

function Test-BooleanReturn {
    # True when a return statement returns the literal $Value, also in parentheses such as 'return ($false)'.
    param($Node, [ValidateSet('$true', '$false')][string] $Value)

    if ($Node -isnot [System.Management.Automation.Language.ReturnStatementAst] -or -not $Node.Pipeline) { return $false }
    $inner = Get-InnerExpression -Node $Node.Pipeline
    return $inner -is [System.Management.Automation.Language.VariableExpressionAst] -and $inner.Extent.Text -eq $Value
}

function Get-ClausePolarity {
    param($Body)

    $denies = $Body.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ThrowStatementAst] -or
            (Test-BooleanReturn -Node $node -Value '$false') -or
            ($node -is [System.Management.Automation.Language.CommandAst] -and $node.GetCommandName() -in @('Exit-SetupStage', 'Write-Error'))
        }, $false)
    if (@($denies).Count -gt 0) { return 'Deny' }
    $allows = $Body.FindAll({
            param($node)
            $node -is [System.Management.Automation.Language.ContinueStatementAst] -or
            (Test-BooleanReturn -Node $node -Value '$true')
        }, $false)
    if (@($allows).Count -gt 0) { return 'Allow' }
    return $null
}

function Get-GuardVariable {
    # A guard on a bare variable checks the logical value assigned to it; returns the variable with the polarity of that value.
    param($Expression, [ValidateSet('Allow', 'Deny')][string] $Polarity)

    $node = Get-InnerExpression -Node $Expression
    if ($node -is [System.Management.Automation.Language.UnaryExpressionAst] -and
        $node.TokenKind -in @([System.Management.Automation.Language.TokenKind]::Not, [System.Management.Automation.Language.TokenKind]::Exclaim)) {
        $flip = if ($Polarity -eq 'Allow') { 'Deny' } else { 'Allow' }
        Get-GuardVariable -Expression $node.Child -Polarity $flip
        return
    }
    if ($node -is [System.Management.Automation.Language.VariableExpressionAst]) {
        [pscustomobject]@{ Name = $node.VariablePath.UserPath; Polarity = $Polarity }
    }
}

function Get-FunctionMutant {
    <#
    .SYNOPSIS
    Generates the weakening mutants of one function: guard conditions, boolean results, logical operands and case-sensitive comparisons.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param([Parameter(Mandatory)][System.Management.Automation.Language.FunctionDefinitionAst] $Function)

    $mutants = [System.Collections.Generic.List[object]]::new()
    $guardVariables = [System.Collections.Generic.List[object]]::new()
    $ifStatements = $Function.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.IfStatementAst] }, $true)
    foreach ($statement in $ifStatements) {
        foreach ($clause in $statement.Clauses) {
            $polarity = Get-ClausePolarity -Body $clause.Item2
            if (-not $polarity) { continue }
            $value = if ($polarity -eq 'Deny') { '$false' } else { '$true' }
            $mutants.Add((ConvertTo-MutantRecord -Extent $clause.Item1.Extent -Replacement "($value)" -Kind 'condition' -Description "condition '$($clause.Item1.Extent.Text)' -> $value"))
            $mutants.Add((ConvertTo-MutantRecord -Extent $clause.Item1.Extent -Replacement "(-not ($($clause.Item1.Extent.Text)))" -Kind 'negation' -Description "condition '$($clause.Item1.Extent.Text)' negated"))
            foreach ($mutant in @(Get-ExpressionMutant -Expression $clause.Item1 -Polarity $polarity)) { $mutants.Add($mutant) }
            foreach ($variable in @(Get-GuardVariable -Expression $clause.Item1 -Polarity $polarity)) { $guardVariables.Add($variable) }
        }
    }
    foreach ($variable in $guardVariables) {
        $assignments = $Function.Body.FindAll({
                param($node)
                $node -is [System.Management.Automation.Language.AssignmentStatementAst] -and
                $node.Operator -eq [System.Management.Automation.Language.TokenKind]::Equals -and
                $node.Left -is [System.Management.Automation.Language.VariableExpressionAst] -and
                $node.Left.VariablePath.UserPath -eq $variable.Name
            }, $true)
        foreach ($assignment in $assignments) {
            foreach ($mutant in @(Get-ExpressionMutant -Expression $assignment.Right -Polarity $variable.Polarity)) { $mutants.Add($mutant) }
        }
    }
    $returns = $Function.Body.FindAll({ param($node) $node -is [System.Management.Automation.Language.ReturnStatementAst] -and $node.Pipeline }, $true)
    foreach ($statement in $returns) {
        $pipeline = $statement.Pipeline
        if ((Test-BooleanReturn -Node $statement -Value '$true') -or (Test-BooleanReturn -Node $statement -Value '$false')) { continue }
        $expression = Get-InnerExpression -Node $pipeline
        $logical = $expression -is [System.Management.Automation.Language.BinaryExpressionAst] -or
            ($expression -is [System.Management.Automation.Language.UnaryExpressionAst] -and
            $expression.TokenKind -in @([System.Management.Automation.Language.TokenKind]::Not, [System.Management.Automation.Language.TokenKind]::Exclaim))
        if (-not $logical) { continue }
        $mutants.Add((ConvertTo-MutantRecord -Extent $pipeline.Extent -Replacement '$true' -Kind 'return' -Description "return '$($pipeline.Extent.Text)' -> `$true"))
        $mutants.Add((ConvertTo-MutantRecord -Extent $pipeline.Extent -Replacement "(-not ($($pipeline.Extent.Text)))" -Kind 'negation' -Description "return '$($pipeline.Extent.Text)' negated"))
        foreach ($mutant in @(Get-ExpressionMutant -Expression $expression -Polarity Allow)) { $mutants.Add($mutant) }
    }

    $seen = [System.Collections.Generic.HashSet[string]]::new()
    $ordinal = @{}
    foreach ($mutant in @($mutants | Sort-Object Start, End, Replacement)) {
        if (-not $seen.Add("$($mutant.Start):$($mutant.End):$($mutant.Replacement)")) { continue }
        $ordinal[$mutant.Description] = 1 + [int] $ordinal[$mutant.Description]
        $mutant | Add-Member -NotePropertyName Id -NotePropertyValue "$($Function.Name): $($mutant.Description)#$($ordinal[$mutant.Description])"
        $mutant
    }
}

function Get-SecurityCheckMutant {
    <#
    .SYNOPSIS
    Generates the mutants of every marked function and verifies that each mutated file still parses.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][string] $RepoPath,
        [Parameter(Mandatory)][object[]] $Marker
    )

    $ids = [System.Collections.Generic.Dictionary[string, string]]::new([StringComparer]::OrdinalIgnoreCase)
    foreach ($check in $Marker) {
        $path = Join-Path $RepoPath $check.File
        $text = [IO.File]::ReadAllText($path)
        $ast = [System.Management.Automation.Language.Parser]::ParseInput($text, $path, [ref] $null, [ref] $null)
        $function = @($ast.FindAll({ param($node) $node -is [System.Management.Automation.Language.FunctionDefinitionAst] -and $node.Extent.StartLineNumber -eq $check.Line }, $true))
        if ($function.Count -ne 1) { throw "$($check.File):$($check.Line): the function of the security check $($check.Name) was not found." }
        $mutants = @(Get-FunctionMutant -Function $function[0])
        if ($mutants.Count -eq 0) { throw "$($check.File):$($check.Line): the security check $($check.Name) has no mutable condition." }
        foreach ($mutant in $mutants) {
            $mutated = $text.Substring(0, $mutant.Start) + $mutant.Replacement + $text.Substring($mutant.End)
            $errors = $null
            $null = [System.Management.Automation.Language.Parser]::ParseInput($mutated, [ref] $null, [ref] $errors)
            if (@($errors).Count -gt 0) { throw "$($check.File):$($mutant.Line): the mutant '$($mutant.Description)' does not parse: $($errors[0].Message)" }
            # Results and exceptions are keyed by Id, so a collision could let a killed mutant hide a survivor.
            if ($ids.ContainsKey($mutant.Id)) { throw "$($check.File):$($mutant.Line): the mutant ID '$($mutant.Id)' is also generated in $($ids[$mutant.Id]). Rename one of the marked functions." }
            $ids[$mutant.Id] = "$($check.File):$($mutant.Line)"
            $mutant | Add-Member -NotePropertyName Check -NotePropertyValue $check.Name
            $mutant | Add-Member -NotePropertyName File -NotePropertyValue $check.File
            $mutant | Add-Member -NotePropertyName Text -NotePropertyValue $mutated
            $mutant
        }
    }
}

function Assert-SecurityCheckConfiguration {
    <#
    .SYNOPSIS
    Fails closed when markers and configured checks differ or when an exception is incomplete.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][object[]] $Marker,
        [Parameter(Mandatory)][System.Collections.IDictionary] $Configuration
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $checks = @($Configuration['Checks'])
    $exceptions = @($Configuration['Exceptions'])
    foreach ($group in @($Marker | Group-Object Name | Where-Object Count -gt 1)) {
        $problems.Add("The security check $($group.Name) is marked more than once.")
    }
    foreach ($check in $checks) {
        if ($check -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace($check['Name'])) { $problems.Add('A configured security check has no Name.'); continue }
        $tests = @($check['Tests'])
        if ($tests.Count -eq 0) { $problems.Add("The security check $($check['Name']) has no tests.") }
        foreach ($test in $tests) {
            $fullNames = @(if ($test -is [System.Collections.IDictionary]) { $test['FullName'] | Where-Object { -not [string]::IsNullOrWhiteSpace($_) } })
            if ($test -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace($test['Path']) -or $fullNames.Count -eq 0) {
                $problems.Add("The security check $($check['Name']) has a test without Path and FullName.")
            }
        }
        if (@($Marker | Where-Object Name -ceq $check['Name']).Count -eq 0) { $problems.Add("The security check $($check['Name']) has no marker in the code.") }
    }
    foreach ($item in $Marker) {
        if (@($checks | Where-Object { $_ -is [System.Collections.IDictionary] -and $_['Name'] -ceq $item.Name }).Count -ne 1) {
            $problems.Add("$($item.File):$($item.Line): the marked security check $($item.Name) must be configured exactly once.")
        }
    }
    foreach ($exception in $exceptions) {
        $missing = @(foreach ($key in @('Mutant', 'Reason', 'Issue')) { if ($exception -isnot [System.Collections.IDictionary] -or [string]::IsNullOrWhiteSpace($exception[$key])) { $key } })
        if ($missing.Count -gt 0) { $problems.Add("A mutation exception lacks $($missing -join ', ').") }
        elseif ($exception['Issue'] -notmatch '^https://github\.com/[^/]+/[^/]+/(issues|pull)/[1-9][0-9]*$') {
            $problems.Add("The mutation exception '$($exception['Mutant'])' must link an issue or pull request URL.")
        }
    }
    if ($problems.Count -gt 0) { throw ($problems -join [Environment]::NewLine) }
}

function Get-MutationJobStatus {
    <#
    .SYNOPSIS
    Classifies one worker result. Errors win over failures; a missing result or a run without tests is an error.
    #>
    [CmdletBinding()]
    param([AllowNull()][System.Collections.IDictionary] $Result)

    if ($null -eq $Result) { return 'Error', 'The worker did not finish the job before the timeout.' }
    # An unclean run is not evidence that a test detected the mutant, even when another test failed.
    if ([int] $Result['Errors'] -gt 0) { return 'Error', "The tests did not run cleanly. $(@($Result['Failures']) -join '; ')" }
    if ([int] $Result['Failed'] -gt 0) { return 'Killed', "Failed: $(@($Result['Failures']) -join '; ')" }
    if ([int] $Result['Passed'] -le 0) { return 'Error', 'No test ran.' }
    return 'Survived', "$($Result['Passed']) tests passed."
}

function Select-MutationException {
    <#
    .SYNOPSIS
    Keeps the exceptions of the selected checks and every exception that matches no generated mutant, so stale exceptions still fail.
    #>
    [CmdletBinding()]
    [OutputType([hashtable])]
    param(
        [AllowEmptyCollection()][object[]] $Exception = @(),
        [AllowEmptyCollection()][object[]] $Inventory = @(),
        [Parameter(Mandatory)][string[]] $Check
    )

    foreach ($item in $Exception) {
        $owner = @($Inventory | Where-Object { $_.Id -ceq $item['Mutant'] })
        if ($owner.Count -eq 0 -or $owner[0].Check -cin $Check) { $item }
    }
}

function Resolve-MutationResult {
    <#
    .SYNOPSIS
    Applies the exceptions to the mutant results. A survivor without an exception, an error and a stale exception fail the run.
    #>
    [CmdletBinding()]
    [OutputType([pscustomobject])]
    param(
        [Parameter(Mandatory)][AllowEmptyCollection()][object[]] $Result,
        [AllowEmptyCollection()][object[]] $Exception = @()
    )

    $problems = [System.Collections.Generic.List[string]]::new()
    $excepted = [System.Collections.Generic.Dictionary[string, object]]::new([StringComparer]::Ordinal)
    foreach ($item in $Exception) { $excepted[[string] $item['Mutant']] = $item }
    foreach ($item in $Result) {
        $exceptionItem = $null
        $null = $excepted.TryGetValue([string] $item.Id, [ref] $exceptionItem)
        if ($item.Status -eq 'Survived' -and $exceptionItem) {
            $item.Status = 'Excepted'
            $item | Add-Member -NotePropertyName Issue -NotePropertyValue $exceptionItem['Issue'] -Force
        }
        elseif ($item.Status -eq 'Survived') { $problems.Add("$($item.File):$($item.Line): $($item.Id) survived.") }
        elseif ($item.Status -ne 'Killed') { $problems.Add("$($item.File):$($item.Line): $($item.Id) ended with $($item.Status). $($item.Detail)") }
    }
    foreach ($id in $excepted.Keys) {
        $match = @($Result | Where-Object Id -ceq $id)
        if ($match.Count -eq 0) { $problems.Add("The mutation exception '$id' matches no mutant. Remove it.") }
        elseif ($match[0].Status -eq 'Killed') { $problems.Add("The mutation exception '$id' is stale: the mutant is killed. Remove it.") }
    }
    [pscustomobject]@{ Results = $Result; Problems = $problems.ToArray() }
}

Export-ModuleMember -Function Get-SecurityCheckMarker, Get-FunctionMutant, Get-SecurityCheckMutant, Assert-SecurityCheckConfiguration, Get-MutationJobStatus, Select-MutationException, Resolve-MutationResult
