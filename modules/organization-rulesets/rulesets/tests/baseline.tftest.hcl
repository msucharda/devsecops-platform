mock_provider "external" {
  mock_data "external" {
    defaults = { result = { state = "null", remote_id = "" } }
  }
}
mock_provider "restapi" {}

variables {
  instance = {
    github        = { host = "example.ghe.com" }
    organizations = { actions = "demo-actions" }
  }
  prerequisites        = {}
  target_organizations = ["demo-actions"]
}

run "protects_default_branches_without_bypass" {
  command = plan

  assert {
    condition = alltrue([
      for organization, resource in restapi_object.ruleset :
      resource.path == "/orgs/${organization}/rulesets" &&
      jsondecode(resource.data).name == "platform-default-branch" &&
      jsondecode(resource.data).enforcement == "active" &&
      jsondecode(resource.data).target == "branch" &&
      length(jsondecode(resource.data).bypass_actors) == 0 &&
      jsondecode(resource.data).conditions.ref_name.include == ["~DEFAULT_BRANCH"] &&
      length(jsondecode(resource.data).conditions.ref_name.exclude) == 0 &&
      jsondecode(resource.data).conditions.repository_name.include == ["~ALL"] &&
      length(jsondecode(resource.data).conditions.repository_name.exclude) == 0
    ]) && length(restapi_object.ruleset) == 1
    error_message = "Each organization must enforce its default branches in all repositories, without bypass or exclusions."
  }

  assert {
    condition = alltrue([
      for resource in restapi_object.ruleset :
      jsonencode(jsondecode(resource.data).rules) == jsonencode([
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
            dismiss_stale_reviews_on_push      = true
            require_code_owner_review         = true
            require_last_push_approval        = false
            required_approving_review_count   = 1
            required_review_thread_resolution = false
          }
        },
      ])
    ])
    error_message = "The baseline must require one fresh CODEOWNER approval and CodeQL high-or-higher, and deny deletion and force push."
  }
}

run "rejects_an_organization_other_than_the_actions_organization" {
  command = plan

  variables {
    target_organizations = ["demo-workloads"]
  }

  expect_failures = [var.target_organizations]
}

run "rejects_an_instance_without_organizations" {
  command = plan

  variables {
    instance = { github = { host = "example.ghe.com" } }
  }

  expect_failures = [var.instance]
}