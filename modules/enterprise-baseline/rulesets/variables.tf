# The runner always passes the contract variables; #20 adds the organization rulesets.
# tflint-ignore: terraform_unused_declarations
variable "instance" {
  description = "Common instance configuration supplied by the module runner."
  type        = any
}

# tflint-ignore: terraform_unused_declarations
variable "prerequisites" {
  description = "Public outputs of prerequisite modules supplied by the module runner."
  type        = any
}

variable "target_organizations" {
  description = "Organizations of the instance. The ruleset App installation tokens are scoped to the same list."
  type        = list(string)
}
