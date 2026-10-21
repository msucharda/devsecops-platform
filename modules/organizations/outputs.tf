output "deployment_identifier" {
  description = "Deployment identifier of the instance; null for the legacy naming."
  value       = var.instance.organizations.deploymentIdentifier
}

output "organizations" {
  description = "Logins of the instance organizations managed or verified by this module."
  value = {
    for kind, organization in local.organizations : kind => organization.organization
  }
  depends_on = [data.external.organization_state]
}
