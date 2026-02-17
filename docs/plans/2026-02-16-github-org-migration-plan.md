# GitHub Org Migration Implementation Plan

> **For Claude:** REQUIRED SUB-SKILL: Use superpowers:executing-plans to implement this plan task-by-task.

**Goal:** Migrate 15+ AFT and pipeline repos from a partially governed GitHub org to a new Enterprise Cloud org with full Terraform-managed policy enforcement.

**Architecture:** Policy-first phased migration (Approach B). Terraform `org-governance` repo establishes org settings, rulesets, teams, and security before any repos are migrated. Repos migrate in dependency-ordered waves with automated mirror + reference update + validation. OPA policies and reusable GitHub Actions workflows enforce compliance post-migration.

**Tech Stack:** Terraform (GitHub provider + AWS provider), GitHub Enterprise Cloud, OPA/Conftest, GitHub Actions, Bash scripting, AWS AFT

**Design doc:** `docs/plans/2026-02-16-github-org-migration-design.md`

---

## Task 1: Bootstrap `org-governance` Terraform Repo

**Files:**
- Create: `org-governance/github/main.tf`
- Create: `org-governance/github/versions.tf`
- Create: `org-governance/.gitignore`
- Create: `org-governance/README.md`

**Step 1: Create Terraform provider configuration**

```hcl
# org-governance/github/versions.tf
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    github = {
      source  = "integrations/github"
      version = "~> 6.0"
    }
  }

  # Update backend to your state storage
  backend "s3" {
    bucket         = "CHANGEME-terraform-state"
    key            = "org-governance/github/terraform.tfstate"
    region         = "CHANGEME-region"
    dynamodb_table = "CHANGEME-terraform-locks"
    encrypt        = true
  }
}
```

```hcl
# org-governance/github/main.tf
provider "github" {
  owner = var.github_org
  # Authentication via GITHUB_TOKEN env var or GitHub App
}

variable "github_org" {
  description = "Target GitHub organization name"
  type        = string
}
```

```gitignore
# org-governance/.gitignore
.terraform/
*.tfstate
*.tfstate.backup
*.tfplan
.terraform.lock.hcl
```

**Step 2: Validate Terraform initializes**

Run: `cd org-governance/github && terraform init`
Expected: "Terraform has been successfully initialized!"

**Step 3: Commit**

```bash
git add org-governance/
git commit -m "feat: bootstrap org-governance terraform repo"
```

---

## Task 2: Org-Level Settings

**Files:**
- Create: `org-governance/github/org-settings.tf`

**Step 1: Write org settings configuration**

```hcl
# org-governance/github/org-settings.tf
resource "github_organization_settings" "org" {
  billing_email                                                = var.billing_email
  company                                                      = var.company_name
  blog                                                         = var.blog_url
  email                                                        = var.org_email
  description                                                  = var.org_description
  has_organization_projects                                    = true
  has_repository_projects                                      = true
  default_repository_permission                                = "read"
  members_can_create_repositories                              = false
  members_can_create_public_repositories                       = false
  members_can_create_private_repositories                      = false
  members_can_create_internal_repositories                     = false
  members_can_fork_private_repositories                        = false
  web_commit_signoff_required                                  = true
  advanced_security_enabled_for_new_repositories               = true
  dependabot_alerts_enabled_for_new_repositories               = true
  dependabot_security_updates_enabled_for_new_repositories     = true
  dependency_graph_enabled_for_new_repositories                = true
  secret_scanning_enabled_for_new_repositories                 = true
  secret_scanning_push_protection_enabled_for_new_repositories = true
}

variable "billing_email" {
  description = "Billing email for the org"
  type        = string
}

variable "company_name" {
  description = "Company name"
  type        = string
  default     = ""
}

variable "blog_url" {
  description = "Blog URL"
  type        = string
  default     = ""
}

variable "org_email" {
  description = "Org contact email"
  type        = string
  default     = ""
}

variable "org_description" {
  description = "Org description"
  type        = string
  default     = ""
}
```

**Step 2: Validate**

Run: `cd org-governance/github && terraform validate`
Expected: "Success! The configuration is valid."

**Step 3: Commit**

```bash
git add org-governance/github/org-settings.tf
git commit -m "feat: add org-level settings with security defaults"
```

---

## Task 3: Teams & Access

**Files:**
- Create: `org-governance/github/teams.tf`
- Create: `org-governance/github/teams.auto.tfvars` (template)

**Step 1: Write team definitions**

```hcl
# org-governance/github/teams.tf
variable "teams" {
  description = "Map of team configurations"
  type = map(object({
    description = string
    privacy     = optional(string, "closed")
    maintainers = optional(list(string), [])
    members     = optional(list(string), [])
  }))
  default = {}
}

resource "github_team" "teams" {
  for_each = var.teams

  name        = each.key
  description = each.value.description
  privacy     = each.value.privacy
}

resource "github_team_membership" "maintainers" {
  for_each = {
    for pair in flatten([
      for team_name, team in var.teams : [
        for user in team.maintainers : {
          key      = "${team_name}-${user}"
          team_id  = github_team.teams[team_name].id
          username = user
          role     = "maintainer"
        }
      ]
    ]) : pair.key => pair
  }

  team_id  = each.value.team_id
  username = each.value.username
  role     = each.value.role
}

resource "github_team_membership" "members" {
  for_each = {
    for pair in flatten([
      for team_name, team in var.teams : [
        for user in team.members : {
          key      = "${team_name}-${user}"
          team_id  = github_team.teams[team_name].id
          username = user
          role     = "member"
        }
      ]
    ]) : pair.key => pair
  }

  team_id  = each.value.team_id
  username = each.value.username
  role     = each.value.role
}
```

**Step 2: Create tfvars template**

```hcl
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
```

**Step 3: Validate**

Run: `cd org-governance/github && terraform validate`
Expected: "Success! The configuration is valid."

**Step 4: Commit**

```bash
git add org-governance/github/teams.tf org-governance/github/teams.auto.tfvars
git commit -m "feat: add team definitions with membership management"
```

---

## Task 4: Organization Rulesets

**Files:**
- Create: `org-governance/github/rulesets.tf`

**Step 1: Write org-level rulesets**

