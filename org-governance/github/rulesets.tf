# org-governance/github/rulesets.tf

# ─── Main branch protection ────────────────────────────────────────────────────
# Applies to the default branch (main) on ALL repos.
# Rules: 2 approvals required, code-owner review, no deletion, no force-push.
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
      required_approving_review_count   = 2    # ≥2 approvals required for main
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = true
      required_review_thread_resolution = true
      require_code_owner_review         = true # CODEOWNERS alerts owners; PRs remain approvable by others
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

# ─── Lab branch protection ──────────────────────────────────────────────────────
# The 'lab' branch has the same access restriction as 'main':
# only assigned team members may merge into it (2 approvals required).
resource "github_organization_ruleset" "lab_branch" {
  name        = "lab-branch-protection"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["refs/heads/lab"]
      exclude = []
    }
    repository_name {
      include = ["~ALL"]
      exclude = []
    }
  }

  rules {
    pull_request {
      required_approving_review_count   = 2
      dismiss_stale_reviews_on_push     = true
      require_last_push_approval        = true
      required_review_thread_resolution = true
    }

    non_fast_forward = true
    deletion         = true
  }
}

# ─── Non-default branch PR protection ──────────────────────────────────────────
# Applies to every branch EXCEPT main and lab.
# Any team member with edit access may merge here — 1 approval sufficient.
resource "github_organization_ruleset" "non_default_pr" {
  name        = "non-default-branch-pr"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~ALL"]
      exclude = ["~DEFAULT_BRANCH", "refs/heads/lab"]
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
      require_last_push_approval        = false
      required_review_thread_resolution = false
    }

    non_fast_forward = true
  }
}

# ─── Branch naming convention ───────────────────────────────────────────────────
# Enforces naming pattern on all user-created branches.
# Exempt: main, dev, lab (these are permanent well-known branches).
# Required format: {prefix}/{jira-key}[-description]
#   prefix   : feature | release | hotfix | spike
#   jira-key : [a-z]+-[0-9]+  (e.g. ecpaws-1001)
#   Only lowercase letters, digits, hyphens — no consecutive hyphens.
resource "github_organization_ruleset" "branch_naming" {
  name        = "branch-naming"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~ALL"]
      exclude = [
        "refs/heads/main",
        "refs/heads/dev",
        "refs/heads/lab",
      ]
    }
    repository_name {
      include = ["~ALL"]
      exclude = ["migration-tooling"]
    }
  }

  rules {
    branch_name_pattern {
      name     = "jira-prefix-naming"
      operator = "regex"
      # One prefix / one Jira key / optional hyphen-separated lowercase segments.
      # Allows: feature/ecpaws-1001  or  feature/ecpaws-1001-create-sandbox-vpc
      pattern = "^(feature|release|hotfix|spike)/[a-z]+-[0-9]+(-[a-z0-9]+)*$"
    }
  }
}

# ─── Commit message convention ──────────────────────────────────────────────────
# All commits on all branches must start with the Jira issue key followed by ": ".
# Pattern: PROJ-1234: description  (e.g. ECPAWS-1001: add S3 bucket)
resource "github_organization_ruleset" "commit_message" {
  name        = "commit-message-jira"
  target      = "branch"
  enforcement = "active"

  conditions {
    ref_name {
      include = ["~ALL"]
      exclude = []
    }
    repository_name {
      include = ["~ALL"]
      exclude = ["migration-tooling"]
    }
  }

  rules {
    commit_message_pattern {
      name     = "jira-issue-key-prefix"
      operator = "regex"
      # Matches: one-or-more letters, hyphen, one-or-more digits, colon, space
      # e.g. ECPAWS-1001: or ecpaws-1001:
      pattern = "^[A-Za-z]+-[0-9]+: "
    }
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

    # commit_message_pattern is enforced org-wide by the "commit-message-jira" ruleset.

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
