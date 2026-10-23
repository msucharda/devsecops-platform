output "organization" {
  description = "Organization of this isolated process."
  value       = local.organization
}

output "security_manager" {
  description = "Declared security-manager assignment; apply and drift verify the actual assignment."
  value = {
    team     = var.security_team
    role_id  = tonumber(data.external.role_plan_state.result.role_id)
    team_id  = tonumber(data.external.role_plan_state.result.team_id)
    assigned = true
  }
}
