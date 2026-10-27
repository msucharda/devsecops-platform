BeforeAll {
    Import-Module (Join-Path (Split-Path $PSScriptRoot -Parent) 'PlatformTools.psm1') -Force
    $modules = Get-PlatformModuleGraph -ModulesPath (Join-Path $PSScriptRoot 'fixtures/modules')
    $exampleYaml = Get-Content -LiteralPath (Join-Path $PSScriptRoot 'fixtures/instance.yaml') -Raw
}

Describe 'Culture-independent configuration normalization' {
    BeforeEach { $originalCulture = [Globalization.CultureInfo]::CurrentCulture }
    AfterEach { [Globalization.CultureInfo]::CurrentCulture = $originalCulture }

    It 'uses ordinal dictionary keys and preserves array order under <Culture>' -ForEach @(
        @{ Culture = 'cs-CZ' }
        @{ Culture = 'en-US' }
        @{ Culture = '' }
    ) {
        [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
        $value = [ordered]@{
            z = @('b', 'a')
            h = [ordered]@{ i = 3; ch = 1; h = 2 }
            ch = 'value'
        }

        ConvertTo-PlatformCanonicalJson $value |
            Should -BeExactly '{"ch":"value","h":{"ch":1,"h":2,"i":3},"z":["b","a"]}'
        ConvertTo-PlatformCanonicalJson @{} | Should -BeExactly '{}'
    }

    It 'normalizes file and inline YAML identically with ordinal resource sets under <Culture>' -ForEach @(
        @{ Culture = 'cs-CZ' }
        @{ Culture = 'en-US' }
        @{ Culture = '' }
    ) {
        [Globalization.CultureInfo]::CurrentCulture = [Globalization.CultureInfo]::GetCultureInfo($Culture)
        $configuration = ConvertFrom-Yaml $exampleYaml
        $configuration.githubApps = @{
            reader = @{
                appId = '101'; installationId = '201'; enterprise = 'example'; permissions = @{ contents = 'read' }
                resources = @{
                    organizations = @('demo-platform', 'demo-actions', 'demo-workloads')
                    repositories = @{
                        'demo-actions' = @('actions-upload-artifact', 'actions-download-artifact',
                            'actions-create-github-app-token', 'actions-checkout')
                    }
                }
            }
        }
        $yaml = ConvertTo-Yaml $configuration
        $path = Join-Path $TestDrive 'instance.yaml'
        Set-Content -LiteralPath $path -Value $yaml

        $fromFile = Get-PlatformInstance -Path $path -Modules $modules
        $fromYaml = Get-PlatformInstance -Yaml $yaml -Modules $modules

        $fromYaml.githubApps.reader.resources.organizations |
            Should -BeExactly @('demo-actions', 'demo-platform', 'demo-workloads')
        $fromYaml.githubApps.reader.resources.repositories['demo-actions'] |
            Should -BeExactly @('actions-checkout', 'actions-create-github-app-token',
                'actions-download-artifact', 'actions-upload-artifact')
        ConvertTo-PlatformCanonicalJson $fromYaml | Should -BeExactly (ConvertTo-PlatformCanonicalJson $fromFile)
        $fromYaml.teardown.allowed | Should -BeFalse
    }

    It 'rejects inline YAML with <Case> before normalization' -ForEach @(
        @{ Case = 'multiple documents'; Yaml = "instance: { name: demo }`n---`ninstance: { name: other }"; Error = '*Expected one YAML mapping*' }
        @{ Case = 'a sequence'; Yaml = '- instance'; Error = '*Expected one YAML mapping*' }
        @{ Case = 'invalid syntax'; Yaml = 'instance: ['; Error = '*Invalid YAML*' }
        @{ Case = 'missing required fields'; Yaml = 'instance: { name: demo }'; Error = '*regions is required*' }
    ) {
        { Get-PlatformInstance -Yaml $Yaml -Modules $modules } | Should -Throw $Error
    }
}
