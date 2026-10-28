# The code security scripts must not run in this file; code_security.tftest.hcl and the Pester stub tests cover them.
mock_provider "external" {}

# Runs see a compliant GitHub response unless the case overrides it.
mock_provider "restapi" {
  override_during = plan
  source          = "./tests/mocks"
}

variables {
  instance = {
    name = "demo"
    github = {
      host       = "example.ghe.com"
      enterprise = "example"
    }
  }
  prerequisites        = {}
  target_organizations = ["demo-platform", "demo-actions", "demo-workloads"]
  secret_scanning_bypass_reviewers = [
    { reviewer_type = "TEAM", reviewer_id = 5678 },
  ]
}

run "manages_each_instance_organization_with_idempotent_patch" {
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
    condition     = toset(keys(restapi_object.organization_settings)) == toset(["demo-platform", "demo-actions", "demo-workloads"])
    error_message = "Every instance organization must have one managed settings object."
  }

  assert {
    condition = alltrue([
      for organization, settings in restapi_object.organization_settings :
      settings.path == "/orgs" &&
      settings.object_id == organization &&
      settings.id_attribute == "login" &&
      settings.create_path == "/orgs/${organization}" &&
      settings.create_method == "PATCH" &&
      settings.update_method == "PATCH" &&
      settings.destroy_method == "PATCH" &&
      settings.ignore_server_additions
    ])
    error_message = "Create, update and destroy must PATCH the existing organization so an interrupted run can repeat them."
  }
}

run "sets_the_managed_baseline" {
  command = plan

  assert {
    condition = alltrue([
      for settings in restapi_object.organization_settings :
      jsondecode(settings.data) == {
        default_repository_permission            = "none"
        members_can_create_repositories          = false
        members_can_create_private_repositories  = false
        members_can_create_internal_repositories = false
      }
    ])
    error_message = "The create/update PATCH must manage base repository permission and member repository creation without sending enterprise-controlled fields."
  }
}

run "restores_github_defaults_only_for_managed_fields_on_destroy" {
  command = plan

  assert {
    condition = alltrue([
      for settings in restapi_object.organization_settings :
      jsondecode(settings.destroy_data) == {
        default_repository_permission            = "read"
        members_can_create_repositories          = true
        members_can_create_private_repositories  = true
        members_can_create_internal_repositories = true
      }
    ])
    error_message = "Destroy must restore the GitHub defaults of exactly the managed fields."
  }

  assert {
    condition = alltrue([
      for settings in restapi_object.organization_settings :
      toset(keys(jsondecode(settings.destroy_data))) == toset(keys(jsondecode(settings.data)))
    ])
    error_message = "Destroy must not change fields the module does not manage."
  }
}

run "publishes_the_managed_organizations" {
  command = plan

  assert {
    condition     = output.organizations == tolist(["demo-actions", "demo-platform", "demo-workloads"])
    error_message = "The module must publish the sorted managed organizations."
  }

  assert {
    condition     = output.organization_settings.default_repository_permission == "none"
    error_message = "The module must publish the managed baseline."
  }
}

run "rejects_an_empty_organization_list" {
  command = plan

  variables {
    target_organizations = []
  }

  expect_failures = [var.target_organizations]
}

run "rejects_duplicate_organizations" {
  command = plan

  variables {
    target_organizations = ["demo-platform", "demo-platform"]
  }

  expect_failures = [var.target_organizations]
}

run "rejects_an_invalid_organization_name" {
  command = plan

  variables {
    target_organizations = ["demo/platform"]
  }

  expect_failures = [var.target_organizations]
}

run "rejects_a_github_host_outside_ghe_com" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "attacker.example"
        enterprise = "example"
      }
    }
  }

  expect_failures = [var.instance]
}

run "accepts_a_github_response_with_the_enforced_baseline" {
  command   = apply
  state_key = "accepts_a_github_response_with_the_enforced_baseline"

  # The terraform_data provisioners would call GitHub; this run checks only the organization settings.
  plan_options {
    target = [restapi_object.organization_settings]
  }

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
}

