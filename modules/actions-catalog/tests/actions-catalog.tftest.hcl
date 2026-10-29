# Runs never call GitHub: plan runs defer the data source until after the pending resources. The output run overrides
# the resources and the live state during plan, so no provisioner runs. Terraform defers the postcondition of a data
# source that depends on pending resources to apply, where overridden resources still run their provisioners; the
# violation list behind it is covered by the Pester tests of Read-CatalogState.ps1.
variables {
  instance = {
    name = "demo"
    github = {
      host       = "example.ghe.com"
      enterprise = "example"
    }
    organizations = {
      deploymentIdentifier = "a1b2c3"
      platform             = "demo-a1b2c3-platform"
      actions              = "demo-a1b2c3-actions"
      workloads            = "demo-a1b2c3-workloads"
    }
  }
  prerequisites        = { "organization-rulesets" = { organizations = ["demo-a1b2c3-actions"] } }
  target_organizations = ["demo-a1b2c3-actions"]
  security_team        = "actions-security"
  # The instance repository of a test has no catalog; each run reads a fixture of vendoring/actions.json.
  vendoring_catalog_path = "tests/fixtures/empty/vendoring/actions.json"
}

run "creates_a_repository_for_every_default_catalog_entry" {
  command = plan

  assert {
    condition = toset(keys(terraform_data.repository)) == toset([
      "actions/checkout", "actions/upload-artifact", "actions/download-artifact",
      "actions/create-github-app-token", "azure/login", "hashicorp/setup-terraform",
    ])
    error_message = "The default catalog must contain the six actions of the platform workflows."
  }

  assert {
    condition = terraform_data.repository["azure/login"].input == {
      api_url = "https://api.example.ghe.com", organization = "demo-a1b2c3-actions", upstream = "azure/login", security_team = "actions-security"
    }
    error_message = "A repository must carry only its identity and the security team in the resource input."
  }

  assert {
    condition     = length(terraform_data.release_tag) == 0
    error_message = "No release means no tag."
  }

  assert {
    condition     = toset(keys(data.external.catalog_state)) == toset(keys(terraform_data.repository))
    error_message = "The state reader must check every catalog repository."
  }

  assert {
    condition     = data.external.catalog_state["azure/login"].query.tag == "" && data.external.catalog_state["azure/login"].query.commit == ""
    error_message = "The state reader must check no tag without a release."
  }

  assert {
    condition     = output.organization == "demo-a1b2c3-actions"
    error_message = "The output must expose the actions organization."
  }
}

run "tags_an_approved_release" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/release/vendoring/actions.json"
  }

  assert {
    condition     = toset(keys(terraform_data.release_tag)) == toset(["actions/checkout"])
    error_message = "Each release must have one tag."
  }

  assert {
    condition = terraform_data.release_tag["actions/checkout"].input == {
      api_url       = "https://api.example.ghe.com", organization = "demo-a1b2c3-actions", upstream = "actions/checkout"
      security_team = "actions-security", tag = "v4.2.2", commit = "1111111111111111111111111111111111111111"
      upstream_commit = "11bd71901bbe5b1630ceea73d27597364c9af683"
    }
    error_message = "A release tag must carry the repository identity, the tag and the commit."
  }

  assert {
    condition = (
      data.external.catalog_state["actions/checkout"].query.tag == "v4.2.2" &&
      data.external.catalog_state["actions/checkout"].query.commit == "1111111111111111111111111111111111111111" &&
      data.external.catalog_state["actions/checkout"].query.upstream_commit == "11bd71901bbe5b1630ceea73d27597364c9af683"
    )
    error_message = "The state reader must verify the released tag."
  }
}

run "exposes_repositories_and_releases_of_a_compliant_catalog" {
  command = plan

  variables {
    catalog                = ["actions/checkout", "azure/login"]
    vendoring_catalog_path = "tests/fixtures/release/vendoring/actions.json"
  }

  override_resource {
    target          = terraform_data.repository
    override_during = plan
  }

  override_resource {
    target          = terraform_data.release_tag
    override_during = plan
  }

  override_data {
    target          = data.external.catalog_state
    override_during = plan
    values = {
      result = { state = "{}", violations = "[]" }
    }
  }

  assert {
    condition = output.repositories == {
      "actions/checkout" = "demo-a1b2c3-actions/actions-checkout", "azure/login" = "demo-a1b2c3-actions/azure-login"
    }
    error_message = "The output must expose the vendored repository of each action."
  }

  assert {
    condition = output.releases == {
      "actions/checkout" = { tag = "v4.2.2", commit = "1111111111111111111111111111111111111111", upstream_commit = "11bd71901bbe5b1630ceea73d27597364c9af683" }
    }
    error_message = "The output must expose the verified release."
  }
}

run "requires_the_platform_organization_from_the_runner" {
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

  # Terraform skips the target_organizations validation while the instance it references is invalid.
  expect_failures = [var.instance]
}

run "rejects_another_target_organization" {
  command = plan

  variables {
    target_organizations = ["demo-a1b2c3-workloads"]
  }

  expect_failures = [var.target_organizations]
}

