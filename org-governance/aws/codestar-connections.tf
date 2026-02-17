# org-governance/aws/codestar-connections.tf
#
# DUAL-ORG MODEL: Both GitHub orgs coexist permanently. Some repos live in
# the old org, some in the new org. Repos in the new org may source modules
# from repos that remain in the old org. Both CodeStar Connections stay active.
#
# LIFECYCLE:
#   1. Create connections manually in Console (or CLI) — required for GitHub OAuth
#   2. Define them here as resources
#   3. Import into Terraform state: terraform import aws_codestarconnections_connection.github["old-org"] <arn>
#   4. From this point, Terraform manages them (name changes, tags, deletion protection)

variable "github_connections" {
  description = "Map of GitHub org name to connection configuration"
  type = map(object({
    name = string
    tags = optional(map(string), {})
  }))
  # Example:
  # {
  #   "old-org" = { name = "github-old-org" }
  #   "new-org" = { name = "github-new-org", tags = { Environment = "production" } }
  # }
}

# Managed resources — import existing connections into these
resource "aws_codestarconnections_connection" "github" {
  for_each = var.github_connections

  name          = each.value.name
  provider_type = "GitHub"
  tags          = each.value.tags

  # Prevent accidental deletion of active connections
  lifecycle {
    prevent_destroy = true
  }
}

# Outputs for pipeline repos to consume
output "connection_arns" {
  description = "All CodeStar Connection ARNs by org name"
  value = {
    for org, conn in aws_codestarconnections_connection.github :
    org => conn.arn
  }
}

output "connection_statuses" {
  description = "Status of each connection (should be AVAILABLE)"
  value = {
    for org, conn in aws_codestarconnections_connection.github :
    org => conn.connection_status
  }
}
