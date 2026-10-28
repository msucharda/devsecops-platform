BeforeAll {
    Import-Module (Join-Path $PSScriptRoot '../WorkflowPreflight.psm1') -Force

    function Save-WorkflowRevision {
        & git -C $repository add --all
        & git -C $repository -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m fixture
        if ($LASTEXITCODE -ne 0) { throw 'Cannot commit workflow fixture.' }
        (& git -C $repository rev-parse HEAD).Trim()
    }

    function New-WorkflowRunnerFixture([string] $RepositoryPath) {
        $modulesPath = Join-Path $RepositoryPath 'platform/modules'
        $null = New-Item -ItemType Directory -Path $modulesPath -Force
        $moduleRoot = Join-Path $modulesPath 'enterprise-baseline'
        Copy-Item -LiteralPath (Join-Path $PSScriptRoot 'fixtures/runner-modules/foundation') -Destination $moduleRoot -Recurse
        $manifestPath = Join-Path $moduleRoot 'module.yaml'
        $manifest = ConvertFrom-Yaml (Get-Content -LiteralPath $manifestPath -Raw)
        $manifest.name = 'enterprise-baseline'
        $manifest.manualPrerequisites = @('liveWorkflowsPromoted')
        ConvertTo-Yaml $manifest | Set-Content -LiteralPath $manifestPath
        $instance = ConvertFrom-Yaml (Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw)
        $instance.modules = @{ 'enterprise-baseline' = @{ parameters = @{} } }
        $instancePath = Join-Path $RepositoryPath 'instance.yaml'
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        @{
            Instance = $instance
            Arguments = @{
                Module = 'enterprise-baseline'
                Action = 'plan'
                InstancePath = $instancePath
                ModulesPath = $modulesPath
                PlatformOrganization = 'demo-platform'
                Backend = 'local'
                StatePath = Join-Path $RepositoryPath 'state'
                ArtifactsPath = Join-Path $RepositoryPath 'artifacts'
                JobSummaryPath = Join-Path $RepositoryPath 'summary.md'
            }
        }
    }
}

