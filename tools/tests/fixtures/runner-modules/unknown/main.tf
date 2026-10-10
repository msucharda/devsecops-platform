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

resource "terraform_data" "fixture" {
  input = {
    name               = var.instance.name
    prerequisite_count = length(var.prerequisites)
  }
}

output "identifier" {
  value = {
    known = var.instance.name
    id    = terraform_data.fixture.id
  }
}
