locals {
  # Fields of PATCH /orgs/{org} (API version 2026-03-10) the module manages.
  # EMU organizations have no public repositories, so public creation is not managed.
  organization_settings = {
    default_repository_permission            = "none"
    members_can_create_repositories          = false
    members_can_create_private_repositories  = false
    members_can_create_internal_repositories = false
    members_can_fork_private_repositories    = false
  }

  # GitHub defaults of the managed fields; destroy restores only these.
  github_defaults = {
    default_repository_permission            = "read"
    members_can_create_repositories          = true
    members_can_create_private_repositories  = true
    members_can_create_internal_repositories = true
    members_can_fork_private_repositories    = false
  }

  # Enterprise policies enforce these; the organization API reads but cannot set them.
  enterprise_enforced_settings = {
    members_can_change_repo_visibility = false
    members_can_delete_repositories    = false
  }
}

# The organization exists before the module runs, so every method is an idempotent PATCH.
# A run interrupted before Terraform records state repeats the same PATCH on the next apply.
resource "restapi_object" "organization_settings" {
  for_each = toset(var.target_organizations)

  path                    = "/orgs"
  object_id               = each.key
  id_attribute            = "login"
  create_path             = "/orgs/${each.key}"
  create_method           = "PATCH"
  update_method           = "PATCH"
  destroy_method          = "PATCH"
  data                    = jsonencode(local.organization_settings)
  destroy_data            = jsonencode(local.github_defaults)
  ignore_server_additions = true

  lifecycle {
    postcondition {
      condition = alltrue([
        for field, value in local.organization_settings :
        try(self.api_data[field], null) == tostring(value)
      ])
      error_message = "GitHub did not return the managed organization baseline for ${each.key}. A missing field means the token cannot read it; treat this as a failure."
    }
  }
}

check "enterprise_repository_management_policies" {
  assert {
    condition = alltrue(flatten([
      for settings in restapi_object.organization_settings : [
        for field, value in local.enterprise_enforced_settings :
        try(settings.api_data[field], null) == tostring(value)
      ]
    ]))
    error_message = "An organization reports that members can change repository visibility or delete repositories, or GitHub did not return these fields. Verify the enterprise prerequisite repositoryManagementPoliciesEnforced."
  }
}