```hcl
# org-governance/github/rulesets.tf

# Baseline ruleset — applies to ALL repos
resource "github_organization_ruleset" "baseline" {
  name        = "baseline"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
    repository_name {
      include = ["~ALL"]
      exclude = ["migration-tooling"]
    }
  }

  rules {
    pull_request {
      required_approving_review_count   = 1
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = true
      required_review_thread_resolution = true
    }

    required_status_checks {
      required_check {
        context = "terraform-compliance"
      }
      strict_required_status_checks_policy = true
    }

    non_fast_forward = true
    deletion         = true
  }
}

# Strict ruleset — applies to aft-* repos
resource "github_organization_ruleset" "aft_strict" {
  name        = "aft-strict"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
    repository_name {
      include = ["aft-*"]
      exclude = []
    }
  }

  rules {
    pull_request {
      required_approving_review_count   = 2
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = true
      required_review_thread_resolution = true
      require_code_owner_review         = true
    }

    required_status_checks {
      required_check {
        context = "terraform-compliance"
      }
      required_check {
        context = "terraform-validate"
      }
      required_check {
        context = "opa-policy-check"
      }
      strict_required_status_checks_policy = true
    }

    commit_message_pattern {
      operator = "starts_with"
      pattern  = "(feat|fix|docs|chore|refactor|test):"
      name     = "conventional-commits"
    }

    non_fast_forward = true
    deletion         = true
  }
}

# Pipeline ruleset — applies to pipeline-* repos
resource "github_organization_ruleset" "pipeline_strict" {
  name        = "pipeline-strict"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~DEFAULT_BRANCH"]
      exclude = []
    }
    repository_name {
      include = ["pipeline-*"]
      exclude = []
    }
  }

  rules {
    pull_request {
      required_approving_review_count   = 2
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = true
      required_review_thread_resolution = true
      require_code_owner_review         = true
    }

    required_status_checks {
      required_check {
        context = "terraform-compliance"
      }
      required_check {
        context = "repo-compliance-check"
      }
      strict_required_status_checks_policy = true
    }

    non_fast_forward = true
    deletion         = true
  }
}
```

**Step 2: Validate**

Run: `cd org-governance/github && terraform validate`
Expected: "Success! The configuration is valid."

**Step 3: Commit**

```bash
git add org-governance/github/rulesets.tf
git commit -m "feat: add org-level rulesets (baseline, aft-strict, pipeline-strict)"
```

---

## Task 5: Repository Definitions

**Files:**
- Create: `org-governance/github/repos.tf`
- Create: `org-governance/github/repos.auto.tfvars` (template)

**Step 1: Write repo creation module**

```hcl
# org-governance/github/repos.tf
variable "repositories" {
  description = "Map of repository configurations"
  type = map(object({
    description            = string
    visibility             = optional(string, "private")
    has_issues             = optional(bool, true)
    has_wiki               = optional(bool, false)
    has_projects           = optional(bool, false)
    delete_branch_on_merge = optional(bool, true)
    auto_init              = optional(bool, false)
    archive_on_destroy     = optional(bool, true)
    vulnerability_alerts   = optional(bool, true)
    topics                 = optional(list(string), [])
    team_access = optional(map(string), {})
    # team_name => permission (pull, triage, push, maintain, admin)
  }))
  default = {}
}

resource "github_repository" "repos" {
  for_each = var.repositories

  name                   = each.key
  description            = each.value.description
  visibility             = each.value.visibility
  has_issues             = each.value.has_issues
  has_wiki               = each.value.has_wiki
  has_projects           = each.value.has_projects
  delete_branch_on_merge = each.value.delete_branch_on_merge
  auto_init              = each.value.auto_init
  archive_on_destroy     = each.value.archive_on_destroy
  vulnerability_alerts   = each.value.vulnerability_alerts
  topics                 = each.value.topics

  security_and_analysis {
    secret_scanning {
      status = "enabled"
    }
    secret_scanning_push_protection {
      status = "enabled"
    }
  }
}

resource "github_team_repository" "access" {
  for_each = {
    for pair in flatten([
      for repo_name, repo in var.repositories : [
        for team_name, permission in repo.team_access : {
          key        = "${repo_name}-${team_name}"
          repository = repo_name
          team_id    = github_team.teams[team_name].id
          permission = permission
        }
      ]
    ]) : pair.key => pair
  }

  repository = each.value.repository
  team_id    = each.value.team_id
  permission = each.value.permission

  depends_on = [github_repository.repos]
}
```

**Step 2: Create repos tfvars template**

```hcl
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
```

**Step 3: Validate**

Run: `cd org-governance/github && terraform validate`
Expected: "Success! The configuration is valid."

**Step 4: Commit**

```bash
git add org-governance/github/repos.tf org-governance/github/repos.auto.tfvars
git commit -m "feat: add repository definitions with team access"
```

---

## Task 6: Org-Level Secrets

**Files:**
- Create: `org-governance/github/secrets.tf`

**Step 1: Write secrets configuration**

```hcl
# org-governance/github/secrets.tf
variable "org_secrets" {
  description = "Organization-level Actions secrets (values stored externally, referenced by name)"
  type = map(object({
    visibility      = string # "all", "private", or "selected"
    selected_repos  = optional(list(string), [])
  }))
  default = {}
}

# Secret values are NOT stored in Terraform state.
# This resource manages visibility/access only.
# Actual secret values must be set via GitHub CLI or API separately.
resource "github_actions_organization_secret" "secrets" {
  for_each = var.org_secrets

  secret_name     = each.key
  visibility      = each.value.visibility
  # plaintext_value is intentionally omitted — set via gh CLI
}

variable "org_variables" {
  description = "Organization-level Actions variables"
  type = map(object({
    value           = string
    visibility      = string
    selected_repos  = optional(list(string), [])
  }))
  default = {}
}

resource "github_actions_organization_variable" "variables" {
  for_each = var.org_variables

  variable_name = each.key
  value         = each.value.value
  visibility    = each.value.visibility
}
```

**Step 2: Validate**

Run: `cd org-governance/github && terraform validate`
Expected: "Success! The configuration is valid."

**Step 3: Commit**

```bash
git add org-governance/github/secrets.tf
git commit -m "feat: add org-level Actions secrets and variables management"
```

---

## Task 7: AWS SCPs and Config Rules

**Files:**
- Create: `org-governance/aws/versions.tf`
- Create: `org-governance/aws/scps.tf`
- Create: `org-governance/aws/config-rules.tf`

**Step 1: Write AWS provider config**