Describe 'Workflow uses preflight' {
    BeforeEach {
        $repository = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $workflowDirectory = Join-Path $repository '.github/workflows'
        $null = New-Item -ItemType Directory -Path $workflowDirectory -Force
        & git -c init.defaultBranch=main init --quiet $repository
        & git -C $repository config core.autocrlf false
        if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize workflow fixture.' }
        $workflowPath = Join-Path $workflowDirectory 'deploy.yml'
        @'
name: Deploy
on: push
jobs:
  deploy:
    runs-on: ubuntu-latest
    steps:
      - uses: demo-actions/checkout@0123456789abcdef0123456789abcdef01234567
'@ | Set-Content -LiteralPath $workflowPath
        $revision = Save-WorkflowRevision
    }

    It 'accepts an actions organization reference pinned to a full SHA at a fixed revision' {
        $result = Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions

        $result.Revision | Should -BeExactly $revision
        $result.References | Should -Be 1
        $result.Workflows | Should -Be 1
    }

    It 'checks the committed revision rather than a modified working copy' {
        (Get-Content -LiteralPath $workflowPath -Raw).Replace('0123456789abcdef0123456789abcdef01234567', 'main') |
            Set-Content -LiteralPath $workflowPath

        (Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions).Revision |
            Should -BeExactly $revision
    }

    It 'rejects <Case> references' -ForEach @(
        @{ Case = 'tag'; Value = 'demo-actions/checkout@v4'; Error = '*unsupported uses*' }
        @{ Case = 'branch'; Value = 'demo-actions/checkout@main'; Error = '*unsupported uses*' }
        @{ Case = 'short SHA'; Value = 'demo-actions/checkout@0123456'; Error = '*unsupported uses*' }
        @{ Case = 'other owner'; Value = 'other-actions/checkout@0123456789abcdef0123456789abcdef01234567'; Error = '*uses owner*' }
        @{ Case = 'Docker image'; Value = 'docker://alpine:3'; Error = '*unsupported uses*' }
        @{ Case = 'expression'; Value = '${{ inputs.action }}'; Error = '*unsupported uses*' }
        @{ Case = 'blank'; Value = ''; Error = '*unsupported uses*' }
        @{ Case = 'mapping'; Value = '{ repository: demo-actions/checkout }'; Error = '*unsupported uses*' }
    ) {
        $text = (Get-Content -LiteralPath $workflowPath -Raw) -replace 'demo-actions/checkout@[a-f0-9]{40}', $Value
        Set-Content -LiteralPath $workflowPath -Value $text
        $null = Save-WorkflowRevision

        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } |
            Should -Throw $Error
    }

    It 'follows a local composite action and ignores an unreachable upstream fixture' {
        $actionDirectory = Join-Path $repository '.github/actions/local'
        $fixtureDirectory = Join-Path $repository 'platform/tools/tests/fixtures/action'
        $null = New-Item -ItemType Directory -Path $actionDirectory, $fixtureDirectory -Force
        @'
name: Local composite
description: Fixture
runs:
  using: composite
  steps:
    - uses: demo-actions/checkout@0123456789abcdef0123456789abcdef01234567
    - run: |
        echo "uses: actions/checkout@v4"
      shell: bash
'@ | Set-Content -LiteralPath (Join-Path $actionDirectory 'action.yml')
        "runs:`n  using: composite`n  steps:`n    - uses: actions/checkout@v4" |
            Set-Content -LiteralPath (Join-Path $fixtureDirectory 'action.yml')
        (Get-Content -LiteralPath $workflowPath -Raw).Replace('demo-actions/checkout@0123456789abcdef0123456789abcdef01234567', './.github/actions/local') |
            Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision

        $result = Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions

        $result.References | Should -Be 2
    }

    It 'accepts <Case> pinned references' -ForEach @(
        @{ Case = 'mixed-case owner'; Reference = 'DeMo-AcTiOnS/checkout@0123456789abcdef0123456789abcdef01234567' }
        @{ Case = 'uppercase SHA'; Reference = 'demo-actions/checkout@0123456789ABCDEF0123456789ABCDEF01234567' }
        @{ Case = 'action subpath'; Reference = 'demo-actions/tools/sub/action@0123456789abcdef0123456789abcdef01234567' }
    ) {
        (Get-Content -LiteralPath $workflowPath -Raw).Replace('demo-actions/checkout@0123456789abcdef0123456789abcdef01234567', $Reference) |
            Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        (Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions).References | Should -Be 1
    }

    It 'rejects unsafe local <Case>' -ForEach @(
        @{ Case = 'parent escape'; Reference = './../outside' }
        @{ Case = 'nested parent escape'; Reference = './actions/../outside' }
        @{ Case = 'dot segment'; Reference = './actions/./local' }
        @{ Case = 'empty segment'; Reference = './actions//local' }
        @{ Case = 'backslash'; Reference = './actions\local' }
        @{ Case = 'expression'; Reference = './actions/${{ inputs.name }}' }
    ) {
        (Get-Content -LiteralPath $workflowPath -Raw).Replace('demo-actions/checkout@0123456789abcdef0123456789abcdef01234567', $Reference) |
            Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } |
            Should -Throw '*unsafe local uses*'
    }

    It 'rejects malformed document <Case>' -ForEach @(
        @{ Case = 'missing jobs'; Text = 'name: Empty'; Error = '*jobs mapping*' }
        @{ Case = 'empty jobs'; Text = 'jobs: {}'; Error = '*jobs mapping*' }
        @{ Case = 'jobs sequence'; Text = 'jobs: [deploy]'; Error = '*jobs mapping*' }
        @{ Case = 'scalar job'; Text = 'jobs: { deploy: unknown }'; Error = '*invalid job*' }
        @{ Case = 'missing steps'; Text = 'jobs: { deploy: { runs-on: ubuntu-latest } }'; Error = '*steps sequence*' }
        @{ Case = 'empty steps'; Text = 'jobs: { deploy: { steps: [] } }'; Error = '*steps sequence*' }
        @{ Case = 'steps mapping'; Text = 'jobs: { deploy: { steps: {} } }'; Error = '*steps sequence*' }
        @{ Case = 'scalar step'; Text = 'jobs: { deploy: { steps: [unknown] } }'; Error = '*invalid step*' }
        @{ Case = 'unknown step'; Text = 'jobs: { deploy: { steps: [ { name: unknown } ] } }'; Error = '*unknown step*' }
        @{ Case = 'numeric run'; Text = 'jobs: { deploy: { steps: [ { run: 42 } ] } }'; Error = '*unknown step*' }
        @{ Case = 'empty run'; Text = "jobs: { deploy: { steps: [ { run: '' } ] } }"; Error = '*unknown step*' }
        @{ Case = 'uses and run'; Text = 'jobs: { deploy: { steps: [ { uses: local, run: echo } ] } }'; Error = '*both uses and run*' }
        @{ Case = 'reusable and steps'; Text = 'jobs: { deploy: { uses: local, steps: [] } }'; Error = '*also has steps*' }
        @{ Case = 'multiple documents'; Text = "jobs: {}`n---`njobs: {}"; Error = '*one YAML mapping*' }
        @{ Case = 'root sequence'; Text = '- jobs: {}'; Error = '*one YAML mapping*' }
        @{ Case = 'empty document'; Text = ''; Error = '*' }
        @{ Case = 'invalid syntax'; Text = 'jobs: ['; Error = '*' }
        @{ Case = 'anchor'; Text = 'jobs: { deploy: { steps: [ &step { run: echo } ] } }'; Error = '*anchors and aliases*' }
        @{ Case = 'alias'; Text = 'jobs: { deploy: { steps: [ *unknown ] } }'; Error = '*anchors and aliases*' }
    ) {
        Set-Content -LiteralPath $workflowPath -Value $Text
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } | Should -Throw $Error
    }

    It 'does not let a job named Values hide another job' -Tag Shape {
        @'
jobs:
  Values:
    steps:
      - run: echo harmless
  deploy:
    steps:
      - uses: actions/checkout@v4
'@ | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } |
            Should -Throw '*unsupported uses*'
    }

    It 'checks a document independently as workflow and local action' -Tag Shape {
        @'
jobs:
  harmless:
    steps:
      - run: echo harmless
runs:
  using: composite
  steps:
    - uses: actions/checkout@v4
'@ | Set-Content -LiteralPath (Join-Path $workflowDirectory 'action.yml')
        'jobs: { deploy: { steps: [ { uses: ./.github/workflows } ] } }' | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } |
            Should -Throw '*unsupported uses*'
    }

    It 'traverses local reusable workflow and a composite cycle exactly once' {
        @'
jobs:
  reuse:
    uses: ./.github/workflows/reusable.yaml
'@ | Set-Content -LiteralPath $workflowPath
        @'
jobs:
  remote:
    uses: demo-actions/tools/.github/workflows/build.yml@0123456789abcdef0123456789abcdef01234567
  local:
    steps:
      - uses: ./.github/actions/local
'@ | Set-Content -LiteralPath (Join-Path $workflowDirectory 'reusable.yaml')
        $local = Join-Path $repository '.github/actions/local'
        $null = New-Item -ItemType Directory -Path $local -Force
        "runs:`n  using: composite`n  steps:`n    - uses: ./.github/actions/local" |
            Set-Content -LiteralPath (Join-Path $local 'action.yaml')
        $null = Save-WorkflowRevision

        $result = Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions

        $result.Workflows | Should -Be 2
        $result.References | Should -Be 4
    }

    It 'rejects local target <Case>' -ForEach @(
        @{ Case = 'missing action'; Reference = './missing'; Reusable = $false; Error = '*exactly one action.yml*' }
        @{ Case = 'missing reusable workflow'; Reference = './.github/workflows/missing.yml'; Reusable = $true; Error = '*regular file in HEAD*' }
        @{ Case = 'reusable outside workflows'; Reference = './other/build.yml'; Reusable = $true; Error = '*must be in .github/workflows*' }
    ) {
        $text = if ($Reusable) { "jobs:`n  reuse:`n    uses: $Reference" }
        else { "jobs:`n  local:`n    steps:`n      - uses: $Reference" }
        Set-Content -LiteralPath $workflowPath -Value $text
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } | Should -Throw $Error
    }

    It 'rejects ambiguous local action manifests' {
        $local = Join-Path $repository 'action'
        $null = New-Item -ItemType Directory -Path $local
        foreach ($name in @('action.yml', 'action.yaml')) {
            "runs: { using: composite, steps: [ { run: echo, shell: bash } ] }" | Set-Content -LiteralPath (Join-Path $local $name)
        }
        "jobs: { local: { steps: [ { uses: ./action } ] } }" | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision

        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } |
            Should -Throw '*exactly one action.yml*'
    }

    It 'rejects local action shape <Case>' -Tag Runtime -ForEach @(
        @{ Case = 'missing runs'; Text = 'name: Missing'; Error = '*missing runs mapping*' }
        @{ Case = 'scalar runs'; Text = 'runs: unknown'; Error = '*missing runs mapping*' }
        @{ Case = 'unknown runtime'; Text = 'runs: { using: unknown }'; Error = '*unsupported action runtime or image*' }
        @{ Case = 'sequence runtime'; Text = 'runs: { using: [composite], steps: [ { run: echo } ] }'; Error = '*unsupported action runtime or image*' }
        @{ Case = 'Docker registry image'; Text = 'runs: { using: docker, image: docker://alpine:3 }'; Error = '*unsupported action runtime or image*' }
        @{ Case = 'JavaScript main missing'; Text = 'runs: { using: node24 }'; Error = '*invalid JavaScript action*' }
        @{ Case = 'JavaScript main empty'; Text = "runs: { using: node24, main: '' }"; Error = '*invalid JavaScript action*' }
        @{ Case = 'JavaScript steps'; Text = 'runs: { using: node24, main: index.js, steps: [] }'; Error = '*invalid JavaScript action*' }
        @{ Case = 'composite missing steps'; Text = 'runs: { using: composite }'; Error = '*steps sequence*' }
        @{ Case = 'composite upstream'; Text = 'runs: { using: composite, steps: [ { uses: actions/checkout@v4 } ] }'; Error = '*unsupported uses*' }
    ) {
        $local = Join-Path $repository 'action'
        $null = New-Item -ItemType Directory -Path $local
        Set-Content -LiteralPath (Join-Path $local 'action.yml') -Value $Text
        "jobs: { local: { steps: [ { uses: ./action } ] } }" | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } | Should -Throw $Error
    }

    It 'accepts local JavaScript runtime <Runtime>' -ForEach @(
        @{ Runtime = 'node20' }
        @{ Runtime = 'node24' }
    ) {
        $local = Join-Path $repository 'action'
        $null = New-Item -ItemType Directory -Path $local
        "runs: { using: $Runtime, main: index.js }" | Set-Content -LiteralPath (Join-Path $local 'action.yml')
        "jobs: { local: { steps: [ { uses: ./action } ] } }" | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        (Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions).References | Should -Be 1
    }

    It 'accepts a local Docker action with a committed Dockerfile' -Tag Docker {
        $local = Join-Path $repository 'action'
        $null = New-Item -ItemType Directory -Path $local
        'runs: { using: docker, image: Dockerfile }' | Set-Content -LiteralPath (Join-Path $local 'action.yml')
        'FROM scratch' | Set-Content -LiteralPath (Join-Path $local 'Dockerfile')
        'jobs: { local: { steps: [ { uses: ./action } ] } }' | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision

        (Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions).References | Should -Be 1
    }

    It 'accepts the repository root as a local action' -Tag RootAction {
        'runs: { using: composite, steps: [ { run: echo } ] }' | Set-Content -LiteralPath (Join-Path $repository 'action.yml')
        'jobs: { local: { steps: [ { uses: ./ } ] } }' | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        (Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions).References | Should -Be 1
    }

    It 'rejects local Docker image <Case>' -Tag Docker -ForEach @(
        @{ Case = 'missing'; Image = ''; Error = '*unsupported action runtime or image*' }
        @{ Case = 'numeric'; Image = '42'; Error = '*unsupported action runtime or image*' }
        @{ Case = 'parent escape'; Image = '../Dockerfile'; Error = '*unsupported action runtime or image*' }
        @{ Case = 'different casing'; Image = 'dockerfile'; Error = '*unsupported action runtime or image*' }
        @{ Case = 'uncommitted Dockerfile'; Image = 'Dockerfile'; Error = '*regular file in HEAD*' }
    ) {
        $local = Join-Path $repository 'action'
        $null = New-Item -ItemType Directory -Path $local
        "runs: { using: docker, image: $Image }" | Set-Content -LiteralPath (Join-Path $local 'action.yml')
        'jobs: { local: { steps: [ { uses: ./action } ] } }' | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        'FROM scratch' | Set-Content -LiteralPath (Join-Path $local 'Dockerfile')
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } | Should -Throw $Error
    }

    It 'rejects a Docker image name even when a same-named file exists' -Tag DockerName {
        $local = Join-Path $repository 'action'
        $null = New-Item -ItemType Directory -Path $local
        'runs: { using: docker, image: alpine }' | Set-Content -LiteralPath (Join-Path $local 'action.yml')
        'FROM scratch' | Set-Content -LiteralPath (Join-Path $local 'alpine')
        'jobs: { local: { steps: [ { uses: ./action } ] } }' | Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } |
            Should -Throw '*unsupported action runtime or image*'
    }

    It 'rejects a repository with no live workflows' {
        Remove-Item -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } | Should -Throw '*no live workflows*'
    }

    It 'rejects unreadable Git tree output' {
        Mock git -ModuleName WorkflowPreflight {
            $global:LASTEXITCODE = 0
            'unreadable'
        } -ParameterFilter { 'ls-tree' -in $args }

        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } |
            Should -Throw '*cannot read the Git tree*'
    }

    It 'rejects an instance configuration below the repository root' {
        { Assert-PlatformWorkflowUses -RepositoryPath $workflowDirectory -ActionsOrganization demo-actions } | Should -Throw '*repository root*'
    }

    It 'rejects a missing Git repository' {
        { Assert-PlatformWorkflowUses -RepositoryPath (Join-Path $repository 'missing') -ActionsOrganization demo-actions } |
            Should -Throw '*cannot read Git revision*'
    }

    It 'rejects a changed HEAD before a state-changing operation' {
        $null = Save-WorkflowRevision
        { Assert-PlatformWorkflowRevision -RepositoryPath $repository -Revision $revision } | Should -Throw '*HEAD changed*'
    }

    It 'rejects a non-SHA1 repository instead of accepting an unknown full HEAD SHA' {
        $sha256 = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        & git init --quiet --object-format=sha256 $sha256
        & git -C $sha256 -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m fixture
        if ($LASTEXITCODE -ne 0) { throw 'Cannot initialize SHA256 fixture.' }
        { Assert-PlatformWorkflowUses -RepositoryPath $sha256 -ActionsOrganization demo-actions } | Should -Throw '*full HEAD SHA*'
    }

    It 'requires a regular file for a <Case>' -ForEach @(
        @{ Case = 'workflow'; Target = '.github/workflows/deploy.yml' }
        @{ Case = 'local action'; Target = 'action/action.yml' }
        @{ Case = 'Dockerfile'; Target = 'action/Dockerfile' }
    ) {
        if ($Case -ne 'workflow') {
            $local = Join-Path $repository 'action'
            $null = New-Item -ItemType Directory -Path $local
            $metadata = if ($Case -eq 'Dockerfile') { 'runs: { using: docker, image: Dockerfile }' }
            else { 'runs: { using: composite, steps: [ { run: echo } ] }' }
            $metadata | Set-Content -LiteralPath (Join-Path $local 'action.yml')
            'FROM scratch' | Set-Content -LiteralPath (Join-Path $local 'Dockerfile')
            'jobs: { local: { steps: [ { uses: ./action } ] } }' | Set-Content -LiteralPath $workflowPath
            $null = Save-WorkflowRevision
        }
        $blob = (& git -C $repository rev-parse "HEAD:$Target").Trim()
        & git -C $repository update-index --cacheinfo "120000,$blob,$Target"
        & git -C $repository -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet -m symlink
        if ($LASTEXITCODE -ne 0) { throw 'Cannot commit symlink fixture.' }

        $errorPattern = if ($Case -eq 'Dockerfile') { "*Dockerfile 'action/Dockerfile' must be a regular file in HEAD*" } else { '*regular file in HEAD*' }
        { Assert-PlatformWorkflowUses -RepositoryPath $repository -ActionsOrganization demo-actions } | Should -Throw $errorPattern
    }

    It 'blocks enterprise-baseline <Action> before Terraform for an upstream uses' -ForEach @(
        @{ Action = 'plan' }
        @{ Action = 'apply' }
    ) {
        $fixture = New-WorkflowRunnerFixture $repository
        $runnerArguments = $fixture.Arguments
        $runnerArguments.Action = $Action
        (Get-Content -LiteralPath $workflowPath -Raw).Replace('demo-actions/checkout', 'actions/checkout') |
            Set-Content -LiteralPath $workflowPath
        $null = Save-WorkflowRevision
        function terraform { throw 'Terraform must not run before workflow preflight.' }

        { & (Join-Path $PSScriptRoot '../Invoke-Module.ps1') @runnerArguments } | Should -Throw '*uses owner*'
    }
}

