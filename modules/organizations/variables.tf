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
    condition     = can(regex("^[a-z0-9]+(-[a-z0-9]+)*$", var.instance.github.enterprise))
    error_message = "The enterprise must be an enterprise slug."
  }

  validation {
    condition     = var.instance.organizations != null
    error_message = "The organizations module needs the platform organization: run the module runner with -PlatformOrganization."
  }

  validation {
    condition = var.instance.organizations == null ? true : alltrue([
      for login in [var.instance.organizations.platform, var.instance.organizations.actions, var.instance.organizations.workloads] :
      can(regex("^[A-Za-z0-9]([A-Za-z0-9-]{0,37}[A-Za-z0-9])?$", login))
    ])
    error_message = "Each derived organization name must be a GitHub organization login."
  }

  validation {
    condition = var.instance.organizations == null ? true : length(distinct([
      for login in [var.instance.organizations.platform, var.instance.organizations.actions, var.instance.organizations.workloads] : lower(login)
    ])) == 3
    error_message = "The platform, actions and workloads organizations must have distinct names."
  }
}

# The runner always passes this contract variable; the module has no prerequisites.
# tflint-ignore: terraform_unused_declarations
variable "prerequisites" {
  description = "Public outputs of prerequisite modules supplied by the module runner."
  type        = any
}

variable "admin_logins" {
  description = "EMU logins of the owners of a newly created organization. Used only on creation."
  type        = list(string)

  validation {
    condition     = length(var.admin_logins) > 0
    error_message = "At least one owner login is required."
  }

  validation {
    condition     = length(distinct([for login in var.admin_logins : lower(login)])) == length(var.admin_logins)
    error_message = "Owner logins must be unique regardless of case."
  }

  validation {
    condition = alltrue([
      for login in var.admin_logins :
      length(login) <= 39 && can(regex("^[A-Za-z0-9]([A-Za-z0-9-]*[A-Za-z0-9])?_[A-Za-z0-9]+$", login))
    ])
    error_message = "Each owner must be an EMU login with the enterprise shortcode suffix, such as alice_demo."
  }
}

variable "billing_email" {
  description = "Billing email of a newly created organization. Used only on creation."
  type        = string

  validation {
    condition     = length(var.billing_email) <= 254 && can(regex("^[^@\\s]+@[^@\\s]+\\.[^@\\s]+$", var.billing_email))
    error_message = "The billing email must be an email address."
  }
}

variable "app_client_ids" {
  description = "Client IDs of enterprise-owned GitHub Apps installed into the actions and workloads organizations without repository access."
  type        = list(string)
  default     = []

  validation {
    condition     = length(distinct(var.app_client_ids)) == length(var.app_client_ids)
    error_message = "App client IDs must be unique."
  }

  validation {
    condition = alltrue([
      for id in var.app_client_ids : length(id) <= 64 && can(regex("^[A-Za-z0-9][A-Za-z0-9.]*$", id))
    ])
    error_message = "Each App client ID must be a GitHub App client ID."
  }
}
