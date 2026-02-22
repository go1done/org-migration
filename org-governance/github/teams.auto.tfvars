# org-governance/github/teams.auto.tfvars
# group_id: Azure AD Object ID — find at GitHub Org Settings → Authentication security → Identity provider groups
# group_name: Azure AD group display name
teams = {
  "aft-platform" = {
    description = "AFT platform team - manages core AFT infrastructure"
    idp_group = {
      group_id   = "CHANGEME"
      group_name = "CHANGEME"
    }
  }
  "aft-customizations" = {
    description = "AFT customizations team - manages account customizations"
    idp_group = {
      group_id   = "CHANGEME"
      group_name = "CHANGEME"
    }
  }
  "pipeline-admins" = {
    description = "Pipeline administrators - manages CI/CD pipelines"
    idp_group = {
      group_id   = "CHANGEME"
      group_name = "CHANGEME"
    }
  }
  "security-reviewers" = {
    description = "Security review team - required CODEOWNERS reviewers"
    idp_group = {
      group_id   = "CHANGEME"
      group_name = "CHANGEME"
    }
  }
}
