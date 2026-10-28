# Keep the contract body intact and change only the fields needed for a compliant organization.
# The single-element expression binds the response once for both computed attributes.
mock_resource "restapi_object" {
  defaults = [for response in [
    merge(
      jsondecode(file("../../tools/tests/fixtures/github-api/orgs/get.json")).body,
      jsondecode(file("tests/fixtures/organization-settings.json")),
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
