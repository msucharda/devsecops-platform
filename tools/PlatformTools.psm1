#Requires -Version 7.4
Set-StrictMode -Version Latest
Import-Module powershell-yaml -RequiredVersion 0.4.12

function Get-PlatformYaml {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $Path)

    try {
        $documents = @(ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $Path -Raw -ErrorAction Stop) -AllDocuments -ErrorAction Stop)
    }
    catch {
        throw "Invalid YAML '$Path': $($_.Exception.Message)"
    }
    if ($documents.Count -ne 1 -or $documents[0] -isnot [System.Collections.IDictionary]) {
        throw "Expected one YAML mapping in '$Path'."
    }
    return $documents[0]
}

function Get-PlatformModuleGraph {
    [CmdletBinding()]
    [OutputType([System.Collections.IDictionary])]
    param([Parameter(Mandatory)][string] $ModulesPath)

    $modules = [ordered]@{}
    $directories = @(Get-ChildItem -LiteralPath $ModulesPath -Directory -ErrorAction Stop)
    [string[]] $names = @($directories | ForEach-Object { $_.Name })
    [System.Array]::Sort($names, [System.StringComparer]::Ordinal)
    foreach ($name in $names) {
        $manifestPath = Join-Path $ModulesPath "$name/module.yaml"
        if (-not (Test-Path -LiteralPath $manifestPath -PathType Leaf)) {
            continue
        }
        $manifest = Get-PlatformYaml -Path $manifestPath
        try {
            $valid = Test-Json -Json (ConvertTo-Json -InputObject $manifest -Depth 100 -Compress) `
                -SchemaFile (Join-Path $PSScriptRoot '../schemas/module.schema.json') -ErrorAction Stop
        }
        catch {
            throw "Invalid module manifest '$manifestPath': $($_.Exception.Message)"
        }
        if (-not $valid) {
            throw "Invalid module manifest '$manifestPath'."
        }
        if ($modules.Contains($manifest.name)) {
            throw "Duplicate module name '$($manifest.name)'."
        }
        if ($manifest.name -cne $name) {
            throw "Module '$($manifest.name)' must match directory '$name' in '$manifestPath'."
        }
        $manualStepIds = [System.Collections.Generic.HashSet[string]]::new([System.StringComparer]::Ordinal)
        foreach ($step in $manifest.manualSteps) {
            if (-not $manualStepIds.Add($step.id)) {
                throw "Module '$name' has duplicate manual step '$($step.id)'."
            }
        }
        [string[]] $prerequisites = @($manifest.prerequisites)
        [System.Array]::Sort($prerequisites, [System.StringComparer]::Ordinal)
        $manifest.prerequisites = $prerequisites
        $modules.Add($manifest.name, $manifest)
    }

    foreach ($name in $modules.PSBase.Keys) {
        foreach ($prerequisite in $modules[$name].prerequisites) {
            if (-not $modules.Contains($prerequisite)) {
                throw "Module '$name' requires missing prerequisite '$prerequisite'."
            }
        }
    }

    $visited = @{}
    $path = [System.Collections.Generic.List[string]]::new()
    $visit = {
        param([string] $Name)
        if ($path.Contains($Name)) {
            $cycle = @($path.GetRange($path.IndexOf($Name), $path.Count - $path.IndexOf($Name))) + $Name
            throw "Prerequisite cycle: $($cycle -join ' -> ')."
        }
        if ($visited.ContainsKey($Name)) {
            return
        }
        $path.Add($Name)
        foreach ($prerequisite in $modules[$Name].prerequisites) {
            & $visit $prerequisite
        }
        $path.RemoveAt($path.Count - 1)
        $visited[$Name] = $true
    }
    foreach ($name in $modules.PSBase.Keys) {
        & $visit $name
    }
    return $modules
}

Export-ModuleMember -Function Get-PlatformYaml, Get-PlatformModuleGraph
