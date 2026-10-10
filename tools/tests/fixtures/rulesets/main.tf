terraform {
  required_version = ">= 1.9.0"
  backend "local" {}
}

variable "instance" {
  description = "Common instance configuration supplied by the runner."
  type        = any
}

variable "prerequisites" {
  description = "Public outputs of prerequisite modules."
  type        = any
}

variable "message" {
  description = "Parameter of the ordinary fixture root."
  type        = string
  default     = "default"
}

variable "target_organizations" {
  description = "Organizations declared in the App resource contract."
  type        = list(string)
}

variable "bypass_actors" {
  description = "Complete bypass configuration included in plan."
  type        = list(string)
  default     = []
}

locals {
  ruleset = {
    organizations = var.target_organizations
    enforcement   = "active"
    rules         = ["pull_request", "non_fast_forward", "deletion"]
    bypass_actors = var.bypass_actors
  }
}

resource "terraform_data" "ruleset" {
  input = local.ruleset
}

output "ruleset" {
  value = local.ruleset
}

output "runner_inputs" {
  value = {
    instance_name      = var.instance.name
    prerequisite_count = length(var.prerequisites)
    message            = var.message
  }
}
