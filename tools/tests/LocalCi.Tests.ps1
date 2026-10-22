BeforeAll {
    $toolRoot = Split-Path $PSScriptRoot -Parent
    $repoRoot = Split-Path $toolRoot -Parent
    Import-Module (Join-Path $toolRoot 'LocalCi.psm1') -Force
    $workflowPath = Join-Path $repoRoot '.github/workflows/ci.yml'

    function Build-FakeRepository {
        $root = Join-Path $TestDrive "repo-$([guid]::NewGuid().ToString('N'))"
        $files = @{
            'tools/Foo.ps1' = 'param()'
            'tools/Checked.ps1' = "# security-check: demo-check`nfunction Test-Demo { }"
            'tools/tests/Foo.Tests.ps1' = "`$script = Join-Path `$PSScriptRoot '../Foo.ps1'"
            'tools/tests/FooBar.Tests.ps1' = "`$script = 'FooBar.ps1'"
            'tools/tests/Foo.Interruption.Tests.ps1' = "Describe 'x' -Tag Interruption { 'Foo.ps1' }"
            'tools/tests/Mod.Tests.ps1' = "'modules/alpha/main.tf'"
            'tools/tests/ModQuote.Tests.ps1' = "Join-Path `$repo 'modules/beta'"
            'tools/tests/Manifest.Tests.ps1' = "'gamma/module.yaml'"
            'tools/tests/Api.Tests.ps1' = 'Get-GitHubApiFixture -Name apps/get-app.owner-enterprise'
            'tools/tests/ApiOther.Tests.ps1' = 'Get-GitHubApiFixture -Name apps/get-app.owner-simple-user'
            'tools/tests/Contract.Tests.ps1' = "Join-Path `$PSScriptRoot 'fixtures/github-api'"
            'tools/tests/Fix.Tests.ps1' = "Join-Path `$PSScriptRoot 'fixtures/rulesets'"
        }
        foreach ($path in $files.Keys) {
            $full = Join-Path $root $path
            $null = New-Item -ItemType Directory -Force -Path (Split-Path $full -Parent)
            Set-Content -LiteralPath $full -Value $files[$path]
        }
        return $root
    }

    function Get-Selection {
        param([string[]] $Changed, [string[]] $Root = @(), [switch] $AllRoots)
        Get-LocalCiSelection -RepoPath $fakeRepo -ChangedFile $Changed -TerraformRoot $Root -AllTerraformRoots:$AllRoots
    }
}

Describe 'Local CI reads ci.yml' {
    BeforeAll {
        $setting = Get-CiWorkflowSetting -WorkflowPath $workflowPath
        Import-Module powershell-yaml
        $workflow = ConvertFrom-Yaml -Yaml (Get-Content -LiteralPath $workflowPath -Raw)
    }

    It 'takes the actionlint version and arguments from the CI step' {
        $run = (@($workflow.jobs.platform.steps | Where-Object { $_['name'] -eq 'Validate deployment workflow syntax' }))[0].run.Trim()
        $run | Should -BeExactly "go run github.com/rhysd/actionlint/cmd/actionlint@v$($setting.ActionlintVersion) $($setting.ActionlintArguments -join ' ')"
        $setting.ActionlintArguments | Should -Contain '.github/workflows/ci.yml'
        $setting.InstanceWorkflowFiles | Should -Contain 'templates/instance/.github/workflows/import-release.yml'
    }

    It 'takes the tool pins from the CI actions' {
        $setting.TerraformVersion | Should -Match '^\d+\.\d+\.\d+$'
        $setting.PlatformTerraformVersion | Should -BeExactly $setting.TerraformVersion
        $setting.TflintVersion | Should -Match '^\d+\.\d+\.\d+$'
        $setting.TrivyVersion | Should -Match '^\d+\.\d+\.\d+$'
    }

    It 'runs the same Terraform commands as the <Name> CI step' -ForEach @(
        @{ Name = 'Terraform format' }, @{ Name = 'Terraform validate' }, @{ Name = 'Terraform test' }, @{ Name = 'TFLint' }, @{ Name = 'Trivy' }
    ) {
        $run = $setting.TerraformRunCommands[$Name]
        $ciCommands = @($run.Split("`n") | ForEach-Object { $_.Trim() } | Where-Object { $_ -cmatch '^(terraform|tflint|trivy) ' })
        $localCommands = @((Get-LocalCiTerraformStepCommand -Root '"$TF_ROOT"')[$Name] | ForEach-Object { $_ -join ' ' })
        $localCommands | Should -BeExactly $ciCommands
    }

    It 'refuses a ci.yml whose <Label>' -ForEach @(
        @{ Label = 'pwsh step is missing'; Find = 'name: Check PowerShell'; Replace = 'name: Check scripts' }
        @{ Label = 'actionlint command changed form'; Find = '-shellcheck= -pyflakes= .github/workflows/ci.yml'; Replace = '-shellcheck= -pyflakes= .github/workflows/ci.yml && echo done |' }
        @{ Label = 'TFLint pin is missing'; Find = 'tflint_version:'; Replace = 'tflint_release:' }
    ) {
        $path = Join-Path $TestDrive 'ci.yml'
        $text = Get-Content -LiteralPath $workflowPath -Raw
        $text.Contains($Find) | Should -BeTrue
        Set-Content -LiteralPath $path -Value $text.Replace($Find, $Replace)

        { Get-CiWorkflowSetting -WorkflowPath $path } | Should -Throw '*Update tools/LocalCi.psm1*'
    }
}

