terraform {
  required_version = ">= 1.9.0"

  required_providers {
    restapi = {
      source  = "Mastercard/restapi"
      version = "~> 3.0"
    }
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

# The runner exports the job's installation token as REST_API_BEARER; the code security scripts read it too.
provider "restapi" {
  uri                  = local.github_api_url
  write_returns_object = true
  headers = {
    Accept                 = "application/vnd.github+json"
    "X-GitHub-Api-Version" = "2026-03-10"
  }
}