```hcl
# org-governance/aws/versions.tf
terraform {
  required_version = ">= 1.5.0"

  required_providers {
    aws = {
      source  = "hashicorp/aws"
      version = "~> 5.0"
    }
  }

  backend "s3" {
    bucket         = "CHANGEME-terraform-state"
    key            = "org-governance/aws/terraform.tfstate"
    region         = "CHANGEME-region"
    dynamodb_table = "CHANGEME-terraform-locks"
    encrypt        = true
  }
}

provider "aws" {
  region = var.aws_region
}

variable "aws_region" {
  description = "AWS region"
  type        = string
  default     = "us-east-1"
}
```

**Step 2: Write SCP definitions**

```hcl
# org-governance/aws/scps.tf
variable "aft_ou_id" {
  description = "AWS Organizations OU ID for AFT-managed accounts"
  type        = string
}

# Deny public S3 buckets
resource "aws_organizations_policy" "deny_public_s3" {
  name        = "deny-public-s3"
  description = "Prevent creation of public S3 buckets"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid       = "DenyPublicS3"
        Effect    = "Deny"
        Action    = [
          "s3:PutBucketPublicAccessBlock",
          "s3:PutAccountPublicAccessBlock"
        ]
        Resource  = "*"
        Condition = {
          StringNotEquals = {
            "s3:PublicAccessBlockConfiguration/BlockPublicAcls"       = "true"
            "s3:PublicAccessBlockConfiguration/BlockPublicPolicy"     = "true"
            "s3:PublicAccessBlockConfiguration/IgnorePublicAcls"      = "true"
            "s3:PublicAccessBlockConfiguration/RestrictPublicBuckets" = "true"
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_public_s3" {
  policy_id = aws_organizations_policy.deny_public_s3.id
  target_id = var.aft_ou_id
}

# Deny leaving the organization
resource "aws_organizations_policy" "deny_leave_org" {
  name        = "deny-leave-org"
  description = "Prevent accounts from leaving the organization"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyLeaveOrg"
        Effect   = "Deny"
        Action   = "organizations:LeaveOrganization"
        Resource = "*"
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "deny_leave_org" {
  policy_id = aws_organizations_policy.deny_leave_org.id
  target_id = var.aft_ou_id
}

# Require encryption at rest
resource "aws_organizations_policy" "require_encryption" {
  name        = "require-encryption-at-rest"
  description = "Require encryption on EBS volumes and RDS instances"
  type        = "SERVICE_CONTROL_POLICY"

  content = jsonencode({
    Version = "2012-10-17"
    Statement = [
      {
        Sid      = "DenyUnencryptedEBS"
        Effect   = "Deny"
        Action   = "ec2:CreateVolume"
        Resource = "*"
        Condition = {
          Bool = {
            "ec2:Encrypted" = "false"
          }
        }
      },
      {
        Sid      = "DenyUnencryptedRDS"
        Effect   = "Deny"
        Action   = "rds:CreateDBInstance"
        Resource = "*"
        Condition = {
          Bool = {
            "rds:StorageEncrypted" = "false"
          }
        }
      }
    ]
  })
}

resource "aws_organizations_policy_attachment" "require_encryption" {
  policy_id = aws_organizations_policy.require_encryption.id
  target_id = var.aft_ou_id
}
```

**Step 3: Write Config rules**

```hcl
# org-governance/aws/config-rules.tf
variable "config_recorder_enabled" {
  description = "Whether AWS Config recorder is already enabled"
  type        = bool
  default     = true
}

# Detect untagged resources
resource "aws_config_config_rule" "required_tags" {
  name = "required-tags"

  source {
    owner             = "AWS"
    source_identifier = "REQUIRED_TAGS"
  }

  input_parameters = jsonencode({
    tag1Key   = "Environment"
    tag2Key   = "Owner"
    tag3Key   = "Project"
    tag4Key   = "ManagedBy"
  })
}

# Detect unencrypted S3 buckets
resource "aws_config_config_rule" "s3_encryption" {
  name = "s3-bucket-server-side-encryption-enabled"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_SERVER_SIDE_ENCRYPTION_ENABLED"
  }
}

# Detect public S3 buckets
resource "aws_config_config_rule" "s3_public_read" {
  name = "s3-bucket-public-read-prohibited"

  source {
    owner             = "AWS"
    source_identifier = "S3_BUCKET_PUBLIC_READ_PROHIBITED"
  }
}

# Detect IAM policies with wildcards
resource "aws_config_config_rule" "iam_no_wildcard" {
  name = "iam-policy-no-statements-with-admin-access"

  source {
    owner             = "AWS"
    source_identifier = "IAM_POLICY_NO_STATEMENTS_WITH_ADMIN_ACCESS"
  }
}
```

**Step 4: Validate both**

Run: `cd org-governance/aws && terraform init && terraform validate`
Expected: "Success! The configuration is valid."

**Step 5: Commit**

```bash
git add org-governance/aws/
git commit -m "feat: add AWS SCPs and Config rules for compliance guardrails"
```

---

## Task 8: OPA Policies Repo

**Files:**
- Create: `org-policies/policies/tagging.rego`
- Create: `org-policies/policies/encryption.rego`
- Create: `org-policies/policies/iam.rego`
- Create: `org-policies/policies/networking.rego`
- Create: `org-policies/policies/naming.rego`
- Create: `org-policies/tests/tagging_test.rego`
- Create: `org-policies/conftest.toml`

**Step 1: Write tagging policy + test**

```rego
# org-policies/policies/tagging.rego
package terraform.tagging

import rego.v1

required_tags := {"Environment", "Owner", "Project", "ManagedBy"}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.change.actions[_] == "create"
    tags := object.get(resource.change.after, "tags", {})
    missing := required_tags - {key | tags[key]}
    count(missing) > 0
    msg := sprintf(
        "%s '%s' is missing required tags: %v",
        [resource.type, resource.name, missing]
    )
}
```

```rego
# org-policies/tests/tagging_test.rego
package terraform.tagging_test

import rego.v1
import data.terraform.tagging

test_deny_missing_tags if {
    result := tagging.deny with input as {
        "resource_changes": [{
            "type": "aws_s3_bucket",
            "name": "test",
            "change": {
                "actions": ["create"],
                "after": {"tags": {}}
            }
        }]
    }
    count(result) > 0
}

test_allow_all_tags if {
    result := tagging.deny with input as {
        "resource_changes": [{
            "type": "aws_s3_bucket",
            "name": "test",
            "change": {
                "actions": ["create"],
                "after": {
                    "tags": {
                        "Environment": "prod",
                        "Owner": "platform",
                        "Project": "aft",
                        "ManagedBy": "terraform"
                    }
                }
            }
        }]
    }
    count(result) == 0
}
```