Describe 'Local CI selection for -Changed' {
    BeforeAll {
        $fakeRepo = Build-FakeRepository
    }

    It 'selects a changed test file' {
        (Get-Selection -Changed 'tools/tests/FooBar.Tests.ps1').PesterPath | Should -BeExactly @('tools/tests/FooBar.Tests.ps1')
    }

    It 'ignores a deleted test file' {
        (Get-Selection -Changed 'tools/tests/Gone.Tests.ps1').PesterPath | Should -BeNullOrEmpty
    }

    It 'maps a changed script to the tests that name it, interruption tests separately' {
        $selection = Get-Selection -Changed 'tools/Foo.ps1'
        $selection.PesterPath | Should -BeExactly @('tools/tests/Foo.Tests.ps1')
        $selection.InterruptionPath | Should -BeExactly @('tools/tests/Foo.Interruption.Tests.ps1')
        $selection.Warning | Should -BeNullOrEmpty
        $selection.AllPester | Should -BeFalse
    }

    It 'does not map a script to a test that names a longer file' {
        (Get-Selection -Changed 'tools/Bar.ps1').PesterPath | Should -BeNullOrEmpty
        (Get-Selection -Changed 'tools/Foo.ps1').PesterPath | Should -Not -Contain 'tools/tests/FooBar.Tests.ps1'
    }

    It 'warns when a PowerShell file maps to no test' {
        $selection = Get-Selection -Changed 'tools/Bar.ps1'
        $selection.Warning | Should -BeExactly @('tools/Bar.ps1 maps to no Pester test.')
        $selection.AllPester | Should -BeFalse
    }

    It 'maps a module change to tests that contain <Token>' -ForEach @(
        @{ File = 'modules/alpha/variables.tf'; Token = 'modules/alpha/'; Test = 'tools/tests/Mod.Tests.ps1' }
        @{ File = 'modules/beta/main.tf'; Token = "modules/beta'"; Test = 'tools/tests/ModQuote.Tests.ps1' }
        @{ File = 'modules/gamma/module.yaml'; Token = 'gamma/module.yaml'; Test = 'tools/tests/Manifest.Tests.ps1' }
    ) {
        (Get-Selection -Changed $File).PesterPath | Should -BeExactly @($Test)
    }

    It 'does not map <File> to an unrelated module test' -ForEach @(
        @{ File = 'modules/gamma/main.tf' }
        @{ File = 'modules/alphabet/main.tf' }
    ) {
        (Get-Selection -Changed $File).PesterPath | Should -BeNullOrEmpty
    }

    It 'maps an API fixture to the tests that use it and to the contract test' {
        (Get-Selection -Changed 'tools/tests/fixtures/github-api/apps/get-app.owner-enterprise.json').PesterPath |
            Should -BeExactly @('tools/tests/Api.Tests.ps1', 'tools/tests/Contract.Tests.ps1')
    }

    It 'maps another fixture to the tests that contain its directory' {
        (Get-Selection -Changed 'tools/tests/fixtures/rulesets/main.tf').PesterPath | Should -BeExactly @('tools/tests/Fix.Tests.ps1')
        (Get-Selection -Changed 'tools/tests/fixtures/vendoring/a.json').PesterPath | Should -BeNullOrEmpty
    }

    It 'escalates to every Pester and interruption test when <File> changes' -ForEach @(
        @{ File = 'tools/Invoke-Tests.ps1' }
        @{ File = 'tools/requirements.psd1' }
    ) {
        $selection = Get-Selection -Changed $File
        $selection.AllPester | Should -BeTrue
        $selection.AllInterruption | Should -BeTrue
        $selection.Reason | Should -BeLike "$File changed*"
    }

    It 'does not escalate for a documentation change' {
        $selection = Get-Selection -Changed 'docs/readme.md'
        $selection.AllPester | Should -BeFalse
        $selection.PesterPath | Should -BeNullOrEmpty
        $selection.TerraformRoot | Should -BeNullOrEmpty
        $selection.AllMutation | Should -BeFalse
        $selection.MutationCheck | Should -BeNullOrEmpty
    }

    It 'selects only the deepest Terraform root that contains a changed file' {
        $roots = @('modules/alpha', 'modules/alpha/sub', 'modules/beta')
        (Get-Selection -Changed 'modules/alpha/sub/main.tf' -Root $roots).TerraformRoot | Should -BeExactly @('modules/alpha/sub')
        (Get-Selection -Changed 'modules/alpha/main.tf' -Root $roots).TerraformRoot | Should -BeExactly @('modules/alpha')
        (Get-Selection -Changed 'modules/alphabet/main.tf' -Root $roots).TerraformRoot | Should -BeNullOrEmpty
    }

    It 'selects every Terraform root when ci.yml changed the Terraform steps' {
        (Get-Selection -Changed '.github/workflows/ci.yml' -Root @('modules/a', 'modules/b') -AllRoots).TerraformRoot |
            Should -BeExactly @('modules/a', 'modules/b')
        (Get-Selection -Changed '.github/workflows/ci.yml' -Root @('modules/a', 'modules/b')).TerraformRoot | Should -BeNullOrEmpty
    }

    It 'mutates only the marked checks of a changed file' {
        $selection = Get-Selection -Changed 'tools/Checked.ps1'
        $selection.MutationCheck | Should -BeExactly @('demo-check')
        $selection.AllMutation | Should -BeFalse
        (Get-Selection -Changed 'tools/Foo.ps1').MutationCheck | Should -BeNullOrEmpty
    }

    It 'mutates every check when <File> changes' -ForEach @(
        @{ File = 'tools/tests/security-checks.psd1' }
        @{ File = 'tools/MutationTesting.psm1' }
    ) {
        (Get-Selection -Changed $File).AllMutation | Should -BeTrue
    }

    It 'maps the real repository changes of this tool to its own tests' {
        $selection = Get-LocalCiSelection -RepoPath $repoRoot -ChangedFile @('tools/LocalCi.psm1', 'tools/Wait-PullRequestChecks.ps1') -TerraformRoot @()
        $selection.PesterPath | Should -Contain 'tools/tests/LocalCi.Tests.ps1'
        $selection.PesterPath | Should -Contain 'tools/tests/WaitPullRequestChecks.Tests.ps1'
    }
}

