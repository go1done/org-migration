# modules/pipeline-source/main.tf
#
# Reusable module for CodePipeline source stages.
# Automatically selects the correct CodeStar Connection based on the GitHub org.
#
# Usage in pipeline repos:
#
#   module "source" {
#     source = "git::https://github.com/new-org/org-governance.git//aws/modules/pipeline-source"
#
#     repository_name = "my-repo"
#     branch          = "main"
#     github_org      = "new-org"
#     connection_arns = {
#       "old-org" = "arn:aws:codeconnections:..."
#       "new-org" = "arn:aws:codeconnections:..."
#     }
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
  description = "GitHub organization name — determines which CodeStar Connection to use"
  type        = string
}

variable "connection_arns" {
  description = "Map of GitHub org name to CodeStar Connection ARN"
  type        = map(string)
}

locals {
  connection_arn = var.connection_arns[var.github_org]
  full_repo_id   = "${var.github_org}/${var.repository_name}"
}

output "source_action_config" {
  description = "Configuration block for a CodePipeline source action"
  value = {
    ConnectionArn    = local.connection_arn
    FullRepositoryId = local.full_repo_id
    BranchName       = var.branch
    # Use this in your aws_codepipeline source stage:
    #
    # action {
    #   name             = "Source"
    #   category         = "Source"
    #   owner            = "AWS"
    #   provider         = "CodeStarSourceConnection"
    #   version          = "1"
    #   output_artifacts = ["source_output"]
    #   configuration = module.source.source_action_config
    # }
  }
}

output "connection_arn" {
  description = "The resolved CodeStar Connection ARN"
  value       = local.connection_arn
}

output "full_repository_id" {
  description = "Full repository ID (org/repo)"
  value       = local.full_repo_id
}