**Step 2: Write encryption policy**

```rego
# org-policies/policies/encryption.rego
package terraform.encryption

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_s3_bucket_server_side_encryption_configuration"
    resource.change.actions[_] == "delete"
    msg := sprintf(
        "Cannot remove encryption from S3 bucket '%s'",
        [resource.name]
    )
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_ebs_volume"
    resource.change.actions[_] == "create"
    not resource.change.after.encrypted
    msg := sprintf(
        "EBS volume '%s' must be encrypted",
        [resource.name]
    )
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_db_instance"
    resource.change.actions[_] == "create"
    not resource.change.after.storage_encrypted
    msg := sprintf(
        "RDS instance '%s' must have storage encryption enabled",
        [resource.name]
    )
}
```

**Step 3: Write IAM policy**

```rego
# org-policies/policies/iam.rego
package terraform.iam

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_iam_policy"
    resource.change.actions[_] == "create"
    policy_doc := json.unmarshal(resource.change.after.policy)
    statement := policy_doc.Statement[_]
    statement.Effect == "Allow"
    action := statement.Action[_]
    action == "*"
    msg := sprintf(
        "IAM policy '%s' must not use wildcard (*) actions",
        [resource.name]
    )
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_iam_role_policy"
    resource.change.actions[_] == "create"
    policy_doc := json.unmarshal(resource.change.after.policy)
    statement := policy_doc.Statement[_]
    statement.Effect == "Allow"
    statement.Resource == "*"
    action := statement.Action[_]
    action == "*"
    msg := sprintf(
        "IAM inline policy on role '%s' must not use wildcard (*) actions with wildcard resources",
        [resource.name]
    )
}
```

**Step 4: Write networking policy**

```rego
# org-policies/policies/networking.rego
package terraform.networking

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_security_group_rule"
    resource.change.actions[_] == "create"
    resource.change.after.type == "ingress"
    resource.change.after.cidr_blocks[_] == "0.0.0.0/0"
    resource.change.after.from_port != 443
    msg := sprintf(
        "Security group rule '%s' allows ingress from 0.0.0.0/0 on port %d (only 443 allowed)",
        [resource.name, resource.change.after.from_port]
    )
}

deny contains msg if {
    resource := input.resource_changes[_]
    resource.type == "aws_security_group"
    resource.change.actions[_] == "create"
    ingress := resource.change.after.ingress[_]
    ingress.cidr_blocks[_] == "0.0.0.0/0"
    ingress.from_port == 0
    ingress.to_port == 0
    msg := sprintf(
        "Security group '%s' allows all traffic from 0.0.0.0/0",
        [resource.name]
    )
}
```

**Step 5: Write naming policy**

```rego
# org-policies/policies/naming.rego
package terraform.naming

import rego.v1

deny contains msg if {
    resource := input.resource_changes[_]
    resource.change.actions[_] == "create"
    tags := object.get(resource.change.after, "tags", {})
    name := object.get(tags, "Name", "")
    name != ""
    not regex.match(`^[a-z][a-z0-9-]+$`, name)
    msg := sprintf(
        "%s '%s' Name tag must be lowercase alphanumeric with hyphens (got '%s')",
        [resource.type, resource.name, name]
    )
}
```

**Step 6: Write conftest config**

```toml
# org-policies/conftest.toml
[policy]
  paths = ["policies/"]
[test]
  paths = ["tests/"]
```

**Step 7: Run OPA tests**

Run: `cd org-policies && opa test policies/ tests/ -v`
Expected: All tests pass

**Step 8: Commit**

```bash
git add org-policies/
git commit -m "feat: add OPA policies for tagging, encryption, IAM, networking, naming"
```

---

## Task 9: Reusable GitHub Actions Workflows

**Files:**
- Create: `org-shared-workflows/.github/workflows/terraform-compliance.yml`
- Create: `org-shared-workflows/.github/workflows/repo-compliance-check.yml`
- Create: `org-shared-workflows/.github/workflows/drift-detection.yml`

**Step 1: Write terraform-compliance workflow**

```yaml
# org-shared-workflows/.github/workflows/terraform-compliance.yml
name: Terraform Compliance

on:
  workflow_call:
    inputs:
      working_directory:
        description: "Directory containing Terraform files"
        required: true
        type: string
      terraform_version:
        description: "Terraform version to use"
        required: false
        type: string
        default: "1.7.0"
    secrets:
      AWS_ROLE_ARN:
        required: true
      GITHUB_TOKEN:
        required: false

jobs:
  compliance:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write
      pull-requests: write

    defaults:
      run:
        working-directory: ${{ inputs.working_directory }}

    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3
        with:
          terraform_version: ${{ inputs.terraform_version }}

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-arn: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Terraform Format Check
        id: fmt
        run: terraform fmt -check -recursive
        continue-on-error: true

      - name: Terraform Init
        run: terraform init -backend=false

      - name: Terraform Validate
        id: validate
        run: terraform validate -no-color

      - name: tflint
        uses: terraform-linters/setup-tflint@v4
      - run: tflint --init && tflint --format compact

      - name: Terraform Plan (JSON output for OPA)
        id: plan
        run: |
          terraform plan -out=tfplan -no-color
          terraform show -json tfplan > tfplan.json

      - name: OPA Policy Check
        uses: open-policy-agent/conftest-action@v2
        with:
          files: ${{ inputs.working_directory }}/tfplan.json
          policy: policies/

      - name: Post PR Comment
        if: github.event_name == 'pull_request'
        uses: actions/github-script@v7
        with:
          script: |
            const output = `### Terraform Compliance Results
            | Check | Status |
            |-------|--------|
            | Format | ${{ steps.fmt.outcome == 'success' && 'Pass' || 'Fail' }} |
            | Validate | ${{ steps.validate.outcome == 'success' && 'Pass' || 'Fail' }} |
            | Plan | ${{ steps.plan.outcome == 'success' && 'Pass' || 'Fail' }} |
            | OPA Policies | ${{ steps.opa.outcome == 'success' && 'Pass' || 'Fail' }} |`;
            github.rest.issues.createComment({
              issue_number: context.issue.number,
              owner: context.repo.owner,
              repo: context.repo.repo,
              body: output
            });
```

**Step 2: Write repo-compliance-check workflow**

