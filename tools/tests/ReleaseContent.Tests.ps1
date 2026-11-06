BeforeAll {
    $repositoryRoot = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
}

Describe 'Platform release content' {
    BeforeAll {
        $asset = Join-Path $TestDrive 'platform.zip'
        # Match the release workflow's committed input and Git export attributes, including test files.
        & git -C $repositoryRoot archive --format=zip --output=$asset HEAD
        if ($LASTEXITCODE -ne 0) { throw "git archive failed with exit code $LASTEXITCODE." }
    }

    It 'includes the complete MIT license at the archive root' {
        $archive = [IO.Compression.ZipFile]::OpenRead($asset)
        try {
            $entry = $archive.GetEntry('LICENSE')
            $entry | Should -Not -BeNullOrEmpty -Because 'distributed copies must include the project license'
            $reader = [IO.StreamReader]::new($entry.Open())
            try { $actual = $reader.ReadToEnd().Replace("`r`n", "`n").Trim() }
            finally { $reader.Dispose() }
        }
        finally { $archive.Dispose() }

        # Standard MIT text: https://opensource.org/license/mit
        $expected = @'
MIT License

Copyright (c) 2026 Martin Sucharda

Permission is hereby granted, free of charge, to any person obtaining a copy
of this software and associated documentation files (the "Software"), to deal
in the Software without restriction, including without limitation the rights
to use, copy, modify, merge, publish, distribute, sublicense, and/or sell
copies of the Software, and to permit persons to whom the Software is
furnished to do so, subject to the following conditions:

The above copyright notice and this permission notice shall be included in all
copies or substantial portions of the Software.

THE SOFTWARE IS PROVIDED "AS IS", WITHOUT WARRANTY OF ANY KIND, EXPRESS OR
IMPLIED, INCLUDING BUT NOT LIMITED TO THE WARRANTIES OF MERCHANTABILITY,
FITNESS FOR A PARTICULAR PURPOSE AND NONINFRINGEMENT. IN NO EVENT SHALL THE
AUTHORS OR COPYRIGHT HOLDERS BE LIABLE FOR ANY CLAIM, DAMAGES OR OTHER
LIABILITY, WHETHER IN AN ACTION OF CONTRACT, TORT OR OTHERWISE, ARISING FROM,
OUT OF OR IN CONNECTION WITH THE SOFTWARE OR THE USE OR OTHER DEALINGS IN THE
SOFTWARE.
'@
        $actual | Should -BeExactly $expected.Replace("`r`n", "`n").Trim()
    }

    It 'contains no platform-test secret scanning matches in any archived file' {
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
