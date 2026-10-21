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
  description = "A module-specific parameter."
  type        = string
  default     = "default"
}

output "foundation_name" {
  value = "${var.instance.name}-foundation"
}

output "message" {
  value = var.message
}

output "primary_region" {
  value = var.instance.regions.primary
}

output "prerequisite_count" {
  value = length(var.prerequisites)
}

output "entra_application" {
  value = try(var.instance.entra.enterpriseApplicationObjectId, "none")
}

output "github_host" {
  value = try(var.instance.github.host, "none")
}

output "github_enterprise" {
  value = try(var.instance.github.enterprise, "none")
}
