# Plan-only tests of the code security objects. Provisioners and the state reader run in the Pester stub tests
# (tools/tests/EnterpriseBaseline.Tests.ps1); a plan defers the reader while the managed objects have pending changes.
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

mock_provider "external" {}

variables {
  instance = {
    name = "demo"
    github = {
      host       = "example.ghe.com"
      enterprise = "example"
    }
    customPatterns = [
      { name = "Platform token", secretRegex = "plat_[A-Za-z0-9]{32}" },
      { name = "Partner key", secretRegex = "pk-[0-9a-f]{40}", beforeSecret = "key=", afterSecret = "\\s" },
    ]
  }
  prerequisites        = {}
  target_organizations = ["demo-platform", "demo-workloads"]
  secret_scanning_bypass_reviewers = [
    { reviewer_type = "TEAM", reviewer_id = 5678 },
    { reviewer_type = "ROLE", reviewer_id = 4 },
  ]
}

run "manages_one_configuration_per_organization" {
  command = plan

  assert {
    condition = (
      toset(keys(terraform_data.code_security_configuration)) == toset(["demo-platform", "demo-workloads"]) &&
      toset(keys(terraform_data.code_security_configuration_settings)) == toset(["demo-platform", "demo-workloads"]) &&
      toset(keys(data.external.code_security_state)) == toset(["demo-platform", "demo-workloads"])
    )
    error_message = "Every instance organization must have one configuration, its settings and a state reader."
  }

  assert {
    condition = alltrue([
      for organization, configuration in terraform_data.code_security_configuration :
      configuration.input == {
        api_url      = "https://api.example.ghe.com"
        organization = organization
        name         = "platform-baseline"
      }
    ])
    error_message = "The configuration identity must name the organization configuration on the instance API host."
  }

  assert {
    condition = alltrue([
      for organization, state in data.external.code_security_state :
      state.query.api_url == "https://api.example.ghe.com" &&
      state.query.organization == organization &&
      state.query.configuration_name == "platform-baseline"
    ])
    error_message = "The state reader must read the managed configuration of its organization."
  }
}

run "enables_and_enforces_the_baseline_settings" {
  command = plan

  assert {
    condition = alltrue([
      for organization, settings in terraform_data.code_security_configuration_settings :
      settings.input.organization == organization &&
      settings.input.api_url == "https://api.example.ghe.com" &&
      settings.input.configuration == {
        name                             = "platform-baseline"
        description                      = "Platform baseline managed by the enterprise-baseline module."
        advanced_security                = "enabled"
        dependency_graph                 = "enabled"
        dependabot_alerts                = "enabled"
        dependabot_security_updates      = "enabled"
        code_scanning_default_setup      = "enabled"
        secret_scanning                  = "enabled"
        secret_scanning_push_protection  = "enabled"
        secret_scanning_validity_checks  = "enabled"
        secret_scanning_delegated_bypass = "enabled"
        enforcement                      = "enforced"
        secret_scanning_delegated_bypass_options = {
          reviewers = [
            { reviewer_type = "TEAM", reviewer_id = 5678, mode = "ALWAYS" },
            { reviewer_type = "ROLE", reviewer_id = 4, mode = "ALWAYS" },
          ]
        }
      }
    ])
    error_message = "The configuration must enable the dependency graph, Dependabot, CodeQL default setup, secret scanning with push protection, validity checks and delegated bypass, and must be enforced."
  }

  assert {
    condition = alltrue([
      for organization, settings in terraform_data.code_security_configuration_settings :
      settings.triggers_replace.configuration == settings.input.configuration
    ])
    error_message = "A change of the managed configuration must rerun the upsert."
  }

  assert {
    condition     = output.code_security_configuration.name == "platform-baseline" && output.code_security_configuration.settings.enforcement == "enforced"
    error_message = "The module must publish the managed configuration."
  }
}

run "manages_each_custom_pattern_in_each_organization" {
  command = plan

  assert {
    condition = toset(keys(terraform_data.custom_pattern)) == toset([
      "demo-platform/Platform token", "demo-platform/Partner key",
      "demo-workloads/Platform token", "demo-workloads/Partner key",
    ])
    error_message = "Every instance organization must have every custom pattern of the instance."
  }

  assert {
    condition = alltrue([
      for key, pattern in terraform_data.custom_pattern :
      pattern.input == {
        api_url      = "https://api.example.ghe.com"
        organization = split("/", key)[0]
        name         = split("/", key)[1]
      }
    ])
    error_message = "The pattern identity must name the pattern in its organization."
  }

  assert {
    condition = (
      terraform_data.custom_pattern_content["demo-workloads/Platform token"].input.pattern == {
        name            = "Platform token"
        pattern         = "plat_[A-Za-z0-9]{32}"
        start_delimiter = "\\A|[^0-9A-Za-z]"
        end_delimiter   = "\\z|[^0-9A-Za-z]"
      } &&
      terraform_data.custom_pattern_content["demo-platform/Partner key"].input.pattern == {
        name            = "Partner key"
        pattern         = "pk-[0-9a-f]{40}"
        start_delimiter = "key="
        end_delimiter   = "\\s"
      }
    )
    error_message = "A pattern without delimiters must use the documented defaults; set delimiters must be kept."
  }

  assert {
    condition     = output.custom_patterns == tolist(["Partner key", "Platform token"])
    error_message = "The module must publish the sorted custom pattern names."
  }
}

