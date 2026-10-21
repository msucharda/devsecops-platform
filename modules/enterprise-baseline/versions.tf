terraform {
  required_version = ">= 1.9.0"

  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 3.0"
    }
  }

  backend "azurerm" {}
}

# The runner exports the job's installation token as REST_API_BEARER.
provider "restapi" {
  uri                  = "https://api.${var.instance.github.host}"
  write_returns_object = true
  headers = {
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2026-03-10"
  }
}
