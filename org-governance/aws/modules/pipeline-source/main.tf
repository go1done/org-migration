# modules/pipeline-source/main.tf
#
# Reusable module for CodePipeline source stages.
# Resolves the correct CodeStar Connection based on which org the repo lives in.
#
# DUAL-ORG MODEL: A single pipeline can source from repos in BOTH orgs.
# Each source gets its own module instance with the correct github_org.
#
# Usage:
#
#   # Source from a repo that moved to the new org
#   module "source_app" {
#     source = "git::https://github.com/new-org/org-governance.git//aws/modules/pipeline-source"
#
#     repository_name = "my-app"
#     github_org      = "new-org"
#     connection_arns = var.connection_arns
#   }
#
#   # Source from a repo that stays in the old org
#   module "source_shared_lib" {
#     source = "git::https://github.com/new-org/org-governance.git//aws/modules/pipeline-source"
#
#     repository_name = "shared-terraform-modules"
#     github_org      = "old-org"          # <-- stays in old org
#     connection_arns = var.connection_arns
#   }

variable "repository_name" {
  description = "GitHub repository name (without org prefix)"
  type        = string
}

variable "branch" {
  description = "Branch to track"
  type        = string
  default     = "main"
}

variable "github_org" {
  description = "GitHub org where this repo lives — determines which CodeStar Connection to use"
  type        = string

  validation {
    condition     = can(regex("^[a-zA-Z0-9-]+$", var.github_org))
    error_message = "Organization name must contain only alphanumeric characters and hyphens."
  }
}

variable "connection_arns" {
  description = "Map of GitHub org name to CodeStar Connection ARN (both orgs)"
  type        = map(string)
}

locals {
  connection_arn = try(
    var.connection_arns[var.github_org],
    null
  )
  full_repo_id = "${var.github_org}/${var.repository_name}"
}

resource "null_resource" "validate_connection" {
  count = local.connection_arn == null ? 1 : 0

  provisioner "local-exec" {
    command = "echo 'ERROR: No CodeStar Connection found for org: ${var.github_org}. Available orgs: ${join(", ", keys(var.connection_arns))}' && exit 1"
  }
}

output "source_action_config" {
  description = "Configuration block for a CodePipeline source action"
  value = {
    ConnectionArn    = local.connection_arn
    FullRepositoryId = local.full_repo_id
    BranchName       = var.branch
  }
}

output "connection_arn" {
  description = "The resolved CodeStar Connection ARN for this repo's org"
  value       = local.connection_arn
}

output "full_repository_id" {
  description = "Full repository ID (org/repo)"
  value       = local.full_repo_id
}
