BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'GitHubApiFixture.psm1') -Force
    $snapshotCommand = Join-Path $PSScriptRoot '../New-DevelopmentStateSnapshot.ps1'
}

Describe 'Development state isolation' {
    BeforeEach {
        $directory = Join-Path $TestDrive ([guid]::NewGuid().ToString())
        $null = New-Item -ItemType Directory -Path $directory
        $source = Join-Path $directory 'standard.tfstate'
        $output = Join-Path $directory 'snapshot'
        $state = @{
            version = 4; terraform_version = '1.16.5'; serial = 3
            lineage = '00000000-0000-0000-0000-000000000001'
            outputs = @{ organizations = @{ value = @('demo-workloads'); type = @('tuple', @('string')); sensitive = $false } }
            resources = @(
                @{ mode = 'data'; type = 'external'; name = 'ruleset_plan_state'; instances = @(@{ index_key = 'demo-workloads'; attributes = @{} }) }
                @{ mode = 'data'; type = 'external'; name = 'ruleset_state'; instances = @(@{ index_key = 'demo-workloads'; attributes = @{} }) }
                @{ mode = 'managed'; type = 'terraform_data'; name = 'ruleset_intent'; instances = @(@{ index_key = 'demo-workloads'; attributes = @{} }) }
                @{ mode = 'managed'; type = 'restapi_object'; name = 'ruleset'; instances = @(@{ index_key = 'demo-workloads'; attributes = @{} }) }
            )
        }
        $arguments = @{
            SourcePath = $source; OutputPath = $output; Module = 'organization-rulesets'; StateRoot = 'rulesets'
            Organization = 'demo-workloads'; SourceETag = '"0x1234"'
            BaselineRevision = 'a' * 40; CandidateRevision = 'b' * 40; ControlRevision = 'c' * 40
        }
        $response = Get-GitHubApiFixture -Name repos/get-org-ruleset -Set @{ id = 101; source = 'demo-workloads'; source_type = 'Organization' }
        $state.resources[0].instances[0].attributes = @{ query = @{ organization = 'demo-workloads' } }
        $state.resources[1].instances[0].attributes = @{ query = @{ organization = 'demo-workloads' } }
        $state.resources[2].instances[0].attributes = @{
            input = @{ value = @{ organization = 'demo-workloads'; destroy_started = $false } }
            output = @{ value = @{ organization = 'demo-workloads'; destroy_started = $false } }
        }
        $state.resources[3].instances[0].attributes = @{
            path = '/orgs/demo-workloads/rulesets'; id = '101'
            api_response = ConvertTo-Json $response -Depth 30 -Compress
        }
        function Write-TestState {
            [IO.File]::WriteAllText($source, (ConvertTo-Json $state -Depth 30), [Text.UTF8Encoding]::new($false))
            $arguments.ExpectedSha256 = (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
        }
        Write-TestState
    }

    It 'publishes an exact root snapshot with immutable source provenance and no baseline write' {
        $result = & $snapshotCommand @arguments
        (Get-FileHash -LiteralPath $result.StatePath).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
        (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json -AsHashtable
        $manifest.source.container | Should -BeExactly 'organization-rulesets'
        $manifest.source.key | Should -BeExactly 'organizations/demo-workloads/terraform.rulesets.tfstate'
        $manifest.source.lineage | Should -BeExactly '00000000-0000-0000-0000-000000000001'
        $manifest.source.serial | Should -Be 3
    }

    It 'also supports the resource-free standard main root for the exact organization' {
        $arguments.StateRoot = 'main'
        $state.resources = @()
        Write-TestState
        $result = & $snapshotCommand @arguments
        $manifest = Get-Content -LiteralPath $result.ManifestPath -Raw | ConvertFrom-Json -AsHashtable
        $manifest.source.key | Should -BeExactly 'organizations/demo-workloads/terraform.tfstate'
    }

    It 'refuses a digest mismatch before publishing either artifact' {
        $arguments.ExpectedSha256 = 'f' * 64
        { & $snapshotCommand @arguments } | Should -Throw '*authorized snapshot digest*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'refuses a noncanonical digest even when it names the same bytes' {
        $arguments.ExpectedSha256 = $arguments.ExpectedSha256.ToUpperInvariant()
        { & $snapshotCommand @arguments } | Should -Throw '*authorized snapshot digest*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects <Case> <Parameter> before publishing provenance' -ForEach @(
        @{ Parameter = 'BaselineRevision'; Case = 'uppercase' }
        @{ Parameter = 'CandidateRevision'; Case = 'uppercase' }
        @{ Parameter = 'ControlRevision'; Case = 'uppercase' }
        @{ Parameter = 'BaselineRevision'; Case = 'trailing newline' }
        @{ Parameter = 'CandidateRevision'; Case = 'trailing newline' }
        @{ Parameter = 'ControlRevision'; Case = 'trailing newline' }
    ) {
        $arguments[$Parameter] = if ($Case -ceq 'uppercase') { $arguments[$Parameter].ToUpperInvariant() } else { $arguments[$Parameter] + "`n" }
        { & $snapshotCommand @arguments } | Should -Throw "*Cannot validate argument*${Parameter}*"
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects a noncanonical root even for a resource-free state' {
        $arguments.StateRoot = 'Main'
        $state.resources = @()
        Write-TestState
        { & $snapshotCommand @arguments } | Should -Throw '*Cannot validate argument*StateRoot*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'requires a source file instead of a <Case>' -ForEach @(
        @{ Case = 'missing path' }
        @{ Case = 'directory' }
    ) {
        $arguments.SourcePath = if ($Case -ceq 'directory') { $directory } else { Join-Path $directory 'missing' }
        { & $snapshotCommand @arguments } | Should -Throw '*existing source state file*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects a root publication directory before accessing its contents' {
        $arguments.OutputPath = [IO.Path]::GetPathRoot($source)
        { & $snapshotCommand @arguments } | Should -Throw '*named subdirectory*'
        (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
    }

    It 'rejects using the source file itself as <Location>' -ForEach @(
        @{ Location = 'output' }
        @{ Location = 'staging' }
        @{ Location = 'lock' }
    ) {
        if ($Location -ceq 'output') { $arguments.OutputPath = $source }
        else {
            $arguments.SourcePath = if ($Location -ceq 'lock') { "$output.lock" } else { "$output.new" }
            Copy-Item -LiteralPath $source -Destination $arguments.SourcePath
        }
        { & $snapshotCommand @arguments } | Should -Throw '*must be disjoint*'
        (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
        (Get-FileHash -LiteralPath $arguments.SourcePath).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
    }

    It 'never deletes or replaces the source under an overlapping <Location> publication path' -ForEach @(
        @{ Location = 'output' }
        @{ Location = 'output with separator' }
        @{ Location = 'staging' }
    ) {
        $arguments.OutputPath = if ($Location.StartsWith('output')) { $directory } else { "$directory-other" }
        if ($Location -ceq 'output with separator') { $arguments.OutputPath += [IO.Path]::DirectorySeparatorChar }
        if ($Location -ceq 'staging') {
            $stage = $arguments.OutputPath + '.new'
            $null = New-Item -ItemType Directory -Path $stage
            $arguments.SourcePath = Join-Path $stage 'standard.tfstate'
            Copy-Item -LiteralPath $source -Destination $arguments.SourcePath
        }
        { & $snapshotCommand @arguments } | Should -Throw '*must be disjoint*'
        (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
        (Get-FileHash -LiteralPath $arguments.SourcePath).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
    }

    It 'rejects a symbolic-link <Location> path without publishing' -ForEach @(
        @{ Location = 'source' }
        @{ Location = 'output' }
        @{ Location = 'lock' }
    ) {
        $link = if ($Location -ceq 'lock') { "$output.lock" } else { Join-Path $TestDrive ([guid]::NewGuid().ToString()) }
        $kind = if ($IsWindows) { 'Junction' } else { 'SymbolicLink' }
        $target = $directory
        if ($Location -ceq 'lock') {
            $target = Join-Path $TestDrive ([guid]::NewGuid().ToString())
            $null = New-Item -ItemType Directory -Path $target
        }
        $null = New-Item -ItemType $kind -Path $link -Target $target
        if ($Location -ceq 'source') { $arguments.SourcePath = Join-Path $link 'standard.tfstate' }
        elseif ($Location -ceq 'output') { $arguments.OutputPath = Join-Path $link 'snapshot' }
        { & $snapshotCommand @arguments } | Should -Throw '*symbolic links*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'does not accept an altered published <Case> as crash recovery' -ForEach @(
        @{ Case = 'state' }
        @{ Case = 'manifest' }
        @{ Case = 'manifest case' }
        @{ Case = 'file set' }
        @{ Case = 'missing state' }
        @{ Case = 'state directory' }
    ) {
        $result = & $snapshotCommand @arguments
        switch ($Case) {
            state { [IO.File]::AppendAllText($result.StatePath, ' ') }
            manifest { [IO.File]::AppendAllText($result.ManifestPath, ' ') }
            'manifest case' {
                $text = [IO.File]::ReadAllText($result.ManifestPath).Replace('organization-rulesets', 'Organization-Rulesets')
                [IO.File]::WriteAllText($result.ManifestPath, $text)
            }
            'file set' { [IO.File]::WriteAllText((Join-Path $output 'unexpected'), 'untrusted') }
            'missing state' { Remove-Item -LiteralPath $result.StatePath }
            'state directory' {
                Remove-Item -LiteralPath $result.StatePath
                $null = New-Item -ItemType Directory -Path $result.StatePath
            }
        }

        { & $snapshotCommand @arguments } | Should -Throw '*Existing development snapshot*'
        (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
    }

    It 'preserves an unexpected staging <Case> instead of deleting or publishing it' -ForEach @(
        @{ Case = 'file'; Name = 'foreign'; IsDirectory = $false }
        @{ Case = 'directory'; Name = 'terraform.rulesets.tfstate'; IsDirectory = $true }
        @{ Case = 'case-only file'; Name = 'Snapshot.json'; IsDirectory = $false }
    ) {
        $stage = "$output.new"
        $null = New-Item -ItemType Directory -Path $stage
        $unexpected = Join-Path $stage $Name
        if ($IsDirectory) { $null = New-Item -ItemType Directory -Path $unexpected }
        else { [IO.File]::WriteAllText($unexpected, 'untrusted') }
        { & $snapshotCommand @arguments } | Should -Throw '*unexpected staging entry*'
        Test-Path -LiteralPath $unexpected | Should -BeTrue
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    # Deliberately malformed or cross-organization state; only the named field differs.
    It 'rejects a noncanonical <Field> JSON field before publication' -ForEach @(
        @{ Field = 'root'; Match = '"version":'; Replacement = '"VERSION":4,"version":' }
        @{ Field = 'resource'; Match = '"mode":'; Replacement = '"Module":"module.foreign","mode":' }
        @{ Field = 'instance'; Match = '"index_key":'; Replacement = '"INDEX_KEY":"demo-platform","index_key":' }
        @{ Field = 'output'; Match = '"value": ['; Replacement = '"Value":[],"value": [' }
        @{ Field = 'Unicode'; Match = '"version":'; Replacement = '"ver\u017fion":4,"version":' }
    ) {
        $json = [IO.File]::ReadAllText($source)
        $noncanonical = $json.Replace($Match, $Replacement)
        $noncanonical | Should -Not -BeExactly $json
        [IO.File]::WriteAllText($source, $noncanonical, [Text.UTF8Encoding]::new($false))
        $arguments.ExpectedSha256 = (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant()
        { & $snapshotCommand @arguments } | Should -Throw '*noncanonical state JSON*'
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects <Case> state before publication' -ForEach @(
        @{ Case = 'foreign output'; Change = { $state.outputs.organizations.value[0] = 'demo-platform' }; ExpectedError = '*exactly the selected organization*' }
        @{ Case = 'additional output org'; Change = { $state.outputs.organizations.value += 'demo-platform' }; ExpectedError = '*exactly the selected organization*' }
        @{ Case = 'foreign instance'; Change = { $state.resources[3].instances[0].index_key = 'demo-platform' }; ExpectedError = '*organization instance*' }
        @{ Case = 'instance case'; Change = { $state.resources[3].instances[0].index_key = 'Demo-workloads' }; ExpectedError = '*organization instance*' }
        @{ Case = 'additional instance'; Change = { $state.resources[3].instances += @{ index_key = 'demo-platform' } }; ExpectedError = '*organization instance*' }
        @{ Case = 'deposed instance'; Change = { $state.resources[3].instances[0].deposed = '00000001' }; ExpectedError = '*organization instance*' }
        @{ Case = 'tainted instance'; Change = { $state.resources[3].instances[0].status = 'tainted' }; ExpectedError = '*organization instance*' }
        @{ Case = 'foreign resource'; Change = { $state.resources[3].name = 'another' }; ExpectedError = '*foreign or duplicate resource*' }
        @{ Case = 'nested module'; Change = { $state.resources[3].module = 'module.other' }; ExpectedError = '*unsupported resource address*' }
        @{ Case = 'duplicate resource'; Change = { $state.resources += $state.resources[3] }; ExpectedError = '*foreign or duplicate resource*' }
        @{ Case = 'partial resource closure'; Change = { $state.resources = @($state.resources[0..2]) }; ExpectedError = '*missing part*' }
        @{ Case = 'different format'; Change = { $state.version = 3 }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'negative serial'; Change = { $state.serial = -1 }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'unknown lineage'; Change = { $state.lineage = '' }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'lineage case'; Change = { $state.lineage = 'AAAAAAAA-0000-0000-0000-000000000001' }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'lineage array'; Change = { $state.lineage = @('00000000-0000-0000-0000-000000000001') }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'unsupported module'; Change = { $arguments.Module = 'organizations' }; ExpectedError = '*support only the organization-rulesets roots*' }
        @{ Case = 'module case'; Change = { $arguments.Module = 'Organization-Rulesets' }; ExpectedError = '*support only the organization-rulesets roots*' }
        @{ Case = 'array root'; Change = { $state = @($state) }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'string version'; Change = { $state.version = '4' }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'string serial'; Change = { $state.serial = '3' }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'non-string lineage'; Change = { $state.lineage = 3 }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'non-list resources'; Change = { $state.resources = @{} }; ExpectedError = '*version-4 snapshot*' }
        @{ Case = 'missing outputs'; Change = { $state.Remove('outputs') }; ExpectedError = '*exactly the selected organization*' }
        @{ Case = 'missing organization output'; Change = { $state.outputs.Remove('organizations') }; ExpectedError = '*exactly the selected organization*' }
        @{ Case = 'scalar organization output'; Change = { $state.outputs.organizations.value = 'demo-workloads' }; ExpectedError = '*exactly the selected organization*' }
        @{ Case = 'non-string output organization'; Change = { $state.outputs.organizations.value[0] = 3 }; ExpectedError = '*exactly the selected organization*' }
        @{ Case = 'array-valued output organization'; Change = { $state.outputs.organizations.value[0] = @('demo-workloads') }; ExpectedError = '*exactly the selected organization*' }
        @{ Case = 'output case'; Change = { $state.outputs.organizations.value[0] = 'Demo-workloads' }; ExpectedError = '*exactly the selected organization*' }
        @{ Case = 'non-object resource'; Change = { $state.resources[3] = 'other' }; ExpectedError = '*unsupported resource address*' }
        @{ Case = 'non-string mode'; Change = { $state.resources[3].mode = @('managed') }; ExpectedError = '*unsupported resource address*' }
        @{ Case = 'mode case'; Change = { $state.resources[3].mode = 'Managed' }; ExpectedError = '*foreign or duplicate resource*' }
        @{ Case = 'non-string type'; Change = { $state.resources[3].type = @('restapi_object') }; ExpectedError = '*unsupported resource address*' }
        @{ Case = 'non-string name'; Change = { $state.resources[3].name = @('ruleset') }; ExpectedError = '*unsupported resource address*' }
        @{ Case = 'non-list instances'; Change = { $state.resources[3].instances = @{} }; ExpectedError = '*organization instance*' }
        @{ Case = 'missing instances'; Change = { $state.resources[3].Remove('instances') }; ExpectedError = '*organization instance*' }
        @{ Case = 'non-object instance'; Change = { $state.resources[3].instances[0] = 'other' }; ExpectedError = '*organization instance*' }
        @{ Case = 'non-string instance key'; Change = { $state.resources[3].instances[0].index_key = @('demo-workloads') }; ExpectedError = '*organization instance*' }
    ) {
        . $Change
        Write-TestState
        { & $snapshotCommand @arguments } | Should -Throw $ExpectedError
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'rejects <Case> resource attributes before publication' -ForEach @(
        @{ Case = 'foreign data query'; Change = { $state.resources[0].instances[0].attributes.query.organization = 'demo-platform' }; ExpectedError = '*organization attributes*' }
        @{ Case = 'missing resource attributes'; Change = { $state.resources[0].instances[0].Remove('attributes') }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-object data query'; Change = { $state.resources[0].instances[0].attributes.query = @(@{ organization = 'demo-workloads' }) }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-string data organization'; Change = { $state.resources[0].instances[0].attributes.query.organization = @('demo-workloads') }; ExpectedError = '*organization attributes*' }
        @{ Case = 'query organization case'; Change = { $state.resources[0].instances[0].attributes.query.organization = 'Demo-workloads' }; ExpectedError = '*organization attributes*' }
        @{ Case = 'foreign creation intent'; Change = { $state.resources[2].instances[0].attributes.input.value.organization = 'demo-platform' }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-object creation intent'; Change = { $state.resources[2].instances[0].attributes.input = @(@{ value = @{ organization = 'demo-workloads'; destroy_started = $false } }) }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-object creation input'; Change = { $state.resources[2].instances[0].attributes.input.value = @(@{ organization = 'demo-workloads'; destroy_started = $false }) }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-string intent organization'; Change = { $state.resources[2].instances[0].attributes.input.value.organization = @('demo-workloads') }; ExpectedError = '*organization attributes*' }
        @{ Case = 'creation intent case'; Change = { $state.resources[2].instances[0].attributes.input.value.organization = 'Demo-workloads' }; ExpectedError = '*organization attributes*' }
        @{ Case = 'foreign persisted output'; Change = { $state.resources[2].instances[0].attributes.output.value.organization = 'demo-platform' }; ExpectedError = '*organization attributes*' }
        @{ Case = 'persisted output case'; Change = { $state.resources[2].instances[0].attributes.output.value.organization = 'Demo-workloads' }; ExpectedError = '*organization attributes*' }
        @{ Case = 'teardown intent'; Change = { $state.resources[2].instances[0].attributes.input.value.destroy_started = $true }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-boolean teardown intent'; Change = { $state.resources[2].instances[0].attributes.input.value.destroy_started = 0 }; ExpectedError = '*organization attributes*' }
        @{ Case = 'foreign API path'; Change = { $state.resources[3].instances[0].attributes.path = '/orgs/demo-platform/rulesets' }; ExpectedError = '*organization attributes*' }
        @{ Case = 'API path case'; Change = { $state.resources[3].instances[0].attributes.path = '/orgs/Demo-workloads/rulesets' }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-string API path'; Change = { $state.resources[3].instances[0].attributes.path = @('/orgs/demo-workloads/rulesets') }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-string API ID'; Change = { $state.resources[3].instances[0].attributes.id = 101 }; ExpectedError = '*organization attributes*' }
        # Keep both ID representations equal so the equality guard cannot mask the invalid zero ID.
        @{ Case = 'zero API ID'; Change = { $state.resources[3].instances[0].attributes.id = '0'; $response.id = 0; $state.resources[3].instances[0].attributes.api_response = ConvertTo-Json $response -Depth 30 -Compress }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-string API response'; Change = { $state.resources[3].instances[0].attributes.api_response = @($state.resources[3].instances[0].attributes.api_response) }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-object API response'; Change = { $state.resources[3].instances[0].attributes.api_response = ConvertTo-Json -InputObject @($response) -Depth 30 -Compress }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-string API source'; Change = { $response.source = @('demo-workloads'); $state.resources[3].instances[0].attributes.api_response = ConvertTo-Json $response -Depth 30 -Compress }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-string API source type'; Change = { $response.source_type = @('Organization'); $state.resources[3].instances[0].attributes.api_response = ConvertTo-Json $response -Depth 30 -Compress }; ExpectedError = '*organization attributes*' }
        @{ Case = 'non-integer API response ID'; Change = { $response.id = '101'; $state.resources[3].instances[0].attributes.api_response = ConvertTo-Json $response -Depth 30 -Compress }; ExpectedError = '*organization attributes*' }
        @{ Case = 'foreign API source'; Change = { $response.source = 'demo-platform'; $state.resources[3].instances[0].attributes.api_response = ConvertTo-Json $response -Depth 30 -Compress }; ExpectedError = '*organization attributes*' }
        @{ Case = 'API source case'; Change = { $response.source = 'Demo-workloads'; $state.resources[3].instances[0].attributes.api_response = ConvertTo-Json $response -Depth 30 -Compress }; ExpectedError = '*organization attributes*' }
        @{ Case = 'API source type case'; Change = { $response.source_type = 'organization'; $state.resources[3].instances[0].attributes.api_response = ConvertTo-Json $response -Depth 30 -Compress }; ExpectedError = '*organization attributes*' }
        @{ Case = 'foreign API ID'; Change = { $state.resources[3].instances[0].attributes.id = '102' }; ExpectedError = '*organization attributes*' }
    ) {
        . $Change
        Write-TestState
        { & $snapshotCommand @arguments } | Should -Throw $ExpectedError
        Test-Path -LiteralPath $output | Should -BeFalse
    }

    It 'refuses a second publisher before touching its staging files and recovers after lease release' {
        $staging = "$output.new"
        $null = [IO.Directory]::CreateDirectory($staging)
        $stagedState = Join-Path $staging 'terraform.rulesets.tfstate'
        [IO.File]::WriteAllText($stagedState, 'owned by the first publisher')
        $lease = [IO.File]::Open("$output.lock", [IO.FileMode]::OpenOrCreate, [IO.FileAccess]::ReadWrite, [IO.FileShare]::None)
        try {
            { & $snapshotCommand @arguments } | Should -Throw '*snapshot.lock*'
            [IO.File]::ReadAllText($stagedState) | Should -BeExactly 'owned by the first publisher'
            Test-Path -LiteralPath $output | Should -BeFalse
        }
        finally { $lease.Dispose() }

        $result = & $snapshotCommand @arguments
        (Get-FileHash -LiteralPath $result.StatePath).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
        (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
        Test-Path -LiteralPath $staging | Should -BeFalse
    }

    It 'recovers publication interrupted <Boundary> without changing the source' -ForEach @(
        @{ Boundary = 'after staging directory'; Files = @() }
        @{ Boundary = 'after state'; Files = @('terraform.rulesets.tfstate') }
        @{ Boundary = 'after manifest'; Files = @('terraform.rulesets.tfstate', 'snapshot.json') }
        @{ Boundary = 'after publication'; Files = $null }
    ) {
        $null = & $snapshotCommand @arguments
        if ($null -ne $Files) {
            Move-Item -LiteralPath $output -Destination "$output.new"
            foreach ($name in @('terraform.rulesets.tfstate', 'snapshot.json')) {
                if ($Files -cnotcontains $name) { Remove-Item -LiteralPath (Join-Path "$output.new" $name) }
            }
        }
        $result = & $snapshotCommand @arguments
        Test-Path -LiteralPath "$output.new" | Should -BeFalse
        (Get-FileHash -LiteralPath $result.StatePath).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
        (Get-FileHash -LiteralPath $source).Hash.ToLowerInvariant() | Should -BeExactly $arguments.ExpectedSha256
        [IO.File]::ReadAllText($result.ManifestPath) | Should -Not -BeNullOrEmpty
    }
}