Describe 'Local CI preflight' {
    BeforeAll {
        $setting = [pscustomobject]@{ TerraformVersion = '1.16.5'; TflintVersion = '0.60.0'; TrivyVersion = '0.72.0'; ActionlintVersion = '1.7.7' }
        $requirements = @{ Runtime = @{ 'powershell-yaml' = '0.4.12' }; Development = @{ Pester = '5.7.1' } }

        function Get-Problem {
            param([hashtable] $Tool = @{}, [hashtable] $Module = @{}, [version] $PowerShell = '7.4.6', [switch] $Terraform)
            $tools = @{ terraform = '1.16.5'; tflint = '0.60.0'; trivy = '0.72.0'; actionlint = '1.7.7'; go = $null }
            foreach ($key in $Tool.Keys) { $tools[$key] = $Tool[$key] }
            $modules = @{ 'powershell-yaml' = @('0.4.12'); Pester = @('5.7.1', '3.4.0') }
            foreach ($key in $Module.Keys) { $modules[$key] = $Module[$key] }
            @(Get-LocalCiPreflightProblem -PowerShellVersion $PowerShell -Requirements $requirements -Setting $setting -NeedsTerraformTools:$Terraform `
                -ModuleProbe { param($name) $modules[$name] }.GetNewClosure() -ToolProbe { param($name) $tools[$name] }.GetNewClosure())
        }
    }

    It 'passes when every tool and module matches CI' {
        Get-Problem -Terraform | Should -BeNullOrEmpty
    }

    It 'fails on <Label>' -ForEach @(
        @{ Label = 'old PowerShell'; Arguments = @{ PowerShell = '7.3.9' }; Message = '*PowerShell 7.4*' }
        @{ Label = 'a module in another version'; Arguments = @{ Module = @{ Pester = @('5.6.0') } }; Message = '*Pester 5.7.1*Install-ToolDependencies.ps1 -Development' }
        @{ Label = 'a missing module'; Arguments = @{ Module = @{ 'powershell-yaml' = @() } }; Message = '*powershell-yaml 0.4.12*Install-ToolDependencies.ps1 -Development' }
        @{ Label = 'missing terraform'; Arguments = @{ Tool = @{ terraform = $null } }; Message = '*terraform is missing*' }
        @{ Label = 'missing tflint for a root'; Arguments = @{ Terraform = $true; Tool = @{ tflint = $null } }; Message = '*tflint is missing*' }
        @{ Label = 'another tflint version'; Arguments = @{ Terraform = $true; Tool = @{ tflint = '0.59.1' } }; Message = '*tflint 0.59.1 differs*' }
        @{ Label = 'missing trivy for a root'; Arguments = @{ Terraform = $true; Tool = @{ trivy = $null } }; Message = '*trivy is missing*' }
        @{ Label = 'missing actionlint and go'; Arguments = @{ Tool = @{ actionlint = $null } }; Message = '*actionlint_1.7.7_checksums.txt*' }
        @{ Label = 'another actionlint without go'; Arguments = @{ Tool = @{ actionlint = '1.7.6' } }; Message = '*actionlint 1.7.7 is version 1.7.6*' }
    ) {
        $problems = Get-Problem @Arguments
        $errors = @($problems | Where-Object Severity -eq 'Error')
        $errors.Count | Should -Be 1
        $errors[0].Message | Should -BeLike $Message
    }

    It 'only warns on <Label>' -ForEach @(
        @{ Label = 'another terraform version'; Arguments = @{ Tool = @{ terraform = '1.16.6' } } }
        @{ Label = 'another trivy version'; Arguments = @{ Terraform = $true; Tool = @{ trivy = '0.76.1' } } }
    ) {
        $problems = Get-Problem @Arguments
        @($problems | Where-Object Severity -eq 'Error') | Should -BeNullOrEmpty
        @($problems | Where-Object Severity -eq 'Warning').Count | Should -Be 1
    }

    It 'does not require tflint and trivy without a Terraform root' {
        Get-Problem -Tool @{ tflint = $null; trivy = $null } | Should -BeNullOrEmpty
    }

    It 'accepts go instead of actionlint' {
        Get-Problem -Tool @{ actionlint = $null; go = 'go version go1.23.4 linux/amd64' } | Should -BeNullOrEmpty
    }
}

Describe 'Local CI temp directory' {
    It 'removes what an interrupted run left behind and keeps the directory' {
        $temp = Join-Path $TestDrive 'local-ci-tmp'
        $null = New-Item -ItemType Directory -Force -Path (Join-Path $temp 'actionlint-1/.github/workflows')
        Set-Content -LiteralPath (Join-Path $temp 'step-1.ps1') -Value 'exit 1'
        Set-Content -LiteralPath (Join-Path $temp '.hidden') -Value 'x'

        Clear-LocalCiTemp -Path $temp

        Test-Path -LiteralPath $temp -PathType Container | Should -BeTrue
        @(Get-ChildItem -LiteralPath $temp -Force) | Should -BeNullOrEmpty
    }

    It 'creates a missing temp directory' {
        $temp = Join-Path $TestDrive 'missing-tmp'
        Clear-LocalCiTemp -Path $temp
        Test-Path -LiteralPath $temp -PathType Container | Should -BeTrue
    }
}

Describe 'Local CI output parsing' {
    It 'extracts the failed test, its location and the first error line' {
        $esc = [char] 27
        $lines = @(
            'Describing Demo'
            "  $esc[31m[-] fails on purpose 12ms (10ms|2ms)$esc[0m"
            '   Expected 1, but got 2.'
            '   at $value | Should -Be 1, /repo/tools/tests/Demo.Tests.ps1:7'
            '  [+] passes 3ms (1ms|2ms)'
            "Tests Passed: 4, $esc[90mFailed: 1, Skipped: 0, Inconclusive: 0, NotRun: 2$esc[0m"
        )

        Get-PesterFailureDetail -Line $lines | Should -BeExactly @('[-] fails on purpose 12ms (10ms|2ms)', '    at /repo/tools/tests/Demo.Tests.ps1:7', '    Expected 1, but got 2.')
        $count = Get-PesterCount -Line $lines
        $count.Passed | Should -Be 4
        $count.Failed | Should -Be 1
        $count.NotRun | Should -Be 2
    }
}

Describe 'Invoke-Tests.ps1 -Path' {
    It 'runs only the given file under StrictMode and fails on <Label>' -ForEach @(
        @{ Label = 'an undefined variable'; Body = "It 'reads' { `$undefinedVariable | Should -BeNullOrEmpty }"; Expected = 'fail' }
        @{ Label = 'nothing when the test passes'; Body = "It 'passes' { 1 | Should -Be 1 }"; Expected = 'pass' }
    ) {
        $path = Join-Path $TestDrive "Probe$([guid]::NewGuid().ToString('N')).Tests.ps1"
        Set-Content -LiteralPath $path -Value "Describe 'probe' { $Body }"

        $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $toolRoot 'Invoke-Tests.ps1') -Path $path 2>&1 | Out-String

        if ($Expected -eq 'pass') { $LASTEXITCODE | Should -Be 0 -Because $output; $output | Should -Match 'Tests Passed: 1,' }
        else { $LASTEXITCODE | Should -Not -Be 0; $output | Should -Match 'undefinedVariable' }
    }

    It 'fails when a given path does not exist' {
        & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File (Join-Path $toolRoot 'Invoke-Tests.ps1') -Path (Join-Path $TestDrive 'Missing.Tests.ps1') 2>&1 | Out-Null
        $LASTEXITCODE | Should -Not -Be 0
    }
}

