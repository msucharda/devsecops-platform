variable "instance" {
  description = "Common instance configuration supplied by the module runner."
  type = object({
    name = string
    github = object({
      host       = string
      enterprise = string
    })
    customPatterns = optional(list(object({
      name         = string
      secretRegex  = string
      beforeSecret = optional(string)
      afterSecret  = optional(string)
    })), [])
  })

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*\\.ghe\\.com$", var.instance.github.host))
    error_message = "The GitHub host must be a GHE.com subdomain such as example.ghe.com."
  }

  validation {
    condition = alltrue([
      for pattern in coalesce(var.instance.customPatterns, []) :
      try(trimspace(pattern.name) != "" && trimspace(pattern.secretRegex) != "", false)
    ])
    error_message = "Each custom pattern needs a non-blank name and secretRegex."
  }

  validation {
    condition = length(distinct([
      for pattern in coalesce(var.instance.customPatterns, []) : pattern.name
    ])) == length(coalesce(var.instance.customPatterns, []))
    error_message = "Custom pattern names must be unique; the module finds each pattern in GitHub by name."
  }
}

# The runner always passes this contract variable. The module orders after organizations and actions-catalog, so the
# catalog repositories exist before the actions policy blocks upstream actions; it reads no prerequisite output.
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

# The module input contract is shared with the early Code Security phase.
# tflint-ignore: terraform_unused_declarations
variable "secret_scanning_bypass_reviewers" {
  description = "Teams or organization roles that review requests to bypass push protection, by GitHub ID. reviewer_type is TEAM or ROLE."
  type = list(object({
    reviewer_type = string
    reviewer_id   = number
  }))

  validation {
    condition     = length(var.secret_scanning_bypass_reviewers) > 0
    error_message = "At least one bypass reviewer is required; the security team must approve push protection bypasses."
  }

  validation {
    condition = alltrue([
      for reviewer in var.secret_scanning_bypass_reviewers :
      try(contains(["TEAM", "ROLE"], reviewer.reviewer_type) && reviewer.reviewer_id >= 1 && floor(reviewer.reviewer_id) == reviewer.reviewer_id, false)
    ])
    error_message = "Each bypass reviewer needs reviewer_type TEAM or ROLE and a positive integer reviewer_id."
  }

  validation {
    condition     = length(distinct(var.secret_scanning_bypass_reviewers)) == length(var.secret_scanning_bypass_reviewers)
    error_message = "Bypass reviewers must be unique."
  }
}