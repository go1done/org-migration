# org-governance/github/secrets.tf
variable "org_secrets" {
  description = "Organization-level Actions secrets (values stored externally, referenced by name)"
  type = map(object({
    visibility      = string # "all", "private", or "selected"
    selected_repos  = optional(list(string), [])
  }))
  default = {}
}

# Secret values are NOT stored in Terraform state.
# This resource manages visibility/access only.
# Actual secret values must be set via GitHub CLI or API separately.
resource "github_actions_organization_secret" "secrets" {
  for_each = var.org_secrets

  secret_name     = each.key
  visibility      = each.value.visibility
  # plaintext_value is intentionally omitted — set via gh CLI
}

variable "org_variables" {
  description = "Organization-level Actions variables"
  type = map(object({
    value           = string
    visibility      = string
    selected_repos  = optional(list(string), [])
  }))
  default = {}
}

resource "github_actions_organization_variable" "variables" {
  for_each = var.org_variables

  variable_name = each.key
  value         = each.value.value
  visibility    = each.value.visibility
}
