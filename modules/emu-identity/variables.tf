variable "instance" {
  description = "Common instance configuration supplied by the module runner."
  type = object({
    name = string
    teams = object({
      platform = list(string)
      security = list(string)
    })
    entra = object({
      tenantId                      = string
      enterpriseApplicationObjectId = string
    })
  })
}

# The runner always passes this contract variable; emu-identity has no prerequisites.
# tflint-ignore: terraform_unused_declarations
variable "prerequisites" {
  description = "Public outputs of prerequisite modules supplied by the module runner."
  type        = any
}
