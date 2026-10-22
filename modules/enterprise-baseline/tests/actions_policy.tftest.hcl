# Plan-only tests of the actions policy. Provisioners and the state reader run in the Pester stub tests
# (tools/tests/EnterpriseBaseline.Tests.ps1); a plan defers the reader while the managed objects have pending changes.
mock_provider "restapi" {
  override_during = plan

  mock_resource "restapi_object" {
    defaults = {
      id              = "mock"
      api_response    = "{}"
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }
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
          default_workflow_permissions     = "read"
          can_approve_pull_request_reviews = false
        }
      }
    ])
    error_message = "Destroy must restore the GitHub defaults of the managed fields in the organization."
  }
}
