BeforeAll {
    $tools = Split-Path $PSScriptRoot -Parent
    $verifier = Join-Path $tools 'Test-DeploymentCandidate.ps1'
    $authorize = Join-Path $tools 'Test-DevelopmentDeploymentAuthorization.ps1'
    Get-Module -Name DevelopmentCandidate -All | Remove-Module -Force
    Import-Module (Join-Path $tools 'DevelopmentCandidate.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
}

Describe 'Development candidate trust boundary' {
    It 'does not fall back to development when standard release validation fails without external approval' {
        Test-Path -LiteralPath $verifier | Should -BeTrue
        $candidate = Join-Path $TestDrive 'candidate'
        $null = New-Item -ItemType Directory -Path $candidate
        { & $verifier -CandidatePath $candidate -TrustedPath $candidate -WorkPath (Join-Path $TestDrive 'work') `
            -PlatformOrganization demo-platform -ApprovalJson '' -ReferenceRepository '' } | Should -Throw
    }

    Describe 'Development standard-deployment exclusion' {
        It 'allows a standard deployment only without an outstanding development disposition' {
            { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') -DevelopmentApprovalJson '' } | Should -Not -Throw
        }

        It 'does not silently resume standard deploy after <Case>' -ForEach @(
            @{ Case = 'a pending development apply'; Value = '{"operation":"apply"}' }
            @{ Case = 'expired approval'; Value = '{"expiresAt":"2020-01-01"}' }
            @{ Case = 'an unreadable approval'; Value = 'invalid' }
        ) {
            { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') -DevelopmentApprovalJson $Value } |
                Should -Throw '*locked*outstanding development approval*'
        }

        It 'permits only the exact protected <Operation> transition while keeping the outstanding approval' -ForEach @(
            @{ Operation = 'adopt' }
            @{ Operation = 'rollback' }
        ) {
            $approval = @{ revision = 'b' * 40; digest = 'c' * 64 }
            $decision = @{
                version = 1L; operation = $Operation; repository = 'https://example.test/platform/instance'
                mainRevision = 'd' * 40; candidateRevision = 'b' * 40; candidateDigest = 'c' * 64
                approvedBy = 'reviewer'; approvalUrl = 'https://example.test/approval/1'
                expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
            }
            $arguments = @{
                DevelopmentApprovalJson = ConvertTo-Json $approval
                DispositionJson = ConvertTo-Json $decision
                RepositoryUrl = $decision.repository; Revision = $decision.mainRevision; EventName = 'workflow_dispatch'
            }
            { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Not -Throw
            foreach ($field in @('version', 'operation', 'repository', 'mainRevision', 'candidateRevision',
                'candidateDigest', 'approvedBy', 'approvalUrl', 'expiresAt')) {
                $changed = $decision.Clone()
                $changed.Remove($field)
                $arguments.DispositionJson = ConvertTo-Json $changed
                { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw
            }
            foreach ($field in @('repository', 'mainRevision', 'candidateRevision', 'candidateDigest')) {
                $changed = $decision.Clone()
                $changed[$field] = $changed[$field].ToUpperInvariant()
                $arguments.DispositionJson = ConvertTo-Json $changed
                { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw "*$field*"
                $changed[$field] = @($decision[$field])
                $arguments.DispositionJson = ConvertTo-Json $changed
                { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw "*$field*"
            }
            foreach ($case in @(
                @{ Field = 'version'; Value = '1' }, @{ Field = 'version'; Value = 2L },
                @{ Field = 'version'; Value = @(1L) }, @{ Field = 'operation'; Value = 'ADOPT' },
                @{ Field = 'approvedBy'; Value = 42L }, @{ Field = 'approvalUrl'; Value = 42L },
                @{ Field = 'approvedBy'; Value = ' ' }, @{ Field = 'approvalUrl'; Value = ' ' },
                @{ Field = 'expiresAt'; Value = 'invalid' }
            )) {
                $changed = $decision.Clone()
                $changed[$case.Field] = $case.Value
                $arguments.DispositionJson = ConvertTo-Json $changed
                { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw
            }
            $arguments.DispositionJson = ConvertTo-Json $decision
            $arguments.EventName = 'pull_request_target'
            { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw '*for main*'
            $arguments.EventName = 'PUSH'
            { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw '*for main*'
            $arguments.EventName = 'workflow_dispatch'
            foreach ($value in @('[]', '[{}]', '"not-an-object"')) {
                $arguments.DispositionJson = $value
                { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw '*for main*'
            }
            $arguments.DispositionJson = ConvertTo-Json $decision
            foreach ($value in @('[]', '[{}]', '"not-an-object"')) {
                $arguments.DevelopmentApprovalJson = $value
                { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw '*for main*'
            }
            $arguments.DevelopmentApprovalJson = ConvertTo-Json $approval
            $changed = $decision.Clone()
            $changed.repository = ' '
            $arguments.RepositoryUrl = ' '
            $arguments.DispositionJson = ConvertTo-Json $changed
            { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw '*repository*'
            $arguments.RepositoryUrl = $decision.repository
            $arguments.DispositionJson = ConvertTo-Json $decision
            $arguments.DevelopmentApprovalJson = ''
            { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw '*locked*'
            $arguments.DevelopmentApprovalJson = ConvertTo-Json $approval
            $decision.expiresAt = [DateTimeOffset]::UtcNow.AddHours(-1).ToString('o')
            $arguments.DispositionJson = ConvertTo-Json $decision
            { & (Join-Path $tools 'Test-StandardDeploymentAvailability.ps1') @arguments } | Should -Throw '*expired*'
        }
    }

    Describe 'Development approval continuity' {
        It 'checks current protected state rather than a stale job output after <Case>' -ForEach @(
            @{ Case = 'revocation'; Current = ''; Attempt = '1'; AuthorizedAttempt = '1'; Error = '*revoked or replaced*' }
            @{ Case = 'replacement'; Current = '{"revision":"changed"}'; Attempt = '1'; AuthorizedAttempt = '1'; Error = '*revoked or replaced*' }
            @{ Case = 'failed-job rerun'; Current = '{"revision":"exact"}'; Attempt = '2'; AuthorizedAttempt = '1'; Error = '*fresh dispatch*' }
            @{ Case = 'whole-workflow rerun'; Current = '{"revision":"exact"}'; Attempt = '2'; AuthorizedAttempt = '2'; Error = '*fresh dispatch*' }
            @{ Case = 'attempt mismatch'; Current = '{"revision":"exact"}'; Attempt = '1'; AuthorizedAttempt = '2'; Error = '*fresh dispatch*' }
        ) {
            { & (Join-Path $tools 'Test-DevelopmentApprovalContinuity.ps1') -CurrentApproval $Current `
                -ExpectedApproval '{"revision":"exact"}' -ExpectedAttempt $AuthorizedAttempt -RunAttempt $Attempt } |
                Should -Throw $Error
        }

        It 'allows only the unchanged current approval in a fresh dispatch' {
            $receipt = Join-Path $TestDrive 'attempt.txt'
            & (Join-Path $tools 'Test-DevelopmentApprovalContinuity.ps1') -CurrentApproval '{"revision": "exact"}' `
                -ExpectedApproval '{"revision":"exact"}' -ExpectedAttempt '1' -RunAttempt '1' -GitHubOutputPath $receipt
            Get-Content $receipt | Should -Be 'attempt=1'
        }

        It 'does not resume development after an explicit standard transition' {
            { & (Join-Path $tools 'Test-DevelopmentApprovalContinuity.ps1') -CurrentApproval '{"revision":"exact"}' `
                -ExpectedApproval '{"revision":"exact"}' -ExpectedAttempt '1' -RunAttempt '1' -Disposition '{"operation":"adopt"}' } |
                Should -Throw '*locked*disposition*'
        }
    }

    Describe 'Development immutable checkout' {
        BeforeEach {
            $repository = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $repository
            & git -C $repository init --quiet
            & git -C $repository config core.autocrlf false
            [IO.File]::WriteAllText((Join-Path $repository 'file.txt'), 'abc')
            & git -C $repository add --all
            & git -C $repository -c user.name=Fixture -c user.email=fixture@example.test commit --quiet -m baseline
        }

        It 'hashes exact tracked bytes with the SHA256 of the known literal abc' {
            $snapshot = Get-DevelopmentCandidateSnapshot -Path $repository
            $snapshot.Files['file.txt'] | Should -Be '100644:ba7816bf8f01cfea414140de5dae2223b00361a396177a9cb410ff61f20015ad'
            $snapshot.Revision | Should -Match '^[a-f0-9]{40}$'
            $snapshot.Digest | Should -Be '9622593169cb2038ce7bed4c4ad9c9f4b3aef3c295c6daada71bbbbce42b69ec'
            { Assert-DevelopmentCandidateRevision -Path $repository -Revision $snapshot.Revision `
                -ExpectedRevision $snapshot.Revision -BaseRevision $snapshot.Revision } | Should -Not -Throw
        }

        It 'rejects a repository subdirectory rather than authorizing its parent' {
            $child = Join-Path $repository 'child'
            $null = New-Item -ItemType Directory -Path $child
            { Get-DevelopmentCandidateSnapshot -Path $child } | Should -Throw '*repository root*'
        }

        It 'rejects a repository-root directory link' {
            $link = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            $null = New-Item -ItemType $kind -Path $link -Target $repository
            { Get-DevelopmentCandidateSnapshot -Path $link } | Should -Throw '*root must not be a symbolic link*'
        }

        It 'rejects untracked working files' {
            [IO.File]::WriteAllText((Join-Path $repository 'extra.txt'), 'unapproved')
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw '*clean checkout*'
        }

        It 'rejects ignored payloads in the candidate but permits only the trusted dependency cache' {
            [IO.File]::WriteAllText((Join-Path $repository '.gitignore'), ".ignored`nplatform/tools/.dependencies/`n")
            & git -C $repository add --all
            & git -C $repository -c user.name=Fixture -c user.email=fixture@example.test commit --quiet -m ignore
            $cache = Join-Path $repository 'platform/tools/.dependencies'
            $null = New-Item -ItemType Directory -Path $cache -Force
            [IO.File]::WriteAllText((Join-Path $cache 'cache.bin'), 'cache')
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw '*ignored files*'
            { Get-DevelopmentCandidateSnapshot -Path $repository -TrustedRuntime } | Should -Not -Throw
            [IO.File]::WriteAllText((Join-Path $repository '.ignored'), 'unapproved')
            { Get-DevelopmentCandidateSnapshot -Path $repository -TrustedRuntime } | Should -Throw '*ignored files*'
        }

        It 'rejects a symlink or submodule mode: <Mode>' -ForEach @(
            @{ Mode = '120000' }
            @{ Mode = '160000' }
        ) {
            $blob = (& git -C $repository rev-parse HEAD:file.txt).Trim()
            & git -C $repository update-index --add --cacheinfo "$Mode,$blob,file.txt"
            & git -C $repository -c user.name=Fixture -c user.email=fixture@example.test commit --quiet -m unsupported
            & git -C $repository update-index --assume-unchanged file.txt
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw '*only regular tracked files*'
        }

        It 'rejects an empty tracked tree' {
            & git -C $repository rm --quiet file.txt
            & git -C $repository -c user.name=Fixture -c user.email=fixture@example.test commit --quiet -m empty
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw '*no tracked files*'
        }

        It 'rejects invalid full Git revision metadata before inspecting its tree: <Metadata>' -ForEach @(
            @{ Metadata = 'not-a-revision' }
            @{ Metadata = ('A' * 40) }
        ) {
            Mock Invoke-DevelopmentGit -ModuleName DevelopmentCandidate -ParameterFilter {
                $Arguments[0] -eq 'rev-parse' -and $Arguments[1] -eq 'HEAD'
            } -MockWith { $Metadata }
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw '*full commit SHA*'
        }

        It 'rejects a noncanonical Git tree entry rather than accepting a new object type' {
            $blob = (& git -C $repository hash-object --no-filters -- file.txt).Trim()
            Mock Invoke-DevelopmentGit -ModuleName DevelopmentCandidate -ParameterFilter {
                $Arguments[0] -eq 'ls-tree'
            } -MockWith { "100644 BLOB $blob`tfile.txt" }
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw '*only regular tracked files*'
        }

        It 'rejects a literal backslash in a Git tree path before resolving it on disk' {
            Mock Invoke-DevelopmentGit -ModuleName DevelopmentCandidate -ParameterFilter {
                $Arguments[0] -eq 'ls-tree'
            } -MockWith { "100644 blob $('a' * 40)`tunsafe\file.txt" }
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw '*unsafe path*'
        }

        It 'rejects a file that became a reparse point even if Git reports a regular entry' {
            $file = Join-Path $repository 'file.txt'
            Mock Get-Item -ModuleName DevelopmentCandidate -ParameterFilter { $LiteralPath -eq $file } -MockWith {
                [pscustomobject]@{ Attributes = [IO.FileAttributes]::ReparsePoint }
            }
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw '*symbolic link*'
        }

        It 'rejects a tracked parent directory link with <GitState>' -ForEach @(
            @{ GitState = 'actual Git status'; GitReportsClean = $false }
            @{ GitState = 'a clean Git report'; GitReportsClean = $true }
        ) {
            $directory = Join-Path $repository 'nested'
            $null = New-Item -ItemType Directory -Path $directory
            [IO.File]::WriteAllText((Join-Path $directory 'nested.txt'), 'abc')
            & git -C $repository add --all
            & git -C $repository -c user.name=Fixture -c user.email=fixture@example.test commit --quiet -m nested
            $outside = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            Move-Item -LiteralPath $directory -Destination $outside
            $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
            $null = New-Item -ItemType $kind -Path $directory -Target $outside
            if ($GitReportsClean) {
                Mock Invoke-DevelopmentGit -ModuleName DevelopmentCandidate -ParameterFilter {
                    $Arguments[0] -eq 'status'
                } -MockWith { '' }
            }
            $errorPattern = if ($IsWindows -or $GitReportsClean) { '*symbolic link*' } else { '*clean checkout*' }
            { Get-DevelopmentCandidateSnapshot -Path $repository } | Should -Throw $errorPattern
        }

        It 'rejects an uppercase claimed revision even if both caller values repeat it' {
            { Assert-DevelopmentCandidateRevision -Path $repository -Revision ('A' * 40) `
                -ExpectedRevision ('A' * 40) -BaseRevision ('a' * 40) } | Should -Throw '*authorized PR head*'
        }

        It 'rejects a noncanonical actual revision even when its letters otherwise match the approval' {
            { Assert-DevelopmentCandidateRevision -Path $repository -Revision ('B' * 40) `
                -ExpectedRevision ('b' * 40) -BaseRevision ('a' * 40) } | Should -Throw '*authorized PR head*'
        }

        It 'rejects an unexpected head or a baseline outside its history: <Case>' -ForEach @(
            @{ Case = 'different head'; Expected = ('a' * 40); Baseline = $null; Error = '*authorized PR head*' }
            @{ Case = 'malformed head'; Expected = 'not-a-sha'; Baseline = $null; Error = '*authorized PR head*' }
            @{ Case = 'unrelated baseline'; Expected = $null; Baseline = ('a' * 40); Error = '*descend*verified baseline*' }
        ) {
            $revision = (& git -C $repository rev-parse HEAD).Trim()
            if ($null -eq $Expected) { $Expected = $revision }
            if ($null -eq $Baseline) { $Baseline = $revision }
            { Assert-DevelopmentCandidateRevision -Path $repository -Revision $revision `
                -ExpectedRevision $Expected -BaseRevision $Baseline } | Should -Throw $Error
        }
    }

    Describe 'Development exact-content approval' {
        BeforeEach {
            $approval = @{
                version = 1L; repository = 'https://example.ghe.com/platform/instance'
                revision = 'b' * 40; baseRevision = 'a' * 40; digest = 'c' * 64
                pullRequest = '42'; operation = 'apply'; approvedBy = 'reviewer'
                approvalUrl = 'https://example.ghe.com/platform/instance/pull/42#approval'
                expiresAt = [DateTimeOffset]::UtcNow.AddHours(1).ToString('o')
            }
            $approvalArguments = @{
                Approval = $approval; ReferenceRepository = $approval.repository; RepositoryUrl = $approval.repository
                Revision = $approval.revision; BaseRevision = $approval.baseRevision; Digest = $approval.digest
                PullRequest = '42'; Operation = 'apply'
            }
        }

        It 'accepts the externally approved exact reference content and operation' {
            { Assert-DevelopmentCandidateApproval @approvalArguments } | Should -Not -Throw
        }

        It 'rejects approval <Field> mismatch before the credential handoff' -ForEach @(
            @{ Field = 'repository'; Value = 'https://example.ghe.com/customer/instance' }
            @{ Field = 'revision'; Value = ('d' * 40) }
            @{ Field = 'baseRevision'; Value = ('d' * 40) }
            @{ Field = 'digest'; Value = ('d' * 64) }
            @{ Field = 'pullRequest'; Value = '43' }
            @{ Field = 'pullRequest'; Value = 42L }
            @{ Field = 'revision'; Value = ('B' * 40) }
            @{ Field = 'operation'; Value = 'plan' }
            @{ Field = 'version'; Value = '1' }
            @{ Field = 'version'; Value = 2L }
            @{ Field = 'approvedBy'; Value = '' }
            @{ Field = 'approvedBy'; Value = 42L }
            @{ Field = 'approvalUrl'; Value = '' }
            @{ Field = 'expiresAt'; Value = '2020-01-01T00:00:00.0000000+00:00' }
            @{ Field = 'expiresAt'; Value = 'invalid' }
            @{ Field = 'expiresAt'; Value = @('2026-12-01T10:00:00.0000000+00:00') }
        ) {
            $approval[$Field] = $Value
            { Assert-DevelopmentCandidateApproval @approvalArguments } | Should -Throw "*$Field*"
        }

        It 'rejects a noncanonical operation even when the approval repeats it' {
            $approval.operation = 'APPLY'
            $approvalArguments.Operation = 'APPLY'
            { Assert-DevelopmentCandidateApproval @approvalArguments } | Should -Throw '*operation must be plan or apply*'
        }

        It 'rejects an absent, array-valued or candidate-supplied approval' -ForEach @(
            @{ Value = $null }
            @{ Value = @(@{ version = 1L }) }
        ) {
            $approvalArguments.Approval = $Value
            { Assert-DevelopmentCandidateApproval @approvalArguments } | Should -Throw '*external JSON object*'
        }

        It 'rejects a different or unconfigured reference repository' -ForEach @(
            @{ Value = '' }
            @{ Value = 'https://example.ghe.com/customer/instance' }
            @{ Value = 'https://EXAMPLE.ghe.com/platform/instance' }
        ) {
            $approvalArguments.ReferenceRepository = $Value
            { Assert-DevelopmentCandidateApproval @approvalArguments } | Should -Throw '*restricted*reference repository*'
        }

        It 'rejects an empty reference even when both caller values are empty' {
            $approvalArguments.ReferenceRepository = ''
            $approvalArguments.RepositoryUrl = ''
            { Assert-DevelopmentCandidateApproval @approvalArguments } | Should -Throw '*restricted*reference repository*'
        }

        It 'rejects a missing approval field: <Field>' -ForEach @(
            foreach ($field in @('version', 'repository', 'revision', 'baseRevision', 'digest', 'pullRequest',
                'operation', 'approvedBy', 'approvalUrl', 'expiresAt')) { @{ Field = $field } }
        ) {
            $approval.Remove($Field)
            { Assert-DevelopmentCandidateApproval @approvalArguments } | Should -Throw "*$Field*"
        }
    }

    Describe 'Development editable boundary' {
        It 'accepts only a concrete change within the module implementation boundary' {
            { Assert-DevelopmentCandidateBoundary -Baseline @{ 'platform/modules/demo/main.tf' = 'old' } `
                -Candidate @{ 'platform/modules/demo/main.tf' = 'new' } } | Should -Not -Throw
        }

        It 'rejects changes to <Path>' -ForEach @(
            @{ Path = '.github/workflows/development.yml' }
            @{ Path = '.platform-bootstrap.json' }
            @{ Path = 'instance.yaml' }
            @{ Path = 'vendoring/actions.json' }
            @{ Path = 'platform/modules/demo/module.yaml' }
            @{ Path = 'platform/tools/Test-DeploymentCandidate.ps1' }
            @{ Path = 'platform/tools/DevelopmentCandidate.psm1' }
            @{ Path = 'platform/tools/DevelopmentControl.psm1' }
            @{ Path = 'platform/tools/DevelopmentTokenLifecycle.psm1' }
            @{ Path = 'platform/tools/Read-DevelopmentControl.ps1' }
            @{ Path = 'platform/tools/New-PlatformGitHubToken.ps1' }
            @{ Path = 'platform/tools/New-DevelopmentStateSnapshot.ps1' }
            @{ Path = 'platform/tools/PlatformTools.psm1' }
            @{ Path = 'platform/tools/.dependencies/payload.ps1' }
            @{ Path = 'Platform/modules/demo/main.tf' }
        ) {
            { Assert-DevelopmentCandidateBoundary -Baseline @{ $Path = 'old' } -Candidate @{ $Path = 'new' } } |
                Should -Throw '*protected authorization or instance content*'
        }

        It 'rejects an empty development change' {
            { Assert-DevelopmentCandidateBoundary -Baseline @{ 'platform/modules/demo/main.tf' = 'same' } `
                -Candidate @{ 'platform/modules/demo/main.tf' = 'same' } } | Should -Throw '*exact development change*'
        }
    }

    Describe 'Development protected execution closure' {
        BeforeEach {
            $graph = @{
                controller = @{
                    prerequisites = @()
                    permissions = @{ azure = @(); microsoftGraph = @('Group.Create'); githubApp = @{} }
                }
                rules = @{
                    prerequisites = @()
                    permissions = @{ azure = @(); microsoftGraph = @(); githubApp = @{} }
                }
            }
            $baselineFiles = @{
                'platform/tools/Invoke-Module.ps1' = 'runner'
                'platform/tools/PlatformTools.psm1' = 'platform-tools'
                'platform/tools/ToolDependencies.psm1' = 'dependency-verifier'
                'platform/tools/requirements.psd1' = 'pins'
                'platform/tools/WorkflowPreflight.psm1' = 'workflow-preflight'
                'platform/tools/vendor/powershell-yaml/runtime.psm1' = 'verified-package'
                'platform/modules/shared/scripts/GitHubRetry.ps1' = 'shared-transport'
                'platform/modules/controller/main.tf' = 'identity'
                'platform/modules/controller/.terraform.lock.hcl' = 'provider-pins'
                'platform/modules/rules/main.tf' = 'rules-before'
            }
            $candidateFiles = $baselineFiles.Clone()
            $candidateFiles['platform/modules/rules/main.tf'] = 'rules-after'
        }

        It 'derives protected execution from identity authority instead of a module-name deny list' {
            @(Get-DevelopmentProtectedModule -Modules $graph) | Should -Be @('controller')
            Import-Module (Join-Path $tools 'PlatformTools.psm1')
            $released = Get-PlatformModuleGraph -ModulesPath (Join-Path $tools '../modules')
            @(Get-DevelopmentProtectedModule -Modules $released | Sort-Object) | Should -Be @('emu-identity', 'organization-roles', 'organizations')
        }

        It 'protects declared <Capability> independently of module name' -ForEach @(
            @{ Capability = 'Azure grants' }
            @{ Capability = 'directory roles' }
            @{ Capability = 'enterprise App authority' }
            @{ Capability = 'organization membership authority' }
        ) {
            $graph.controller.permissions.microsoftGraph = @()
            switch ($Capability) {
                'Azure grants' { $graph.controller.permissions.azure = @('Contributor') }
                'directory roles' { $graph.controller.permissions.entraDirectoryRoles = @(@{ phase = 'apply'; scope = 'enterpriseApplication' }) }
                'enterprise App authority' {
                    $graph.controller.permissions.githubApp = @{ apply = @{ permissions = @{ enterprise_organizations = 'write' } } }
                }
                'organization membership authority' {
                    $graph.controller.permissions.githubApp = @{ apply = @{ permissions = @{ members = 'write' } } }
                }
            }
            @(Get-DevelopmentProtectedModule -Modules $graph) | Should -Be @('controller')
        }

        It 'does not freeze ordinary organization-only authority needed by the Rulesets scenario' {
            $graph.rules.permissions.githubApp = @{ apply = @{ permissions = @{ organization_administration = 'write' } } }
            @(Get-DevelopmentProtectedModule -Modules $graph) | Should -Be @('controller')
        }

        It 'allows the representative rules change without executing identity candidates' {
            { Assert-DevelopmentProtectedExecution -Baseline $baselineFiles -Candidate $candidateFiles -Modules $graph } |
                Should -Not -Throw
        }

        It 'rejects changed protected executable input <Path>' -ForEach @(
            @{ Path = 'platform/tools/Invoke-Module.ps1' }
            @{ Path = 'platform/tools/PlatformTools.psm1' }
            @{ Path = 'platform/tools/ToolDependencies.psm1' }
            @{ Path = 'platform/tools/requirements.psd1' }
            @{ Path = 'platform/tools/WorkflowPreflight.psm1' }
            @{ Path = 'platform/tools/vendor/powershell-yaml/runtime.psm1' }
            @{ Path = 'platform/modules/shared/scripts/GitHubRetry.ps1' }
            @{ Path = 'platform/modules/controller/main.tf' }
            @{ Path = 'platform/modules/controller/.terraform.lock.hcl' }
            @{ Path = 'platform/modules/controller/external-hook.ps1' }
        ) {
            $candidateFiles[$Path] = 'candidate-controlled'
            { Assert-DevelopmentProtectedExecution -Baseline $baselineFiles -Candidate $candidateFiles -Modules $graph } |
                Should -Throw '*protected executable closure*'
        }

        It 'rejects deletion from the protected executable closure' {
            $candidateFiles.Remove('platform/modules/controller/main.tf')
            { Assert-DevelopmentProtectedExecution -Baseline $baselineFiles -Candidate $candidateFiles -Modules $graph } |
                Should -Throw '*protected executable closure*'
        }

        It 'does not accept candidate artifacts as protected identity dependencies' {
            $graph.controller.prerequisites = @('rules')
            { Assert-DevelopmentProtectedExecution -Baseline $baselineFiles -Candidate $candidateFiles -Modules $graph } |
                Should -Throw '*protected executable closure*'
        }

        It 'includes transitive prerequisites in the protected execution closure' {
            $graph.controller.prerequisites = @('rules')
            @(Get-DevelopmentProtectedModule -Modules $graph | Sort-Object) | Should -Be @('controller', 'rules')
            $candidateFiles['platform/modules/rules/main.tf'] = $baselineFiles['platform/modules/rules/main.tf']
            { Assert-DevelopmentProtectedExecution -Baseline $baselineFiles -Candidate $candidateFiles -Modules $graph } |
                Should -Not -Throw
        }

        It 'refuses a candidate App with <Permission> write authority over the reference repository' -ForEach @(
            @{ Permission = 'administration' }; @{ Permission = 'contents' }; @{ Permission = 'actions' }; @{ Permission = 'workflows' }
            @{ Permission = 'organization_administration' }; @{ Permission = 'environments' }
            @{ Permission = 'secrets' }; @{ Permission = 'actions_variables' }; @{ Permission = 'organization_secrets' }
            @{ Permission = 'organization_actions_variables' }; @{ Permission = 'custom_properties' }
            @{ Permission = 'unknown_future_permission' }
        ) {
            $instance = @{
                credentials = @{ rules = @{ apply = @{ githubApp = 'rules-app' } } }
                githubApps = @{ 'rules-app' = @{
                    permissions = @{ $Permission = 'write' }; resources = @{ organizations = @('platform') }
                } }
            }
            { Assert-DevelopmentPhaseAuthority -Instance $instance -Modules $graph -Repository platform/instance } |
                Should -Throw '*reference repository authority*'
        }

        It 'refuses organization authority even when repository selection excludes the reference' {
            $instance = @{
                credentials = @{ rules = @{ apply = @{ githubApp = 'rules-app' } } }
                githubApps = @{ 'rules-app' = @{
                    permissions = @{ organization_administration = 'write' }
                    resources = @{ organizations = @('platform'); repositories = @{ platform = @() } }
                } }
            }
            { Assert-DevelopmentPhaseAuthority -Instance $instance -Modules $graph -Repository platform/instance } |
                Should -Throw '*reference repository authority*'
        }

        It 'refuses an enterprise installation in a candidate-executing context' {
            $instance = @{
                credentials = @{ rules = @{ apply = @{ githubApp = 'rules-app' } } }
                githubApps = @{ 'rules-app' = @{ permissions = @{ contents = 'write' }; resources = @{ enterprise = $true } } }
            }
            { Assert-DevelopmentPhaseAuthority -Instance $instance -Modules $graph -Repository platform/instance } |
                Should -Throw '*enterprise installation authority*'
        }

        It 'requires the exact repository for the phase authority inspection' {
            { Assert-DevelopmentPhaseAuthority -Instance @{} -Modules $graph -Repository platform/instance/extra } |
                Should -Throw '*exact reference repository*'
        }

        It 'accepts only a nonempty immutable prerequisite artifact ID: <Value>' -ForEach @(
            @{ Value = '' }; @{ Value = '0' }; @{ Value = '1,2' }; @{ Value = 'name' }; @{ Value = '-1' }; @{ Value = ' 123' }
        ) {
            { Assert-DevelopmentPrerequisiteArtifact -ArtifactId $Value } | Should -Throw '*immutable prerequisite artifact ID*'
        }

        It 'accepts the exact immutable prerequisite artifact ID returned by the upload action' {
            { Assert-DevelopmentPrerequisiteArtifact -ArtifactId '1234567890' } | Should -Not -Throw
        }

        It 'permits repository writes only outside the reference repository' {
            $instance = @{
                credentials = @{ rules = @{ apply = @{ githubApp = 'rules-app' } } }
                githubApps = @{ 'rules-app' = @{
                    permissions = @{ administration = 'write'; contents = 'write' }
                    resources = @{ organizations = @('actions') }
                } }
            }
            { Assert-DevelopmentPhaseAuthority -Instance $instance -Modules $graph -Repository platform/instance } |
                Should -Not -Throw
            $instance.githubApps['rules-app'].resources = @{ organizations = @('platform'); repositories = @{ platform = @('other') } }
            { Assert-DevelopmentPhaseAuthority -Instance $instance -Modules $graph -Repository platform/instance } |
                Should -Not -Throw
            $instance.githubApps['rules-app'].resources.repositories.platform = @('instance')
            { Assert-DevelopmentPhaseAuthority -Instance $instance -Modules $graph -Repository platform/instance } |
                Should -Throw '*reference repository authority*'
        }
    }

    Describe 'Development dispatch authorization' {
        BeforeEach {
            $savedTeam = $env:PLATFORM_TEAM_SLUG
            $savedTokens = $env:PLATFORM_GITHUB_TOKENS
            $env:PLATFORM_TEAM_SLUG = 'platform-team'
            $env:PLATFORM_GITHUB_TOKENS = '{"platform":"membership-token"}'
            $pull = Get-GitHubApiFixture -Name pulls/get -Set @{
                number = 42; state = 'open'; merged = $false; draft = $false
                'head.sha' = ('b' * 40); 'base.sha' = ('a' * 40)
                'head.ref' = 'feature/development'; 'base.ref' = 'main'
                'head.repo.id' = 1; 'base.repo.id' = 1
                'head.repo.full_name' = 'platform/instance'; 'base.repo.full_name' = 'platform/instance'
                'user.type' = 'User'; 'user.login' = 'member'
            }
            $arguments = @{
                PullRequest = '42'; Revision = 'b' * 40; WorkPath = Join-Path $TestDrive ([guid]::NewGuid())
                Repository = 'platform/instance'; Ref = 'refs/heads/main'; Sha = 'a' * 40
                EventName = 'workflow_dispatch'; ApiUrl = 'https://api.example.test'; ServerUrl = 'https://example.test'; ReadToken = 'read-only'
            }
            Mock Invoke-RestMethod {
                param($Uri)
                if ($Uri -like '*/pulls/42') { return ,$pull }
                if ($Uri -like '*/teams/platform-team') {
                    return [pscustomobject](Get-GitHubApiFixture -Name teams/get-by-name -Set @{ slug = 'platform-team' })
                }
                if ($Uri -like '*/memberships/member') {
                    return [pscustomobject](Get-GitHubApiFixture -Name teams/get-membership-for-user-in-org)
                }
                throw "Unexpected API: $Uri"
            }
        }

        AfterEach {
            $env:PLATFORM_TEAM_SLUG = $savedTeam
            $env:PLATFORM_GITHUB_TOKENS = $savedTokens
        }

        It 'preserves origin and active platform-team membership on a manually dispatched candidate' {
            $preflight = & $authorize @arguments -Preflight
            $preflight.Eligible | Should -BeTrue
            $preflight.Allowed | Should -BeFalse
            $result = & $authorize @arguments
            $result.Allowed | Should -BeTrue
            $result.Revision | Should -Be ('b' * 40)
        }

        It 'refuses a <Case> before authorizing a candidate' -ForEach @(
            # Deliberately invalid scalar discriminator in an otherwise valid PR fixture.
            @{ Case = 'empty-array head'; Change = { $pull.head.sha = @() }; Error = '*head or trusted base changed*' }
            @{ Case = 'array head SHA'; Change = { $pull.head.sha = @('b' * 40) }; Error = '*head or trusted base changed*' }
            @{ Case = 'null head SHA'; Change = { $pull.head.sha = $null }; Error = '*head or trusted base changed*' }
            @{ Case = 'array head object'; Change = { $pull.head = @($pull.head) }; Error = '*head or trusted base changed*' }
            @{ Case = 'null head object'; Change = { $pull.head = $null }; Error = '*head or trusted base changed*' }
            @{ Case = 'empty-array base'; Change = { $pull.base.sha = @() }; Error = '*head or trusted base changed*' }
            @{ Case = 'array base SHA'; Change = { $pull.base.sha = @('a' * 40) }; Error = '*head or trusted base changed*' }
            @{ Case = 'null base SHA'; Change = { $pull.base.sha = $null }; Error = '*head or trusted base changed*' }
            @{ Case = 'array base object'; Change = { $pull.base = @($pull.base) }; Error = '*head or trusted base changed*' }
            @{ Case = 'null base object'; Change = { $pull.base = $null }; Error = '*head or trusted base changed*' }
            @{ Case = 'empty-array PR state'; Change = { $pull.state = @() }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'array PR state'; Change = { $pull.state = @('open') }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'null PR state'; Change = { $pull.state = $null }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'string PR number'; Change = { $pull.number = '42' }; Error = '*specified open*' }
            @{ Case = 'array PR number'; Change = { $pull.number = @(42) }; Error = '*specified open*' }
            @{ Case = 'changed head'; Change = { $pull.head.sha = 'c' * 40 }; Error = '*head or trusted base changed*' }
            @{ Case = 'noncanonical head'; Change = { $pull.head.sha = 'B' * 40 }; Error = '*head or trusted base changed*' }
            @{ Case = 'changed base'; Change = { $pull.base.sha = 'c' * 40 }; Error = '*head or trusted base changed*' }
            @{ Case = 'noncanonical base'; Change = { $pull.base.sha = 'A' * 40 }; Error = '*head or trusted base changed*' }
            @{ Case = 'closed PR'; Change = { $pull.state = 'closed' }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'noncanonical PR state'; Change = { $pull.state = 'OPEN' }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'merged PR'; Change = { $pull.merged = $true }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'draft PR'; Change = { $pull.draft = $true }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'wrong PR'; Change = { $pull.number = 43 }; Error = '*specified open*' }
            @{ Case = 'fork'; Change = { $pull.head.repo.id = 2 }; Error = '*not authorized*fork*' }
            @{ Case = 'App author'; Change = { $pull.user.type = 'Bot' }; Error = '*not authorized*App*' }
            @{ Case = 'vendoring branch'; Change = { $pull.head.ref = 'vendor/release/test' }; Error = '*not authorized*vendoring*' }
            @{ Case = 'non-main dispatch'; Change = { $arguments.Ref = 'refs/heads/feature' }; Error = '*protected main*' }
            @{ Case = 'noncanonical main dispatch'; Change = { $arguments.Ref = 'refs/heads/MAIN' }; Error = '*protected main*' }
            @{ Case = 'automatic event'; Change = { $arguments.EventName = 'push' }; Error = '*manual dispatch*' }
            @{ Case = 'noncanonical event'; Change = { $arguments.EventName = 'WORKFLOW_DISPATCH' }; Error = '*manual dispatch*' }
            @{ Case = 'malformed dispatch SHA'; Change = { $arguments.Sha = 'not-a-sha' }; Error = '*immutable protected main*' }
            @{ Case = 'noncanonical dispatch SHA'; Change = { $arguments.Sha = 'A' * 40; $pull.base.sha = 'A' * 40 }; Error = '*immutable protected main*' }
            @{ Case = 'malformed revision'; Change = { $arguments.Revision = 'not-a-sha' }; Error = '*exact PR number and head SHA*' }
            @{ Case = 'noncanonical revision'; Change = { $arguments.Revision = 'B' * 40; $pull.head.sha = 'B' * 40 }; Error = '*exact PR number and head SHA*' }
            @{ Case = 'malformed PR'; Change = { $arguments.PullRequest = '../42' }; Error = '*exact PR number and head SHA*' }
            @{ Case = 'malformed repository'; Change = { $arguments.Repository = '../platform/instance' }; Error = '*exact PR number and head SHA*' }
            @{ Case = 'missing workflow token'; Change = { $arguments.ReadToken = '' }; Error = '*read-only workflow token*' }
            @{ Case = 'nullable PR author'; Change = { $pull.user = $null }; Error = '*readable human PR author*' }
            @{ Case = 'missing PR author'; Change = { $pull.Remove('user') }; Error = '*readable human PR author*' }
            @{ Case = 'missing PR author login'; Change = { $pull.user.Remove('login') }; Error = '*readable human PR author*' }
            @{ Case = 'empty PR author login'; Change = { $pull.user.login = '' }; Error = '*readable human PR author*' }
            @{ Case = 'non-string PR author login'; Change = { $pull.user.login = @('contributor') }; Error = '*readable human PR author*' }
            @{ Case = 'nullable head repository'; Change = { $pull.head.repo = $null }; Error = '*not authorized*fork*' }
            # Intentionally invalid API response: the single PR operation must return an object, not an array.
            @{ Case = 'non-object PR'; Change = { $pull = @($pull) }; Error = '*specified open*' }
            @{ Case = 'unknown merged state'; Change = { $pull.merged = $null }; Error = '*specified open*' }
            @{ Case = 'unknown draft state'; Change = { $pull.draft = $null }; Error = '*specified open*' }
        ) {
            . $Change
            { & $authorize @arguments -Preflight } | Should -Throw $Error
        }

        It 'does not transmit the workflow token to an unrelated or non-HTTPS API: <Api>' -ForEach @(
            @{ Api = 'https://api.other.test' }
            @{ Api = 'http://api.example.test' }
            @{ Api = 'https://api.example.test/unexpected' }
        ) {
            $arguments.ApiUrl = $Api
            { & $authorize @arguments -Preflight } | Should -Throw '*current HTTPS GitHub Cloud server*'
            Should -Invoke Invoke-RestMethod -Times 0
        }

        It 'rejects an unsafe server identity: <Server>' -ForEach @(
            @{ Server = 'http://example.test' }
            @{ Server = 'https://example.test:8443' }
            @{ Server = 'https://user@example.test' }
            @{ Server = 'https://example.test?unexpected=true' }
            @{ Server = 'https://example.test#fragment' }
            @{ Server = 'https://example.test/path' }
        ) {
            $arguments.ServerUrl = $Server
            { & $authorize @arguments -Preflight } | Should -Throw '*current HTTPS GitHub Cloud server*'
            Should -Invoke Invoke-RestMethod -Times 0
        }
    }
}
