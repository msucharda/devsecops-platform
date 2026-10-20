output "organizations" {
  description = "Organizations with the managed baseline."
  value       = sort(var.target_organizations)
}

output "organization_settings" {
  description = "Managed organization settings applied to every organization."
  value       = local.organization_settings
}
