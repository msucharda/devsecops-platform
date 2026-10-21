output "organizations" {
  description = "Organizations whose rulesets this root manages."
  value       = sort(var.target_organizations)
}
