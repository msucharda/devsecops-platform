terraform {
  required_version = ">= 1.9.0"

  required_providers {
    external = {
      source  = "hashicorp/external"
      version = "~> 2.3"
    }
  }

  backend "azurerm" {}
}

locals {
  github_api_url = "https://api.${var.instance.github.host}"
}
