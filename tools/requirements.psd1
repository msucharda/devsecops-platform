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
        }
        TFLint = @{
            Version = '0.60.0'
            LinuxAmd64ArchiveSha256 = '3476ceedcf0c4f9f2bed35e92988e1411bec2caa543c9387bffaa720df9efaf7'
        }
    }
}
