# org-governance/github/repos.auto.tfvars
# CHANGEME: populate with actual repo inventory from source org
repositories = {
  # --- Governance repos (created fresh, not migrated) ---
  "org-governance" = {
    description = "Terraform-managed GitHub org settings, rulesets, and AWS SCPs"
    topics      = ["terraform", "governance", "iac"]
    team_access = {
      "aft-platform" = "admin"
    }
  }
  "org-policies" = {
    description = "OPA/Rego policies for Terraform compliance"
    topics      = ["opa", "compliance", "policies"]
    team_access = {
      "aft-platform"      = "admin"
      "security-reviewers" = "push"
    }
  }
  "org-shared-workflows" = {
    description = "Reusable GitHub Actions workflows for compliance and CI/CD"
    topics      = ["github-actions", "ci-cd", "compliance"]
    team_access = {
      "pipeline-admins" = "admin"
      "aft-platform"    = "push"
    }
  }
  "migration-tooling" = {
    description = "Temporary repo for migration scripts and manifests"
    topics      = ["migration"]
    team_access = {
      "aft-platform" = "admin"
    }
  }

  # --- Wave 1: Canary repos (CHANGEME: replace with actual repos) ---
  # "aft-helper-module" = {
  #   description = "CHANGEME"
  #   topics      = ["aft", "terraform"]
  #   auto_init   = false  # will be populated by git mirror
  #   team_access = {
  #     "aft-customizations" = "push"
  #     "aft-platform"       = "admin"
  #   }
  # }

  # --- Wave 2: AFT Customization repos ---
  # "aft-global-customizations" = {
  #   description = "AFT global customizations applied to all accounts"
  #   topics      = ["aft", "terraform", "customizations"]
  #   auto_init   = false
  #   team_access = {
  #     "aft-customizations" = "push"
  #     "aft-platform"       = "admin"
  #   }
  # }
  # "aft-account-customizations" = { ... }
  # "aft-account-provisioning-customizations" = { ... }

  # --- Wave 3: AFT Core ---
  # "aft-account-request" = { ... }

  # --- Wave 4: Pipeline repos ---
  # "pipeline-infra" = { ... }
  # "pipeline-app-deploy" = { ... }
}
