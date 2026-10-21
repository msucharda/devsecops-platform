BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    # The stub of Invoke-GitHubBootstrap.ps1 lives in GitHubBootstrap.Tests.ps1. The harness reuses its
    # BeforeAll and BeforeEach blocks instead of a copy, so stub changes for new API calls apply here too.
    $stubFile = Join-Path $PSScriptRoot 'GitHubBootstrap.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlocks = @{}
    foreach ($command in $stubAst.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -cin @('BeforeAll', 'BeforeEach', 'AfterEach') -and -not $stubBlocks.ContainsKey($name) -and
            $command.CommandElements.Count -eq 2 -and $command.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
            $stubBlocks[$name] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
    }
    foreach ($name in @('BeforeAll', 'BeforeEach', 'AfterEach')) {
        if (-not $stubBlocks.ContainsKey($name)) { throw "$stubFile has no $name block for the bootstrap stub." }
    }
    . $stubBlocks.BeforeAll

    function Copy-TestValue {
        param([AllowNull()] $Value)
        if ($Value -is [System.Collections.IDictionary]) {
            $copy = @{}
            foreach ($key in $Value.Keys) { $copy[$key] = Copy-TestValue $Value[$key] }
            return $copy
        }
        if ($Value -is [System.Collections.IList]) { return , @(foreach ($item in $Value) { Copy-TestValue $item }) }
        return $Value
    }
}

