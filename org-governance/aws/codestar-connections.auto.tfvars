# org-governance/aws/codestar-connections.auto.tfvars
#
# Both connections remain active permanently.
# CHANGEME: Replace with your actual org names and connection names.
#
# The "name" must match the connection name you created in the Console/CLI.

github_connections = {
  "CHANGEME-old-org" = {
    name = "github-CHANGEME-old-org"
    tags = {
      Purpose   = "Source code access for repos staying in old org"
      ManagedBy = "terraform"
    }
  }
  "CHANGEME-new-org" = {
    name = "github-CHANGEME-new-org"
    tags = {
      Purpose   = "Source code access for repos migrated to new org"
      ManagedBy = "terraform"
    }
  }
}
