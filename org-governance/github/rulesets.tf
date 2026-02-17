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