Describe 'GitHub bootstrap interruption harness' -Tag 'Interruption' {
    BeforeEach {
        . $stubBlocks.BeforeEach
        # The workflow check costs about one second per run and has its own tests. The harness tests recovery only.
        Set-Content -LiteralPath (Join-Path $release 'tools/Generate-DeploymentWorkflow.ps1') -Value 'param($ModulesPath, $OutputPath, [switch] $Check)'
        $plan = Get-InterruptionPlan
        $stubTransport = $cloudTransport
        $initialCloud = Copy-TestValue $cloud
        # Documented conflict responses of create operations; the stub itself overwrites existing objects.
        # https://docs.github.com/enterprise-cloud@latest/rest/repos/repos#create-an-organization-repository (422)
        # https://docs.github.com/enterprise-cloud@latest/rest/teams/teams#create-a-team (422)
        # https://docs.github.com/enterprise-cloud@latest/rest/git/refs#create-a-reference (422)
        # https://docs.github.com/enterprise-cloud@latest/rest/repos/rules#create-a-repository-ruleset (422)
        # https://docs.github.com/enterprise-cloud@latest/rest/deployments/branch-policies#create-a-deployment-branch-policy (303)
        $conflictOf = {
            param([string] $Path, [hashtable] $Data)
            $unprocessable = { param($Message) [pscustomobject]@{ StatusCode = 422; Content = (@{ message = $Message; status = '422' } | ConvertTo-Json -Compress) } }
            if ($Path -cmatch '^/orgs/([^/]+)/repos$' -and $cloud.resources.ContainsKey("/repos/$($Matches[1])/$($Data.name)")) {
                return & $unprocessable 'Repository creation failed.'
            }
            if ($Path -cmatch '^/orgs/([^/]+)/teams$' -and $cloud.resources.ContainsKey("/orgs/$($Matches[1])/teams/$($Data.name)")) {
                return & $unprocessable 'Validation Failed'
            }
            if ($Path -like '*/git/refs' -and $cloud.resources.ContainsKey("$($Path.Substring(0, $Path.Length - 1))/$($Data.ref.Substring(5))")) {
                return & $unprocessable 'Reference already exists'
            }
            if ($Path -like '*/rulesets' -and @($cloud.resources.Keys | Where-Object { $_ -like "$Path/*" -and $cloud.resources[$_].name -ceq $Data.name }).Count) {
                return & $unprocessable 'Validation Failed'
            }
            if ($Path -like '*/deployment-branch-policies' -and @($cloud.branchRules[$Path] | Where-Object { $_ -and $_.name -ceq $Data.name }).Count) {
                return [pscustomobject]@{ StatusCode = 303; Content = '' }
            }
        }
        Mock Invoke-WebRequest {
            param([uri] $Uri, [string] $Body, [string] $Method = 'GET', [hashtable] $Headers)
            $call = @{ Uri = $Uri; Body = $Body; Method = $Method; Headers = $Headers }
            $path = $Uri.AbsolutePath
            $data = if ($Body) { ConvertFrom-Json -InputObject $Body -AsHashtable } else { @{} }
            if ($Method -eq 'GET' -and $path -like '*/contents/*') {
                # The shared stub serves contents from the last created tree on any ref. GitHub serves the tree of the
                # commit the ref points to, so an interrupted publication must not expose contents on main.
                $ref = [Web.HttpUtility]::ParseQueryString($Uri.Query)['ref']
                $main = $cloud.resources['/repos/demo-a1b2c3-platform/instance/git/ref/heads/main']
                $published = if ($ref -ceq 'main') { $main -and $main.object.sha -ceq 'commit-sha' } else { $ref -ceq 'commit-sha' }
                if (-not ($cloud.commit -and $published)) { return [pscustomobject]@{ StatusCode = 404; Content = '{"message":"Not Found"}' } }
            }
            if ($Method -eq 'GET' -or ($path -eq '/graphql' -and $data.query -notlike 'mutation*')) { return & $stubTransport @call }
            # Variables and workflow dispatches document no conflict response; a repeated creation is a duplicate.
            $identity = if ($Method -eq 'POST' -and $path -like '*/variables') { "variable $path/$($data.name)" }
            elseif ($Method -eq 'POST' -and $path -like '*/dispatches') { "dispatch $path" }
            else { '' }
            Invoke-InterruptionStep -Plan $plan -Request "$Method $path" -Identity $identity -Apply {
                $conflict = & $conflictOf $path $data
                if ($conflict) { return $conflict }
                & $stubTransport @call
            } -Interrupt {
                [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption."}' }
            }
        }
        $initialInventory = $null
        $reset = {
            $cloud.Clear()
            foreach ($key in $initialCloud.Keys) { $cloud[$key] = Copy-TestValue $initialCloud[$key] }
            $cloud.writes = [Collections.Generic.List[object]]::new()
            $deploymentIdentifiers.Clear()
            if (Test-Path -LiteralPath $inventory) { Remove-Item -LiteralPath $inventory }
            if ($null -ne $initialInventory) { [IO.File]::WriteAllText($inventory, $initialInventory) }
        }
        $snapshot = {
            $record = Get-Content -LiteralPath $inventory -Raw | ConvertFrom-Json -AsHashtable
            # verifiedAt records the time of the last successful App check, so it differs on every run.
            foreach ($app in @($record['apps'].Values)) { if ($app.Contains('verifiedAt')) { $app['verifiedAt'] = '<time>' } }
            @{
                inventory = $record
                resources = $cloud.resources; environments = $cloud.environments; variables = $cloud.variables
                branchRules = $cloud.branchRules; secrets = @($cloud.secrets.Keys | Sort-Object); tree = $cloud.tree; commit = $cloud.commit
            }
        }
    }

    AfterEach {
        . $stubBlocks.AfterEach
    }

    It 'recovers from an interruption at every mutating step of resource setup' {
        $arguments.ResourcesOnly = $true
        $run = { $null = & $bootstrap @arguments 3>$null 6>$null }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot @shard)

        $report = Format-InterruptionResult -Name 'Invoke-GitHubBootstrap.ps1 (resource setup)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'recovers from an interruption at every mutating step of credential setup after resource setup' {
        # The documented order runs resource setup first, then registers the Apps and runs credential setup.
        # Interruptions of the resource steps are covered by the previous test.
        $arguments.ResourcesOnly = $true
        $null = & $bootstrap @arguments 3>$null 6>$null
        $initialCloud = Copy-TestValue $cloud
        $initialInventory = [IO.File]::ReadAllText($inventory)
        $arguments.ResourcesOnly = $false
        $run = { $null = & $bootstrap @arguments 3>$null 6>$null }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot @shard)

        $report = Format-InterruptionResult -Name 'Invoke-GitHubBootstrap.ps1 (credential setup)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
