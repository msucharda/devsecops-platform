locals {
  # Fields of PUT /orgs/{org}/actions/permissions and PUT /orgs/{org}/actions/permissions/workflow (API version 2026-03-10).
  # local_only allows actions of the organization and of the enterprise, including the catalog repositories of the
  # actions organization, which are open to the enterprise. Dependabot updates need no allowed action (issue #6, C4).
  # can_approve_pull_request_reviews also controls whether GitHub Actions can create pull requests.
  actions_policy = {
    enabled_repositories             = "all"
    allowed_actions                  = "local_only"
    default_workflow_permissions     = "read"
    can_approve_pull_request_reviews = false
  }

  # GitHub defaults of the managed fields; destroy restores only these.
  actions_policy_github_defaults = {
    enabled_repositories             = "all"
    allowed_actions                  = "all"
    default_workflow_permissions     = "read"
    can_approve_pull_request_reviews = false
  }

  actions_policy_script = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Invoke-ActionsPolicyChange.ps1", "-Action"]
}

# The REST provider expects a JSON body from every write, but both PUT requests answer 204 without one. Scripts
# therefore write the policy; every write is an idempotent PUT, so a repeated apply after an interruption converges.

# Identity of the policy. Only its destroy restores the GitHub defaults of the managed fields.
resource "terraform_data" "actions_policy" {
  for_each = toset(var.target_organizations)

  input = {
    api_url      = local.github_api_url
    organization = each.key
    policy       = local.actions_policy_github_defaults
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Invoke-ActionsPolicyChange.ps1", "-Action"]
    command     = "ResetPolicy"
    environment = { ACTIONS_POLICY_INPUT = jsonencode(self.input) }
  }
}

# Content of the policy. A change replaces only this resource, so the policy is never reset to the defaults in between.
resource "terraform_data" "actions_policy_settings" {
  for_each = toset(var.target_organizations)

  triggers_replace = {
    identity = terraform_data.actions_policy[each.key].id
    policy   = local.actions_policy
  }

  input = {
    api_url      = local.github_api_url
    organization = each.key
    policy       = local.actions_policy
  }

  provisioner "local-exec" {
    interpreter = local.actions_policy_script
    command     = "SetPolicy"
    environment = { ACTIONS_POLICY_INPUT = jsonencode(self.input) }
  }
}

# Reads the actual policy. Without pending changes the plan reads it and fails on drift; with pending changes the read
# waits for apply and verifies the result. A read error fails the run, so an unknown state never passes as compliant.
# Only its postcondition consumes the result.
# tflint-ignore: terraform_unused_declarations
data "external" "actions_policy_state" {
  for_each = toset(var.target_organizations)

  program = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Read-ActionsPolicyState.ps1"]
  query = merge({ for field, value in local.actions_policy : field => tostring(value) }, {
    api_url      = local.github_api_url
    organization = each.key
  })

  depends_on = [terraform_data.actions_policy, terraform_data.actions_policy_settings]

  lifecycle {
    postcondition {
      condition     = length(jsondecode(self.result.violations)) == 0
      error_message = "${join(" ", jsondecode(self.result.violations))} The module does not repair drift automatically; restore the policy or rerun the apply with -replace=terraform_data.actions_policy_settings[\"${each.key}\"]."
    }
  }
}
