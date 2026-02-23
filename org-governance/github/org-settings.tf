# org-governance/github/org-settings.tf
#
# Settings mapped from "Org settings" policy image:
#   • Repo creation restricted to org admins only
#   • All repos private — no internal or public repos
#   • Members cannot change repo visibility
#   • Forks of private repos enabled (same-org intent); cross-org restriction
#     cannot be enforced via Terraform — see docs/not-terraform-enforceable.md
#   • Team creation restricted to org admins only
resource "github_organization_settings" "org" {
  billing_email                                                = var.billing_email
  company                                                      = var.company_name
  blog                                                         = var.blog_url
  email                                                        = var.org_email
  description                                                  = var.org_description
  has_organization_projects                                    = true
  has_repository_projects                                      = true
  default_repository_permission                                = "read"

  # Repo creation — org admins only
  members_can_create_repositories          = false
  members_can_create_public_repositories   = false
  members_can_create_private_repositories  = false
  members_can_create_internal_repositories = false # No "internal" repos — private only

  # Forks: private-repo forks are allowed (within-org workflow).
  # Restricting forks to the same org only is not expressible via this
  # provider setting — see docs/not-terraform-enforceable.md.
  members_can_fork_private_repositories = true

  web_commit_signoff_required = true

  # Security defaults for new repositories
  advanced_security_enabled_for_new_repositories               = true
  dependabot_alerts_enabled_for_new_repositories               = true
  dependabot_security_updates_enabled_for_new_repositories     = true
  dependency_graph_enabled_for_new_repositories                = true
  secret_scanning_enabled_for_new_repositories                 = true
  secret_scanning_push_protection_enabled_for_new_repositories = true
}

variable "billing_email" {
  description = "Billing email for the org"
  type        = string
}

variable "company_name" {
  description = "Company name"
  type        = string
  default     = ""
}

variable "blog_url" {
  description = "Blog URL"
  type        = string
  default     = ""
}

variable "org_email" {
  description = "Org contact email"
  type        = string
  default     = ""
}

variable "org_description" {
  description = "Org description"
  type        = string
  default     = ""
}
