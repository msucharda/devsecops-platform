locals {
  # Organization configuration, not enterprise_enforced; GitHub App tokens cannot apply enterprise-enforced configurations.
  code_security_configuration_name = "platform-baseline"

  # Fields of POST and PATCH /orgs/{org}/code-security/configurations (API version 2026-03-10) that the module manages.
  # advanced_security enabled turns on both Code Security and Secret Protection; the response reports it in the same field.
  code_security_settings = {
    advanced_security                = "enabled"
    dependency_graph                 = "enabled"
    dependabot_alerts                = "enabled"
    dependabot_security_updates      = "enabled"
    code_scanning_default_setup      = "enabled"
    secret_scanning                  = "enabled"
    secret_scanning_push_protection  = "enabled"
    secret_scanning_validity_checks  = "enabled"
    secret_scanning_delegated_bypass = "enabled"
    enforcement                      = "enforced"
  }

  secret_scanning_bypass_reviewers = [
    for reviewer in var.secret_scanning_bypass_reviewers : {
      reviewer_type = reviewer.reviewer_type
      reviewer_id   = reviewer.reviewer_id
      mode          = "ALWAYS"
    }
  ]

  code_security_configuration = merge(local.code_security_settings, {
    name        = local.code_security_configuration_name
    description = "Platform baseline managed by the enterprise-baseline module."
    secret_scanning_delegated_bypass_options = {
      reviewers = local.secret_scanning_bypass_reviewers
    }
  })

  # Documented delimiter defaults of POST /orgs/{org}/secret-scanning/custom-patterns.
  custom_pattern_default_start_delimiter = "\\A|[^0-9A-Za-z]"
  custom_pattern_default_end_delimiter   = "\\z|[^0-9A-Za-z]"

  custom_patterns = {
    for pattern in coalesce(var.instance.customPatterns, []) : pattern.name => {
      name            = pattern.name
      pattern         = pattern.secretRegex
      start_delimiter = try(coalesce(pattern.beforeSecret), local.custom_pattern_default_start_delimiter)
      end_delimiter   = try(coalesce(pattern.afterSecret), local.custom_pattern_default_end_delimiter)
    }
  }

  organization_custom_patterns = merge({}, [
    for organization in var.target_organizations : {
      for name, pattern in local.custom_patterns : "${organization}/${name}" => {
        organization = organization
        pattern      = pattern
      }
    }
  ]...)

  code_security_script = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/../scripts/Invoke-CodeSecurityChange.ps1", "-Action"]
}

# The REST provider cannot recover a configuration whose POST response was lost, and the custom pattern API deletes
# by ID and version in the request body. Scripts therefore find every object by name, so each action can be repeated.

# Identity of the configuration. Only its destroy deletes the configuration; deleting it detaches the repositories.
resource "terraform_data" "code_security_configuration" {
  for_each = toset(var.target_organizations)

  input = {
    api_url      = local.github_api_url
    organization = each.key
    name         = local.code_security_configuration_name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/../scripts/Invoke-CodeSecurityChange.ps1", "-Action"]
    command     = "RemoveConfiguration"
    environment = { CODE_SECURITY_INPUT = jsonencode(self.input) }
  }
}

# Content, default and attachment. A change replaces only this resource, so the configuration is updated in place.
resource "terraform_data" "code_security_configuration_settings" {
  for_each = toset(var.target_organizations)

  triggers_replace = {
    identity      = terraform_data.code_security_configuration[each.key].id
    configuration = local.code_security_configuration
  }

  input = {
    api_url       = local.github_api_url
    organization  = each.key
    configuration = local.code_security_configuration
  }

  provisioner "local-exec" {
    interpreter = local.code_security_script
    command     = "SetConfiguration"
    environment = { CODE_SECURITY_INPUT = jsonencode(self.input) }
  }
}

# Identity of a custom pattern. Only its destroy deletes the pattern and resolves its alerts.
resource "terraform_data" "custom_pattern" {
  for_each = local.organization_custom_patterns

  input = {
    api_url      = local.github_api_url
    organization = each.value.organization
    name         = each.value.pattern.name
  }

  provisioner "local-exec" {
    when        = destroy
    interpreter = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/../scripts/Invoke-CodeSecurityChange.ps1", "-Action"]
    command     = "RemoveCustomPattern"
    environment = { CODE_SECURITY_INPUT = jsonencode(self.input) }
  }
}

# Content and push protection of a custom pattern; a change updates the pattern in place.
resource "terraform_data" "custom_pattern_content" {
  for_each = local.organization_custom_patterns

  triggers_replace = {
    identity = terraform_data.custom_pattern[each.key].id
    pattern  = each.value.pattern
  }

  input = {
    api_url      = local.github_api_url
    organization = each.value.organization
    pattern      = each.value.pattern
  }

  provisioner "local-exec" {
    interpreter = local.code_security_script
    command     = "SetCustomPattern"
    environment = { CODE_SECURITY_INPUT = jsonencode(self.input) }
  }
}