run "manages_no_custom_pattern_by_default" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
    }
  }

  assert {
    condition     = length(terraform_data.custom_pattern) == 0 && length(terraform_data.custom_pattern_content) == 0
    error_message = "The default instance must not create custom patterns."
  }

  assert {
    condition     = length(terraform_data.code_security_configuration) == 2
    error_message = "The configuration must not depend on custom patterns."
  }
}

run "uses_default_delimiters_for_empty_delimiters" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
      customPatterns = [{ name = "Platform token", secretRegex = "plat_x", beforeSecret = "", afterSecret = "" }]
    }
  }

  assert {
    condition = (
      terraform_data.custom_pattern_content["demo-platform/Platform token"].input.pattern.start_delimiter == "\\A|[^0-9A-Za-z]" &&
      terraform_data.custom_pattern_content["demo-platform/Platform token"].input.pattern.end_delimiter == "\\z|[^0-9A-Za-z]"
    )
    error_message = "An empty delimiter must mean the documented default."
  }
}

run "rejects_a_custom_pattern_with_a_blank_name" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
      customPatterns = [{ name = " ", secretRegex = "plat_x" }]
    }
  }

  expect_failures = [var.instance]
}

run "rejects_a_custom_pattern_with_a_blank_regex" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
      customPatterns = [{ name = "Platform token", secretRegex = "" }]
    }
  }

  expect_failures = [var.instance]
}

run "rejects_duplicate_custom_pattern_names" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
      customPatterns = [
        { name = "Platform token", secretRegex = "plat_x" },
        { name = "Platform token", secretRegex = "plat_y" },
      ]
    }
  }

  expect_failures = [var.instance]
}

run "rejects_no_bypass_reviewer" {
  command = plan

  variables {
    secret_scanning_bypass_reviewers = []
  }

  expect_failures = [var.secret_scanning_bypass_reviewers]
}

run "rejects_an_unknown_reviewer_type" {
  command = plan

  variables {
    secret_scanning_bypass_reviewers = [{ reviewer_type = "USER", reviewer_id = 5678 }]
  }

  expect_failures = [var.secret_scanning_bypass_reviewers]
}

run "rejects_a_lowercase_reviewer_type" {
  command = plan

  variables {
    secret_scanning_bypass_reviewers = [{ reviewer_type = "team", reviewer_id = 5678 }]
  }

  expect_failures = [var.secret_scanning_bypass_reviewers]
}

run "rejects_a_zero_reviewer_id" {
  command = plan

  variables {
    secret_scanning_bypass_reviewers = [{ reviewer_type = "TEAM", reviewer_id = 0 }]
  }

  expect_failures = [var.secret_scanning_bypass_reviewers]
}

run "rejects_a_fractional_reviewer_id" {
  command = plan

  variables {
    secret_scanning_bypass_reviewers = [{ reviewer_type = "TEAM", reviewer_id = 5678.5 }]
  }

  expect_failures = [var.secret_scanning_bypass_reviewers]
}

run "rejects_a_missing_reviewer_id" {
  command = plan

  variables {
    secret_scanning_bypass_reviewers = [{ reviewer_type = "TEAM", reviewer_id = null }]
  }

  expect_failures = [var.secret_scanning_bypass_reviewers]
}

run "rejects_duplicate_bypass_reviewers" {
  command = plan

  variables {
    secret_scanning_bypass_reviewers = [
      { reviewer_type = "TEAM", reviewer_id = 5678 },
      { reviewer_type = "TEAM", reviewer_id = 5678 },
    ]
  }

  expect_failures = [var.secret_scanning_bypass_reviewers]
}

run "rejects_a_missing_reviewer_type" {
  command = plan

  variables {
    secret_scanning_bypass_reviewers = [{ reviewer_type = null, reviewer_id = 5678 }]
  }

  expect_failures = [var.secret_scanning_bypass_reviewers]
}

run "rejects_a_custom_pattern_without_name" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
      customPatterns = [{ name = null, secretRegex = "plat_x" }]
    }
  }

  expect_failures = [var.instance]
}
