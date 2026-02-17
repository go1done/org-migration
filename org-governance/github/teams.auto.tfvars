# org-governance/github/teams.auto.tfvars
# CHANGEME: populate with actual team members
teams = {
  "aft-platform" = {
    description = "AFT platform team - manages core AFT infrastructure"
    maintainers = ["CHANGEME"]
    members     = ["CHANGEME"]
  }
  "aft-customizations" = {
    description = "AFT customizations team - manages account customizations"
    maintainers = ["CHANGEME"]
    members     = ["CHANGEME"]
  }
  "pipeline-admins" = {
    description = "Pipeline administrators - manages CI/CD pipelines"
    maintainers = ["CHANGEME"]
    members     = ["CHANGEME"]
  }
  "security-reviewers" = {
    description = "Security review team - required CODEOWNERS reviewers"
    maintainers = ["CHANGEME"]
    members     = ["CHANGEME"]
  }
}
