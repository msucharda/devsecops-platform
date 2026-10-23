terraform {
  required_version = ">= 1.9.0"
  backend "local" {}
}

variable "instance" {
  type = any
}

variable "prerequisites" {
  type = any
}

variable "target_organizations" {
  type = list(string)
  validation {
    condition     = length(var.target_organizations) == 1
    error_message = "Each Terraform process must receive one organization."
  }
}

variable "reviewers" {
  type    = list(number)
  default = []
}

resource "terraform_data" "organization" {
  input = var.target_organizations[0]
}

output "organizations" {
  value = var.target_organizations
}

output "identity" {
  value = terraform_data.organization.id
}

output "reviewers" {
  value = var.reviewers
}
