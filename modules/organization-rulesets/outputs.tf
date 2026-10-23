# Dependent modules read this output; the deploy job publishes it only after the rulesets root apply succeeded.
output "organizations" {
  description = "Organizations whose rulesets the rulesets root of this module manages."
  value       = sort(var.target_organizations)
}