Describe 'Enterprise workflow preflight boundary' {
    BeforeEach {
        $repository = Join-Path $TestDrive ([guid]::NewGuid().ToString('N'))
        $fixture = New-WorkflowRunnerFixture $repository
        $instance = $fixture.Instance
        $runnerArguments = $fixture.Arguments
        $instancePath = $runnerArguments.InstancePath
        $workflowDirectory = Join-Path $repository '.github/workflows'
        $null = New-Item -ItemType Directory -Path $workflowDirectory -Force
        'jobs: { local: { steps: [ { uses: demo-actions/checkout@0123456789abcdef0123456789abcdef01234567 } ] } }' |
            Set-Content -LiteralPath (Join-Path $workflowDirectory 'deploy.yml')
        & git -c init.defaultBranch=main init --quiet $repository
        & git -C $repository config core.autocrlf false
        $revision = Save-WorkflowRevision
        $runner = Join-Path $PSScriptRoot '../Invoke-Module.ps1'
    }

    It 'keeps liveWorkflowsPromoted mandatory for <Action> despite valid workflows' -ForEach @(
        @{ Action = 'plan' }
        @{ Action = 'apply' }
    ) {
        $instance.manualPrerequisites.liveWorkflowsPromoted = $false
        ConvertTo-Yaml $instance | Set-Content -LiteralPath $instancePath
        $runnerArguments.Action = $Action
        function terraform { throw 'Terraform must not run.' }
        { & $runner @runnerArguments } | Should -Throw '*requires manual prerequisite confirmations*liveWorkflowsPromoted*'
    }

    It 'refuses a missing platform organization' {
        $runnerArguments.Remove('PlatformOrganization')
        { & $runner @runnerArguments } | Should -Throw '*requires PlatformOrganization*'
    }

    It 'reaches Terraform only after a successful preflight' {
        function terraform { throw 'Reached Terraform after preflight.' }
        { & $runner @runnerArguments } | Should -Throw '*Reached Terraform after preflight*'
    }

    It 'stops after interruption and a HEAD change before Terraform <Operation>' -Tag Boundary -ForEach @(
        @{ Operation = 'plan'; Boundary = 'init' }
        @{ Operation = 'apply'; Boundary = 'show' }
    ) {
        $runnerArguments.Action = $Operation
        function terraform {
            $global:LASTEXITCODE = 0
            if ($args[1] -eq 'init') {
                $null = New-Item -ItemType Directory -Path $env:TF_DATA_DIR -Force
                '{"backend":{"type":"local"}}' | Set-Content -LiteralPath (Join-Path $env:TF_DATA_DIR 'terraform.tfstate')
            }
            if ($args[1] -eq $Boundary) {
                & git -C $repository -c user.name=Fixture -c user.email=fixture@example.invalid commit --quiet --allow-empty -m changed
                $global:LASTEXITCODE = 0
            }
            if ($args[1] -eq 'show') { return '{"planned_values":{"outputs":{}},"output_changes":{}}' }
            if ($args[1] -eq $Operation) { throw 'Terraform must not run on the changed revision.' }
        }
        { & $runner @runnerArguments } | Should -Throw '*HEAD changed*'
    }
}
