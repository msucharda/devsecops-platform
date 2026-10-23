BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $runner = Join-Path (Split-Path $PSScriptRoot -Parent) 'Invoke-Module.ps1'
    $shard = Get-InterruptionShard
}

Describe 'Organization runner interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $modules = Join-Path $directory 'modules'
        $null = New-Item -ItemType Directory -Path $modules -Force
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/organization-module') -Destination (Join-Path $modules 'scoped') -Recurse
        $organizations = @('demo-platform', 'demo-actions', 'demo-workloads')
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/organization-module-instance.yaml') -Raw)
        $fixtureRoot = Join-Path $modules 'scoped'
        $null = New-Item -ItemType Directory -Path (Join-Path $fixtureRoot 'rulesets')
        Copy-Item -LiteralPath (Join-Path $fixtureRoot 'main.tf') -Destination (Join-Path $fixtureRoot 'rulesets/main.tf')
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $fixtureRoot 'module.yaml') -Raw)
        $manifest.permissions.githubApp.rulesetPlan = @{
            permissions = @{ organization_administration = 'write' }
            resources = @{ organizations = 'target_organizations' }
            purpose = 'organization-rulesets-full-read'
        }
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath (Join-Path $fixtureRoot 'module.yaml')
        $instance.githubApps.rulesets = @{
            appId = '103'; installationId = '203'; enterprise = 'example'
            permissions = @{ organization_administration = 'write' }; resources = @{ organizations = $organizations }
        }
        $instance.credentials.scoped.rulesetPlan = @{ environment = 'scoped-ruleset-plan'; githubApp = 'rulesets' }
        $instancePath = Join-Path $directory 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $runnerArguments = @{
            Module = 'scoped'; InstancePath = $instancePath; ModulesPath = $modules
            PlatformOrganization = 'demo-platform'; Backend = 'local'
            StatePath = (Join-Path $directory 'state'); ArtifactsPath = (Join-Path $directory 'outputs')
            JobSummaryPath = (Join-Path $directory 'summary.md')
        }
        $oldTokens = $env:PLATFORM_GITHUB_TOKENS
        $env:PLATFORM_GITHUB_TOKENS = '{"demo-platform":"platform-token","demo-actions":"actions-token","demo-workloads":"workloads-token"}'
        $interruptionPlan = Get-InterruptionPlan
        $remoteOrganizations = @{}
        $backendPaths = @{}
        $destroyPlans = @{}

        # This stub models the Terraform process boundary, not a GitHub API. API write/recovery contracts
        # are exercised separately by the real Terraform and documented GitHub API stubs.
        function terraform {
            $verb = $args[1]
            $global:LASTEXITCODE = 0
            if ($verb -eq 'init') {
                $backendPaths[$env:TF_DATA_DIR] = ($args | Where-Object { $_ -like '-backend-config=path=*' }) -replace '^-backend-config=path=', ''
                $null = New-Item -ItemType Directory -Path $env:TF_DATA_DIR -Force
                Set-Content -LiteralPath (Join-Path $env:TF_DATA_DIR 'terraform.tfstate') -Value '{"backend":{"type":"local"}}'
                return ''
            }
            $terraformStatePath = $backendPaths[$env:TF_DATA_DIR]
            $selectedOrganization = Split-Path (Split-Path $terraformStatePath -Parent) -Leaf
            $terraformObjectIdentity = "$selectedOrganization/$(Split-Path $terraformStatePath -Leaf)"
            $publicOutputs = @{
                organizations = @{ sensitive = $false; value = @($selectedOrganization) }
                identity = @{ sensitive = $false; value = "id-$terraformObjectIdentity" }
            }
            switch ($verb) {
                plan {
                    $destroyPlans[$env:TF_DATA_DIR] = $args -contains '-destroy'
                    if ($destroyPlans[$env:TF_DATA_DIR] -or -not (Test-Path -LiteralPath $terraformStatePath)) { $global:LASTEXITCODE = 2 }
                    return ''
                }
                show {
                    $data = if ($args.Count -gt 3) {
                        @{ planned_values = @{ outputs = $(if ($destroyPlans[$env:TF_DATA_DIR]) { @{} } else { $publicOutputs }) } }
                    } elseif (Test-Path -LiteralPath $terraformStatePath) {
                        @{ values = @{ outputs = $publicOutputs } }
                    } else { @{} }
                    return ConvertTo-Json -InputObject $data -Depth 10 -Compress
                }
                apply {
                    $interrupt = { $global:LASTEXITCODE = 1; 'Injected Terraform process interruption.' }
                    if ($destroyPlans[$env:TF_DATA_DIR]) {
                        Invoke-InterruptionStep -Plan $interruptionPlan -Request "destroy $terraformObjectIdentity" -Apply {
                            $null = $remoteOrganizations.Remove($terraformObjectIdentity)
                            Remove-Item -LiteralPath $terraformStatePath
                            ''
                        } -Interrupt $interrupt
                    } elseif (-not (Test-Path -LiteralPath $terraformStatePath)) {
                        Invoke-InterruptionStep -Plan $interruptionPlan -Request "apply $terraformObjectIdentity" -Identity $terraformObjectIdentity -Apply {
                            $remoteOrganizations[$terraformObjectIdentity] = "id-$terraformObjectIdentity"
                            Set-Content -LiteralPath $terraformStatePath -Value "id-$terraformObjectIdentity"
                            ''
                        } -Interrupt $interrupt
                    }
                    return
                }
                output {
                    $data = if (Test-Path -LiteralPath $terraformStatePath) { $publicOutputs } else { @{} }
                    return ConvertTo-Json -InputObject $data -Depth 10 -Compress
                }
                default { throw "Unexpected Terraform command '$verb'." }
            }
        }
        $captureLocal = {
            $files = @{}
            foreach ($root in @($runnerArguments.StatePath, $runnerArguments.ArtifactsPath)) {
                if (Test-Path -LiteralPath $root) {
                    foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse) {
                        $files[$file.FullName] = [IO.File]::ReadAllText($file.FullName)
                    }
                }
            }
            return $files
        }
        $restoreLocal = {
            param($Files)
            foreach ($root in @($runnerArguments.StatePath, $runnerArguments.ArtifactsPath)) {
                if (Test-Path -LiteralPath $root) {
                    foreach ($file in Get-ChildItem -LiteralPath $root -File -Recurse) {
                        Remove-Item -LiteralPath $file.FullName -Force
                    }
                }
            }
            foreach ($file in $Files.Keys) {
                $null = New-Item -ItemType Directory -Path (Split-Path $file -Parent) -Force
                [IO.File]::WriteAllText($file, $Files[$file])
            }
        }
        $reset = { $remoteOrganizations.Clear(); & $restoreLocal @{} }
        $snapshot = {
            $outputs = Join-Path $runnerArguments.ArtifactsPath $(if ($Rulesets) { 'scoped.rulesets.json' } else { 'scoped.json' })
            @{
                remote = @{} + $remoteOrganizations
                local = & $captureLocal
                outputs = $(if (Test-Path -LiteralPath $outputs) { Get-Content -LiteralPath $outputs -Raw | ConvertFrom-Json -AsHashtable })
            }
        }
    }

    AfterEach {
        Remove-Item -LiteralPath Function:\terraform -ErrorAction SilentlyContinue
        $env:PLATFORM_GITHUB_TOKENS = $oldTokens
    }

    It 'resumes every organization after each <Root> root process boundary' -ForEach @(
        @{ Root = 'ordinary'; Rulesets = $false }
        @{ Root = 'rulesets'; Rulesets = $true }
    ) {
        $run = { $null = & $runner -Action apply -Rulesets:$Rulesets @runnerArguments 6>$null }

        $result = @(Invoke-InterruptionMatrix -Plan $interruptionPlan -Reset $reset -Run $run -Snapshot $snapshot `
            -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name "Organization runner ($Root)" -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    Context 'Interrupted teardown' -Tag OrganizationTeardown {
        It 'resumes all organizations and both roots with rulesets destroyed first and empty states skipped' {
            $instance.teardown = @{ allowed = $true }
            ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
            $reset = {
                $remoteOrganizations.Clear()
                & $restoreLocal @{}
                foreach ($stateName in @('terraform.rulesets.tfstate', 'terraform.tfstate')) {
                    foreach ($organizationName in $organizations) {
                        $stateDirectory = Join-Path $runnerArguments.StatePath "scoped/organizations/$organizationName"
                        $null = New-Item -ItemType Directory -Path $stateDirectory -Force
                        $identity = "$organizationName/$stateName"
                        $remoteOrganizations[$identity] = "id-$identity"
                        Set-Content -LiteralPath (Join-Path $stateDirectory $stateName) -Value "id-$identity"
                    }
                }
            }
            $run = {
                $null = & $runner -Action destroy -Rulesets @runnerArguments 6>$null
                $null = & $runner -Action destroy @runnerArguments 6>$null
            }
            $snapshot = { @{ remote = @{} + $remoteOrganizations; local = & $captureLocal } }

            $result = @(Invoke-InterruptionMatrix -Plan $interruptionPlan -Reset $reset -Run $run -Snapshot $snapshot `
                -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

            $report = Format-InterruptionResult -Name 'Organization runner teardown' -Result $result
            Write-Information $report -InformationAction Continue
            @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
            $remoteOrganizations.Count | Should -Be 0
            $expectedRequests = @(
                'destroy demo-platform/terraform.rulesets.tfstate'
                'destroy demo-actions/terraform.rulesets.tfstate'
                'destroy demo-workloads/terraform.rulesets.tfstate'
                'destroy demo-platform/terraform.tfstate'
                'destroy demo-actions/terraform.tfstate'
                'destroy demo-workloads/terraform.tfstate'
            )
            ($interruptionPlan.Requests -join ',') | Should -Be ($expectedRequests -join ',')
            $env:PLATFORM_GITHUB_TOKENS = $null
            & $run
            ($interruptionPlan.Requests -join ',') | Should -Be ($expectedRequests -join ',')
        }
    }
}