```yaml
# org-shared-workflows/.github/workflows/repo-compliance-check.yml
name: Repository Compliance Check

on:
  workflow_call:

jobs:
  compliance:
    runs-on: ubuntu-latest
    permissions:
      contents: read

    steps:
      - uses: actions/checkout@v4

      - name: Check CODEOWNERS exists
        run: |
          if [ ! -f "CODEOWNERS" ] && [ ! -f ".github/CODEOWNERS" ] && [ ! -f "docs/CODEOWNERS" ]; then
            echo "::error::CODEOWNERS file is missing"
            exit 1
          fi

      - name: Validate CODEOWNERS syntax
        run: |
          CODEOWNERS_FILE=""
          for f in CODEOWNERS .github/CODEOWNERS docs/CODEOWNERS; do
            [ -f "$f" ] && CODEOWNERS_FILE="$f" && break
          done
          # Check each line has a valid pattern and at least one owner
          grep -v '^#' "$CODEOWNERS_FILE" | grep -v '^$' | while read -r line; do
            owners=$(echo "$line" | awk '{$1=""; print $0}' | xargs)
            if [ -z "$owners" ]; then
              echo "::error::CODEOWNERS line missing owners: $line"
              exit 1
            fi
          done

      - name: Secret scan with gitleaks
        uses: gitleaks/gitleaks-action@v2
        env:
          GITHUB_TOKEN: ${{ secrets.GITHUB_TOKEN }}

      - name: Check for .gitignore
        run: |
          if [ ! -f ".gitignore" ]; then
            echo "::warning::.gitignore file is missing"
          fi

      - name: Terraform format check (if HCL files exist)
        run: |
          if compgen -G "**/*.tf" > /dev/null 2>&1; then
            terraform fmt -check -recursive
          fi
```

**Step 3: Write drift-detection workflow**

```yaml
# org-shared-workflows/.github/workflows/drift-detection.yml
name: Drift Detection

on:
  workflow_call:
    inputs:
      working_directory:
        description: "Directory containing Terraform files"
        required: true
        type: string
      schedule_cron:
        description: "Cron schedule for drift detection"
        required: false
        type: string
        default: "0 6 * * 1-5"
    secrets:
      AWS_ROLE_ARN:
        required: true
      SLACK_WEBHOOK_URL:
        required: false

jobs:
  detect-drift:
    runs-on: ubuntu-latest
    permissions:
      contents: read
      id-token: write

    defaults:
      run:
        working-directory: ${{ inputs.working_directory }}

    steps:
      - uses: actions/checkout@v4

      - uses: hashicorp/setup-terraform@v3

      - uses: aws-actions/configure-aws-credentials@v4
        with:
          role-to-arn: ${{ secrets.AWS_ROLE_ARN }}
          aws-region: us-east-1

      - name: Terraform Init
        run: terraform init

      - name: Terraform Plan (detect drift)
        id: plan
        run: |
          terraform plan -detailed-exitcode -no-color 2>&1 | tee plan_output.txt
          echo "exit_code=${PIPESTATUS[0]}" >> "$GITHUB_OUTPUT"
        continue-on-error: true

      - name: Alert on drift
        if: steps.plan.outputs.exit_code == '2'
        run: |
          echo "::warning::Drift detected in ${{ inputs.working_directory }}"
          if [ -n "${{ secrets.SLACK_WEBHOOK_URL }}" ]; then
            curl -X POST "${{ secrets.SLACK_WEBHOOK_URL }}" \
              -H 'Content-type: application/json' \
              -d "{\"text\": \"Drift detected in \`${{ inputs.working_directory }}\` — review required.\"}"
          fi
```

**Step 4: Commit**

```bash
git add org-shared-workflows/
git commit -m "feat: add reusable GitHub Actions workflows (compliance, drift detection)"
```

---

## Task 10: Migration Tooling — Inventory Script

**Files:**
- Create: `migration-tooling/scripts/inventory.sh`
- Create: `migration-tooling/config/repo-manifest.yaml`

**Step 1: Write inventory script**

```bash
#!/usr/bin/env bash
# migration-tooling/scripts/inventory.sh
# Enumerates all repos in the source org and generates a manifest template.
#
# Usage: ./inventory.sh <source-org> [output-file]
# Requires: gh CLI authenticated to the source org

set -euo pipefail

SOURCE_ORG="${1:?Usage: $0 <source-org> [output-file]}"
OUTPUT="${2:-repo-manifest.yaml}"

echo "Fetching repos from ${SOURCE_ORG}..."

echo "repos:" > "$OUTPUT"

gh repo list "$SOURCE_ORG" \
  --limit 200 \
  --json name,description,visibility,defaultBranchRef,isArchived,hasWikiEnabled \
  --jq '.[] | select(.isArchived == false)' \
  | jq -s '.' \
  | jq -r '.[] | "  - name: \(.name)\n    description: \"\(.description // "")\"\n    visibility: \(.visibility | ascii_downcase)\n    default_branch: \(.defaultBranchRef.name // "main")\n    source: '"$SOURCE_ORG"'/\(.name)\n    target: CHANGEME-NEW-ORG/\(.name)\n    wave: 0  # CHANGEME: assign to wave 1-4\n    status: pending\n    type: unknown  # CHANGEME: aft-core | aft-customization | module | pipeline | other\n    ci_coupled: false  # CHANGEME\n    depends_on: []  # CHANGEME\n"' \
  >> "$OUTPUT"

echo ""
echo "Wrote ${OUTPUT} with $(grep -c '  - name:' "$OUTPUT") repos."
echo ""
echo "Next steps:"
echo "  1. Assign each repo to a wave (1-4)"
echo "  2. Set the type for each repo"
echo "  3. Set ci_coupled to true for repos with org-coupled CI/CD"
echo "  4. Add depends_on for repos with cross-repo Terraform module refs"
echo "  5. Replace CHANGEME-NEW-ORG with your target org name"
```

**Step 2: Create manifest template**

```yaml
# migration-tooling/config/repo-manifest.yaml
# Generated by inventory.sh — edit wave assignments and metadata before migrating.
#
# wave: 0 = unassigned, 1 = canary, 2 = AFT customizations, 3 = AFT core, 4 = pipelines
# status: pending | migrating | migrated | failed
# type: aft-core | aft-customization | module | pipeline | governance | other

repos: []
# Run inventory.sh to populate this file
```

**Step 3: Make executable and commit**

```bash
chmod +x migration-tooling/scripts/inventory.sh
git add migration-tooling/
git commit -m "feat: add inventory script and manifest template"
```

