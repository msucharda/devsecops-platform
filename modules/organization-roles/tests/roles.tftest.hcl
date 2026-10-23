mock_provider "external" {
  mock_data "external" {
    defaults = {
      result = {
        role_id  = "8030"
        team_id  = "1"
        assigned = "true"
      }
    }
  }
}

variables {
  instance = {
    name   = "demo"
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

run "declares_a_preexisting_assignment" {
  command = plan

  assert {
    condition     = output.security_manager.assigned
    error_message = "The module must declare the security-manager assignment, including a pre-existing assignment."
  }

  assert {
    condition     = terraform_data.role_guard.input.role_id == 8030 && terraform_data.role_guard.input.team_id == 1
    error_message = "The identity guard must bind the role and team IDs read by plan."
  }
}