run "accepts_the_ruleset_of_organization_rulesets_with_another_letter_case" {
  command = plan

  variables {
    prerequisites = { "organization-rulesets" = { organizations = ["Demo-A1B2C3-Actions"] } }
  }
}

# Each run changes one field of the valid organization-rulesets outputs.
run "requires_the_ruleset_of_organization_rulesets_in_the_actions_organization" {
  command = plan

  variables {
    prerequisites = { "organization-rulesets" = { organizations = ["demo-a1b2c3-platform"] } }
  }

  expect_failures = [var.prerequisites]
}

run "requires_the_organization_rulesets_outputs" {
  command = plan

  variables {
    prerequisites = { organizations = { organizations = { actions = "demo-a1b2c3-actions" } } }
  }

  expect_failures = [var.prerequisites]
}

run "requires_the_organizations_output_of_organization_rulesets" {
  command = plan

  variables {
    prerequisites = { "organization-rulesets" = { custom_patterns = [] } }
  }

  expect_failures = [var.prerequisites]
}

run "rejects_an_empty_organizations_output_of_organization_rulesets" {
  command = plan

  variables {
    prerequisites = { "organization-rulesets" = { organizations = [] } }
  }

  expect_failures = [var.prerequisites]
}

# Intentionally invalid input: an empty actions organization must not match an empty output entry.
run "rejects_an_empty_actions_organization" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
      organizations = {
        platform  = "demo-a1b2c3-platform"
        actions   = ""
        workloads = "demo-a1b2c3-workloads"
      }
    }
    target_organizations = [""]
    prerequisites        = { "organization-rulesets" = { organizations = [""] } }
  }

  expect_failures = [var.prerequisites]
}

# Intentionally invalid input: the output is a list, not a map whose value names the organization.
run "rejects_an_organizations_output_that_is_not_a_list" {
  command = plan

  variables {
    prerequisites = { "organization-rulesets" = { organizations = { actions = "demo-a1b2c3-actions" } } }
  }

  expect_failures = [var.prerequisites]
}

run "rejects_more_target_organizations" {
  command = plan

  variables {
    target_organizations = ["demo-a1b2c3-actions", "demo-a1b2c3-workloads"]
  }

  expect_failures = [var.target_organizations]
}

run "rejects_an_invalid_security_team" {
  command = plan

  variables {
    security_team = "Actions Security"
  }

  expect_failures = [var.security_team]
}

run "rejects_an_empty_catalog" {
  command = plan

  variables {
    catalog = []
  }

  expect_failures = [var.catalog]
}

run "rejects_a_duplicate_catalog_entry" {
  command = plan

  variables {
    catalog = ["actions/checkout", "actions/checkout"]
  }

  expect_failures = [var.catalog]
}

run "rejects_an_upper_case_catalog_entry" {
  command = plan

  variables {
    catalog = ["Actions/Checkout"]
  }

  expect_failures = [var.catalog]
}

run "rejects_a_catalog_entry_with_a_path" {
  command = plan

  variables {
    catalog = ["actions/checkout/sub"]
  }

  expect_failures = [var.catalog]
}

run "rejects_a_dot_repository" {
  command = plan

  variables {
    catalog = ["actions/.."]
  }

  expect_failures = [var.catalog]
}

run "rejects_a_copy_name_longer_than_100_characters" {
  command = plan

  variables {
    catalog = ["actions/${join("", [for i in range(93) : "a"])}"]
  }

  expect_failures = [var.catalog]
}

run "accepts_a_copy_name_of_100_characters" {
  command = plan

  variables {
    catalog = ["actions/${join("", [for i in range(92) : "a"])}"]
  }
}

run "rejects_colliding_repository_names" {
  command = plan

  variables {
    catalog = ["actions/checkout-x", "actions-checkout/x"]
  }

  expect_failures = [var.catalog]
}

run "rejects_a_missing_vendoring_catalog" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/missing/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_vendoring_catalog_of_another_version" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/version-1/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_vendored_action_outside_the_catalog" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/outside-catalog/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_an_upper_case_vendored_action" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/upper-case-action/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_vendored_copy_in_another_organization" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/other-repository/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_vendored_action_without_a_tag" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/missing-tag/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_an_invalid_release_tag" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/invalid-tag/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_release_tag_ending_with_lock" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/lock-tag/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_an_abbreviated_release_commit" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/abbreviated-commit/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_an_upper_case_release_commit" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/upper-case-commit/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_vendoring_catalog_path_of_another_file" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/release/vendoring/other.json"
  }

  expect_failures = [var.vendoring_catalog_path]
}

run "rejects_a_boolean_release_tag" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/boolean-tag/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_numeric_release_tag" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/numeric-tag/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_numeric_release_commit" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/numeric-commit/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_missing_upstream_commit" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/missing-upstream-commit/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_a_numeric_upstream_commit" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/numeric-upstream-commit/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}

run "rejects_an_uppercase_upstream_commit" {
  command = plan

  variables {
    vendoring_catalog_path = "tests/fixtures/upper-case-upstream-commit/vendoring/actions.json"
  }

  expect_failures = [output.releases]
}
