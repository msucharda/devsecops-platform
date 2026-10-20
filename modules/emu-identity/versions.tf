terraform {
  required_version = ">= 1.9.0"

  required_providers {
    azuread = {
      source  = "hashicorp/azuread"
      version = "~> 3.4"
    }
  }

  backend "azurerm" {}
}

provider "azuread" {
  tenant_id = var.instance.entra.tenantId
  use_oidc  = true
}
