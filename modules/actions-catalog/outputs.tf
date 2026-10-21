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
  value       = { for upstream, release in var.releases : upstream => { tag = release.tag, commit = release.commit } }
  depends_on  = [data.external.catalog_state]
}
