locals {
  api_url      = "https://api.${var.instance.github.host}"
  organization = one(var.target_organizations)
  program      = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Invoke-OrganizationRoleChange.ps1", "-Action"]
}

data "external" "role_plan_state" {
  program = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Read-OrganizationRoleState.ps1"]
  query = {
    api_url      = local.api_url
    organization = local.organization
    team         = var.security_team
  }
}

# Keep destroy cleanup separate from a possibly tainted assignment resource.
resource "terraform_data" "role_guard" {
  input = {
    api_url      = local.api_url
    organization = local.organization
    team         = var.security_team
    role_name    = "security_manager"
    role_id      = tonumber(data.external.role_plan_state.result.role_id)
    team_id      = tonumber(data.external.role_plan_state.result.team_id)
  }
  triggers_replace = [
    local.api_url, local.organization,
    data.external.role_plan_state.result.role_id, data.external.role_plan_state.result.team_id,
  ]

  provisioner "local-exec" {
    interpreter = local.program
    command     = "AssertIdentity"
    environment = {
      ORGANIZATION_ROLES_INPUT = jsonencode(self.input)
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Invoke-OrganizationRoleChange.ps1", "-Action"]
    command     = "Remove"
    environment = {
      ORGANIZATION_ROLES_INPUT = jsonencode(self.input)
    }
  }
}

resource "terraform_data" "assignment" {
  input            = terraform_data.role_guard.output
  triggers_replace = terraform_data.role_guard.id

  provisioner "local-exec" {
    interpreter = local.program
    command     = "Assign"
    environment = {
      ORGANIZATION_ROLES_INPUT = jsonencode(self.input)
    }
  }
}

data "external" "role_state" {
  program = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Read-OrganizationRoleState.ps1"]
  query = {
    api_url      = local.api_url
    organization = local.organization
    team         = var.security_team
  }
  depends_on = [terraform_data.assignment]

  lifecycle {
    postcondition {
      condition     = self.result.assigned == "true"
      error_message = "The organization security team has no direct security_manager role assignment."
    }
  }
}
