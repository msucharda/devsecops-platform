locals {
  api_url = "https://api.${var.instance.github.host}"
  kinds   = ["actions", "workloads"]
  organizations = {
    for kind in local.kinds : kind => {
      api_url      = local.api_url
      enterprise   = var.instance.github.enterprise
      organization = var.instance.organizations[kind]
    }
  }
  installations = {
    for pair in setproduct(local.kinds, var.app_client_ids) : "${pair[0]}/${pair[1]}" => {
      kind      = pair[0]
      client_id = pair[1]
    }
  }
  # The random deployment identifier proves that an existing organization with this name belongs to this deployment.
  owns_existing = var.instance.organizations.deploymentIdentifier != null
  provisioner   = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Invoke-OrganizationChange.ps1", "-Action"]
}

# Creates the organization through the GraphQL mutation createEnterpriseOrganization. The input holds only the
# identity of the organization; owners and billing email apply only on creation, so changing them replaces nothing.
resource "terraform_data" "organization" {
  for_each = local.organizations

  input = each.value

  provisioner "local-exec" {
    interpreter = local.provisioner
    command     = "CreateOrganization"
    environment = {
      ORGANIZATIONS_INPUT = jsonencode(merge(each.value, {
        admin_logins   = var.admin_logins
        billing_email  = var.billing_email
        allow_existing = local.owns_existing || contains(var.adopt_organizations, each.key)
      }))
    }
  }

  # GitHub has no API to delete an organization with an App token. A human deletes it (manual step
  # delete-instance-organizations); destroy only verifies that it is gone and fails closed otherwise.
  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Invoke-OrganizationChange.ps1", "-Action"]
    command     = "AssertOrganizationRemoved"
    environment = {
      ORGANIZATIONS_INPUT = jsonencode(self.input)
    }
  }
}

resource "terraform_data" "installation" {
  for_each = local.installations

  input = merge(local.organizations[each.value.kind], { client_id = each.value.client_id })

  triggers_replace = [terraform_data.organization[each.value.kind].id]

  provisioner "local-exec" {
    interpreter = local.provisioner
    command     = "InstallApp"
    environment = {
      ORGANIZATIONS_INPUT = jsonencode(self.input)
    }
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Invoke-OrganizationChange.ps1", "-Action"]
    command     = "UninstallApp"
    environment = {
      ORGANIZATIONS_INPUT = jsonencode(self.input)
    }
  }
}

# Reads the live state after the changes. The program lists every difference from the module state (deleted
# organization, missing App, App with access to all repositories) and fails on any read error, so the plan never
# treats an unknown state as compliant. Terraform does not evaluate the postcondition when planning a destroy.
data "external" "organization_state" {
  for_each = local.organizations

  program = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Read-OrganizationState.ps1"]
  query   = merge(each.value, { client_ids = jsonencode(var.app_client_ids) })

  depends_on = [terraform_data.organization, terraform_data.installation]

  lifecycle {
    postcondition {
      condition     = length(jsondecode(self.result.violations)) == 0
      error_message = join(" ", jsondecode(self.result.violations))
    }
  }
}