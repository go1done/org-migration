# org-governance/aws/codestar-connections.tf
#
# Maps existing CodeStar Connections to GitHub orgs so pipelines can
# automatically resolve the correct connection ARN by org name.

variable "codestar_connections" {
  description = "Map of GitHub org name to CodeStar Connection ARN"
  type        = map(string)
  # Example:
  # {
  #   "old-org" = "arn:aws:codeconnections:us-east-1:123456789012:connection/abc-123"
  #   "new-org" = "arn:aws:codeconnections:us-east-1:123456789012:connection/def-456"
  # }
}

variable "active_github_org" {
  description = "The GitHub org that pipelines should use (set to new org after migration)"
  type        = string
}

# Look up existing connections by ARN (data source validates they exist)
data "aws_codestarconnections_connection" "github" {
  for_each = var.codestar_connections
  arn      = each.value
}

# Outputs for pipeline repos to consume
output "active_connection_arn" {
  description = "CodeStar Connection ARN for the active GitHub org"
  value       = var.codestar_connections[var.active_github_org]
}

output "connection_arns" {
  description = "All CodeStar Connection ARNs by org name"
  value       = var.codestar_connections
}

output "active_connection_status" {
  description = "Status of the active connection (should be AVAILABLE)"
  value       = data.aws_codestarconnections_connection.github[var.active_github_org].connection_status
}
