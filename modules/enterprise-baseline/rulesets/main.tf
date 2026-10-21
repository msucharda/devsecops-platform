locals {
  github_api_url = "https://api.${var.instance.github.host}"
  ruleset = {
    name          = "platform-default-branch"
    target        = "branch"
    enforcement   = "active"
    bypass_actors = []
    conditions = {
      ref_name        = { include = ["~DEFAULT_BRANCH"], exclude = [] }
      repository_name = { include = ["~ALL"], exclude = [], protected = false }
    }
    rules = [
      {
        type = "code_scanning"
        parameters = {
          code_scanning_tools = [{
            tool                      = "CodeQL"
            alerts_threshold          = "none"
            security_alerts_threshold = "high_or_higher"
          }]
        }
      },
      { type = "deletion" },
      { type = "non_fast_forward" },
      {
        type = "pull_request"
        parameters = {
          allowed_merge_methods             = ["merge", "rebase", "squash"]
          dismiss_stale_reviews_on_push     = true
          require_code_owner_review         = true
          require_last_push_approval        = false
          required_approving_review_count   = 1
          required_review_thread_resolution = false
        }
      },
    ]
  }
}

# Persist identity before the remote POST. A lost response is recovered by name on the next apply.
resource "terraform_data" "ruleset" {
  for_each = toset(var.target_organizations)

  input = {
    api_url      = local.github_api_url
    organization = each.key
    name         = local.ruleset.name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/../scripts/Invoke-RulesetChange.ps1", "-Action"]
    command     = "Remove"
    environment = { RULESET_INPUT = jsonencode(self.input) }
  }
}

resource "terraform_data" "ruleset_content" {
  for_each = toset(var.target_organizations)

  triggers_replace = {
    identity = terraform_data.ruleset[each.key].id
    ruleset  = local.ruleset
  }

  input = {
    api_url      = local.github_api_url
    organization = each.key
    ruleset      = local.ruleset
  }

  provisioner "local-exec" {
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/../scripts/Invoke-RulesetChange.ps1", "-Action"]
    command     = "Set"
    environment = { RULESET_INPUT = jsonencode(self.input) }
  }
}

# Refresh must read the full detail, not the list's permission-dependent projection.
# tflint-ignore: terraform_unused_declarations
data "external" "ruleset_state" {
  for_each = toset(var.target_organizations)

  program = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/../scripts/Read-RulesetState.ps1"]
  query = {
    api_url      = local.github_api_url
    organization = each.key
    name         = local.ruleset.name
  }

  depends_on = [terraform_data.ruleset_content]

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.result.state).bypass_actors == [], false)
      error_message = "The ruleset of ${each.key} has bypass actors or did not expose bypass_actors. Missing data is not proof of an empty bypass list."
    }
    postcondition {
      condition     = try(jsonencode(jsondecode(self.result.state)) == jsonencode(local.ruleset), false)
      error_message = "The default branch ruleset of ${each.key} is missing or differs from the baseline. Restore it or rerun apply with -replace=terraform_data.ruleset_content[\"${each.key}\"]."
    }
  }
}
