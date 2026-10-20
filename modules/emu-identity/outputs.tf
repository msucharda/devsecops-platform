# Only values known during plan are published; the runner rejects unknown planned outputs.
output "group_names" {
  description = "Display names of the Entra ID groups that SCIM provisions to GHE."
  value       = { for key, group in local.groups : key => group.display_name }
}
