BeforeAll {
    $tools = Split-Path $PSScriptRoot -Parent
    Import-Module (Join-Path $tools 'ToolDependencies.psm1') -Force
    Import-Module (Join-Path $PSScriptRoot 'InterruptionHarness.psm1') -Force
}

Describe 'Vendored runtime update recovery' -Tag Interruption {
    It 'keeps an importable pin and resumes across every interrupted publication boundary' {
        $root = Join-Path $TestDrive 'active-tools'
        $initial = Join-Path $TestDrive 'initial-tools'
        $null = New-Item -ItemType Directory -Path $initial
        Copy-Item (Join-Path $tools 'requirements.psd1') $initial
        Copy-Item (Join-Path $tools 'vendor') (Join-Path $initial 'vendor') -Recurse
        $old = Import-PowerShellDataFile (Join-Path $initial 'requirements.psd1')
        $oldVersion = $old.Runtime['powershell-yaml']
        $payload = Join-Path $TestDrive 'next-payload'
        Copy-Item (Join-Path $initial "vendor/powershell-yaml/$oldVersion") $payload -Recurse
        # Deliberately synthetic next-version package; not a published upstream release.
        $nextVersion = '99.0.0'
        $manifest = Join-Path $payload 'powershell-yaml.psd1'
        Set-Content -LiteralPath $manifest -Value ((Get-Content $manifest -Raw).Replace(
            "ModuleVersion = '$oldVersion'", "ModuleVersion = '$nextVersion'"))
        $null = New-Item -ItemType Directory -Path (Join-Path $payload '_rels'), (Join-Path $payload 'package')
        Set-Content (Join-Path $payload '_rels/.rels') '<Relationships/>'
        Set-Content (Join-Path $payload 'package/metadata') 'metadata'
        Set-Content -LiteralPath (Join-Path $payload '[Content_Types].xml') -Value '<Types/>'
        $fixturePackage = Join-Path $TestDrive 'next.nupkg'
        [IO.Compression.ZipFile]::CreateFromDirectory($payload, $fixturePackage)
        $fixture = @{
            Plan = Get-InterruptionPlan
            Root = $root
            Package = $fixturePackage
            Hash = (Get-FileHash $fixturePackage).Hash
            Move = Get-Command Move-Item -CommandType Cmdlet
            Write = Get-Command Set-Content -CommandType Cmdlet
            Remove = Get-Command Remove-Item -CommandType Cmdlet
        }
        Mock Invoke-WebRequest {
            Invoke-InterruptionStep -Plan $fixture.Plan -Request 'Download package' -Apply {
                Copy-Item -LiteralPath $fixture.Package -Destination $OutFile
            } -Interrupt { throw 'Injected updater interruption.' }
        }
        Mock Move-Item {
            $request = if ($Destination -like '*.nupkg') { 'Publish package' }
                elseif ($Destination -like '*requirements.psd1') { 'Unsafe pin overwrite' }
                else { 'Publish module' }
            if ($request -eq 'Unsafe pin overwrite' -and (Test-Path -LiteralPath $Destination)) {
                # PowerShell 7.4 deletes the existing destination before moving the replacement.
                # https://github.com/PowerShell/PowerShell/blob/v7.4.0/src/System.Management.Automation/namespaces/FileSystemProvider.cs#L5919-L5930
                [IO.File]::Delete($Destination)
            }
            $identity = if ($request -in @('Publish module', 'Publish package')) { $request } else { '' }
            Invoke-InterruptionStep -Plan $fixture.Plan -Request $request -Identity $identity -Apply {
                & $fixture.Move -LiteralPath $LiteralPath -Destination $Destination -Force:$Force
            } -Interrupt { throw 'Injected updater interruption.' }
        }
        Mock Set-Content {
            Invoke-InterruptionStep -Plan $fixture.Plan -Request 'Prepare pin' -Apply {
                & $fixture.Write -LiteralPath $LiteralPath -Value $Value -NoNewline:$NoNewline -Encoding $Encoding
            } -Interrupt { throw 'Injected updater interruption.' }
        } -ParameterFilter { $LiteralPath -like '*requirements.psd1' }
        Mock Remove-Item {
            Invoke-InterruptionStep -Plan $fixture.Plan -Request 'Clean staging after pin commit' -Apply {
                & $fixture.Remove -LiteralPath $LiteralPath -Recurse -Force
            } -Interrupt { throw 'Injected updater interruption.' }
        } -ParameterFilter { (Split-Path $LiteralPath -Leaf) -like 'vendor-update-*' }

        $reset = {
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            Copy-Item -LiteralPath $initial -Destination $root -Recurse
        }
        $run = {
            & (Join-Path $tools 'Update-VendoredModule.ps1') -ToolsPath $root -Version $nextVersion -Sha256 $fixture.Hash
        }
        $recover = {
            param($InterruptedError)
            $null = $InterruptedError
            # The pin must be usable before retry, not merely repairable by the next run.
            $active = Get-ToolDependencyPath -Name powershell-yaml -ToolsPath $root
            Test-Path -LiteralPath $active | Should -BeTrue
            & $run
        }
        $snapshot = {
            $files = @{}
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Force -File) {
                $relative = [IO.Path]::GetRelativePath($root, $file.FullName)
                if ($relative -match '(^|[\\/])\.dependencies([\\/]|$)') { continue }
                $files[$relative] = (Get-FileHash -LiteralPath $file.FullName).Hash
            }
            return $files
        }
        $captureLocal = {
            $files = @{}
            foreach ($file in Get-ChildItem -LiteralPath $root -Recurse -Force -File) {
                $relative = [IO.Path]::GetRelativePath($root, $file.FullName)
                $files[$relative] = [Convert]::ToBase64String([IO.File]::ReadAllBytes($file.FullName))
            }
            return $files
        }
        $restoreLocal = {
            param($State)
            if (Test-Path -LiteralPath $root) { Remove-Item -LiteralPath $root -Recurse -Force }
            $null = [IO.Directory]::CreateDirectory($root)
            foreach ($relative in $State.Keys) {
                $path = Join-Path $root $relative
                $null = [IO.Directory]::CreateDirectory((Split-Path $path -Parent))
                [IO.File]::WriteAllBytes($path, [Convert]::FromBase64String($State[$relative]))
            }
        }
        $shard = Get-InterruptionShard
        $results = @(Invoke-InterruptionMatrix -Plan $fixture.Plan -Reset $reset -Run $run -Recover $recover `
            -Snapshot $snapshot -CaptureLocal $captureLocal -RestoreLocal $restoreLocal @shard)
        $failures = @($results | Where-Object { -not $_.Passed })
        $failures.Count | Should -Be 0 -Because (($failures | ForEach-Object {
            "$($_.Stop)/$($_.Kind) $($_.Request): $($_.Problem)"
        }) -join "`n")
        $steps = @((1..5) | Where-Object { ($_ - 1) % $shard.ShardCount -eq $shard.ShardIndex })
        $results.Count | Should -Be ($steps.Count * 4)
        Write-Information "Updater interruption matrix: $($results.Count) cases passed." -InformationAction Continue
    }
}
