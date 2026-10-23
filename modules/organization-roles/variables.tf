variable "instance" {
  description = "Common instance identity and its three derived organization names."
  type = object({
    name   = string
    github = object({ host = string })
    organizations = object({
      platform  = string
      actions   = string
      workloads = string
    })
  })

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*\\.ghe\\.com$", var.instance.github.host))
    error_message = "The GitHub host must be a GHE.com subdomain."
  }
}

# tflint-ignore: terraform_unused_declarations
variable "prerequisites" {
  description = "Public outputs of prerequisite modules supplied by the runner."
  type        = any
}

variable "target_organizations" {
  description = "The runner validates the complete instance scope and passes one organization to each isolated process."
  type        = list(string)

  validation {
    condition = (
      length(var.target_organizations) == 1 &&
      alltrue([for org in var.target_organizations : can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", org))])
    )
    error_message = "Each Terraform process must receive exactly one valid organization login."
  }

  validation {
    condition = alltrue([
      for org in var.target_organizations :
      contains([for login in values(var.instance.organizations) : lower(login)], lower(org))
    ])
    error_message = "The target organization must belong to the platform/actions/workloads instance scope."
  }
}

variable "security_team" {
  description = "Slug of the pre-existing organization security team linked manually to the Entra ID security group."
  type        = string
  default     = "security"

  validation {
    condition     = can(regex("^[A-Za-z0-9]+(-[A-Za-z0-9]+)*$", var.security_team))
    error_message = "security_team must be a team slug containing only letters, digits and separating hyphens."
  }
}
