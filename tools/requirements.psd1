@{
    Runtime = @{
        'powershell-yaml' = '0.4.12'
    }
    Development = @{
        Pester = '5.7.1'
        PSScriptAnalyzer = '1.24.0'
    }
    Sha256 = @{
        'powershell-yaml' = 'd4602bc7a4a093766520422d53ca8b09acde162286fae11e2ee6c8edfea07810'
        Pester = '4a27904c6814a5fbe4758f8e49861f6a1994aee77b71165a5c43c0371ba6c580'
        PSScriptAnalyzer = 'e86c97d44bb1bc8a1de35e753b85ea1d938f6f9f881639a181507e079bca4556'
    }
    Binaries = @{
        Terraform = @{
            Version = '1.16.5'
            LinuxAmd64Sha256 = '2807bc0c4edde23aabe665a82482398e0b67c537bcf556669a9b0e9580c4f510'
            LinuxAmd64ArchiveSha256 = '2bc2fcfff033265c9e02ca0351f01794eb122f62a9b2a49a3294b9e49eaab5e4'
            WindowsAmd64ArchiveSha256 = '01700102b7291f95c0ab61394b55bfd5f57a12ac65632c2c1958691c8cf438ef'
        }
        TFLint = @{
            Version = '0.60.0'
            LinuxAmd64ArchiveSha256 = '3476ceedcf0c4f9f2bed35e92988e1411bec2caa543c9387bffaa720df9efaf7'
        }
        Actionlint = @{
            Version = '1.7.7'
            LinuxAmd64ArchiveSha256 = '023070a287cd8cccd71515fedc843f1985bf96c436b7effaecce67290e7e0757'
            WindowsAmd64ArchiveSha256 = '7f12f1801bca3d480d67aaf7774f4c2a6359a3ca8eebe382c95c10c9704aa731'
        }
    }
}