Describe 'Invoke-LocalCi.ps1' {
    BeforeAll {
        $localCi = Join-Path $toolRoot 'Invoke-LocalCi.ps1'
        function Invoke-LocalCiProcess {
            param([string[]] $Arguments)
            $log = Join-Path $TestDrive "local-ci-$([guid]::NewGuid().ToString('N')).log"
            $output = & ([Environment]::ProcessPath) -NoProfile -NonInteractive -File $localCi @Arguments -LogPath $log 2>&1 | Out-String
            [pscustomobject]@{ ExitCode = $LASTEXITCODE; Output = $output; Log = $log }
        }
    }

    It 'refuses -Changed together with -Full with exit code 2' {
        $result = Invoke-LocalCiProcess -Arguments @('-Changed', '-Full', '-Plan')
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'mutually exclusive'
    }

    It 'refuses an invalid -Base with exit code 2' {
        $result = Invoke-LocalCiProcess -Arguments @('-Base', 'refs/heads/no-such-branch-for-local-ci', '-Plan')
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match "Invalid -Base"
    }

    It 'refuses a nested run with exit code 2 before it touches the temp directory' {
        $env:INVOKE_LOCAL_CI_ACTIVE = '1'
        try { $result = Invoke-LocalCiProcess -Arguments @('-Base', 'HEAD') }
        finally { Remove-Item Env:INVOKE_LOCAL_CI_ACTIVE }
        $result.ExitCode | Should -Be 2
        $result.Output | Should -Match 'nested runs are refused'
        $result.Output | Should -Not -Match 'PASS Preflight'
    }

    It 'prints the plan without running a step' {
        $result = Invoke-LocalCiProcess -Arguments @('-Base', 'HEAD', '-Plan')
        $result.ExitCode | Should -Be 0 -Because $result.Output
        $result.Output | Should -Match 'Mode: Changed'
        $result.Output | Should -Match 'Pester: '
        $result.Output | Should -Match 'Terraform roots: '
        $result.Output | Should -Not -Match 'PASS Preflight'
        Get-Content -LiteralPath $result.Log -Raw | Should -Match 'Mode: Changed'
    }
}
