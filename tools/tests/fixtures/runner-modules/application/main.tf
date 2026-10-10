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

output "application_name" {
  value = "${var.prerequisites.foundation.foundation_name}-application"
}

output "primary_region" {
  value = var.instance.regions.primary
}
