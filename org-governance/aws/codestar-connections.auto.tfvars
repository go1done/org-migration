# org-governance/aws/codestar-connections.auto.tfvars
#
# Both connections remain active permanently — repos in the new org may
# source modules from repos that stay in the old org.

codestar_connections = {
  "CHANGEME-old-org" = "arn:aws:codeconnections:CHANGEME-region:CHANGEME-account-id:connection/CHANGEME-old-connection-id"
  "CHANGEME-new-org" = "arn:aws:codeconnections:CHANGEME-region:CHANGEME-account-id:connection/CHANGEME-new-connection-id"
}
