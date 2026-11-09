#Requires -Version 7.4
[CmdletBinding()]
param([AllowEmptyString()][string] $DevelopmentApprovalJson = $env:PLATFORM_DEVELOPMENT_APPROVAL)

Set-StrictMode -Version Latest
$ErrorActionPreference = 'Stop'

# security-check: standard-deployment-development-lock
function Assert-StandardDeploymentAvailability {
    param([AllowEmptyString()][string] $ApprovalJson)
    if (-not [string]::IsNullOrWhiteSpace($ApprovalJson)) {
        throw 'Standard deployment is locked by an outstanding development approval. Record adoption or rollback and explicitly clear the external approval before resuming; expiration is not rollback.'
    }
}

Assert-StandardDeploymentAvailability -ApprovalJson $DevelopmentApprovalJson
