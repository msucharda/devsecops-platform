BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot '../PlatformTools.psm1')
    $shard = Get-InterruptionShard
    $stubFile = Join-Path $PSScriptRoot 'Bootstrap.Tests.ps1'
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlocks = @{}
    foreach ($command in $ast.FindAll({ param($node) $node -is [Management.Automation.Language.CommandAst] }, $true)) {
        $name = $command.GetCommandName()
        if ($name -cin @('BeforeAll', 'BeforeEach', 'AfterEach') -and -not $stubBlocks.ContainsKey($name) -and
            $command.CommandElements.Count -eq 2 -and $command.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]) {
            $stubBlocks[$name] = $command.CommandElements[1].ScriptBlock.GetScriptBlock()
        }
        if ($name -ceq 'Mock' -and $command.CommandElements[1].Extent.Text -ceq 'Invoke-WebRequest' -and -not $stubBlocks.ContainsKey('Transport')) {
            $stubBlocks.Transport = $command.CommandElements[2].ScriptBlock.GetScriptBlock()
        }
    }
    foreach ($name in @('BeforeAll', 'BeforeEach', 'AfterEach', 'Transport')) {
        if (-not $stubBlocks.ContainsKey($name)) { throw "$stubFile has no $name block for the Azure stub." }
    }
    . $stubBlocks.BeforeAll
}

Describe 'Azure bootstrap interruption harness' -Tag 'Interruption' {
    BeforeEach {
        . $stubBlocks.BeforeEach
        $instance.modules = @{ foundation = @{} }
        $manifestPath = Join-Path $modulesPath 'foundation/module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.permissions.azure = @(@{
            role = 'Reader'; scope = '/subscriptions/22222222-2222-2222-2222-222222222222'; phase = 'plan'
        })
        $manifest.permissions.microsoftGraph = @('Group.Create', @{ permission = 'Group.Read.All'; phase = 'plan' })
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $configuration = [IO.File]::ReadAllText($instancePath)
        $plan = Get-InterruptionPlan
        $transport = $stubBlocks.Transport
        $output = @{ Result = $null }
        Mock Invoke-WebRequest {
            param([uri] $Uri, [string] $Method = 'GET', [string] $Body)
            $Method = $Method.ToUpperInvariant()
            $call = @{ Uri = $Uri; Method = $Method; Body = $Body }
            # getEntities is a read operation despite its POST method.
            if ($Method -ceq 'GET' -or $Uri.AbsolutePath -ceq '/graphql' -or
                $Uri.AbsolutePath -ceq '/providers/Microsoft.Management/getEntities') { return & $transport @call }
            $identity = ''
            if ($Uri.AbsolutePath -match '/userAssignedIdentities/[^/]+$') { $identity = $Uri.AbsolutePath }
            elseif ($Uri.AbsolutePath -match '/servicePrincipals/([^/]+)/appRoleAssignments$') {
                $principal = $Matches[1]
                $resource = @($cloud.resources.Values | Where-Object {
                    $_.id -match '/userAssignedIdentities/[^/]+$' -and
                    $_.properties.principalId -ceq $principal
                })[0]
                $data = ConvertFrom-Json -InputObject $Body -AsHashtable
                $identity = "$($resource.id)/$($data.appRoleId)"
            }
            Invoke-InterruptionStep -Plan $plan -Request "$Method $($Uri.AbsolutePath)" -Identity $identity -Apply {
                & $transport @call
            } -Interrupt { throw 'Injected Azure interruption.' }
        }
        $reset = {
            $cloud.resources = @{}
            $cloud.graphAssignments = @{}
            $cloud.writes.Clear()
            $cloud.directoryRoleDefinitions.Clear()
            $cloud.directoryRoleAssignments.Clear()
            $output.Result = $null
            [IO.File]::WriteAllText($instancePath, $configuration)
        }
        $run = { $output.Result = & $bootstrap -InstancePath $instancePath -ModulesPath $modulesPath }
        $captureLocal = { [IO.File]::ReadAllText($instancePath) }.GetNewClosure()
        $restoreLocal = { param($Text) [IO.File]::WriteAllText($instancePath, $Text) }.GetNewClosure()
        $snapshot = {
            $aliases = @{}
            foreach ($resource in $cloud.resources.Values) {
                if ($resource.id -match '/userAssignedIdentities/[^/]+$') {
                    foreach ($field in @('principalId', 'clientId')) {
                        $aliases[$resource.properties[$field]] = "$($resource.id)/$field"
                    }
                }
            }
            $normalize = {
                param($Value)
                $text = ConvertTo-PlatformCanonicalJson $Value
                foreach ($id in $aliases.Keys) { $text = $text.Replace($id, $aliases[$id]) }
                # Assignment names are derived from generated principal IDs; role and scope stay intact.
                return $text -replace '/roleAssignments/[0-9a-f-]{36}', '/roleAssignments/<id>'
            }
            @{
                resources = @($cloud.resources.Values | ForEach-Object { & $normalize $_ } | Sort-Object -CaseSensitive)
                grants = @($cloud.graphAssignments.Values | ForEach-Object { foreach ($grant in $_) { & $normalize $grant } } | Sort-Object -CaseSensitive)
                modules = & $normalize $output.Result.Modules
                configuration = [IO.File]::ReadAllText($instancePath)
            }
        }
    }

    AfterEach { . $stubBlocks.AfterEach }

    It 'reconciles the backend, phase identities and grants without duplicate identities after every interrupted write' {
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
            -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)
        $report = Format-InterruptionResult -Name 'Invoke-Bootstrap.ps1' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
