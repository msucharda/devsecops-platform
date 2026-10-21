mock_provider "external" {}

variables {
  instance = { github = { host = "example.ghe.com" } }
  prerequisites        = {}
  target_organizations = ["demo-platform", "demo-workloads"]
}

run "protects_default_branches_without_bypass" {
  command = plan

  assert {
    condition = alltrue([
      for organization, resource in terraform_data.ruleset_content :
      resource.input.organization == organization &&
      resource.input.ruleset.name == "platform-default-branch" &&
      resource.input.ruleset.enforcement == "active" &&
      resource.input.ruleset.target == "branch" &&
      length(resource.input.ruleset.bypass_actors) == 0 &&
      resource.input.ruleset.conditions.ref_name.include == ["~DEFAULT_BRANCH"] &&
      length(resource.input.ruleset.conditions.ref_name.exclude) == 0 &&
      resource.input.ruleset.conditions.repository_name.include == ["~ALL"] &&
      length(resource.input.ruleset.conditions.repository_name.exclude) == 0
    ]) && length(terraform_data.ruleset_content) == 2
    error_message = "Each organization must enforce its default branches in all repositories, without bypass or exclusions."
  }

  assert {
    condition = alltrue([
      for resource in terraform_data.ruleset_content :
      resource.input.ruleset.rules == [
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
      ]
    ])
    error_message = "The baseline must require one fresh CODEOWNER approval and CodeQL high-or-higher, and deny deletion and force push."
  }
}
