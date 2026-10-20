mock_provider "azuread" {
  override_data {
    target = data.azuread_service_principal.ghe
    values = {
      object_id = "33333333-3333-3333-3333-333333333333"
      app_roles = [
        { display_name = "Enterprise Owner", id = "aaaaaaaa-0000-0000-0000-000000000001", enabled = true, allowed_member_types = ["User"], description = "", value = "" },
        { display_name = "User", id = "aaaaaaaa-0000-0000-0000-000000000002", enabled = true, allowed_member_types = ["User"], description = "", value = "" },
        { display_name = "User", id = "aaaaaaaa-0000-0000-0000-000000000003", enabled = false, allowed_member_types = ["User"], description = "", value = "" },
      ]
    }
  }

  override_data {
    target = data.azuread_users.platform
    values = { object_ids = ["bbbbbbbb-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002"] }
  }

  override_data {
    target = data.azuread_users.security
    values = { object_ids = ["bbbbbbbb-0000-0000-0000-000000000003"] }
  }
}

override_resource {
  target = azuread_group.platform
  values = { object_id = "cccccccc-0000-0000-0000-000000000001" }
}

override_resource {
  target = azuread_group.security
  values = { object_id = "cccccccc-0000-0000-0000-000000000002" }
}

override_resource {
  target = azuread_group.copilot
  values = { object_id = "cccccccc-0000-0000-0000-000000000003" }
}

variables {
  instance = {
    name = "demo"
    teams = {
      platform = ["platform-1@example.test", "platform-2@example.test"]
      security = ["security-1@example.test"]
    }
    entra = {
      tenantId                      = "11111111-1111-1111-1111-111111111111"
      enterpriseApplicationObjectId = "33333333-3333-3333-3333-333333333333"
    }
  }
  prerequisites = {}
}

run "plan_publishes_known_outputs" {
  command = plan

  assert {
    condition     = output.group_names == { platform = "demo-platform-team", security = "demo-security-team", copilot = "demo-copilot-users" }
    error_message = "Outputs must publish only group names that are known during plan."
  }
}

run "groups_and_app_roles" {
  command = apply

  assert {
    condition     = azuread_group.platform.display_name == "demo-platform-team" && azuread_group.security.display_name == "demo-security-team" && azuread_group.copilot.display_name == "demo-copilot-users"
    error_message = "Group names must derive from the instance name."
  }

  assert {
    condition     = alltrue([for group in [azuread_group.platform, azuread_group.security, azuread_group.copilot] : group.security_enabled])
    error_message = "All groups must be security groups; EMU links only security groups."
  }

  assert {
    condition     = toset(azuread_group.platform.members) == toset(["bbbbbbbb-0000-0000-0000-000000000001", "bbbbbbbb-0000-0000-0000-000000000002"]) && toset(azuread_group.security.members) == toset(["bbbbbbbb-0000-0000-0000-000000000003"])
    error_message = "Platform and security members must come from the configured UPNs."
  }

  assert {
    condition     = azuread_app_role_assignment.platform.app_role_id == "aaaaaaaa-0000-0000-0000-000000000001"
    error_message = "The platform team group must receive Enterprise Owner."
  }

  assert {
    condition     = azuread_app_role_assignment.security.app_role_id == "aaaaaaaa-0000-0000-0000-000000000002" && azuread_app_role_assignment.copilot.app_role_id == "aaaaaaaa-0000-0000-0000-000000000002"
    error_message = "The security and Copilot groups must receive the enabled User app role."
  }

  assert {
    condition     = alltrue([for assignment in [azuread_app_role_assignment.platform, azuread_app_role_assignment.security, azuread_app_role_assignment.copilot] : assignment.resource_object_id == "33333333-3333-3333-3333-333333333333"])
    error_message = "App roles must be assigned in the configured enterprise application."
  }

  assert {
    condition     = azuread_app_role_assignment.platform.principal_object_id == azuread_group.platform.object_id && azuread_app_role_assignment.security.principal_object_id == azuread_group.security.object_id && azuread_app_role_assignment.copilot.principal_object_id == azuread_group.copilot.object_id
    error_message = "Each app role must be assigned to its own group."
  }
}
