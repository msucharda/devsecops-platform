BeforeAll {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

Describe 'Platform release content' {
    It 'contains no platform-test secret scanning matches in any archived file' {
        $asset = Join-Path $TestDrive 'platform.zip'
        # Match the release workflow's committed input and Git export attributes, including test files.
        & git -C $repositoryRoot archive --format=zip --output=$asset HEAD
        if ($LASTEXITCODE -ne 0) { throw "git archive failed with exit code $LASTEXITCODE." }

        $violations = [Collections.Generic.List[string]]::new()
        $archive = [IO.Compression.ZipFile]::OpenRead($asset)
        try {
            $archive.Entries.Count | Should -BeGreaterThan 0
            foreach ($entry in $archive.Entries) {
                if ($entry.FullName.EndsWith('/')) { continue }
                $reader = [IO.StreamReader]::new($entry.Open())
                try {
                    if ($reader.ReadToEnd() -cmatch '(?<![0-9A-Za-z])PLATFORMTEST_[A-Z0-9]{20}(?![0-9A-Za-z])') {
                        $violations.Add($entry.FullName)
                    }
                }
                finally { $reader.Dispose() }
            }
        }
        finally { $archive.Dispose() }

        $violations | Should -BeNullOrEmpty -Because 'release files must pass the platform-test push protection pattern'
    }
}
