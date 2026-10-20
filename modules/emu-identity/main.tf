locals {
  groups = {
    platform = {
      display_name = "${var.instance.name}-platform-team"
      description  = "Platform team of instance ${var.instance.name}. Enterprise Owner in GHE. Members come from teams.platform."
      app_role     = "Enterprise Owner"
    }
    security = {
      display_name = "${var.instance.name}-security-team"
      description  = "Security team of instance ${var.instance.name}. Members come from teams.security."
      app_role     = "User"
    }
    copilot = {
      display_name = "${var.instance.name}-copilot-users"
      description  = "Copilot users of instance ${var.instance.name}. Membership is managed by the customer in Entra ID."
      app_role     = "User"
    }
  }

  app_roles = {
    for role in data.azuread_service_principal.ghe.app_roles : role.display_name => role.id
    if role.enabled
  }
}

data "azuread_service_principal" "ghe" {
  object_id = var.instance.entra.enterpriseApplicationObjectId
}

data "azuread_users" "platform" {
  user_principal_names = var.instance.teams.platform
}

data "azuread_users" "security" {
  user_principal_names = var.instance.teams.security
}

# Owners are omitted on purpose: the provider makes the apply identity the sole owner, which
# Group.Create requires for later updates, while plan identities produce no ownership drift.
resource "azuread_group" "platform" {
  display_name     = local.groups.platform.display_name
  description      = local.groups.platform.description
  security_enabled = true
  members          = data.azuread_users.platform.object_ids
}

resource "azuread_group" "security" {
  display_name     = local.groups.security.display_name
  description      = local.groups.security.description
  security_enabled = true
  members          = data.azuread_users.security.object_ids
}

# Members are not declared, so Terraform leaves the customer-managed membership untouched.
resource "azuread_group" "copilot" {
  display_name     = local.groups.copilot.display_name
  description      = local.groups.copilot.description
  security_enabled = true
}

resource "azuread_app_role_assignment" "platform" {
  app_role_id         = local.app_roles[local.groups.platform.app_role]
  principal_object_id = azuread_group.platform.object_id
  resource_object_id  = data.azuread_service_principal.ghe.object_id
}

resource "azuread_app_role_assignment" "security" {
  app_role_id         = local.app_roles[local.groups.security.app_role]
  principal_object_id = azuread_group.security.object_id
  resource_object_id  = data.azuread_service_principal.ghe.object_id
}

resource "azuread_app_role_assignment" "copilot" {
  app_role_id         = local.app_roles[local.groups.copilot.app_role]
  principal_object_id = azuread_group.copilot.object_id
  resource_object_id  = data.azuread_service_principal.ghe.object_id
}
