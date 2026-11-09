BeforeAll {
    $tools = Split-Path $PSScriptRoot -Parent
    $verifier = Join-Path $tools 'Test-DeploymentCandidate.ps1'
    $authorize = Join-Path $tools 'Test-DevelopmentDeploymentAuthorization.ps1'
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
            @{ Field = 'operation'; Value = 'plan' }
            @{ Field = 'version'; Value = '1' }
            @{ Field = 'version'; Value = 2L }
            @{ Field = 'approvedBy'; Value = '' }
            @{ Field = 'approvalUrl'; Value = '' }
            @{ Field = 'expiresAt'; Value = '2020-01-01T00:00:00.0000000+00:00' }
            @{ Field = 'expiresAt'; Value = 'invalid' }
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
        ) {
            $approvalArguments.ReferenceRepository = $Value
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
            @{ Path = 'platform/tools/New-PlatformGitHubToken.ps1' }
            @{ Path = 'platform/tools/PlatformTools.psm1' }
            @{ Path = 'platform/tools/.dependencies/payload.ps1' }
        ) {
            { Assert-DevelopmentCandidateBoundary -Baseline @{ $Path = 'old' } -Candidate @{ $Path = 'new' } } |
                Should -Throw '*protected authorization or instance content*'
        }

        It 'rejects an empty development change' {
            { Assert-DevelopmentCandidateBoundary -Baseline @{ 'platform/modules/demo/main.tf' = 'same' } `
                -Candidate @{ 'platform/modules/demo/main.tf' = 'same' } } | Should -Throw '*exact development change*'
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
            @{ Case = 'changed head'; Change = { $pull.head.sha = 'c' * 40 }; Error = '*head or trusted base changed*' }
            @{ Case = 'changed base'; Change = { $pull.base.sha = 'c' * 40 }; Error = '*head or trusted base changed*' }
            @{ Case = 'closed PR'; Change = { $pull.state = 'closed' }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'merged PR'; Change = { $pull.merged = $true }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'draft PR'; Change = { $pull.draft = $true }; Error = '*open, unmerged, ready PR*' }
            @{ Case = 'wrong PR'; Change = { $pull.number = 43 }; Error = '*specified open*' }
            @{ Case = 'fork'; Change = { $pull.head.repo.id = 2 }; Error = '*not authorized*fork*' }
            @{ Case = 'App author'; Change = { $pull.user.type = 'Bot' }; Error = '*not authorized*App*' }
            @{ Case = 'vendoring branch'; Change = { $pull.head.ref = 'vendor/release/test' }; Error = '*not authorized*vendoring*' }
            @{ Case = 'non-main dispatch'; Change = { $arguments.Ref = 'refs/heads/feature' }; Error = '*protected main*' }
            @{ Case = 'automatic event'; Change = { $arguments.EventName = 'push' }; Error = '*manual dispatch*' }
            @{ Case = 'malformed dispatch SHA'; Change = { $arguments.Sha = 'not-a-sha' }; Error = '*immutable protected main*' }
            @{ Case = 'malformed revision'; Change = { $arguments.Revision = 'not-a-sha' }; Error = '*exact PR number and head SHA*' }
            @{ Case = 'malformed PR'; Change = { $arguments.PullRequest = '../42' }; Error = '*exact PR number and head SHA*' }
            @{ Case = 'malformed repository'; Change = { $arguments.Repository = '../platform/instance' }; Error = '*exact PR number and head SHA*' }
            @{ Case = 'missing workflow token'; Change = { $arguments.ReadToken = '' }; Error = '*read-only workflow token*' }
            @{ Case = 'nullable PR author'; Change = { $pull.user = $null }; Error = '*' }
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
