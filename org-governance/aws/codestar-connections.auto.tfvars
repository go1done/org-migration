# org-governance/aws/codestar-connections.auto.tfvars
# CHANGEME: Replace with your actual connection ARNs and org names

codestar_connections = {
  "CHANGEME-old-org" = "arn:aws:codeconnections:CHANGEME-region:CHANGEME-account-id:connection/CHANGEME-old-connection-id"
  "CHANGEME-new-org" = "arn:aws:codeconnections:CHANGEME-region:CHANGEME-account-id:connection/CHANGEME-new-connection-id"
}

# Set this to the new org name after migration Wave 4 (pipeline repos)
# During migration, pipelines in the old org still use the old connection
active_github_org = "CHANGEME-new-org"
