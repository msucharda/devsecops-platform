BeforeAll {
    $toolsPath = Split-Path $PSScriptRoot -Parent
    $selector = Join-Path $toolsPath 'Select-InstanceModules.ps1'
    $fixtures = Join-Path $PSScriptRoot 'fixtures/modules'
}

Describe 'Instance module selection' {
    It 'adds transitive prerequisites once and excludes unrelated modules' {
        $instance = Join-Path $TestDrive 'instance.yaml'
        @'
instance:
  name: example
modules:
  service:
    parameters: {}
  application: {}
'@ | Set-Content -LiteralPath $instance

        $json = & $selector -ModulesPath $fixtures -InstancePath $instance

        $json | Should -Be '["application","foundation","service"]'
    }

    It 'always returns a JSON array for <Case>' -ForEach @(
        @{ Case = 'no selected modules'; Yaml = 'modules: {}'; Expected = '[]' }
        @{ Case = 'one independent module'; Yaml = 'modules: {observer: {}}'; Expected = '["observer"]' }
        @{ Case = 'a module and its prerequisite'; Yaml = 'modules: {application: {}}'; Expected = '["application","foundation"]' }
    ) {
        $instance = Join-Path $TestDrive 'instance.yaml'
        $Yaml | Set-Content -LiteralPath $instance

        & $selector -ModulesPath $fixtures -InstancePath $instance | Should -Be $Expected
    }

    It 'writes the same selection to the GitHub job output without replacing existing outputs' {
        $instance = Join-Path $TestDrive 'instance.yaml'
        'modules: {application: {}}' | Set-Content -LiteralPath $instance
        $githubOutput = Join-Path $TestDrive 'github-output'
        [IO.File]::WriteAllText($githubOutput, "previous=value`n")

        $json = & $selector -ModulesPath $fixtures -InstancePath $instance -GitHubOutputPath $githubOutput

        $json | Should -Be '["application","foundation"]'
        [IO.File]::ReadAllText($githubOutput) | Should -Be "previous=value`nmodules=[`"application`",`"foundation`"]`n"
    }

    It 'can select a module named keys without treating it as a dictionary property' {
        $modules = Join-Path $TestDrive 'member-modules'
        New-Item -ItemType Directory -Path $modules | Out-Null
        Copy-Item -LiteralPath (Join-Path $fixtures 'observer') -Destination (Join-Path $modules 'keys') -Recurse
        $manifestPath = Join-Path $modules 'keys/module.yaml'
        $manifest = Get-Content -LiteralPath $manifestPath -Raw
        $manifest.Replace('name: observer', 'name: keys') | Set-Content -LiteralPath $manifestPath
        $instance = Join-Path $TestDrive 'keys-instance.yaml'
        'modules: {keys: {}}' | Set-Content -LiteralPath $instance

        & $selector -ModulesPath $modules -InstancePath $instance | Should -Be '["keys"]'
    }

    It 'rejects <Case> with an instance configuration path' -ForEach @(
        @{ Case = 'missing modules'; Yaml = 'instance: {name: example}'; Error = '*$.modules*' }
        @{ Case = 'a module list'; Yaml = 'modules: [application]'; Error = '*$.modules*' }
        @{ Case = 'null modules'; Yaml = 'modules: null'; Error = '*$.modules*' }
        @{ Case = 'a non-mapping module configuration'; Yaml = 'modules: {application: true}'; Error = '*$.modules.application*' }
        @{ Case = 'an unknown module'; Yaml = 'modules: {missing: {}}'; Error = '*$.modules.missing*unknown*missing*' }
        @{ Case = 'an invalid module name'; Yaml = 'modules: {Application: {}}'; Error = '*$.modules.Application*' }
        @{ Case = 'multiple YAML documents'; Yaml = "modules: {}`n---`nmodules: {}"; Error = '*one YAML mapping*invalid-instance*' }
        @{ Case = 'duplicate YAML keys'; Yaml = "modules: {}`nmodules: {}"; Error = '*invalid-instance*Duplicate key*' }
    ) {
        $instance = Join-Path $TestDrive 'invalid-instance.yaml'
        $Yaml | Set-Content -LiteralPath $instance
        $githubOutput = Join-Path $TestDrive 'not-written'

        { & $selector -ModulesPath $fixtures -InstancePath $instance -GitHubOutputPath $githubOutput } |
            Should -Throw $Error
        Test-Path -LiteralPath $githubOutput | Should -BeFalse
    }
}