run "rejects_a_github_response_that_keeps_read_as_base_permission" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { default_repository_permission = "read" },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_allows_member_repository_creation" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { members_can_create_repositories = true },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_allows_private_repository_creation" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { members_can_create_private_repositories = true },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_allows_internal_repository_creation" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { members_can_create_internal_repositories = true },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_allows_private_forks" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { members_can_fork_private_repositories = true },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_with_a_null_private_fork_policy" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { members_can_fork_private_repositories = null },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

  assert {
    condition = alltrue([
      for settings in restapi_object.organization_settings :
      settings.api_data == tomap({
        for field, value in jsondecode(settings.api_response) :
        field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }) &&
      jsondecode(settings.api_response).members_can_fork_private_repositories == null &&
      settings.api_data.members_can_fork_private_repositories == "<nil>"
    ])
    error_message = "The documented null fork policy must remain null in api_response and become <nil> in api_data."
  }

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_with_a_string_false_private_fork_policy" {
  command = plan

  # Deliberately invalid API input: GET /orgs/{org} documents a nullable boolean, not a string.
  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { members_can_fork_private_repositories = "false" },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

  assert {
    condition = alltrue([
      for settings in restapi_object.organization_settings :
      settings.api_data == tomap({
        for field, value in jsondecode(settings.api_response) :
        field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }) &&
      jsonencode(jsondecode(settings.api_response).members_can_fork_private_repositories) == jsonencode("false") &&
      settings.api_data.members_can_fork_private_repositories == "false"
    ])
    error_message = "The invalid string false fork policy must retain its JSON type instead of becoming boolean false."
  }

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_without_default_repository_permission" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      {
        for field, value in merge(
          jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
          jsondecode(file("tests/fixtures/organization-settings.json")),
        ) : field => value if field != "default_repository_permission"
      }
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_without_members_can_create_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      {
        for field, value in merge(
          jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
          jsondecode(file("tests/fixtures/organization-settings.json")),
        ) : field => value if field != "members_can_create_repositories"
      }
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_without_members_can_create_private_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      {
        for field, value in merge(
          jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
          jsondecode(file("tests/fixtures/organization-settings.json")),
        ) : field => value if field != "members_can_create_private_repositories"
      }
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_without_members_can_create_internal_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      {
        for field, value in merge(
          jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
          jsondecode(file("tests/fixtures/organization-settings.json")),
        ) : field => value if field != "members_can_create_internal_repositories"
      }
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_without_members_can_fork_private_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      {
        for field, value in merge(
          jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
          jsondecode(file("tests/fixtures/organization-settings.json")),
        ) : field => value if field != "members_can_fork_private_repositories"
      }
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_that_lets_members_change_visibility" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { members_can_change_repo_visibility = true },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_lets_members_delete_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      merge(
        jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
        jsondecode(file("tests/fixtures/organization-settings.json")),
        { members_can_delete_repositories = true },
      )
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [restapi_object.organization_settings]
}

run "warns_when_github_does_not_return_the_enterprise_enforced_visibility_field" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      {
        for field, value in merge(
          jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
          jsondecode(file("tests/fixtures/organization-settings.json")),
        ) : field => value if field != "members_can_change_repo_visibility"
      }
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [check.enterprise_repository_management_policies]
}
run "warns_when_github_does_not_return_the_enterprise_enforced_deletion_field" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = [for response in [
      {
        for field, value in merge(
          jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
          jsondecode(file("tests/fixtures/organization-settings.json")),
        ) : field => value if field != "members_can_delete_repositories"
      }
      ] : {
      id              = "mock"
      api_response    = jsonencode(response)
      create_response = "{}"
      api_data = {
        for field, value in response : field => value == null ? "<nil>" : tostring(value)
        if contains(keys(jsondecode(file("tests/fixtures/organization-settings.json"))), field)
      }
    }][0]
  }

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

  expect_failures = [check.enterprise_repository_management_policies]
}
