# Plan runs never call GitHub: the data source reads after the pending resources. Apply runs override the
# resources, so no provisioner runs, and override the live state per case.
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
  prerequisites  = {}
  admin_logins   = ["alice_demo", "bob_demo"]
  billing_email  = "billing@example.test"
  app_client_ids = ["Iv23liAAAAAAAAAAAAAA", "Iv23liBBBBBBBBBBBBBB"]
}

run "creates_actions_and_workloads_organizations" {
  command = plan

  assert {
    condition = terraform_data.organization["actions"].input == {
      api_url = "https://api.example.ghe.com", enterprise = "example", organization = "demo-a1b2c3-actions"
    }
    error_message = "The actions organization must carry only its identity in the resource input."
  }

  assert {
    condition     = terraform_data.organization["workloads"].input.organization == "demo-a1b2c3-workloads"
    error_message = "The workloads organization must use the derived name."
  }

  assert {
    condition     = toset(keys(terraform_data.organization)) == toset(["actions", "workloads"])
    error_message = "The module must not manage the platform organization."
  }

  assert {
    condition     = terraform_data.removal_guard["actions"].input == terraform_data.organization["actions"].input
    error_message = "The removal guard must verify the same organization on destroy."
  }

  assert {
    condition     = output.organizations == { actions = "demo-a1b2c3-actions", workloads = "demo-a1b2c3-workloads" }
    error_message = "The output must expose the organization logins."
  }

  assert {
    condition     = output.deployment_identifier == "a1b2c3"
    error_message = "The output must expose the deployment identifier."
  }
}

run "installs_every_app_into_both_organizations" {
  command = plan

  assert {
    condition = toset(keys(terraform_data.installation)) == toset([
      "actions/Iv23liAAAAAAAAAAAAAA", "actions/Iv23liBBBBBBBBBBBBBB",
      "workloads/Iv23liAAAAAAAAAAAAAA", "workloads/Iv23liBBBBBBBBBBBBBB",
    ])
    error_message = "Every App must have one installation per organization."
  }

  assert {
    condition     = terraform_data.installation["workloads/Iv23liBBBBBBBBBBBBBB"].input.organization == "demo-a1b2c3-workloads"
    error_message = "An installation must target its organization."
  }

  assert {
    condition     = terraform_data.installation["workloads/Iv23liBBBBBBBBBBBBBB"].input.client_id == "Iv23liBBBBBBBBBBBBBB"
    error_message = "An installation must carry its App client ID."
  }

  assert {
    condition     = terraform_data.installation_guard["workloads/Iv23liBBBBBBBBBBBBBB"].input == terraform_data.installation["workloads/Iv23liBBBBBBBBBBBBBB"].input
    error_message = "The installation guard must uninstall the same App on destroy."
  }
}

run "uses_legacy_names_without_identifier" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
      organizations = {
        deploymentIdentifier = null
        platform             = "demo-platform"
        actions              = "demo-actions"
        workloads            = "demo-workloads"
      }
    }
    app_client_ids = []
  }

  assert {
    condition     = output.organizations == { actions = "demo-actions", workloads = "demo-workloads" }
    error_message = "The legacy instance must use the legacy organization names."
  }

  assert {
    condition     = output.deployment_identifier == null
    error_message = "The legacy instance has no deployment identifier."
  }

  assert {
    condition     = length(terraform_data.installation) == 0
    error_message = "No App means no installation."
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

  expect_failures = [var.instance]
}

run "rejects_colliding_organization_names" {
  command = plan

  variables {
    instance = {
      name = "demo"
      github = {
        host       = "example.ghe.com"
        enterprise = "example"
      }
      organizations = {
        deploymentIdentifier = null
        platform             = "demo-platform"
        actions              = "Demo-Platform"
        workloads            = "demo-workloads"
      }
    }
  }

  expect_failures = [var.instance]
}

run "rejects_an_owner_without_emu_shortcode" {
  command = plan

  variables {
    admin_logins = ["alice"]
  }

  expect_failures = [var.admin_logins]
}

run "rejects_duplicate_owners_in_other_case" {
  command = plan

  variables {
    admin_logins = ["alice_demo", "Alice_demo"]
  }

  expect_failures = [var.admin_logins]
}

run "rejects_no_owner" {
  command = plan

  variables {
    admin_logins = []
  }

  expect_failures = [var.admin_logins]
}

run "rejects_an_invalid_billing_email" {
  command = plan

  variables {
    billing_email = "billing"
  }

  expect_failures = [var.billing_email]
}

run "rejects_an_invalid_app_client_id" {
  command = plan

  variables {
    app_client_ids = ["Iv23li/AAAA"]
  }

  expect_failures = [var.app_client_ids]
}