---

## Task 11: Migration Tooling — Migrate Repo Script

**Files:**
- Create: `migration-tooling/scripts/migrate-repo.sh`

**Step 1: Write single-repo migration script**

```bash
#!/usr/bin/env bash
# migration-tooling/scripts/migrate-repo.sh
# Mirrors a single repo from source org to target org.
#
# Usage: ./migrate-repo.sh <source-org/repo> <target-org/repo>
# Requires: gh CLI, git, authenticated to both orgs

set -euo pipefail

SOURCE="${1:?Usage: $0 <source-org/repo> <target-org/repo>}"
TARGET="${2:?Usage: $0 <source-org/repo> <target-org/repo>}"

SOURCE_ORG="${SOURCE%%/*}"
SOURCE_REPO="${SOURCE##*/}"
TARGET_ORG="${TARGET%%/*}"
TARGET_REPO="${TARGET##*/}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Migration: ${SOURCE} -> ${TARGET} ==="

# Step 1: Pre-flight checks
echo "[1/5] Pre-flight checks..."
if ! gh repo view "$SOURCE" --json name -q '.name' > /dev/null 2>&1; then
  echo "ERROR: Source repo ${SOURCE} not found or not accessible"
  exit 1
fi

if ! gh repo view "$TARGET" --json name -q '.name' > /dev/null 2>&1; then
  echo "ERROR: Target repo ${TARGET} not found. Create it via Terraform first."
  exit 1
fi

# Step 2: Mirror clone
echo "[2/5] Cloning ${SOURCE} (mirror)..."
git clone --mirror "https://github.com/${SOURCE}.git" "${WORK_DIR}/${SOURCE_REPO}.git"

# Step 3: Push mirror to target
echo "[3/5] Pushing mirror to ${TARGET}..."
cd "${WORK_DIR}/${SOURCE_REPO}.git"
git push --mirror "https://github.com/${TARGET}.git"

# Step 4: Scan for org references
echo "[4/5] Scanning for source org references..."
cd "$WORK_DIR"
git clone "https://github.com/${TARGET}.git" "${TARGET_REPO}"
cd "${TARGET_REPO}"

REFS_FOUND=$(grep -rn "${SOURCE_ORG}" --include='*.tf' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.md' --include='*.hcl' . 2>/dev/null || true)
if [ -n "$REFS_FOUND" ]; then
  echo ""
  echo "WARNING: Found references to source org '${SOURCE_ORG}':"
  echo "$REFS_FOUND"
  echo ""
  echo "These need to be updated to '${TARGET_ORG}' in a migration PR."

  # Create migration branch with automated replacements
  git checkout -b "migration/update-org-refs"
  grep -rl "${SOURCE_ORG}" --include='*.tf' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.hcl' . 2>/dev/null | while read -r file; do
    sed -i "s|${SOURCE_ORG}|${TARGET_ORG}|g" "$file"
  done
  git add -A
  if git diff --cached --quiet; then
    echo "No changes to commit after reference update."
  else
    git commit -m "chore: update org references from ${SOURCE_ORG} to ${TARGET_ORG}"
    git push -u origin "migration/update-org-refs"
    echo ""
    echo "Migration branch pushed. Create a PR to review the changes:"
    echo "  gh pr create --repo ${TARGET} --base main --head migration/update-org-refs --title 'Update org references post-migration'"
  fi
else
  echo "No source org references found."
fi

# Step 5: Validation summary
echo ""
echo "[5/5] Migration summary:"
echo "  Source:  ${SOURCE}"
echo "  Target:  ${TARGET}"
echo "  Status:  Mirror complete"
echo ""
echo "Post-migration checklist:"
echo "  [ ] Verify org rulesets applied (check branch protection)"
echo "  [ ] Open test PR to validate review requirements"
echo "  [ ] Run CI/CD end-to-end"
echo "  [ ] Review and merge org reference update PR (if created)"
echo "  [ ] Archive source repo when satisfied"
```

**Step 2: Make executable and commit**

```bash
chmod +x migration-tooling/scripts/migrate-repo.sh
git add migration-tooling/scripts/migrate-repo.sh
git commit -m "feat: add single-repo migration script with reference scanning"
```

---

## Task 12: Migration Tooling — Bulk Migration & Validation

**Files:**
- Create: `migration-tooling/scripts/bulk-migrate.sh`
- Create: `migration-tooling/scripts/validate-migration.sh`
- Create: `migration-tooling/scripts/find-org-refs.sh`

**Step 1: Write bulk migration script**

```bash
#!/usr/bin/env bash
# migration-tooling/scripts/bulk-migrate.sh
# Migrates all repos in a given wave from repo-manifest.yaml.
#
# Usage: ./bulk-migrate.sh <wave-number> <manifest-file>
# Requires: yq, gh CLI, git

set -euo pipefail

WAVE="${1:?Usage: $0 <wave-number> <manifest-file>}"
MANIFEST="${2:?Usage: $0 <wave-number> <manifest-file>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Bulk Migration: Wave ${WAVE} ==="

REPOS=$(yq eval ".repos[] | select(.wave == ${WAVE} and .status == \"pending\")" "$MANIFEST")
if [ -z "$REPOS" ]; then
  echo "No pending repos found for wave ${WAVE}."
  exit 0
fi

REPO_COUNT=$(yq eval "[.repos[] | select(.wave == ${WAVE} and .status == \"pending\")] | length" "$MANIFEST")
echo "Found ${REPO_COUNT} repos to migrate in wave ${WAVE}."
echo ""

INDEX=0
yq eval -o=json ".repos[] | select(.wave == ${WAVE} and .status == \"pending\")" "$MANIFEST" | jq -c '.' | while read -r repo; do
  INDEX=$((INDEX + 1))
  NAME=$(echo "$repo" | jq -r '.name')
  SOURCE=$(echo "$repo" | jq -r '.source')
  TARGET=$(echo "$repo" | jq -r '.target')

  echo "--- [${INDEX}/${REPO_COUNT}] Migrating: ${NAME} ---"

  # Update status to migrating
  yq eval -i "(.repos[] | select(.name == \"${NAME}\")).status = \"migrating\"" "$MANIFEST"

  if "${SCRIPT_DIR}/migrate-repo.sh" "$SOURCE" "$TARGET"; then
    yq eval -i "(.repos[] | select(.name == \"${NAME}\")).status = \"migrated\"" "$MANIFEST"
    echo "SUCCESS: ${NAME} migrated."
  else
    yq eval -i "(.repos[] | select(.name == \"${NAME}\")).status = \"failed\"" "$MANIFEST"
    echo "FAILED: ${NAME} migration failed. Continuing with remaining repos."
  fi
  echo ""
done

echo "=== Wave ${WAVE} Complete ==="
echo "Results:"
yq eval ".repos[] | select(.wave == ${WAVE}) | .name + \": \" + .status" "$MANIFEST"
```

