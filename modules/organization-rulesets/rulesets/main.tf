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

# This read must not depend on mutable resources: pending changes in another organization cannot defer it to apply.
# tflint-ignore: terraform_unused_declarations
data "external" "ruleset_plan_state" {
  for_each = toset(var.target_organizations)

  program = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/../scripts/Read-RulesetState.ps1"]
  query = {
    api_url      = local.github_api_url
    organization = each.key
    name         = local.ruleset.name
  }

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.result.state) == null ? true : jsonencode(jsondecode(self.result.state).bypass_actors) == "[]", false)
      error_message = "The existing ruleset of ${each.key} has bypass actors; restore the empty bypass list before apply."
    }
    postcondition {
      condition     = try(jsondecode(self.result.state) == null || jsonencode(jsondecode(self.result.state)) == jsonencode(local.ruleset), false)
      error_message = "The existing default branch ruleset of ${each.key} differs from the baseline. Restore the managed settings before apply."
    }
  }
}

# Persist creation intent before POST; recovery can import an object whose POST response was lost.
resource "terraform_data" "ruleset_intent" {
  for_each = toset(var.target_organizations)

  input = {
    api_url         = local.github_api_url
    organization    = each.key
    name            = local.ruleset.name
    destroy_started = var.ruleset_destroy_started
  }
}

import {
  for_each = {
    for organization, state in data.external.ruleset_plan_state :
    organization => state.result.remote_id if state.result.remote_id != ""
  }
  to = restapi_object.ruleset[each.key]
  id = "/orgs/${each.key}/rulesets/${each.value}"
}

resource "restapi_object" "ruleset" {
  for_each = toset(var.target_organizations)

  path                    = "/orgs/${each.key}/rulesets"
  id_attribute            = "id"
  data                    = jsonencode(local.ruleset)
  ignore_server_additions = true

  depends_on = [terraform_data.ruleset_intent]

  lifecycle {
    postcondition {
      condition = try(
        tostring(jsondecode(self.api_response).id) == self.id &&
        jsondecode(self.api_response).source_type == "Organization" &&
        lower(jsondecode(self.api_response).source) == lower(each.key) &&
        jsondecode(self.api_response).name == local.ruleset.name &&
        jsonencode(jsondecode(self.api_response).bypass_actors) == "[]",
        false
      )
      error_message = "The ruleset of ${each.key} has mismatched identity, bypass actors or an unreadable bypass_actors field."
    }
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

  depends_on = [restapi_object.ruleset]

  lifecycle {
    postcondition {
      condition     = try(jsonencode(jsondecode(self.result.state).bypass_actors) == "[]", false)
      error_message = "The ruleset of ${each.key} has bypass actors or did not expose bypass_actors. Missing data is not proof of an empty bypass list."
    }
    postcondition {
      condition     = try(jsonencode(jsondecode(self.result.state)) == jsonencode(local.ruleset), false)
      error_message = "The default branch ruleset of ${each.key} is missing or differs from the baseline. Restore the managed settings before apply."
    }
  }
}
