BeforeAll {
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
    $shard = Get-InterruptionShard
    # The stub of the GitHub API lives in ActionsCatalog.Tests.ps1. The harness reuses its BeforeAll block
    # instead of a copy, so stub changes for new API calls apply here too.
    $stubFile = Join-Path $PSScriptRoot 'ActionsCatalog.Tests.ps1'
    $parseErrors = $null
    $stubAst = [Management.Automation.Language.Parser]::ParseFile($stubFile, [ref] $null, [ref] $parseErrors)
    if ($parseErrors) { throw "Cannot parse $stubFile." }
    $stubBlock = $stubAst.FindAll({
            param($node)
            $node -is [Management.Automation.Language.CommandAst] -and $node.GetCommandName() -ceq 'BeforeAll' -and
            $node.CommandElements.Count -eq 2 -and $node.CommandElements[1] -is [Management.Automation.Language.ScriptBlockExpressionAst]
        }, $true) | Select-Object -First 1
    if (-not $stubBlock) { throw "$stubFile has no BeforeAll block for the catalog stub." }
    . $stubBlock.CommandElements[1].ScriptBlock.GetScriptBlock()
}

Describe 'Actions catalog interruption harness' -Tag 'Interruption' {
    BeforeEach {
        $env:REST_API_BEARER = $token
        $stub = Initialize-CatalogStub
        $plan = Get-InterruptionPlan
        # The stub returns the documented conflict responses of repeated writes:
        # https://docs.github.com/enterprise-cloud@latest/rest/repos/repos#create-an-organization-repository (422)
        # https://docs.github.com/enterprise-cloud@latest/rest/git/refs#create-a-reference (422)
        # https://docs.github.com/enterprise-cloud@latest/rest/repos/contents#create-or-update-file-contents (422 without sha)
        # The remaining writes (access level, team permission) are idempotent PUT requests.
        Mock -ModuleName ActionsCatalog Invoke-WebRequest {
            $uri = [Uri] $Uri
            $method = ([string] $Method).ToUpperInvariant()
            $call = @{ Method = $method; PathAndQuery = $uri.PathAndQuery; Headers = $Headers; Body = $PesterBoundParameters['Body'] }
            $respond = { param($Reply) [pscustomobject]@{ StatusCode = $Reply.Status; Content = $Reply.Body; Headers = @{ Link = $null } } }
            if ($method -ceq 'GET') { return & $respond (Invoke-CatalogStub @call) }
            Invoke-InterruptionStep -Plan $plan -Request "$method $($uri.AbsolutePath)" -Apply {
                & $respond (Invoke-CatalogStub @call)
            } -Interrupt {
                [pscustomobject]@{ StatusCode = 503; Content = '{"message":"Injected interruption."}'; Headers = @{ Link = $null } }
            }
        }
        $resetStub = {
            param([scriptblock] $Prepare)
            $initial = Initialize-CatalogStub
            $stub.Clear()
            foreach ($key in $initial.Keys) { $stub[$key] = $initial[$key] }
            if ($Prepare) { & $Prepare }
        }
        # The module keeps no local state; Terraform records a resource only after its provisioner succeeds.
        $captureLocal = { $null }
        $restoreLocal = { param($Text) $null = $Text }
        $snapshot = {
            $repositories = @{}
            foreach ($name in $stub.Repositories.Keys) {
                $repository = $stub.Repositories[$name]
                $repositories[$name] = @{
                    visibility = $repository.visibility; defaultBranch = $repository.default_branch; access = $repository.access
                    teams = $repository.teams; heads = $repository.heads; tags = $repository.tags
                    files = if ($repository.heads.Contains('main')) { $repository.commits[$repository.heads['main']].files } else { @{} }
                }
            }
            @{ repositories = $repositories }
        }
    }

    AfterEach {
        Remove-Item Env:\REST_API_BEARER -ErrorAction SilentlyContinue
    }

    It 'recovers from an interruption at every mutating step of a new catalog repository' {
        $reset = { & $resetStub }
        $run = { Initialize-CatalogRepository @target }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Initialize-CatalogRepository' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'recovers from an interruption at every mutating step of an adopted repository' {
        $reset = {
            & $resetStub {
                $null = Add-StubRepository -Files @{ '.github/CODEOWNERS' = $codeOwners }
            }
        }
        $run = { Initialize-CatalogRepository @target }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'Initialize-CatalogRepository (adoption)' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }

    It 'recovers from an interruption at every mutating step of a release tag' {
        $reset = {
            & $resetStub {
                $null = Add-StubCompliantRepository -Files @{ '.vendoring.json' = (Get-StubReceipt); 'action.yml' = 'name: checkout' }
            }
        }
        $run = {
            $release = $stub.Repositories[$repositoryName].heads['main']
            New-CatalogReleaseTag @target -Tag 'v4.2.2' -Commit $release
        }

        $result = @(Invoke-InterruptionMatrix -Plan $plan -Reset $reset -Run $run -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)

        $report = Format-InterruptionResult -Name 'New-CatalogReleaseTag' -Result $result
        Write-Information $report -InformationAction Continue
        @($result | Where-Object { -not $_.Passed }).Count | Should -Be 0 -Because $report
    }
}