**Step 2: Write validation script**

```bash
#!/usr/bin/env bash
# migration-tooling/scripts/validate-migration.sh
# Validates a migrated repo meets compliance requirements.
#
# Usage: ./validate-migration.sh <org/repo>
# Requires: gh CLI

set -euo pipefail

REPO="${1:?Usage: $0 <org/repo>}"

echo "=== Validating: ${REPO} ==="

PASS=0
FAIL=0

check() {
  local name="$1" result="$2"
  if [ "$result" = "true" ] || [ "$result" = "PASS" ]; then
    echo "  [PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${name}"
    FAIL=$((FAIL + 1))
  fi
}

# Check vulnerability alerts
VULN=$(gh api "repos/${REPO}" --jq '.security_and_analysis.secret_scanning.status' 2>/dev/null || echo "disabled")
check "Secret scanning enabled" "$([ "$VULN" = "enabled" ] && echo true || echo false)"

# Check push protection
PUSH_PROT=$(gh api "repos/${REPO}" --jq '.security_and_analysis.secret_scanning_push_protection.status' 2>/dev/null || echo "disabled")
check "Push protection enabled" "$([ "$PUSH_PROT" = "enabled" ] && echo true || echo false)"

# Check default branch protection (via rulesets)
RULESETS=$(gh api "repos/${REPO}/rulesets" --jq 'length' 2>/dev/null || echo "0")
check "Rulesets applied (count: ${RULESETS})" "$([ "$RULESETS" -gt 0 ] && echo true || echo false)"

# Check CODEOWNERS exists
CODEOWNERS=$(gh api "repos/${REPO}/contents/CODEOWNERS" --jq '.name' 2>/dev/null || \
  gh api "repos/${REPO}/contents/.github/CODEOWNERS" --jq '.name' 2>/dev/null || echo "")
check "CODEOWNERS file exists" "$([ -n "$CODEOWNERS" ] && echo true || echo false)"

# Check topics
TOPICS=$(gh api "repos/${REPO}" --jq '.topics | length' 2>/dev/null || echo "0")
check "Topics assigned (count: ${TOPICS})" "$([ "$TOPICS" -gt 0 ] && echo true || echo false)"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && echo "Status: ALL CHECKS PASSED" || echo "Status: SOME CHECKS FAILED"
exit "$FAIL"
```

**Step 3: Write org reference finder**

```bash
#!/usr/bin/env bash
# migration-tooling/scripts/find-org-refs.sh
# Scans a repo for references to the old org name.
#
# Usage: ./find-org-refs.sh <repo-path> <old-org-name>

set -euo pipefail

REPO_PATH="${1:?Usage: $0 <repo-path> <old-org-name>}"
OLD_ORG="${2:?Usage: $0 <repo-path> <old-org-name>}"

echo "Scanning ${REPO_PATH} for references to '${OLD_ORG}'..."
echo ""

RESULTS=$(grep -rn "$OLD_ORG" \
  --include='*.tf' \
  --include='*.tfvars' \
  --include='*.hcl' \
  --include='*.yml' \
  --include='*.yaml' \
  --include='*.json' \
  --include='*.md' \
  --include='*.sh' \
  --include='Makefile' \
  "$REPO_PATH" 2>/dev/null || true)

if [ -n "$RESULTS" ]; then
  echo "Found references:"
  echo "$RESULTS"
  echo ""
  echo "Total: $(echo "$RESULTS" | wc -l) occurrences"
else
  echo "No references found."
fi
```

**Step 4: Make all executable and commit**

```bash
chmod +x migration-tooling/scripts/bulk-migrate.sh
chmod +x migration-tooling/scripts/validate-migration.sh
chmod +x migration-tooling/scripts/find-org-refs.sh
git add migration-tooling/scripts/
git commit -m "feat: add bulk migration, validation, and org-ref scanning scripts"
```

---

## Task 13: Compliance Dashboard

**Files:**
- Create: `org-governance/compliance/dashboard.tf`
- Create: `org-governance/compliance/compliance-report.yml` (GitHub Action)

**Step 1: Write compliance report workflow**

This runs in the `org-governance` repo on a schedule.

```yaml
# org-governance/.github/workflows/compliance-report.yml
name: Org Compliance Report

on:
  schedule:
    - cron: "0 8 * * 1-5"  # Weekdays at 8am UTC
  workflow_dispatch:

permissions:
  contents: read
  issues: write

jobs:
  report:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v4

      - name: Generate compliance report
        env:
          GH_TOKEN: ${{ secrets.ORG_ADMIN_TOKEN }}
          ORG_NAME: ${{ vars.ORG_NAME }}
        run: |
          echo "# Org Compliance Report - $(date -u +%Y-%m-%d)" > report.md
          echo "" >> report.md
          echo "| Repo | Secret Scanning | Push Protection | Rulesets | CODEOWNERS |" >> report.md
          echo "|------|----------------|-----------------|----------|------------|" >> report.md

          NONCOMPLIANT=0

          gh repo list "$ORG_NAME" --limit 200 --json name --jq '.[].name' | while read -r repo; do
            FULL="${ORG_NAME}/${repo}"

            SS=$(gh api "repos/${FULL}" --jq '.security_and_analysis.secret_scanning.status // "unknown"' 2>/dev/null || echo "unknown")
            PP=$(gh api "repos/${FULL}" --jq '.security_and_analysis.secret_scanning_push_protection.status // "unknown"' 2>/dev/null || echo "unknown")
            RS=$(gh api "repos/${FULL}/rulesets" --jq 'length' 2>/dev/null || echo "0")
            CO="no"
            gh api "repos/${FULL}/contents/CODEOWNERS" > /dev/null 2>&1 && CO="yes"
            gh api "repos/${FULL}/contents/.github/CODEOWNERS" > /dev/null 2>&1 && CO="yes"

            SS_ICON=$([ "$SS" = "enabled" ] && echo "pass" || echo "FAIL")
            PP_ICON=$([ "$PP" = "enabled" ] && echo "pass" || echo "FAIL")
            RS_ICON=$([ "$RS" -gt 0 ] && echo "pass ($RS)" || echo "FAIL")
            CO_ICON=$([ "$CO" = "yes" ] && echo "pass" || echo "FAIL")

            echo "| ${repo} | ${SS_ICON} | ${PP_ICON} | ${RS_ICON} | ${CO_ICON} |" >> report.md

            if [ "$SS_ICON" = "FAIL" ] || [ "$PP_ICON" = "FAIL" ] || [ "$RS_ICON" = "FAIL" ] || [ "$CO_ICON" = "FAIL" ]; then
              NONCOMPLIANT=$((NONCOMPLIANT + 1))
            fi
          done

          echo "" >> report.md
          echo "**Non-compliant repos: ${NONCOMPLIANT}**" >> report.md

      - name: Create issue if non-compliant
        env:
          GH_TOKEN: ${{ secrets.GITHUB_TOKEN }}
        run: |
          if grep -q "FAIL" report.md; then
            gh issue create \
              --title "Compliance Report: $(date -u +%Y-%m-%d) - Issues Found" \
              --body "$(cat report.md)" \
              --label "compliance"
          fi

      - name: Upload report artifact
        uses: actions/upload-artifact@v4
        with:
          name: compliance-report
          path: report.md
```

