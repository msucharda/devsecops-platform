output "organizations" {
  description = "Organizations with the enforced code security baseline."
  value       = sort(var.target_organizations)
}

output "code_security_configuration" {
  description = "Name and managed settings of the enforced code security configuration in every organization."
  value = {
    name     = local.code_security_configuration_name
    settings = local.code_security_settings
  }
}

output "custom_patterns" {
  description = "Names of the custom patterns with push protection in every organization."
  value       = sort(keys(local.custom_patterns))
}
