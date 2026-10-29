BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard

    $sharedFile = Join-Path $PSScriptRoot 'CodeSecurity.Tests.ps1'
    $parseErrors = $null
    $ast = [Management.Automation.Language.Parser]::ParseFile($sharedFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $sharedFile." }
    $sharedBeforeAll = $ast.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and
            $node.GetCommandName() -ceq 'BeforeAll' -and
            $node.CommandElements.Count -eq 2 -and
            $node.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true) | Select-Object -First 1
    if (-not $sharedBeforeAll) { throw "$sharedFile has no BeforeAll block for the CodeSecurity fixtures." }
    $sharedSetup = $sharedBeforeAll.CommandElements[1].ScriptBlock.GetScriptBlock()
    . $sharedSetup
}

Describe 'CodeSecurity lifecycle interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $env:REST_API_BEARER = $token
        $context = @{ Stub = $null; Plan = Get-InterruptionPlan; Case = $null; ReferenceRequests = $null }
        Mock -ModuleName CodeSecurity Start-Sleep {}
        Mock -ModuleName CodeSecurity Invoke-WebRequest {
            $target = [Uri] $Uri
            "$($target.Scheme)://$($target.Authority)" | Should -Be $apiUrl
            $methodName = ([string] $Method).ToUpperInvariant()
            $path = $target.AbsolutePath
            $bodyText = Get-Variable -Name Body -ValueOnly -ErrorAction Ignore
            $request = {
                $reply = Invoke-CodeSecurityStubRequest -State $context.Stub -Method $methodName `
                    -PathAndQuery $target.PathAndQuery -Headers $Headers -Body $bodyText
                if ($reply.Drop) { throw 'The connection was closed before the response arrived.' }
                [pscustomobject]@{ StatusCode = $reply.Status; Content = $reply.Body; Headers = @{ Link = $reply.Link } }
            }
            if ($methodName -eq 'GET') { return & $request }
            $identity = if ($methodName -eq 'POST' -and $path -cmatch '/code-security/configurations$') {
                'configuration platform-baseline'
            }
            elseif ($methodName -eq 'POST' -and $path -cmatch '/secret-scanning/custom-patterns$') {
                'custom pattern Platform token'
            }
            else { '' }
            Invoke-InterruptionStep -Plan $context.Plan -Request "$methodName $path" -Identity $identity `
                -Apply $request -Interrupt { throw 'Injected interruption before the response arrived.' }
        }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    It 'replays <Case> after every mutating API request' -ForEach @(
        @{
            Case = 'configuration creation, default and attachment'
            Expected = @(
                'POST /orgs/demo/code-security/configurations'
                'PUT /orgs/demo/code-security/configurations/{id}/defaults'
                'POST /orgs/demo/code-security/configurations/{id}/attach'
            )
        }
        @{
            Case = 'configuration update, default and attachment'
            Expected = @(
                'PATCH /orgs/demo/code-security/configurations/{id}'
                'PUT /orgs/demo/code-security/configurations/{id}/defaults'
                'POST /orgs/demo/code-security/configurations/{id}/attach'
            )
        }
        @{
            Case = 'configuration default removal and deletion'
            Expected = @(
                'PUT /orgs/demo/code-security/configurations/{id}/defaults'
                'DELETE /orgs/demo/code-security/configurations/{id}'
            )
        }
        @{
            Case = 'custom pattern creation and push protection'
            Expected = @(
                'POST /orgs/demo/secret-scanning/custom-patterns'
                'PATCH /orgs/demo/secret-scanning/pattern-configurations'
            )
        }
        @{
            Case = 'custom pattern content update'
            Expected = @('PATCH /orgs/demo/secret-scanning/custom-patterns/{id}')
        }
        @{
            Case = 'custom pattern deletion'
            Expected = @('DELETE /orgs/demo/secret-scanning/custom-patterns')
        }
    ) {
        $context.Case = $Case
        $reset = {
            $context.Stub = Initialize-CodeSecurityStub -Organization demo -Origin $apiUrl -Token $token
            if ($context.Case -like 'configuration update*' -or $context.Case -like 'configuration default removal*') {
                $existing = Get-GitHubApiFixture -Name code-security/get-configuration -Set @{
                    id = 42; name = 'platform-baseline'; secret_scanning = 'disabled'
                }
                $context.Stub.Configurations.Add($existing)
                if ($context.Case -like 'configuration default removal*') {
                    $context.Stub.Defaults.public = 42
                    $context.Stub.Defaults.private_and_internal = 42
                    foreach ($repository in $context.Stub.Repositories.Values) {
                        $repository.configuration = 42
                        $repository.status = 'attached'
                    }
                }
            }
            if ($context.Case -like 'custom pattern content update' -or $context.Case -like 'custom pattern deletion') {
                $pattern = (Get-GitHubApiFixture -Name secret-scanning/list-org-custom-patterns -Set @{
                    '0.name' = 'Platform token'
                    '0.pattern' = 'plat_[A-Za-z0-9]{32}'
                    '0.start_delimiter' = '\A|[^0-9A-Za-z]'
                    '0.end_delimiter' = '\z|[^0-9A-Za-z]'
                })[0]
                $pattern['revision'] = 1
                $context.Stub.Patterns.Add($pattern)
            }
        }
        $run = {
            switch ($context.Case) {
                { $_ -like 'configuration creation*' -or $_ -like 'configuration update*' } {
                    $null = Set-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo `
                        -Configuration (Get-TestConfiguration) -AttachmentIntervalSeconds 0
                    break
                }
                'configuration default removal and deletion' {
                    $null = Remove-CodeSecurityConfiguration -ApiUrl $apiUrl -Organization demo -Name platform-baseline
                    break
                }
                'custom pattern creation and push protection' {
                    $null = Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern)
                    break
                }
                'custom pattern content update' {
                    $null = Set-CustomPattern -ApiUrl $apiUrl -Organization demo -Pattern (Get-TestPattern -Pattern 'plat_[a-z]{40}')
                    break
                }
                'custom pattern deletion' {
                    $null = Remove-CustomPattern -ApiUrl $apiUrl -Organization demo -Name 'Platform token'
                    break
                }
                default { throw "Unknown CodeSecurity interruption scenario: $($context.Case)." }
            }
        }
        $snapshot = {
            $remote = $context.Stub
            if ($null -eq $context.ReferenceRequests) {
                $context.ReferenceRequests = [string[]] $context.Plan.Requests.ToArray()
            }
            $configurations = @(foreach ($configuration in $remote.Configurations) {
                $copy = ConvertTo-Json -InputObject $configuration -Depth 100 -Compress |
                    ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate
                $copy.Remove('id')
                $copy.Remove('url')
                $copy.Remove('html_url')
                $copy.Remove('created_at')
                $copy.Remove('updated_at')
                $copy
            })
            $patterns = @(foreach ($pattern in $remote.Patterns) {
                $copy = ConvertTo-Json -InputObject $pattern -Depth 100 -Compress |
                    ConvertFrom-Json -AsHashtable -Depth 100 -NoEnumerate
                $copy.Remove('id')
                $copy.Remove('created_at')
                $copy.Remove('updated_at')
                $copy
            })
            $repositoryStates = @{}
            foreach ($entry in $remote.Repositories.GetEnumerator()) {
                $configuration = @($remote.Configurations | Where-Object { $_['id'] -eq $entry.Value.configuration })
                $repositoryStates[$entry.Key] = @{
                    configuration = if ($null -eq $entry.Value.configuration) { $null } elseif ($configuration.Count -eq 1) { $configuration[0]['name'] } else { '<unknown>' }
                    status = $entry.Value.status
                }
            }
            $defaultNames = @{}
            foreach ($visibility in @('public', 'private_and_internal')) {
                $configuration = @($remote.Configurations | Where-Object { $_['id'] -eq $remote.Defaults[$visibility] })
                $defaultNames[$visibility] = if ($null -eq $remote.Defaults[$visibility]) { $null } elseif ($configuration.Count -eq 1) { $configuration[0]['name'] } else { '<unknown>' }
            }
            @{
                configurations = $configurations
                defaults = $defaultNames
                repositories = $repositoryStates
                patterns = $patterns
                patternConfigVersion = $remote.PatternConfigVersion
            }
        }
        $captureLocal = { return $null }
        $restoreLocal = { param($CapturedState) $null = $CapturedState }

        $result = @(Invoke-InterruptionMatrix -Plan $context.Plan -Reset $reset -Run $run `
                -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)
        $report = Format-InterruptionResult -Name $Case -Result $result
        Write-Information $report -InformationAction Continue
        @($context.ReferenceRequests | ForEach-Object { $_ -replace '/[0-9]+(?=/|$)', '/{id}' }) |
            Should -Be $Expected -Because "the reference run must exercise each mutating step of $Case"
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
