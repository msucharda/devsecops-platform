mock_provider "external" {}

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

run "organization_patch_fields_require_explicit_justification" {
  command = plan

  assert {
    condition = alltrue(flatten([
      for settings in restapi_object.organization_settings : [
        for payload in [jsondecode(settings.data), jsondecode(settings.destroy_data)] : length(keys(payload)) > 0 && alltrue([
          for field in keys(payload) : try(
            startswith(jsonencode(jsondecode(file("organization-patch-allowlist.json")).allowedFields[field]), "\"") &&
            trimspace(jsondecode(file("organization-patch-allowlist.json")).allowedFields[field]) != "",
            false
          )
        ])
      ]
    ]))
    error_message = "PATCH payload fields must have a nonempty reason in the explicit allow-list. This offline contract does not prove writability under enterprise policy."
  }
}
