# Plan-only tests of the actions policy. Provisioners and the state reader run in the Pester stub tests
# (tools/tests/EnterpriseBaseline.Tests.ps1); a plan defers the reader while the managed objects have pending changes.
mock_provider "restapi" {
  override_during = plan
  source          = "./tests/mocks"
}

mock_provider "external" {}

variables {
  instance = {
    name = "demo"
    github = {
      host       = "example.ghe.com"
      enterprise = "example"
    }
  }
  prerequisites        = {}
  target_organizations = ["demo-platform", "demo-workloads"]
  secret_scanning_bypass_reviewers = [
    { reviewer_type = "TEAM", reviewer_id = 5678 },
  ]
}

run "manages_the_policy_of_every_organization" {
  command = plan

  assert {
    condition = alltrue([
      for settings in restapi_object.organization_settings :
      settings.api_data == tomap({
        for field, value in jsondecode(settings.api_response) :
        field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      })
    ])
    error_message = "The mock api_data must be the provider's string projection of the same api_response, including omitted fields."
  }

  assert {
    condition = (
      toset(keys(terraform_data.actions_policy)) == toset(["demo-platform", "demo-workloads"]) &&
      toset(keys(terraform_data.actions_policy_settings)) == toset(["demo-platform", "demo-workloads"]) &&
      toset(keys(data.external.actions_policy_state)) == toset(["demo-platform", "demo-workloads"])
    )
    error_message = "Every instance organization must have the policy identity, its settings and a state reader."
  }

  assert {
    condition = alltrue([
      for organization, policy in terraform_data.actions_policy_settings :
      policy.input == {
        api_url      = "https://api.example.ghe.com"
        organization = organization
        policy = {
          enabled_repositories             = "all"
          allowed_actions                  = "local_only"
          sha_pinning_required             = true
          default_workflow_permissions     = "read"
          can_approve_pull_request_reviews = false
        }
      } &&
      policy.triggers_replace.policy == policy.input.policy
    ])
    error_message = "Actions must be enabled for all repositories and limited to local actions; GITHUB_TOKEN must be read-only and must not approve or create pull requests."
  }

  assert {
    condition = alltrue([
      for organization, state in data.external.actions_policy_state :
      state.query == tomap({
        api_url                          = "https://api.example.ghe.com"
        organization                     = organization
        enabled_repositories             = "all"
        allowed_actions                  = "local_only"
        sha_pinning_required             = "true"
        default_workflow_permissions     = "read"
        can_approve_pull_request_reviews = "false"
      })
    ])
    error_message = "The state reader must verify the managed policy of its organization."
  }
}

run "restores_the_github_defaults_on_destroy" {
  command = plan

  assert {
    condition = alltrue([
      for organization, policy in terraform_data.actions_policy :
      policy.input == {
        api_url      = "https://api.example.ghe.com"
        organization = organization
        policy = {
          enabled_repositories             = "all"
          allowed_actions                  = "all"
          sha_pinning_required             = false
          default_workflow_permissions     = "read"
          can_approve_pull_request_reviews = false
        }
      }
    ])
    error_message = "Destroy must restore the GitHub defaults of the managed fields in the organization."
  }
}
