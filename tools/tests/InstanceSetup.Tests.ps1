BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $repoRoot = (Resolve-Path (Join-Path $PSScriptRoot '../..')).Path
    $modulesPath = Join-Path $PSScriptRoot 'fixtures/runner-modules'
    Import-Module (Join-Path $repoRoot 'tools/InstanceSetup.psm1') -Force
    InModuleScope InstanceSetup -Parameters @{ Root = $repoRoot } {
        param($Root)
        Import-Module (Join-Path $Root 'tools/PlatformTools.psm1') -Force
    }

    function Get-TestSetup {
        $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $setup = InModuleScope InstanceSetup -Parameters @{ Root = $repoRoot; Work = $work; Modules = $modulesPath } {
            param($Root, $Work, $Modules)
            Initialize-SetupContext -RepoPath $Root -WorkPath $Work -ModulesPath $Modules
        }
        $setup.Settings = @{
            name = 'ref'
            region = 'westeurope'
            tenantId = '11111111-1111-1111-1111-111111111111'
            managementSubscriptionId = '22222222-2222-2222-2222-222222222222'
            subscriptionIds = [string[]] @('22222222-2222-2222-2222-222222222222')
            enterpriseApplicationObjectId = '33333333-3333-3333-3333-333333333333'
            enterprise = 'example'
            githubHost = 'example.ghe.com'
        }
        $setup.Facts.Upn = 'owner@contoso.test'
        $setup.Facts.Login = 'owner'
        return $setup
    }

    function Write-TestStage {
        param(
            [hashtable] $Setup,
            [string[]] $Id,
            [string] $Status = 'Ok'
        )

        foreach ($stageId in $Id) {
            $Setup.Stages[$stageId] = [pscustomobject]@{ Step = 'T'; Id = $stageId; Title = $stageId; Status = $Status; Detail = '' }
        }
    }

    function Get-TestResponse {
        param([int] $StatusCode = 200, $Data = @{})
        [pscustomobject]@{ StatusCode = $StatusCode; Content = (ConvertTo-Json -InputObject $Data -Depth 100 -Compress); Headers = @{} }
    }

    function ConvertFrom-TestBase64Url {
        param([string] $Text)
        $padded = $Text.Replace('-', '+').Replace('_', '/')
        $padded += '=' * ((4 - $padded.Length % 4) % 4)
        return [Convert]::FromBase64String($padded)
    }
}

