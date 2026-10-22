BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $publish = Join-Path (Split-Path $PSScriptRoot -Parent) 'Publish-PlatformRelease.ps1'
    $commit = 'a' * 40
}

Describe 'Platform release publication' {
    BeforeEach {
        $asset = Join-Path $TestDrive 'platform.zip'
        [IO.File]::WriteAllBytes($asset, [byte[]] (1..64))
        $digest = 'sha256:' + (Get-FileHash -LiteralPath $asset -Algorithm SHA256).Hash.ToLowerInvariant()
        $arguments = @{ Repository = 'octo/devsecops-platform'; Tag = 'v1.2.0'; Commit = $commit; AssetPath = $asset; ApiUrl = 'https://api.github.com'; Token = 'workflow-token' }
        # The stub models one repository: the tag reference, an optional annotated tag object and the releases with assets.
        # Response shapes come from the shared fixtures of the documented operations (REST API version 2026-03-10).
        $cloud = @{ refType = 'commit'; refSha = $commit; tagObject = $null; releases = [Collections.Generic.List[object]]::new(); nextId = 10; publishResponse = $null; uploadDigest = $null; uploadUrl = $null }
        $newRelease = {
            param([hashtable] $Data)
            $id = $cloud.nextId++
            Get-GitHubApiFixture -Name repos/create-release -Set @{
                id = $id; tag_name = $Data.tag_name; draft = [bool] $Data.draft; prerelease = [bool] $Data.prerelease
                target_commitish = $Data.target_commitish; name = $Data.name; assets = [Collections.Generic.List[object]]::new()
                upload_url = if ($cloud.uploadUrl) { $cloud.uploadUrl } else { "https://uploads.github.com/repos/octo/devsecops-platform/releases/$id/assets{?name,label}" }
                html_url = "https://github.com/octo/devsecops-platform/releases/tag/$($Data.tag_name)"
            }
        }
        $newAsset = {
            param([string] $Name, [string] $AssetDigest, [string] $State = 'uploaded')
            $id = $cloud.nextId++
            Get-GitHubApiFixture -Name repos/upload-release-asset -Set @{ id = $id; name = $Name; digest = $AssetDigest; state = $State }
        }
        $respond = {
            param([int] $Status, $Value)
            $content = if ($null -eq $Value) { '' } else { ConvertTo-Json -InputObject $Value -Depth 20 -Compress }
            [pscustomobject] @{ StatusCode = $Status; Content = $content }
        }
        $cloudTransport = {
            param([uri] $Uri, [string] $Method = 'GET', $Body)
            $Method = $Method.ToUpperInvariant()
            $path = $Uri.AbsolutePath
            $query = [Web.HttpUtility]::ParseQueryString($Uri.Query)
            if ($Method -eq 'GET' -and $path -cin @('/repos/octo/devsecops-platform/git/ref/tags/v1.2.0', '/repos/octo/devsecops-platform/git/ref/tags/v1.2.0-rc.1')) {
                return & $respond 200 (Get-GitHubApiFixture -Name git/get-ref -Set @{ ref = "refs/tags/$($path.Split('/')[-1])"; 'object.type' = $cloud.refType; 'object.sha' = $cloud.refSha })
            }
            if ($Method -eq 'GET' -and $path -cmatch '^/repos/octo/devsecops-platform/git/tags/([a-f0-9]{40})$' -and $cloud.tagObject -and $Matches[1] -ceq $cloud.refSha) {
                return & $respond 200 (Get-GitHubApiFixture -Name git/get-tag -Set @{ sha = $cloud.refSha; 'object.type' = 'commit'; 'object.sha' = $cloud.tagObject })
            }
            if ($Method -eq 'GET' -and $path -ceq '/repos/octo/devsecops-platform/releases') {
                $page = [int] $query['page']
                $items = @($cloud.releases | Select-Object -Skip (($page - 1) * 100) -First 100)
                return & $respond 200 $items
            }
            if ($Method -eq 'POST' -and $path -ceq '/repos/octo/devsecops-platform/releases') {
                $release = & $newRelease (ConvertFrom-Json $Body -AsHashtable)
                $cloud.releases.Add($release)
                return & $respond 201 $release
            }
            if ($Method -eq 'POST' -and $Uri.Host -ceq 'uploads.github.com' -and $path -cmatch '^/repos/octo/devsecops-platform/releases/([0-9]+)/assets$') {
                $release = @($cloud.releases | Where-Object { $_.id -eq [int] $Matches[1] })[0]
                if (@($release.assets | Where-Object { $_.name -ceq $query['name'] }).Count) {
                    return & $respond 422 @{ message = 'Validation Failed'; errors = @(@{ resource = 'ReleaseAsset'; code = 'already_exists'; field = 'name' }) }
                }
                # Invoke-WebRequest sends only a byte[] body as binary; any other value, such as an object[] of bytes,
                # is sent as its string form, so GitHub would store and hash that text.
                $sent = [Text.Encoding]::UTF8.GetBytes("$Body")
                if ($Body -is [byte[]]) { $sent = $Body }
                $hash = 'sha256:' + [Convert]::ToHexString([Security.Cryptography.SHA256]::HashData($sent)).ToLowerInvariant()
                $item = & $newAsset $query['name'] $(if ($cloud.uploadDigest) { $cloud.uploadDigest } else { $hash })
                $release.assets.Add($item)
                return & $respond 201 $item
            }
            if ($Method -eq 'DELETE' -and $path -cmatch '^/repos/octo/devsecops-platform/releases/assets/([0-9]+)$') {
                foreach ($release in $cloud.releases) {
                    $item = @($release.assets | Where-Object { $_.id -eq [int] $Matches[1] })
                    if ($item.Count) { $null = $release.assets.Remove($item[0]); return & $respond 204 $null }
                }
                return & $respond 404 @{ message = 'Not Found' }
            }
            if ($Method -eq 'PATCH' -and $path -cmatch '^/repos/octo/devsecops-platform/releases/([0-9]+)$') {
                $release = @($cloud.releases | Where-Object { $_.id -eq [int] $Matches[1] })[0]
                $data = ConvertFrom-Json $Body -AsHashtable
                $release.draft = $data.draft
                $release.prerelease = $data.prerelease
                $release.make_latest = $data.make_latest
                $response = Get-GitHubApiFixture -Name repos/update-release
                foreach ($key in @($release.Keys)) { if ($response.Contains($key)) { $response[$key] = $release[$key] } }
                if ($cloud.publishResponse) { & $cloud.publishResponse $response }
                return & $respond 200 $response
            }
            return & $respond 404 @{ message = 'Not Found' }
        }
        $writes = [Collections.Generic.List[string]]::new()
    }

    Describe 'Platform release publication' {
        BeforeEach {
            Mock Invoke-WebRequest {
                param([uri] $Uri, [string] $Method = 'GET', $Body)
                $Method = $Method.ToUpperInvariant()
                if ($Method -ne 'GET') { $writes.Add("$Method $($Uri.AbsolutePath)") }
                & $cloudTransport -Uri $Uri -Method $Method -Body $Body
            }
        }

        It 'publishes a <Kind> release with exactly the attested asset' -ForEach @(
            @{ Kind = 'stable'; Tag = 'v1.2.0'; Prerelease = $false; Latest = 'legacy' }
            @{ Kind = 'release candidate'; Tag = 'v1.2.0-rc.1'; Prerelease = $true; Latest = 'false' }
        ) {
            $arguments.Tag = $Tag

            $result = & $publish @arguments 6>$null

            $result.Created | Should -BeTrue
            $result.Prerelease | Should -Be $Prerelease
            $result.Digest | Should -BeExactly $digest
            $cloud.releases.Count | Should -Be 1
            $release = $cloud.releases[0]
            $release.tag_name | Should -BeExactly $Tag
            $release.target_commitish | Should -BeExactly $commit
            $release.draft | Should -BeFalse
            $release.prerelease | Should -Be $Prerelease
            $release.make_latest | Should -BeExactly $Latest
            @($release.assets).Count | Should -Be 1
            $release.assets[0].name | Should -BeExactly "platform-$Tag.zip"
            $release.assets[0].digest | Should -BeExactly $digest
            $writes[0] | Should -BeExactly 'POST /repos/octo/devsecops-platform/releases'
            $writes[-1] | Should -BeLike 'PATCH /repos/octo/devsecops-platform/releases/*'
            Should -Invoke Invoke-WebRequest -ParameterFilter { $Headers['X-GitHub-Api-Version'] -ceq '2026-03-10' -and $Headers.Authorization -ceq 'Bearer workflow-token' }
        }

        It 'uploads the asset as a byte[] body with exactly the file content' {
            $uploads = [Collections.Generic.List[object]]::new()
            Mock Invoke-WebRequest {
                param([uri] $Uri, [string] $Method = 'GET', $Body)
                if ($Uri.Host -ceq 'uploads.github.com') { $uploads.Add([pscustomobject] @{ Body = $Body; ContentType = $ContentType }) }
                & $cloudTransport -Uri $Uri -Method $Method -Body $Body
            }

            $null = & $publish @arguments 6>$null

            $uploads.Count | Should -Be 1
            $uploads[0].ContentType | Should -BeExactly 'application/zip'
            # A byte[] passed through an if expression is enumerated into object[] and sent as text.
            $uploads[0].Body.GetType().FullName | Should -BeExactly 'System.Byte[]'
            [Convert]::ToHexString($uploads[0].Body) | Should -BeExactly ([Convert]::ToHexString([IO.File]::ReadAllBytes($asset)))
        }

        It 'creates a new release when a draft of another tag exists' {
            $other = & $newRelease @{ tag_name = 'v1.2.0-rc.1'; draft = $true; prerelease = $true; target_commitish = 'b' * 40; name = 'v1.2.0-rc.1' }
            $other.assets.Add((& $newAsset 'platform-v1.2.0-rc.1.zip' ('sha256:' + '0' * 64)))
            $cloud.releases.Add($other)

            $result = & $publish @arguments 6>$null

            $result.Created | Should -BeTrue
            $cloud.releases.Count | Should -Be 2
            $writes[0] | Should -BeExactly 'POST /repos/octo/devsecops-platform/releases'
            $other.draft | Should -BeTrue
            @($other.assets).Count | Should -Be 1
            $other.assets[0].name | Should -BeExactly 'platform-v1.2.0-rc.1.zip'
            @($writes | Where-Object { $_ -like "* /repos/octo/devsecops-platform/releases/$($other.id)*" -or $_ -like "DELETE *" }).Count | Should -Be 0
            $release = $cloud.releases[1]
            $release.tag_name | Should -BeExactly 'v1.2.0'
            $release.draft | Should -BeFalse
            $release.assets[0].digest | Should -BeExactly $digest
        }

        It 'accepts an annotated tag whose tag object points to the built commit' {
            $cloud.refType = 'tag'
            $cloud.refSha = 'b' * 40
            $cloud.tagObject = $commit

            $result = & $publish @arguments 6>$null

            $result.Created | Should -BeTrue
        }

        It 'rejects a tag-commit mismatch: <Case>' -ForEach @(
            @{ Case = 'tag moved to another commit'; RefType = 'commit'; RefSha = 'c' * 40; TagObject = $null }
            @{ Case = 'reference type is not commit'; RefType = 'tree'; RefSha = 'a' * 40; TagObject = $null }
            @{ Case = 'reference type differs in case'; RefType = 'Commit'; RefSha = 'a' * 40; TagObject = $null }
            @{ Case = 'commit SHA differs in case'; RefType = 'commit'; RefSha = 'A' * 40; TagObject = $null }
            @{ Case = 'annotated tag points to another commit'; RefType = 'tag'; RefSha = 'b' * 40; TagObject = 'c' * 40 }
        ) {
            $cloud.refType = $RefType
            $cloud.refSha = $RefSha
            $cloud.tagObject = $TagObject

            { & $publish @arguments 6>$null } | Should -Throw '*does not point to the built commit*'
            $writes.Count | Should -Be 0
        }

        It 'rejects the invalid release tag <Tag>' -ForEach @(
            @{ Tag = '' }, @{ Tag = 'v1.2' }, @{ Tag = '1.2.0' }, @{ Tag = 'V1.2.0' }, @{ Tag = 'v01.2.0' }, @{ Tag = 'v1.2.0-beta.1' }
            @{ Tag = 'v1.2.0-rc.01' }, @{ Tag = 'v1.2.0-RC.1' }, @{ Tag = 'v1.2.0 ' }, @{ Tag = 'v1.2.0+build' }
        ) {
            $arguments.Tag = $Tag

            { & $publish @arguments 6>$null } | Should -Throw '*must be vMAJOR.MINOR.PATCH*'
            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'rejects a non-HTTPS API and a missing token' {
            $arguments.ApiUrl = 'http://api.github.com'
            { & $publish @arguments 6>$null } | Should -Throw '*HTTPS GitHub API URL*'
            $arguments.ApiUrl = 'https://api.github.com'
            $arguments.Token = ''
            { & $publish @arguments 6>$null } | Should -Throw '*GITHUB_TOKEN*'
            Should -Invoke Invoke-WebRequest -Times 0
        }

        It 'confirms an identical published release without writing' {
            $release = & $newRelease @{ tag_name = 'v1.2.0'; draft = $false; prerelease = $false; target_commitish = $commit; name = 'v1.2.0' }
            $release.assets.Add((& $newAsset 'platform-v1.2.0.zip' $digest))
            $cloud.releases.Add($release)

            $result = & $publish @arguments 6>$null

            $result.Created | Should -BeFalse
            $writes.Count | Should -Be 0
        }

        It 'never changes a published release with different content: <Case>' -ForEach @(
            @{ Case = 'digest differs'; Assets = @(@{ Name = 'platform-v1.2.0.zip'; Digest = 'sha256:' + '0' * 64; State = 'uploaded' }); Prerelease = $false }
            @{ Case = 'digest differs in case'; Assets = @(@{ Name = 'platform-v1.2.0.zip'; Digest = 'UPPER'; State = 'uploaded' }); Prerelease = $false }
            @{ Case = 'digest is null'; Assets = @(@{ Name = 'platform-v1.2.0.zip'; Digest = $null; State = 'uploaded' }); Prerelease = $false }
            @{ Case = 'asset name differs in case'; Assets = @(@{ Name = 'Platform-v1.2.0.zip'; Digest = 'LOCAL'; State = 'uploaded' }); Prerelease = $false }
            @{ Case = 'asset is not uploaded'; Assets = @(@{ Name = 'platform-v1.2.0.zip'; Digest = 'LOCAL'; State = 'starter' }); Prerelease = $false }
            @{ Case = 'asset state differs in case'; Assets = @(@{ Name = 'platform-v1.2.0.zip'; Digest = 'LOCAL'; State = 'Uploaded' }); Prerelease = $false }
            @{ Case = 'extra asset'; Assets = @(@{ Name = 'platform-v1.2.0.zip'; Digest = 'LOCAL'; State = 'uploaded' }, @{ Name = 'notes.txt'; Digest = 'LOCAL'; State = 'uploaded' }); Prerelease = $false }
            @{ Case = 'no asset'; Assets = @(); Prerelease = $false }
            @{ Case = 'prerelease differs'; Assets = @(@{ Name = 'platform-v1.2.0.zip'; Digest = 'LOCAL'; State = 'uploaded' }); Prerelease = $true }
        ) {
            $release = & $newRelease @{ tag_name = 'v1.2.0'; draft = $false; prerelease = $Prerelease; target_commitish = $commit; name = 'v1.2.0' }
            foreach ($item in $Assets) {
                $value = switch ($item.Digest) { 'LOCAL' { $digest } 'UPPER' { $digest.ToUpperInvariant() } default { $item.Digest } }
                $release.assets.Add((& $newAsset $item.Name $value $item.State))
            }
            $cloud.releases.Add($release)

            { & $publish @arguments 6>$null } | Should -Throw '*already published with different content*'
            $writes.Count | Should -Be 0
        }

        It 'rejects a tag with more than one release' {
            foreach ($index in 1..2) { $cloud.releases.Add((& $newRelease @{ tag_name = 'v1.2.0'; draft = $true; prerelease = $false; target_commitish = $commit; name = 'v1.2.0' })) }

            { & $publish @arguments 6>$null } | Should -Throw '*has 2 releases*'
            $writes.Count | Should -Be 0
        }

        It 'finds the release of the tag on a later page' {
            foreach ($index in 1..100) { $cloud.releases.Add((& $newRelease @{ tag_name = "v0.0.$index"; draft = $false; prerelease = $false; target_commitish = $commit; name = 'old' })) }
            $release = & $newRelease @{ tag_name = 'v1.2.0'; draft = $false; prerelease = $false; target_commitish = $commit; name = 'v1.2.0' }
            $release.assets.Add((& $newAsset 'platform-v1.2.0.zip' $digest))
            $cloud.releases.Add($release)

            $result = & $publish @arguments 6>$null

            $result.Created | Should -BeFalse
            $writes.Count | Should -Be 0
        }

        It 'resumes a draft and replaces stale, partial and foreign assets' {
            $release = & $newRelease @{ tag_name = 'v1.2.0'; draft = $true; prerelease = $false; target_commitish = $commit; name = 'v1.2.0' }
            $release.assets.Add((& $newAsset 'platform-v1.2.0.zip' ('sha256:' + '0' * 64)))
            $release.assets.Add((& $newAsset 'partial.zip' $digest 'starter'))
            $release.assets.Add((& $newAsset 'notes.txt' $null))
            $cloud.releases.Add($release)

            $result = & $publish @arguments 6>$null

            $result.Created | Should -BeTrue
            $cloud.releases.Count | Should -Be 1
            $release.draft | Should -BeFalse
            @($release.assets).Count | Should -Be 1
            $release.assets[0].digest | Should -BeExactly $digest
            @($writes | Where-Object { $_ -like 'DELETE *' }).Count | Should -Be 3
            $writes | Should -Not -Contain 'POST /repos/octo/devsecops-platform/releases'
        }

        It 'keeps a matching asset of a draft and deletes its duplicate' {
            $release = & $newRelease @{ tag_name = 'v1.2.0'; draft = $true; prerelease = $false; target_commitish = $commit; name = 'v1.2.0' }
            $release.assets.Add((& $newAsset 'platform-v1.2.0.zip' $digest))
            $release.assets.Add((& $newAsset 'platform-v1.2.0.zip' $digest))
            $cloud.releases.Add($release)

            $null = & $publish @arguments 6>$null

            @($release.assets).Count | Should -Be 1
            @($writes | Where-Object { $_ -like 'POST *' }).Count | Should -Be 0
        }

        It 'keeps the release a draft when the uploaded asset reports another digest: <Case>' -ForEach @(
            @{ Case = 'different digest'; Reported = 'sha256:' + '0' * 64 }
            @{ Case = 'null digest'; Reported = 'null' }
        ) {
            $cloud.uploadDigest = $Reported

            { & $publish @arguments 6>$null } | Should -Throw '*does not report the digest*'
            $cloud.releases[0].draft | Should -BeTrue
            @($writes | Where-Object { $_ -like 'PATCH *' }).Count | Should -Be 0
        }

        It 'rejects an unexpected upload URL' {
            $cloud.uploadUrl = 'http://uploads.github.com/repos/octo/devsecops-platform/releases/10/assets{?name,label}'

            { & $publish @arguments 6>$null } | Should -Throw '*unexpected release upload URL*'
            @($writes | Where-Object { $_ -like 'POST *assets' }).Count | Should -Be 0
        }

        It 'rejects a publish response that does not match: <Case>' -ForEach @(
            @{ Case = 'still a draft'; Change = { param($r) $r.draft = $true } }
            @{ Case = 'other tag'; Change = { param($r) $r.tag_name = 'v1.2.1' } }
            @{ Case = 'tag differs in case'; Change = { param($r) $r.tag_name = 'V1.2.0' } }
            @{ Case = 'prerelease differs'; Change = { param($r) $r.prerelease = $true } }
            @{ Case = 'asset digest differs'; Change = { param($r) $r.assets = @(@{ name = 'platform-v1.2.0.zip'; state = 'uploaded'; digest = 'sha256:' + '0' * 64 }) } }
            @{ Case = 'draft is the string FALSE'; Change = { param($r) $r.draft = 'FALSE' } }
            @{ Case = 'draft is the number 0'; Change = { param($r) $r.draft = 0 } }
            @{ Case = 'draft is null'; Change = { param($r) $r.draft = $null } }
            @{ Case = 'prerelease is the string false'; Change = { param($r) $r.prerelease = 'false' } }
            @{ Case = 'prerelease is null'; Change = { param($r) $r.prerelease = $null } }
        ) {
            $cloud.publishResponse = $Change

            { & $publish @arguments 6>$null } | Should -Throw '*does not match the attested asset*'
        }

        It 'changes nothing when an existing release has no boolean draft state: <Case>' -ForEach @(
            @{ Case = 'draft missing'; Change = { param($r) $r.Remove('draft') } }
            @{ Case = 'draft null'; Change = { param($r) $r.draft = $null } }
            @{ Case = 'draft is the string false'; Change = { param($r) $r.draft = 'false' } }
            @{ Case = 'draft is the number 0'; Change = { param($r) $r.draft = 0 } }
        ) {
            # Deliberately invalid: the documented release schema requires a boolean draft.
            $release = & $newRelease @{ tag_name = 'v1.2.0'; draft = $false; prerelease = $false; target_commitish = $commit; name = 'v1.2.0' }
            $release.assets.Add((& $newAsset 'platform-v1.2.0.zip' ('sha256:' + '0' * 64)))
            & $Change $release
            $cloud.releases.Add($release)

            { & $publish @arguments 6>$null } | Should -Throw '*no boolean draft state*'
            $writes.Count | Should -Be 0
        }
    }
    }
