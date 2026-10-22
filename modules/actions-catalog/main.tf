locals {
  api_url      = "https://api.${var.instance.github.host}"
  organization = var.instance.organizations.actions
  repositories = {
    for upstream in var.catalog : upstream => {
      api_url       = local.api_url
      organization  = local.organization
      upstream      = upstream
      security_team = var.security_team
    }
  }
  # The vendoring catalog of the instance repository is the single source of approved imports. The runner plans the module
  # in <instance>/platform/modules/actions-catalog, so the catalog lies three levels up.
  vendoring_path = coalesce(var.vendoring_catalog_path, "${path.module}/../../../vendoring/actions.json")
  vendoring      = try(jsondecode(file(local.vendoring_path)), null)
  vendored       = try({ for upstream, copy in local.vendoring.actions : upstream => copy }, {})
  # Missing or non-string fields become empty strings, which the preconditions of the releases output reject.
  releases = {
    for upstream, copy in local.vendored : upstream => {
      repository = try(copy.repository == null ? "" : tostring(copy.repository), "")
      tag        = try(copy.tag == null ? "" : tostring(copy.tag), "")
      commit     = try(copy.sha == null ? "" : tostring(copy.sha), "")
    }
  }
  # Only entries of the catalog reach a resource; any other entry fails the plan through the releases output.
  release_tags = { for upstream, release in local.releases : upstream => { tag = release.tag, commit = release.commit } if contains(var.catalog, upstream) }
  provisioner  = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Invoke-CatalogChange.ps1", "-Action"]
}

# Creates or adopts the internal repository {owner}-{repository}, opens its actions to the enterprise, gives the security
# team push access and writes CODEOWNERS into the empty repository. Every step reads first, so a repeated apply after an
# interruption converges. Destroy keeps the repository: it disappears with the actions organization (organizations module).
resource "terraform_data" "repository" {
  for_each = local.repositories

  input            = each.value
  triggers_replace = each.value

  provisioner "local-exec" {
    interpreter = local.provisioner
    command     = "InitializeRepository"
    environment = {
      CATALOG_INPUT = jsonencode(each.value)
    }
  }
}

# Tags the approved import commit with the upstream tag after its receipt and its place on protected main are verified.
# An existing tag is never moved; a new release adds a new tag.
resource "terraform_data" "release_tag" {
  for_each = local.release_tags

  input            = merge(local.repositories[each.key], { tag = each.value.tag, commit = each.value.commit })
  triggers_replace = [terraform_data.repository[each.key].id, merge(local.repositories[each.key], each.value)]

  provisioner "local-exec" {
    interpreter = local.provisioner
    command     = "CreateReleaseTag"
    environment = {
      CATALOG_INPUT = jsonencode(self.input)
    }
  }
}

# Reads the live state after the changes with read-only requests and lists every difference from the module state.
# Any read error fails the program, so the plan never treats an unknown state as compliant.
data "external" "catalog_state" {
  for_each = local.repositories

  program = ["pwsh", "-NoProfile", "-NonInteractive", "-File", "${path.module}/scripts/Read-CatalogState.ps1"]
  query = merge(each.value, {
    tag    = try(local.release_tags[each.key].tag, "")
    commit = try(local.release_tags[each.key].commit, "")
  })

  depends_on = [terraform_data.repository, terraform_data.release_tag]

  lifecycle {
    postcondition {
      condition     = length(jsondecode(self.result.violations)) == 0
      error_message = join(" ", jsondecode(self.result.violations))
    }
  }
}
