# The runner always passes the contract variables; this root only publishes the organizations of the rulesets root.
# tflint-ignore: terraform_unused_declarations
variable "instance" {
  description = "Common instance configuration supplied by the module runner, including organizations derived from the platform organization."
  type = object({
    github = object({ host = string })
    organizations = optional(object({
      deploymentIdentifier = optional(string)
      platform             = optional(string)
      actions              = string
      workloads            = optional(string)
    }))
  })

  validation {
    condition     = var.instance.organizations != null
    error_message = "The organization-rulesets module needs the actions organization: run the module runner with -PlatformOrganization."
  }
}

# tflint-ignore: terraform_unused_declarations
variable "prerequisites" {
  description = "Public outputs of prerequisite modules supplied by the module runner."
  type        = any
}

variable "target_organizations" {
  description = "Organizations whose rulesets the rulesets root of this module manages; that root receives the same list."
  type        = list(string)

  validation {
    condition = (
      length(var.target_organizations) == 1 &&
      length(distinct([for org in var.target_organizations : lower(org)])) == length(var.target_organizations) &&
      alltrue([for org in var.target_organizations : can(regex("^[A-Za-z0-9][A-Za-z0-9-]*$", org))])
    )
    error_message = "The REST provider supports exactly one organization per run; supply one valid GitHub organization name."
  }
  validation {
    condition = try(
      length(var.target_organizations) == 1 &&
      var.instance.organizations.actions != "" &&
      lower(var.target_organizations[0]) == lower(var.instance.organizations.actions),
      false
    )
    error_message = "target_organizations must contain exactly the actions organization of the instance."
  }
}
