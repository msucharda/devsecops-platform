output "organization" {
  description = "Login of the actions organization that holds the catalog."
  value       = local.organization
}

output "repositories" {
  description = "Vendored repository (organization/name) of each upstream action in the catalog."
  value       = { for upstream, repository in local.repositories : upstream => "${repository.organization}/${replace(upstream, "/", "-")}" }
  depends_on  = [data.external.catalog_state]
}

output "releases" {
  description = "Verified tag and commit of each released action; workflows pin the commit."
  value       = local.release_tags
  depends_on  = [data.external.catalog_state]

  # Terraform checks these conditions during plan, before any resource changes.
  precondition {
    condition     = local.vendoring != null && try(local.vendoring.version == 2, false) && can(keys(local.vendoring.actions))
    error_message = "The vendoring catalog ${local.vendoring_path} must be readable JSON with version 2 and an actions mapping; migrate upstreamCommit from approved receipts."
  }

  precondition {
    condition     = alltrue([for upstream in keys(local.releases) : contains(var.catalog, upstream)])
    error_message = "Each action of the vendoring catalog must be a lowercase entry of the catalog parameter."
  }

  precondition {
    condition = alltrue([
      for upstream, release in local.releases : release.repository == "${local.organization}/${replace(upstream, "/", "-")}"
    ])
    error_message = "Each action of the vendoring catalog must name its copy {actions organization}/{owner}-{repo}."
  }

  precondition {
    condition = alltrue([
      for release in values(local.releases) :
      length(release.tag) <= 100 && can(regex("^[A-Za-z0-9][A-Za-z0-9._-]*$", release.tag)) &&
      !strcontains(release.tag, "..") && !endswith(release.tag, ".lock") && !endswith(release.tag, ".")
    ])
    error_message = "Each action of the vendoring catalog must record its upstream tag as a plain tag name such as v4.2.2."
  }

  precondition {
    condition     = alltrue([for release in values(local.releases) : can(regex("^[0-9a-f]{40}$", release.commit))])
    error_message = "Each action of the vendoring catalog must record a full lowercase commit SHA."
  }

  precondition {
    condition     = alltrue([for release in values(local.releases) : can(regex("^[0-9a-f]{40}$", release.upstream_commit))])
    error_message = "Each action of the vendoring catalog must record upstreamCommit as a full lowercase commit SHA from its approved receipt."
  }
}
