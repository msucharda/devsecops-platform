mock_provider "external" {
  mock_data "external" {
    defaults = { result = { state = "null", remote_id = "", code_security_ready = "true" } }
  }
}
mock_provider "restapi" {}

variables {
  instance = {
    github = { host = "example.ghe.com" }
    organizations = {
      platform  = "demo-platform"
      actions   = "demo-actions"
      workloads = "demo-workloads"
    }
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
            allowed_merge_methods                           = ["merge", "rebase", "squash"]
            dismiss_stale_reviews_on_push                   = true
            require_code_owner_review                       = true
            require_extra_approval_for_unattributed_changes = true
            require_last_push_approval                      = false
            required_approving_review_count                 = 1
            required_review_thread_resolution               = false
          }
        },
      ])
    ])
    error_message = "The baseline must require one fresh CODEOWNER approval, extra approval for unattributed changes and CodeQL high-or-higher, and deny deletion and force push."
  }
}

run "protects_the_platform_organization" {
  command = plan

  variables {
    target_organizations = ["demo-platform"]
  }

  assert {
    condition = (
      toset(keys(restapi_object.ruleset)) == toset(["demo-platform"]) &&
      restapi_object.ruleset["demo-platform"].path == "/orgs/demo-platform/rulesets" &&
      length(jsondecode(restapi_object.ruleset["demo-platform"].data).bypass_actors) == 0 &&
      length(jsondecode(restapi_object.ruleset["demo-platform"].data).rules) == 4
    )
    error_message = "The platform organization must receive the same complete ruleset without bypass."
  }
}

run "protects_the_workload_organization" {
  command = plan

  variables {
    target_organizations = ["demo-workloads"]
  }

  assert {
    condition = (
      toset(keys(restapi_object.ruleset)) == toset(["demo-workloads"]) &&
      restapi_object.ruleset["demo-workloads"].path == "/orgs/demo-workloads/rulesets" &&
      length(jsondecode(restapi_object.ruleset["demo-workloads"].data).bypass_actors) == 0 &&
      length(jsondecode(restapi_object.ruleset["demo-workloads"].data).rules) == 4
    )
    error_message = "The workload organization must receive the same complete ruleset without bypass."
  }
}

run "rejects_an_organization_outside_the_instance" {
  command = plan

  variables {
    target_organizations = ["foreign"]
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