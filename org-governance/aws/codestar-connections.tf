# org-governance/aws/codestar-connections.tf
#
# DUAL-ORG MODEL: Both GitHub orgs coexist permanently. Some repos live in
# the old org, some in the new org. Repos in the new org may source modules
# from repos that remain in the old org. Both CodeStar Connections stay active.

variable "codestar_connections" {
  description = "Map of GitHub org name to CodeStar Connection ARN (both orgs)"
  type        = map(string)
  # Example:
  # {
  #   "old-org" = "arn:aws:codeconnections:us-east-1:123456789012:connection/abc-123"
  #   "new-org" = "arn:aws:codeconnections:us-east-1:123456789012:connection/def-456"
  # }
}

# Look up existing connections by ARN (validates they exist and are available)
data "aws_codestarconnections_connection" "github" {
  for_each = var.codestar_connections
  arn      = each.value
}

# Outputs for pipeline repos to consume — both connections available
output "connection_arns" {
  description = "All CodeStar Connection ARNs by org name"
  value       = var.codestar_connections
}

output "connection_statuses" {
  description = "Status of each connection (should be AVAILABLE)"
  value = {
    for org, _ in var.codestar_connections :
    org => data.aws_codestarconnections_connection.github[org].connection_status
  }
}
