variable "instance" {
  description = "Common instance configuration supplied by the module runner."
  type = object({
    name = string
    github = object({
      host       = string
      enterprise = string
    })
  })

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*\\.ghe\\.com$", var.instance.github.host))
    error_message = "The GitHub host must be a GHE.com subdomain such as example.ghe.com."
  }
}

# The runner always passes this contract variable; #18 adds actions-catalog.
# tflint-ignore: terraform_unused_declarations
variable "prerequisites" {
  description = "Public outputs of prerequisite modules supplied by the module runner."
  type        = any
}

variable "target_organizations" {
  description = "Organizations of the instance. The App installation tokens are scoped to the same list."
  type        = list(string)

  validation {
    condition     = length(var.target_organizations) > 0
    error_message = "At least one target organization is required."
  }

  validation {
    condition     = length(distinct(var.target_organizations)) == length(var.target_organizations)
    error_message = "Target organizations must be unique."
  }

  validation {
    condition = alltrue([
      for organization in var.target_organizations :
      can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", organization))
    ])
    error_message = "Each target organization must be a GitHub organization login."
  }
}