**Step 2: Commit**

```bash
git add org-governance/.github/
git commit -m "feat: add scheduled org compliance report workflow"
```

---

## Task 14: Apply Foundation (Terraform Plan & Apply)

This is a manual execution task — not automated in CI yet.

**Step 1: Populate all CHANGEME values**

Review and update:
- `org-governance/github/versions.tf` — S3 backend config
- `org-governance/github/teams.auto.tfvars` — team members
- `org-governance/github/repos.auto.tfvars` — repo list (start with governance repos only)
- `org-governance/aws/versions.tf` — S3 backend config

**Step 2: Initialize and plan (GitHub)**

```bash
cd org-governance/github
export GITHUB_TOKEN="ghp_CHANGEME"
export TF_VAR_github_org="CHANGEME-new-org"
export TF_VAR_billing_email="CHANGEME"
terraform init
terraform plan -out=tfplan
```

Review plan output carefully.

**Step 3: Apply (GitHub)**

```bash
terraform apply tfplan
```

**Step 4: Initialize and plan (AWS)**

```bash
cd org-governance/aws
export TF_VAR_aft_ou_id="ou-CHANGEME"
terraform init
terraform plan -out=tfplan
```

**Step 5: Apply (AWS)**

```bash
terraform apply tfplan
```

**Step 6: Commit state changes / verify**

```bash
git add -A
git commit -m "chore: apply foundation - org settings, teams, rulesets, SCPs"
```

---

## Task 15: Execute Wave 1 — Canary Migration

**Step 1: Run inventory on source org**

```bash
cd migration-tooling
./scripts/inventory.sh CHANGEME-old-org config/repo-manifest.yaml
```

**Step 2: Edit manifest — assign 2-3 low-risk repos to wave 1**

Edit `config/repo-manifest.yaml` and set `wave: 1` for canary repos.

**Step 3: Ensure target repos exist in Terraform**

Uncomment and populate wave 1 repos in `org-governance/github/repos.auto.tfvars`, then:

```bash
cd org-governance/github && terraform plan -out=tfplan && terraform apply tfplan
```

**Step 4: Run wave 1 migration**

```bash
cd migration-tooling
./scripts/bulk-migrate.sh 1 config/repo-manifest.yaml
```

**Step 5: Validate each migrated repo**

```bash
./scripts/validate-migration.sh CHANGEME-new-org/repo-name-1
./scripts/validate-migration.sh CHANGEME-new-org/repo-name-2
```

**Step 6: Manual validation**

- Open a test PR in each migrated repo — confirm review requirements enforced
- Merge a PR — confirm CI runs and status checks pass
- Check Dependabot — confirm it created PRs if dependencies are outdated

**Step 7: Commit manifest update**

```bash
git add config/repo-manifest.yaml
git commit -m "chore: wave 1 canary migration complete"
```

---

## Task 16: Execute Wave 2 — AFT Customization Repos

Follow the same pattern as Task 15:

1. Uncomment wave 2 repos in `repos.auto.tfvars`, terraform apply
2. `./scripts/bulk-migrate.sh 2 config/repo-manifest.yaml`
3. Validate each repo
4. **Extra:** Run `terraform plan` in each AFT customization repo to verify module sources updated correctly
5. Commit manifest

---

## Task 17: Execute Wave 3 — AFT Core + Account Request

Follow the same pattern, with extra safeguards:

1. Schedule during a change window
2. Uncomment wave 3 repos in `repos.auto.tfvars`, terraform apply
3. `./scripts/bulk-migrate.sh 3 config/repo-manifest.yaml`
4. Validate each repo
5. **Extra:** Run `terraform plan` in AFT management account — confirm zero unexpected changes
6. Keep source repos accessible for 2 weeks
7. Commit manifest

---

## Task 18: Execute Wave 4 — Pipeline Repos

1. Uncomment wave 4 repos in `repos.auto.tfvars`, terraform apply
2. `./scripts/bulk-migrate.sh 4 config/repo-manifest.yaml`
3. Validate each repo
4. **Extra:** Update all external integrations (CodePipeline, webhooks, Slack)
5. Recreate org-level secrets via `gh secret set` for any not managed by Terraform
6. Commit manifest

---

## Task 19: Cleanup

**Step 1: Archive all source repos**

```bash
# For each migrated repo in source org
gh repo edit old-org/repo-name --visibility private
gh repo archive old-org/repo-name
```

**Step 2: Final compliance audit**

```bash
# Run validation on every repo in new org
gh repo list new-org --limit 200 --json name --jq '.[].name' | while read -r repo; do
  ./scripts/validate-migration.sh "new-org/${repo}"
done
```

**Step 3: Terraform drift check**

```bash
cd org-governance/github && terraform plan  # expect "No changes"
cd org-governance/aws && terraform plan     # expect "No changes"
```

**Step 4: Remove migration tooling**

```bash
gh repo archive new-org/migration-tooling
```

**Step 5: Revoke migration credentials**

Delete the PAT or GitHub App used for migration.

**Step 6: Final commit**

```bash
git commit -m "chore: migration complete - all waves done, cleanup finished"
```
