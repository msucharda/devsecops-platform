variables {
  instance = {
    github = { host = "example.ghe.com" }
    organizations = {
      platform  = "demo-a1b2c3-platform"
      actions   = "demo-a1b2c3-actions"
      workloads = "demo-a1b2c3-workloads"
    }
  }
  prerequisites        = {}
  target_organizations = ["demo-a1b2c3-actions"]
}

run "publishes_the_organization_of_the_rulesets_root" {
  command = plan

  assert {
    condition     = output.organizations == tolist(["demo-a1b2c3-actions"])
    error_message = "The module must publish the organization whose rulesets it manages."
  }
}

run "rejects_more_than_one_organization" {
  command = plan

  variables {
    target_organizations = ["demo-a1b2c3-actions", "demo-a1b2c3-workloads"]
  }

  expect_failures = [var.target_organizations]
}

run "rejects_no_organization" {
  command = plan

  variables {
    target_organizations = []
  }

  expect_failures = [var.target_organizations]
}

run "rejects_an_invalid_organization_name" {
  command = plan

  variables {
    target_organizations = ["-demo"]
  }

  expect_failures = [var.target_organizations]
}

run "accepts_the_actions_organization_in_another_letter_case" {
  command = plan

  variables {
    target_organizations = ["DEMO-A1B2C3-ACTIONS"]
  }
}

run "rejects_another_organization_of_the_instance" {
  command = plan

  variables {
    target_organizations = ["demo-a1b2c3-workloads"]
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

run "rejects_an_empty_actions_organization" {
  command = plan

  variables {
    instance = {
      github        = { host = "example.ghe.com" }
      organizations = { actions = "" }
    }
    target_organizations = ["demo-a1b2c3-actions"]
  }

  expect_failures = [var.target_organizations]
}