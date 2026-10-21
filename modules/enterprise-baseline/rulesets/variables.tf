variable "instance" {
  description = "Common instance configuration supplied by the module runner."
  type = object({
    github = object({ host = string })
  })
}

# tflint-ignore: terraform_unused_declarations
variable "prerequisites" {
  description = "Public outputs of prerequisite modules supplied by the module runner."
  type        = any
}

variable "target_organizations" {
  description = "Organizations of the instance. The ruleset App installation tokens are scoped to the same list."
  type        = list(string)

  validation {
    condition = (
      length(var.target_organizations) > 0 &&
      length(distinct([for org in var.target_organizations : lower(org)])) == length(var.target_organizations) &&
      alltrue([for org in var.target_organizations : can(regex("^[A-Za-z0-9][A-Za-z0-9-]*$", org))])
    )
    error_message = "Target organizations must be a non-empty list of unique GitHub organization names."
  }
}
