# The code security scripts must not run in this file; code_security.tftest.hcl and the Pester stub tests cover them.
mock_provider "external" {}

# Plan runs see a compliant GitHub response; apply runs override it per case.
mock_provider "restapi" {
  override_during = plan

  mock_resource "restapi_object" {
    defaults = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
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

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        login                                    = "demo-platform"
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

run "rejects_a_github_response_that_keeps_read_as_base_permission" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "read"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_allows_member_repository_creation" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "true"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_allows_private_repository_creation" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "true"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_allows_internal_repository_creation" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "true"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_allows_private_forks" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id = "mock"
      api_response = jsonencode(merge(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body, {
        members_can_fork_private_repositories = true
      }))
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "true"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_without_default_repository_permission" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_without_members_can_create_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_without_members_can_create_private_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_without_members_can_create_internal_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission           = "none"
        members_can_create_repositories         = "false"
        members_can_create_private_repositories = "false"
        members_can_fork_private_repositories   = "false"
        members_can_change_repo_visibility      = "false"
        members_can_delete_repositories         = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_without_members_can_fork_private_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id = "mock"
      api_response = jsonencode({
        for field, value in jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body :
        field => value if field != "members_can_fork_private_repositories"
      })
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}
run "rejects_a_github_response_that_lets_members_change_visibility" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "true"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}

run "rejects_a_github_response_that_lets_members_delete_repositories" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
        members_can_delete_repositories          = "true"
      }
    }
  }

  expect_failures = [restapi_object.organization_settings]
}

run "warns_when_github_does_not_return_the_enterprise_enforced_visibility_field" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_delete_repositories          = "false"
      }
    }
  }

  expect_failures = [check.enterprise_repository_management_policies]
}
run "warns_when_github_does_not_return_the_enterprise_enforced_deletion_field" {
  command = plan

  override_resource {
    target          = restapi_object.organization_settings
    override_during = plan
    values = {
      id              = "mock"
      api_response    = jsonencode(jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body)
      create_response = "{}"
      api_data = {
        default_repository_permission            = "none"
        members_can_create_repositories          = "false"
        members_can_create_private_repositories  = "false"
        members_can_create_internal_repositories = "false"
        members_can_fork_private_repositories    = "false"
        members_can_change_repo_visibility       = "false"
      }
    }
  }

  expect_failures = [check.enterprise_repository_management_policies]
}