Describe 'Instance setup wizard' {
    BeforeEach {
        $answers = [System.Collections.Generic.Queue[string]]::new()
        Mock Read-Host -ModuleName InstanceSetup {
            if ($answers.Count -eq 0) { throw "Unexpected prompt: $Prompt" }
            $answers.Dequeue()
        }
        Mock Write-Host -ModuleName InstanceSetup {}
        Mock Write-Progress -ModuleName InstanceSetup {}
        Mock Start-Sleep -ModuleName InstanceSetup {}
        Mock Start-Process -ModuleName InstanceSetup {}
    }

    Context 'API access' {
        It 'classifies HTTP status codes' {
            Mock Invoke-WebRequest -ModuleName InstanceSetup {
                switch -Wildcard ($Uri) {
                    '*/ok' { Get-TestResponse -Data @{ value = 1 } }
                    '*/missing' { Get-TestResponse -StatusCode 404 -Data @{ message = 'Not Found' } }
                    '*/forbidden' { Get-TestResponse -StatusCode 403 -Data @{ error = @{ code = 'AuthorizationFailed'; message = 'denied' } } }
                    default { Get-TestResponse -StatusCode 400 -Data @{ message = 'bad' } }
                }
            }
            $setup = Get-TestSetup
            $results = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                foreach ($path in @('ok', 'missing', 'forbidden', 'bad')) {
                    Invoke-SetupApi -Setup $Setup -Uri "https://graph.microsoft.com/v1.0/$path" -Token 'test'
                }
            }

            @($results | ForEach-Object { $_.Status }) | Should -Be @('Ok', 'Missing', 'Forbidden', 'Error')
            $results[0].Data['value'] | Should -Be 1
            $results[2].Message | Should -BeLike '*AuthorizationFailed: denied*'
            $results[2].Area | Should -Be 'azure'
        }

        It 'retries network errors and throttling' {
            $responses = [System.Collections.Generic.Queue[object]]::new()
            $responses.Enqueue('network')
            $responses.Enqueue((Get-TestResponse -StatusCode 429))
            $responses.Enqueue((Get-TestResponse -Data @{ login = 'owner' }))
            Mock Invoke-WebRequest -ModuleName InstanceSetup {
                $next = $responses.Dequeue()
                if ($next -eq 'network') { throw 'connection reset' }
                $next
            }
            $setup = Get-TestSetup
            $result = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-SetupApi -Setup $Setup -Uri 'https://api.example.ghe.com/user' -Token 'test'
            }

            $result.Status | Should -Be 'Ok'
            $result.Area | Should -Be 'github'
            Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 3 -Exactly
            Should -Invoke Start-Sleep -ModuleName InstanceSetup -Times 2 -Exactly
        }

        It 'refuses addresses outside the allowlist' {
            Mock Invoke-WebRequest -ModuleName InstanceSetup { Get-TestResponse }
            $setup = Get-TestSetup
            foreach ($uri in @('https://api.github.com/user', 'http://graph.microsoft.com/v1.0/me', 'https://graph.microsoft.com:8443/v1.0/me')) {
                { InModuleScope InstanceSetup -Parameters @{ Setup = $setup; Uri = $uri } {
                        param($Setup, $Uri)
                        Invoke-SetupApi -Setup $Setup -Uri $Uri -Token 'test'
                    } } | Should -Throw '*Untrusted setup API address*'
            }
            Should -Invoke Invoke-WebRequest -ModuleName InstanceSetup -Times 0 -Exactly
        }
    }

    Context 'Stage runner' {
        It 'skips a stage whose requirement did not pass' {
            Mock Invoke-StepTool -ModuleName InstanceSetup { 'ran' }
            $setup = Get-TestSetup
            Write-TestStage -Setup $setup -Id 'inputs' -Status Missing
            InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-SetupStage -Setup $Setup -Id 'next' -Step 'A1' -Title 'Next' -Requires 'inputs' -Handler 'Invoke-StepTool'
            }

            $setup.Stages['next'].Status | Should -Be 'Skipped'
            $setup.Stages['next'].Detail | Should -BeLike '*inputs*'
            Should -Invoke Invoke-StepTool -ModuleName InstanceSetup -Times 0 -Exactly
        }

        It 'records a failed stage that the user skips' {
            Mock Invoke-StepTool -ModuleName InstanceSetup {
                $exception = [System.InvalidOperationException]::new('Role is missing.')
                $exception.Data['SetupStatus'] = 'Forbidden'
                $exception.Data['SetupGuidance'] = [string[]] @('Activate the role.')
                $exception.Data['SetupArea'] = 'azure'
                throw $exception
            }
            $answers.Enqueue('s')
            $setup = Get-TestSetup
            InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-SetupStage -Setup $Setup -Id 'tools' -Step 'A1' -Title 'Tools' -Handler 'Invoke-StepTool'
            }

            $setup.Stages['tools'].Status | Should -Be 'Forbidden'
            $setup.Stages['tools'].Detail | Should -Be 'Role is missing.'
        }

        It 'retries a failed stage on request' {
            $calls = @{ Count = 0 }
            Mock Invoke-StepTool -ModuleName InstanceSetup {
                $calls.Count++
                if ($calls.Count -eq 1) { throw 'transient' }
                'Tools are ready.'
            }
            $answers.Enqueue('r')
            $setup = Get-TestSetup
            InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-SetupStage -Setup $Setup -Id 'tools' -Step 'A1' -Title 'Tools' -Handler 'Invoke-StepTool'
            }

            $setup.Stages['tools'].Status | Should -Be 'Ok'
            $setup.Stages['tools'].Detail | Should -Be 'Tools are ready.'
            Should -Invoke Invoke-StepTool -ModuleName InstanceSetup -Times 2 -Exactly
        }

        It 'stops the wizard when the user quits' {
            Mock Invoke-StepTool -ModuleName InstanceSetup { throw 'failed' }
            $answers.Enqueue('q')
            $setup = Get-TestSetup
            { InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                    param($Setup)
                    Invoke-SetupStage -Setup $Setup -Id 'tools' -Step 'A1' -Title 'Tools' -Handler 'Invoke-StepTool'
                } } | Should -Throw -ExceptionType ([System.OperationCanceledException])
            $setup.Stages['tools'].Status | Should -Be 'Error'
        }
    }

    Context 'Confirmations and flags' {
        It 'reuses a stored confirmation without a prompt' {
            $setup = Get-TestSetup
            $setup.State.confirmations['licenses'] = '2026-01-01T00:00:00Z'
            $result = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Confirm-SetupPrerequisite -Setup $Setup -Name 'licenses' -Guidance @('Check.') -Prompt 'Done?'
            }

            $result | Should -BeTrue
            Should -Invoke Read-Host -ModuleName InstanceSetup -Times 0 -Exactly
        }

        It 'removes a stored confirmation that the user withdraws' {
            $setup = Get-TestSetup
            $setup.Reconfirm = $true
            $setup.State.confirmations['licenses'] = '2026-01-01T00:00:00Z'
            $answers.Enqueue('n')
            $result = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Confirm-SetupPrerequisite -Setup $Setup -Name 'licenses' -Guidance @('Check.') -Prompt 'Done?'
            }

            $result | Should -BeFalse
            $setup.State.confirmations.Contains('licenses') | Should -BeFalse
            (Get-Content -LiteralPath $setup.StatePath -Raw) | Should -Not -BeLike '*licenses*'
        }

        It 'sets a flag only after its steps pass' {
            $setup = Get-TestSetup
            Write-TestStage -Setup $setup -Id @(
                'azure-login', 'entra-license', 'subscriptions', 'azure-owner', 'resource-providers', 'management-groups',
                'enterprise-app', 'scim', 'owner-assignment', 'github-owner', 'enterprise-policies', 'github-licenses', 'probe-authorization'
            )
            Write-TestStage -Setup $setup -Id 'probe-admin' -Status Error
            $setup.Facts.ForksDisabled = $true
            $setup.State.confirmations['licenses'] = 'now'
            $setup.State.confirmations['emuUserNamespacesRestricted'] = 'now'
            $flags = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Get-SetupFlag -Setup $Setup
            }

            @($flags.Keys) | Should -Be @(
                'tenant', 'subscriptions', 'enterpriseOidc', 'enterpriseScim', 'enterpriseOwner', 'licenses',
                'privateInternalForksDisabled', 'emuUserNamespacesRestricted', 'fineGrainedPatApprovalRequired',
                'patMaxLifetime90Days', 'githubAppAvailabilityVerified'
            )
            @($flags.Keys | Where-Object { $flags[$_] }) | Should -Be @(
                'tenant', 'subscriptions', 'enterpriseOidc', 'enterpriseScim', 'enterpriseOwner', 'licenses',
                'privateInternalForksDisabled', 'emuUserNamespacesRestricted'
            )

            Write-TestStage -Setup $setup -Id 'enterprise-policies' -Status Skipped
            Write-TestStage -Setup $setup -Id 'management-groups' -Status Missing
            $flags = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Get-SetupFlag -Setup $Setup
            }
            $flags['emuUserNamespacesRestricted'] | Should -BeFalse
            $flags['subscriptions'] | Should -BeFalse
        }
    }

    Context 'Inputs' {
        It 'takes defaults from session.ps1, instance.yaml and the current run in this order' {
            $setup = Get-TestSetup
            $null = New-Item -ItemType Directory -Force -Path $setup.WorkPath
            Set-Content -LiteralPath (Join-Path $setup.WorkPath 'session.ps1') -Value @(
                "`$name = 'sess'"
                "`$region = 'westeurope'"
                "`$tenantId = '44444444-4444-4444-4444-444444444444'"
                "`$mgmtSub = '55555555-5555-5555-5555-555555555555'"
                "`$subscriptionIds = @('55555555-5555-5555-5555-555555555555', '66666666-6666-6666-6666-666666666666')"
                "`$spId = '77777777-7777-7777-7777-777777777777'"
                "`$enterprise = 'session'"
            )
            $setup.Existing = [ordered]@{ instance = [ordered]@{ name = 'yaml' } }
            $setup.Settings = @{ region = 'northeurope' }
            $defaults = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Get-SetupInputDefault -Setup $Setup
            }

            $defaults['name'] | Should -Be 'yaml'
            $defaults['region'] | Should -Be 'northeurope'
            $defaults['tenantId'] | Should -Be '44444444-4444-4444-4444-444444444444'
            $defaults['managementSubscriptionId'] | Should -Be '55555555-5555-5555-5555-555555555555'
            $defaults['subscriptionIds'] | Should -Be @('55555555-5555-5555-5555-555555555555', '66666666-6666-6666-6666-666666666666')
            $defaults['enterpriseApplicationObjectId'] | Should -Be '77777777-7777-7777-7777-777777777777'
            $defaults['enterprise'] | Should -Be 'session'
        }

        It 'validates the input values' {
            $problems = InModuleScope InstanceSetup {
                @(
                    Get-SetupInputProblem -Name 'name' -Value 'ref1'
                    Get-SetupInputProblem -Name 'name' -Value 'Toolongname'
                    Get-SetupInputProblem -Name 'enterprise' -Value 'my-enterprise'
                    Get-SetupInputProblem -Name 'enterprise' -Value 'My_Enterprise'
                    Get-SetupInputProblem -Name 'tenantId' -Value 'not-a-guid'
                ) | ForEach-Object { [bool] $_ }
            }
            # Only invalid values produce a problem text.
            $problems | Should -Be @($true, $true, $true)
        }
    }

    Context 'GitHub App helpers' {
        It 'reuses a registered private App when OAuth slug lookup returns 404' {
            $setup = Get-TestSetup
            $setup.State.probe['organization'] = 'probe-test'
            InModuleScope InstanceSetup -Parameters @{ Scenario = @{ Setup = $setup } } {
                param($Scenario)
                $Setup = $Scenario.Setup
                Mock Invoke-SetupApi { @{ Status = 'Missing'; Code = 404; Data = $null; Message = 'HTTP 404: Not Found' } }
                Mock Confirm-SetupAction { $true }
                Mock Request-SetupManualStep {}
                Mock Read-SetupValue { '101' }
                Mock Find-SetupAppKey { throw 'Reached JWT key verification.' }

                { Get-SetupProbeApp -Setup $Setup -Role admin -Permission @{ members = 'write' } -Selection all } |
                    Should -Throw '*Reached JWT key verification*'
                Should -Invoke Request-SetupManualStep -Times 0 -Exactly
                Should -Invoke Confirm-SetupAction -Times 1 -Exactly -ParameterFilter {
                    $Prompt -like '*already registered*'
                }
            }
            $setup.State.probe['adminAppId'] | Should -Be '101'
        }

        It 'compares App permissions exactly and ignores implicit metadata read' {
            $results = InModuleScope InstanceSetup {
                $expected = @{ members = 'read' }
                Test-SetupAppPermission -Actual @{ members = 'read'; metadata = 'read' } -Expected $expected
                Test-SetupAppPermission -Actual @{ members = 'write' } -Expected $expected
                Test-SetupAppPermission -Actual @{ members = 'read'; contents = 'read' } -Expected $expected
                Test-SetupAppPermission -Actual $null -Expected $expected
            }
            $results | Should -Be @($true, $false, $false, $false)
        }

        It 'signs an App JWT with the private key' {
            $rsa = [System.Security.Cryptography.RSA]::Create(2048)
            try {
                $keyPath = Join-Path $TestDrive 'app.pem'
                Set-Content -LiteralPath $keyPath -Value $rsa.ExportRSAPrivateKeyPem()
                $jwt = InModuleScope InstanceSetup -Parameters @{ KeyPath = $keyPath } {
                    param($KeyPath)
                    ConvertTo-SetupAppJwt -AppId '123' -KeyPath $KeyPath
                }
                $parts = $jwt.Split('.')
                $claims = [System.Text.Encoding]::UTF8.GetString((ConvertFrom-TestBase64Url -Text $parts[1])) | ConvertFrom-Json
                $signed = $rsa.VerifyData([System.Text.Encoding]::UTF8.GetBytes("$($parts[0]).$($parts[1])"), (ConvertFrom-TestBase64Url -Text $parts[2]),
                    [System.Security.Cryptography.HashAlgorithmName]::SHA256, [System.Security.Cryptography.RSASignaturePadding]::Pkcs1)
            }
            finally {
                $rsa.Dispose()
            }

            $parts.Count | Should -Be 3
            $claims.iss | Should -Be '123'
            ($claims.exp - $claims.iat) | Should -Be 600
            $signed | Should -BeTrue
        }

        It 'does not require the probe organization after both probes passed' {
            $setup = Get-TestSetup
            $setup.State.probe['organization'] = 'probe-20260101'
            $setup.State.probe['authorizationPassed'] = '2026-01-01T00:00:00Z'
            $setup.State.probe['adminPassed'] = '2026-01-01T00:00:00Z'
            Mock Invoke-SetupApi -ModuleName InstanceSetup { throw 'Unexpected API call.' }
            $result = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-StepProbeOrg -Setup $Setup
            }

            $result | Should -BeLike '*probe-20260101*'
            Should -Invoke Invoke-SetupApi -ModuleName InstanceSetup -Times 0 -Exactly
        }
    }

    Context 'Elevated access' {
        BeforeEach {
            $apiCalls = [System.Collections.Generic.List[string]]::new()
            Mock Test-SetupGlobalAdministrator -ModuleName InstanceSetup { $true }
            Mock Invoke-SetupApi -ModuleName InstanceSetup {
                $apiCalls.Add("$($PesterBoundParameters['Method']) $Uri")
                @{ Status = 'Ok'; Code = 200; Data = @{}; Headers = @{}; Message = ''; Area = 'azure' }
            }
        }

        It 'removes the elevation also when the action fails' {
            $rootCalls = @{ Count = 0 }
            Mock Get-SetupRootAccess -ModuleName InstanceSetup {
                $rootCalls.Count++
                if ($rootCalls.Count -gt 1) { , @{ id = '/providers/Microsoft.Authorization/roleAssignments/elevated'; properties = @{ scope = '/' } } }
            }
            $answers.Enqueue('y')
            $setup = Get-TestSetup
            { InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                    param($Setup)
                    Invoke-SetupElevatedAction -Setup $Setup -Purpose 'Test' -AdminGuidance @('Ask.') -Action { throw 'boom' }
                } } | Should -Throw '*boom*'

            $apiCalls[0] | Should -BeLike 'POST */elevateAccess?*'
            $apiCalls[-1] | Should -Be 'DELETE https://management.azure.com/providers/Microsoft.Authorization/roleAssignments/elevated?api-version=2022-04-01'
        }

        It 'changes nothing when the user declines the elevation' {
            Mock Get-SetupRootAccess -ModuleName InstanceSetup {}
            $answers.Enqueue('n')
            $setup = Get-TestSetup
            { InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                    param($Setup)
                    Invoke-SetupElevatedAction -Setup $Setup -Purpose 'Test' -AdminGuidance @('Ask.') -Action { 'changed' }
                } } | Should -Throw '*was declined*'
            $apiCalls.Count | Should -Be 0
        }
    }

    Context 'Instance configuration' {
        BeforeEach {
            $setup = Get-TestSetup
            $null = New-Item -ItemType Directory -Force -Path $setup.WorkPath
            Write-TestStage -Setup $setup -Id @('azure-login', 'entra-license', 'enterprise-app', 'scim')
            $setup.Facts.OidcModeVerified = $true
        }

        It 'writes a valid instance.yaml and session.ps1 after a confirmation' {
            $sessionPath = Join-Path $setup.WorkPath 'session.ps1'
            Set-Content -LiteralPath $sessionPath -Value "`$name = 'manual'"
            $setup.Facts.UserRoleId = '44444444-4444-4444-4444-444444444444'
            $setup.State.probe['organization'] = 'probe-org'
            $setup.State.probe['adminAppId'] = '12'
            $setup.State.probe['adminInstallationId'] = '34'
            $answers.Enqueue('y')
            $detail = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-StepConfiguration -Setup $Setup
            }
            $text = Get-Content -LiteralPath $setup.InstancePath -Raw
            $instance = ConvertFrom-Yaml -Yaml $text
            $session = Get-Content -LiteralPath $sessionPath -Raw

            $detail | Should -BeLike 'Wrote *Unverified flags: subscriptions, enterpriseOwner,*'
            $text | Should -Not -Match "`r"
            $instance.instance.name | Should -Be 'ref'
            $instance.regions.primary | Should -Be 'westeurope'
            @($instance.teams.platform) | Should -Be @('owner@contoso.test')
            @($instance.teams.security) | Should -Be @('owner@contoso.test')
            @($instance.modules.Keys) | Should -Be @('application')
            $instance.bootstrap.githubHost | Should -Be 'example.ghe.com'
            @($instance.bootstrap.subscriptionIds) | Should -Be @('22222222-2222-2222-2222-222222222222')
            $instance.manualPrerequisites.tenant | Should -BeTrue
            $instance.manualPrerequisites.enterpriseOidc | Should -BeTrue
            $instance.manualPrerequisites.enterpriseScim | Should -BeTrue
            $instance.manualPrerequisites.subscriptions | Should -BeFalse
            $instance.manualPrerequisites.githubAppAvailabilityVerified | Should -BeFalse
            $instance.teardown.allowed | Should -BeFalse
            $session | Should -BeLike '# Generated by tools/Start-InstanceSetup.ps1.*'
            $session | Should -BeLike "*`$cfg = '$($setup.InstancePath)'*"
            $session | Should -BeLike "*`$subscriptionIds = @('22222222-2222-2222-2222-222222222222')*"
            $session | Should -BeLike "*`$userRole = '44444444-4444-4444-4444-444444444444'*"
            $session | Should -BeLike "*`$probeOrg = 'probe-org'*"
            $session | Should -BeLike "*`$adminApp = @{ AppId = '12'; InstallationId = '34'; KeyPath = '$(Join-Path $setup.WorkPath 'keys/probe-admin.pem')' }*"
            $session | Should -Not -Match "`r"
            Get-Content -LiteralPath "$sessionPath.bak" -Raw | Should -BeLike "*`$name = 'manual'*"
        }

        It 'merges an existing configuration and resets unverified flags' {
            Set-Content -LiteralPath $setup.InstancePath -Value @'
instance:
  name: old
regions:
  primary: northeurope
teams:
  platform: [lead@contoso.test, platform@example.test]
  security: [sec@contoso.test]
modules:
  foundation: {}
customPatterns: []
manualSteps: {}
manualPrerequisites:
  subscriptions: true
teardown:
  allowed: false
'@
            $setup.Existing = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $setup.InstancePath -Raw) -Ordered
            $answers.Enqueue('y')
            $null = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-StepConfiguration -Setup $Setup
            }
            $instance = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $setup.InstancePath -Raw)

            $instance.instance.name | Should -Be 'ref'
            @($instance.teams.platform) | Should -Be @('lead@contoso.test', 'owner@contoso.test')
            @($instance.teams.security) | Should -Be @('sec@contoso.test')
            @($instance.modules.Keys) | Should -Be @('foundation')
            $instance.manualPrerequisites.subscriptions | Should -BeFalse
            Get-Content -LiteralPath "$($setup.InstancePath).bak" -Raw | Should -BeLike '*name: old*'
        }

        It 'asks nothing when the configuration is up to date' {
            $answers.Enqueue('y')
            $null = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-StepConfiguration -Setup $Setup
            }
            $detail = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-StepConfiguration -Setup $Setup
            }

            $detail | Should -BeLike 'instance.yaml is up to date.*'
            Should -Invoke Read-Host -ModuleName InstanceSetup -Times 1 -Exactly
            Test-Path -LiteralPath (Join-Path $setup.WorkPath 'session.ps1.bak') | Should -BeFalse
        }

        It 'writes nothing without a confirmation' {
            $answers.Enqueue('n')
            { InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                    param($Setup)
                    Invoke-StepConfiguration -Setup $Setup
                } } | Should -Throw '*was not written*'
            Test-Path -LiteralPath $setup.InstancePath | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $setup.WorkPath 'session.ps1') | Should -BeFalse
        }
    }

    Context 'Preflight' {
        BeforeEach {
            $setup = Get-TestSetup
            $fakeRepo = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
            $null = New-Item -ItemType Directory -Force -Path (Join-Path $fakeRepo 'tools')
            Set-Content -LiteralPath (Join-Path $fakeRepo 'tools/Test-BootstrapPrerequisites.ps1') -Value @'
param($InstancePath, $ModulesPath)
Get-Content -LiteralPath (Join-Path $PSScriptRoot 'rows.json') -Raw | ConvertFrom-Json
'@
            $setup.RepoPath = $fakeRepo
            $rowsPath = Join-Path $fakeRepo 'tools/rows.json'
        }

        It 'passes when every check passes' {
            ConvertTo-Json -InputObject @(
                @{ Area = 'Azure'; Check = 'Sign-in'; Status = 'Pass'; Detail = '' }
                @{ Area = 'Manual prerequisites'; Check = '$.manualPrerequisites.tenant'; Status = 'Confirmed'; Detail = '' }
            ) | Set-Content -LiteralPath $rowsPath
            $detail = InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                param($Setup)
                Invoke-StepPreflight -Setup $Setup
            }
            $detail | Should -Be 'Preflight passed all 2 checks. Continue with phase B: bootstrap.'
        }

        It 'fails on a failed check' {
            ConvertTo-Json -InputObject @(
                @{ Area = 'Azure'; Check = 'Sign-in'; Status = 'Fail'; Detail = 'No token.' }
                @{ Area = 'Azure'; Check = 'Owner'; Status = 'Skip'; Detail = 'Requires sign-in.' }
            ) | Set-Content -LiteralPath $rowsPath
            { InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                    param($Setup)
                    Invoke-StepPreflight -Setup $Setup
                } } | Should -Throw '*2 preflight check(s) failed or were skipped*'
        }

        It 'reports unconfirmed manual prerequisites' {
            ConvertTo-Json -InputObject @(
                @{ Area = 'Azure'; Check = 'Sign-in'; Status = 'Pass'; Detail = '' }
                @{ Area = 'Manual prerequisites'; Check = '$.manualPrerequisites.licenses'; Status = 'Manual'; Detail = '' }
            ) | Set-Content -LiteralPath $rowsPath
            { InModuleScope InstanceSetup -Parameters @{ Setup = $setup } {
                    param($Setup)
                    Invoke-StepPreflight -Setup $Setup
                } } | Should -Throw '*1 manual prerequisite flag(s) are false*'
        }
    }

    Context 'Wizard' {
        BeforeEach {
            $handlers = @(
                'Tool', 'Input', 'AzureLogin', 'EntraLicense', 'Subscription', 'AzureOwner', 'ResourceProvider', 'StateBackend',
                'ManagementGroup', 'EnterpriseApp', 'Scim', 'OwnerAssignment', 'GitHubLogin', 'GitHubOwner', 'EnterprisePolicy',
                'GitHubLicense', 'ProbeOrg', 'ProbeAuthorization', 'ProbeAdmin', 'Configuration', 'Preflight'
            )
            foreach ($handler in $handlers) {
                Mock -CommandName "Invoke-Step$handler" -ModuleName InstanceSetup -MockWith { 'Done.' }
            }
            Mock Invoke-StepInput -ModuleName InstanceSetup {
                $Setup.Settings['githubHost'] = 'example.ghe.com'
                'Inputs.'
            }
            Mock gh -ModuleName InstanceSetup { $global:LASTEXITCODE = 0 }
            $work = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        }

        It 'refuses a work folder inside the source repository' {
            { Invoke-InstanceSetup -RepoPath $repoRoot -WorkPath (Join-Path $repoRoot 'instance-data') -ModulesPath $modulesPath } |
                Should -Throw '*inside the source repository*'
            Test-Path -LiteralPath (Join-Path $repoRoot 'instance-data') | Should -BeFalse
        }

        It 'runs every stage in order and skips the dependants of a skipped stage' {
            Mock Invoke-StepAzureLogin -ModuleName InstanceSetup {
                $exception = [System.InvalidOperationException]::new('No sign-in.')
                $exception.Data['SetupStatus'] = 'Missing'
                throw $exception
            }
            $answers.Enqueue('s')
            $result = Invoke-InstanceSetup -RepoPath $repoRoot -WorkPath $work -ModulesPath $modulesPath

            $result.Stages.Count | Should -Be $handlers.Count
            $statuses = @{}
            foreach ($stage in $result.Stages) { $statuses[$stage.Id] = $stage.Status }
            $statuses['azure-login'] | Should -Be 'Missing'
            foreach ($id in @('entra-license', 'subscriptions', 'azure-owner', 'state-backend', 'enterprise-app', 'scim', 'configuration', 'preflight')) {
                $statuses[$id] | Should -Be 'Skipped'
            }
            foreach ($id in @('tools', 'inputs', 'github-login', 'github-owner', 'enterprise-policies', 'probe-org', 'probe-admin')) {
                $statuses[$id] | Should -Be 'Ok'
            }
            $result.Flags['tenant'] | Should -BeFalse
            Test-Path -LiteralPath (Join-Path $work 'setup-state.json') | Should -BeTrue
            Should -Invoke Invoke-StepConfiguration -ModuleName InstanceSetup -Times 0 -Exactly
        }

        It 'offers to remove temporary gh scopes at the end' {
            Mock Invoke-StepProbeOrg -ModuleName InstanceSetup {
                $Setup.AddedScopes.Add('admin:org')
                'Probe organization.'
            }
            $answers.Enqueue('y')
            $null = Invoke-InstanceSetup -RepoPath $repoRoot -WorkPath $work -ModulesPath $modulesPath

            Should -Invoke gh -ModuleName InstanceSetup -Times 1 -Exactly -ParameterFilter {
                ($args -join ' ') -eq 'auth refresh --hostname example.ghe.com --remove-scopes admin:org'
            }
        }
    }
}
