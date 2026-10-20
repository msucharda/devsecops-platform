BeforeAll {
    $root = Split-Path (Split-Path $PSScriptRoot -Parent) -Parent
    $runbook = Get-Content -LiteralPath (Join-Path $root 'docs/runbooks/organizations-c3.md') -Raw
    $helperBlock = @([regex]::Matches($runbook, '(?s)```powershell\r?\n(.*?)```') |
        Where-Object { $_.Groups[1].Value -match 'function New-C3Token' })
    if ($helperBlock.Count -ne 1) { throw 'Expected one C3 helper block.' }
    . ([scriptblock]::Create($helperBlock[0].Groups[1].Value))
    $rsa = [Security.Cryptography.RSA]::Create(2048)
    $keyPath = Join-Path $TestDrive 'app.pem'
    $rsa.ExportRSAPrivateKeyPem() | Set-Content -LiteralPath $keyPath
    $rsa.Dispose()
    $api = 'https://api.example.test'
}

Describe 'C3 runbook token contract' {
    BeforeEach {
        $app = @{
            appId = '101'; installationId = '201'
            permissions = @{ enterprise_organization_installations = 'read' }
        }
        Mock Invoke-RestMethod {
            return @{ token = 'c3-fake-token'; permissions = @{ enterprise_organization_installations = 'read' } }
        }
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 204 } }
    }

    It 'returns the actual permissions as a separate sanitized record with a SecureString token' {
        $result = New-C3Token -App $app -KeyPath $keyPath
        try {
            $result.Token | Should -BeOfType ([securestring])
            $result.Permissions.enterprise_organization_installations | Should -BeExactly 'read'
            $result.Permissions | ConvertTo-Json -Compress | Should -Not -Match 'c3-fake-token'
            Should -Invoke Invoke-WebRequest -Times 0 -Exactly
        } finally {
            if ($result.Token -is [securestring]) { $result.Token.Dispose() }
        }
    }

    It 'preserves implicit metadata in the actual organization-token evidence without broadening the contract' {
        $app.permissions = @{ members = 'read'; organization_administration = 'write' }
        Mock Invoke-RestMethod {
            return @{ token = 'c3-fake-token'; permissions = [pscustomobject]@{
                organization_administration = 'write'; metadata = 'read'; members = 'read'
            } }
        }

        $result = New-C3Token -App $app -KeyPath $keyPath -Organization
        try {
            $result.Permissions.metadata | Should -BeExactly 'read'
            $result.Permissions.members | Should -BeExactly 'read'
            $app.permissions.Contains('metadata') | Should -BeFalse
            Should -Invoke Invoke-RestMethod -Times 1 -Exactly -ParameterFilter {
                $Method -eq 'POST' -and $Body -match '"members":"read"' -and $Body -notmatch 'metadata'
            }
        } finally { $result.Token.Dispose() }
    }

    It 'revokes and rejects token permissions that differ from the current contract: <Case>' -ForEach @(
        @{ Case = 'broader access'; Actual = @{ enterprise_organization_installations = 'write' } }
        @{ Case = 'additional permission'; Actual = @{ enterprise_organization_installations = 'read'; enterprise_administration = 'read' } }
        @{ Case = 'missing permission'; Actual = @{} }
        @{ Case = 'missing map'; Actual = $null }
    ) {
        Mock Invoke-RestMethod { return @{ token = 'c3-fake-token'; permissions = $Actual } }

        { New-C3Token -App $app -KeyPath $keyPath } | Should -Throw '*permissions*'

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly -ParameterFilter {
            $Method -eq 'DELETE' -and $Uri -eq 'https://api.example.test/installation/token' -and
                $Token -is [securestring]
        }
    }

    It 'reports unconfirmed revocation instead of hiding cleanup failure' {
        Mock Invoke-RestMethod {
            return @{ token = 'c3-fake-token'; permissions = @{ enterprise_organization_installations = 'write' } }
        }
        Mock Invoke-WebRequest { [pscustomobject]@{ StatusCode = 403 } }

        { New-C3Token -App $app -KeyPath $keyPath } | Should -Throw '*revocation was not confirmed*HTTP 403*'

        Should -Invoke Invoke-WebRequest -Times 1 -Exactly
    }
}