# Reads the actual state. Without pending changes the plan reads it and fails on drift; with pending changes the read
# waits for apply and verifies the result. A read error fails the run. Only its postconditions consume the result.
# tflint-ignore: terraform_unused_declarations
data "external" "code_security_state" {
  for_each = toset(var.target_organizations)

  program = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/../scripts/Read-CodeSecurityState.ps1"]
  query = {
    api_url            = local.github_api_url
    organization       = each.key
    configuration_name = local.code_security_configuration_name
  }

  depends_on = [
    terraform_data.code_security_configuration,
    terraform_data.code_security_configuration_settings,
    terraform_data.custom_pattern,
    terraform_data.custom_pattern_content,
  ]

  lifecycle {
    postcondition {
      condition     = try(jsondecode(self.result.state).configuration.target_type == "organization", false)
      error_message = "Organization ${each.key} has no organization code security configuration named ${local.code_security_configuration_name}. Rerun the apply with -replace=terraform_data.code_security_configuration_settings[\"${each.key}\"] to restore it."
    }

    postcondition {
      condition = alltrue([
        for field, value in local.code_security_settings :
        try(jsondecode(self.result.state).configuration[field] == value, false)
      ])
      error_message = "The code security configuration of ${each.key} does not match the managed settings. The module does not repair drift automatically; restore the settings or rerun the apply with -replace=terraform_data.code_security_configuration_settings[\"${each.key}\"]."
    }

    postcondition {
      condition = try(
        length(jsondecode(self.result.state).configuration.secret_scanning_delegated_bypass_options.reviewers) == length(local.secret_scanning_bypass_reviewers) &&
        toset([
          for reviewer in jsondecode(self.result.state).configuration.secret_scanning_delegated_bypass_options.reviewers :
          "${reviewer.reviewer_type}/${reviewer.reviewer_id}/${reviewer.mode}"
        ]) == toset([for reviewer in local.secret_scanning_bypass_reviewers : "${reviewer.reviewer_type}/${reviewer.reviewer_id}/${reviewer.mode}"]),
        false
      )
      error_message = "The push protection bypass reviewers of ${each.key} differ from secret_scanning_bypass_reviewers. Restore the reviewers or rerun the apply with -replace=terraform_data.code_security_configuration_settings[\"${each.key}\"]."
    }

    postcondition {
      condition = alltrue([
        for visibility in ["public", "private_and_internal"] :
        try(toset([
          for default in jsondecode(self.result.state).defaults :
          default.configuration_id if contains(["all", visibility], default.default_for_new_repos)
        ]) == toset([tostring(jsondecode(self.result.state).configuration.id)]), false)
      ])
      error_message = "The code security configuration of ${each.key} is not the only default for new public, private and internal repositories."
    }

    postcondition {
      condition = try(alltrue([
        for repository in jsondecode(self.result.state).repositories :
        contains(["attached", "enforced"], repository.status)
      ]), false)
      error_message = "A repository of ${each.key} is not attached to the code security configuration, or its attachment is pending or failed. The plan output of the data source lists the statuses."
    }

    postcondition {
      condition     = try(length(jsondecode(self.result.state).uncovered_repositories) == 0, false)
      error_message = "A repository of ${each.key} has no successful attachment to the code security configuration. Rerun the apply with -replace=terraform_data.code_security_configuration_settings[\"${each.key}\"] to attach it."
    }
    postcondition {
      condition     = try(length(jsondecode(self.result.state).foreign_attachments) == 0, false)
      error_message = "A repository of ${each.key} is attached to another code security configuration. Rerun the apply with -replace=terraform_data.code_security_configuration_settings[\"${each.key}\"] to attach the managed configuration to all repositories."
    }

    postcondition {
      condition = alltrue([
        for name, pattern in local.custom_patterns :
        try(
          jsondecode(self.result.state).custom_patterns[name].pattern == pattern.pattern &&
          jsondecode(self.result.state).custom_patterns[name].start_delimiter == pattern.start_delimiter &&
          jsondecode(self.result.state).custom_patterns[name].end_delimiter == pattern.end_delimiter &&
          length(jsondecode(self.result.state).custom_patterns[name].must_match) == 0 &&
          length(jsondecode(self.result.state).custom_patterns[name].must_not_match) == 0,
          false
        )
      ])
      error_message = "A custom pattern of ${each.key} is missing or differs from customPatterns in the instance configuration. Rerun the apply with -replace for the affected terraform_data.custom_pattern_content."
    }

    postcondition {
      condition = alltrue([
        for name, pattern in local.custom_patterns :
        try(
          jsondecode(self.result.state).custom_patterns[name].state == "published" &&
          jsondecode(self.result.state).custom_patterns[name].push_protection_enabled == true,
          false
        )
      ])
      error_message = "A custom pattern of ${each.key} is not published or has push protection disabled. Publish the pattern and rerun the apply with -replace for the affected terraform_data.custom_pattern_content."
    }
  }
}
