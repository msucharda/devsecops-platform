BeforeAll {
    Import-Module powershell-yaml -RequiredVersion 0.4.12
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

Describe 'GitHub Actions version updates' {
    It 'checks source workflows, instance templates, generated fixtures and the acceptance workflow' {
        $configuration = Get-Content (Join-Path $root '.github/dependabot.yml') -Raw | ConvertFrom-Yaml

        $configuration.version | Should -Be 2
        @($configuration.updates.directory | Sort-Object) | Should -Be @(
            '/'
            '/templates/instance/.github/workflows'
            '/tools/acceptance/github'
            '/tools/tests/fixtures'
        )
        foreach ($update in $configuration.updates) {
            $update.'package-ecosystem' | Should -BeExactly 'github-actions'
            $update.schedule.interval | Should -BeExactly 'weekly'
            $update.'open-pull-requests-limit' | Should -BeGreaterThan 0
        }
    }

    It 'pins executable workflows and generated fixtures to full SHA commits with release tag comments' {
        $directories = @(
            '.github/workflows'
            'templates/instance/.github/workflows'
            'tools/acceptance/github'
            'tools/tests/fixtures'
        )
        $references = 0
        foreach ($directory in $directories) {
            foreach ($file in Get-ChildItem (Join-Path $root $directory) -File -Filter '*.yml') {
                foreach ($line in Get-Content $file.FullName) {
                    if ($line -match '^\s*(?:-\s*)?uses:\s+[^./\s][^@\s]*@') {
                        $references++
                        $line | Should -Match 'uses:\s+[A-Za-z0-9_.-]+/[A-Za-z0-9_.-]+@[0-9a-f]{40}\s+# v[0-9]+\.[0-9]+\.[0-9]+\s*$' `
                            -Because "$($file.Name) must retain a commit pin and its upstream release tag"
                    }
                }
            }
        }
        $references | Should -BeGreaterThan 0
    }
}
