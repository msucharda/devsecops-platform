Set-StrictMode -Version Latest

$script:FixtureRoot = Join-Path $PSScriptRoot 'fixtures/microsoft-api'

function Get-MicrosoftApiFixtureContract {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][ValidatePattern('^[a-z0-9-]+/[a-z0-9.-]+$')][string] $Name)

    $path = Join-Path $script:FixtureRoot "$Name.json"
    if (-not (Test-Path -LiteralPath $path -PathType Leaf)) {
        throw "Microsoft API fixture '$Name' does not exist in '$script:FixtureRoot'."
    }
    return Get-Content -LiteralPath $path -Raw | ConvertFrom-Json -AsHashtable -Depth 100
}

function Get-MicrosoftApiFixtureNode {
    [CmdletBinding()]
    param(
        [AllowNull()][object] $Body,
        [AllowEmptyString()][string] $Path
    )

    $nodes = @(, $Body)
    if ($Path) {
        foreach ($segment in $Path.Split('.')) {
            $nodes = @(foreach ($node in $nodes) {
                if ($segment -ceq '[]') { $node }
                elseif ($node -is [System.Collections.IDictionary] -and $node.Contains($segment)) { , $node[$segment] }
            })
        }
    }
    return $nodes
}

function Get-MicrosoftApiFixture {
    <#
    .SYNOPSIS
    Returns a fresh copy of a documented Microsoft Graph or Azure Resource Manager response body.
    .PARAMETER Set
    Replaces documented fields by dotted path, for example 'value.0.principalId'.
    A path that the documented fixture does not contain is refused.
    #>
    [CmdletBinding()]
    param(
        [Parameter(Mandatory)][string] $Name,
        [System.Collections.IDictionary] $Set = @{}
    )

    $body = (Get-MicrosoftApiFixtureContract -Name $Name)['body']
    foreach ($path in $Set.Keys) {
        # Graph names such as '@odata.nextLink' contain dots, so a whole top-level key wins over a dotted path.
        [string[]] $segments = if ($body -is [System.Collections.IDictionary] -and $body.Contains($path)) { $path } else { $path.Split('.') }
        $parent = $body
        for ($index = 0; $index -lt $segments.Count; $index++) {
            $segment = $segments[$index]
            $isList = $parent -is [System.Collections.IList] -and $segment -match '^[0-9]+$' -and [int] $segment -lt $parent.Count
            $isMap = $parent -is [System.Collections.IDictionary] -and $parent.Contains($segment)
            if (-not ($isList -or $isMap)) {
                throw "Path '$path' is not part of the documented fixture '$Name'. Extend the fixture from the documented schema instead."
            }
            $key = if ($isList) { [int] $segment } else { $segment }
            if ($index -eq $segments.Count - 1) { $parent[$key] = $Set[$path] }
            else { $parent = $parent[$key] }
        }
    }
    return , $body
}

Export-ModuleMember -Function Get-MicrosoftApiFixture, Get-MicrosoftApiFixtureContract, Get-MicrosoftApiFixtureNode
