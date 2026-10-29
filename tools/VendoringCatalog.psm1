Set-StrictMode -Version Latest

# security-check: vendoring-upstream-commit
function Assert-VendoringUpstreamCommit {
    param([AllowNull()][object] $Commit, [string] $Upstream)

    if ($Commit -isnot [string] -or $Commit -cnotmatch '\A[a-f0-9]{40}\z') {
        throw "Catalog upstreamCommit for '$Upstream' must be a full lowercase commit SHA from its approved receipt."
    }
}

# security-check: vendoring-catalog-snapshot
function Assert-VendoringCatalog {
    param([AllowNull()][object] $Catalog, [string] $ActionsOrganization)

    if ($Catalog -isnot [Collections.IDictionary] -or $Catalog['version'] -isnot [long] -or
        $Catalog['version'] -ne 2 -or $Catalog['actions'] -isnot [Collections.IDictionary]) {
        throw 'Action catalog must declare version 2 and an actions mapping; migrate upstreamCommit from approved receipts.'
    }
    foreach ($entry in $Catalog['actions'].PSBase.Keys) {
        $copy = $Catalog['actions'][$entry]
        if ($entry -cnotmatch '\A[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?/[a-z0-9_.-]{1,100}\z' -or
            $copy -isnot [Collections.IDictionary] -or
            $copy['repository'] -isnot [string] -or
            $copy['repository'] -cne "$ActionsOrganization/$($entry.Replace('/', '-'))" -or
            $copy['sha'] -isnot [string] -or
            ($copy.Contains('tag') -and $copy['tag'] -isnot [string]) -or
            $copy['sha'] -cnotmatch '\A[a-f0-9]{40}\z') {
            throw "Invalid catalog entry '$entry': expected $ActionsOrganization/owner-repo and a full commit SHA."
        }
        Assert-VendoringUpstreamCommit -Commit $copy['upstreamCommit'] -Upstream $entry
    }
}

function ConvertTo-CanonicalVendoringCatalog {
    param([AllowNull()][object] $Value)

    if ($Value -is [Collections.IDictionary]) {
        $ordered = [ordered]@{}
        $keys = [string[]]@($Value.PSBase.Keys)
        [Array]::Sort($keys, [StringComparer]::Ordinal)
        foreach ($key in $keys) { $ordered[$key] = ConvertTo-CanonicalVendoringCatalog -Value $Value[$key] }
        return $ordered
    }
    if ($Value -is [array]) {
        return ,@($Value | ForEach-Object { ConvertTo-CanonicalVendoringCatalog -Value $_ })
    }
    return $Value
}

Export-ModuleMember -Function Assert-VendoringCatalog, ConvertTo-CanonicalVendoringCatalog
