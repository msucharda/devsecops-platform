variable "instance" {
  description = "Common instance configuration supplied by the module runner, including organizations derived from the platform organization."
  type = object({
    name = string
    github = object({
      host       = string
      enterprise = string
    })
    organizations = optional(object({
      deploymentIdentifier = optional(string)
      platform             = string
      actions              = string
      workloads            = string
    }))
  })

  validation {
    condition     = can(regex("^[a-z][a-z0-9]*(-[a-z0-9]+)*\\.ghe\\.com$", var.instance.github.host))
    error_message = "The GitHub host must be a GHE.com subdomain such as example.ghe.com."
  }

  validation {
    condition     = var.instance.organizations != null
    error_message = "The actions-catalog module needs the platform organization: run the module runner with -PlatformOrganization."
  }
}

# The runner always passes this contract variable; the module reads the actions organization from the instance.
# tflint-ignore: terraform_unused_declarations
variable "prerequisites" {
  description = "Public outputs of prerequisite modules supplied by the module runner."
  type        = any
}

# The module runner reads the variable as the GitHub App resource scope; the validation pins it to the actions organization.
# tflint-ignore: terraform_unused_declarations
variable "target_organizations" {
  description = "GitHub App resource scope of the module: exactly the actions organization of the instance."
  type        = list(string)

  validation {
    condition = (
      var.instance.organizations != null && length(var.target_organizations) == 1 &&
      lower(var.target_organizations[0]) == lower(try(var.instance.organizations.actions, ""))
    )
    error_message = "target_organizations must contain exactly the actions organization of the instance."
  }
}

variable "security_team" {
  description = "Slug of the team in the actions organization that owns every catalog repository through CODEOWNERS and approves imports."
  type        = string

  validation {
    condition     = length(var.security_team) <= 100 && can(regex("^[a-z0-9]([a-z0-9-]*[a-z0-9])?$", var.security_team))
    error_message = "The security team must be a lowercase team slug."
  }
}

variable "catalog" {
  description = "Upstream actions (lowercase owner/repository) vendored into the repository {owner}-{repository} of the actions organization."
  type        = list(string)
  default = [
    "actions/checkout",
    "actions/upload-artifact",
    "actions/download-artifact",
    "actions/create-github-app-token",
    "azure/login",
    "hashicorp/setup-terraform",
  ]

  validation {
    condition     = length(var.catalog) > 0 && length(distinct(var.catalog)) == length(var.catalog)
    error_message = "The catalog must list each upstream action once."
  }

  validation {
    condition = alltrue([
      for upstream in var.catalog :
      can(regex("^[a-z0-9]([a-z0-9-]{0,37}[a-z0-9])?/[a-z0-9_.-]{1,100}$", upstream)) && !can(regex("/\\.\\.?$", upstream)) &&
      length(upstream) <= 100
    ])
    error_message = "Each catalog entry must be a lowercase upstream owner/repository whose copy name {owner}-{repo} has at most 100 characters."
  }

  validation {
    condition     = length(distinct([for upstream in var.catalog : replace(upstream, "/", "-")])) == length(var.catalog)
    error_message = "Two catalog entries map to the same repository name."
  }
}

variable "releases" {
  description = "Approved imports to tag: upstream action => upstream tag and the commit of the vendored copy on main whose receipt records that tag."
  type = map(object({
    tag    = string
    commit = string
  }))
  default = {}

  validation {
    condition     = alltrue([for upstream in keys(var.releases) : contains(var.catalog, upstream)])
    error_message = "Each release must belong to an action in the catalog."
  }

  validation {
    condition = alltrue([
      for release in values(var.releases) :
      length(release.tag) <= 100 && can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", release.tag)) &&
      !strcontains(release.tag, "..") && !endswith(release.tag, ".lock") && !endswith(release.tag, ".")
    ])
    error_message = "Each release tag must be a plain tag name such as v4.2.2."
  }

  validation {
    condition     = alltrue([for release in values(var.releases) : can(regex("^[0-9a-f]{40}$", release.commit))])
    error_message = "Each release commit must be a full lowercase commit SHA."
  }
}
