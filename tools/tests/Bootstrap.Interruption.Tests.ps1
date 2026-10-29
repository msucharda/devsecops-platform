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
        $manifest.permissions.entraDirectoryRoles = @(
            @{ phase = 'apply'; scope = 'enterpriseApplication'; actions = @(
                'microsoft.directory/servicePrincipals/appRoleAssignedTo/update'
                'microsoft.directory/servicePrincipals/appRoleAssignedTo/read'
                'microsoft.directory/servicePrincipals/standard/read'
            ) }
            @{ phase = 'plan'; scope = 'enterpriseApplication'; actions = @(
                'microsoft.directory/servicePrincipals/appRoleAssignedTo/read'
                'microsoft.directory/servicePrincipals/standard/read'
            ) }
        )
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
            elseif ($Method -ceq 'POST' -and $Uri.AbsolutePath -ceq '/v1.0/roleManagement/directory/roleDefinitions') {
                $data = ConvertFrom-Json -InputObject $Body -AsHashtable
                $identity = "directory role $($data.displayName)"
            }
            elseif ($Method -ceq 'POST' -and $Uri.AbsolutePath -ceq '/v1.0/roleManagement/directory/roleAssignments') {
                $data = ConvertFrom-Json -InputObject $Body -AsHashtable
                $definition = @($cloud.directoryRoleDefinitions | Where-Object { $_.id -ceq $data.roleDefinitionId })[0]
                $identity = "directory assignment $($definition.displayName)/$($data.directoryScopeId)"
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
                foreach ($definition in $cloud.directoryRoleDefinitions) { $aliases[$definition.id] = "directoryRole/$($definition.displayName)" }
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
                directoryRoleDefinitions = @($cloud.directoryRoleDefinitions | ForEach-Object { & $normalize $_ } | Sort-Object -CaseSensitive)
                directoryRoleAssignments = @($cloud.directoryRoleAssignments | ForEach-Object {
                    $assignment = $_.Clone()
                    $assignment.Remove('id')
                    & $normalize $assignment
                } | Sort-Object -CaseSensitive)
                modules = if ($null -ne $output.Result) { & $normalize $output.Result.Modules } else { $null }
                configuration = [IO.File]::ReadAllText($instancePath)
            }
        }
    }

    AfterEach { . $stubBlocks.AfterEach }

    It 'reports every failed recovery when no bootstrap result is available' -Tag 'RecoveryDiagnostics' {
        $run = {
            Invoke-InterruptionStep -Plan $plan -Request 'PUT /snapshot-diagnostic' -Apply {
                $output.Result = @{ Modules = @('reference-module') }
            } -Interrupt { throw 'Injected interruption.' }
        }
        $recover = { throw 'Deliberately failed recovery.' }
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Recover $recover -Snapshot $snapshot `
            -CaptureLocal $captureLocal -RestoreLocal $restoreLocal -Kind BeforeApply)

        $result.Count | Should -Be 2
        foreach ($case in $result) {
            $case.Passed | Should -BeFalse
            $case.Problem | Should -BeLike '*the rerun failed: Deliberately failed recovery.*'
        }
    }

    It 'reconciles the backend, phase identities and grants without duplicate identities after every interrupted write' {
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
            -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)
        $report = Format-InterruptionResult -Name 'Invoke-Bootstrap.ps1' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'repairs drifted directory role permissions after every interrupted patch without replacing roles or assignments' {
        & $run
        $definition = @($cloud.directoryRoleDefinitions | Where-Object displayName -EQ 'platform-demo-foundation-plan')[0]
        $definition.rolePermissions = @(@{ allowedResourceActions = @('microsoft.directory/servicePrincipals/appRoleAssignedTo/update') })
        $seed = @{
            Resources = ConvertTo-Json -InputObject $cloud.resources -Depth 100
            Grants = ConvertTo-Json -InputObject $cloud.graphAssignments -Depth 100
            Definitions = ConvertTo-Json -InputObject @($cloud.directoryRoleDefinitions) -Depth 100
            Assignments = ConvertTo-Json -InputObject @($cloud.directoryRoleAssignments) -Depth 100
        }
        $reset = {
            $cloud.resources = ConvertFrom-Json -InputObject $seed.Resources -AsHashtable
            $cloud.graphAssignments = ConvertFrom-Json -InputObject $seed.Grants -AsHashtable
            $cloud.directoryRoleDefinitions.Clear()
            foreach ($item in (ConvertFrom-Json -InputObject $seed.Definitions -AsHashtable -NoEnumerate)) { $cloud.directoryRoleDefinitions.Add($item) }
            $cloud.directoryRoleAssignments.Clear()
            foreach ($item in (ConvertFrom-Json -InputObject $seed.Assignments -AsHashtable -NoEnumerate)) { $cloud.directoryRoleAssignments.Add($item) }
            $cloud.writes.Clear()
            $output.Result = $null
            [IO.File]::WriteAllText($instancePath, $configuration)
        }
        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot `
            -CaptureLocal $captureLocal -RestoreLocal $restoreLocal -ShardByInterruption @shard)
        $report = Format-InterruptionResult -Name 'Invoke-Bootstrap.ps1 (directory role drift repair)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
