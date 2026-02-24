#!/usr/bin/env bash
# migration-tooling/scripts/apply-org-policy.sh
# Applies the complete GitHub org governance policy from the policy specification.
# Covers ALL settings from the policy images that are settable via REST API:
#   - Org member privilege settings (section 1)
#   - Security defaults for new repositories (section 2)
#   - All org-level branch rulesets (section 3)
#
# Run this AFTER or INSTEAD OF 'terraform apply' for org-governance settings.
# Settings that overlap with Terraform are still applied (idempotent).
# Settings the Terraform provider v6 cannot handle are marked with [NON-TF].
#
# Usage:
#   export GITHUB_TOKEN="ghp_your_personal_access_token"
#   ./apply-org-policy.sh <org-name> [--dry-run]
#
# Required token scopes: admin:org
# Requires: curl, python3
#
# Rules NOT applied by this script (no REST API support — see gap summary at end):
#   - Spike branches cannot merge to any branch (no source-branch restriction in rulesets API)
#   - Feature branches cannot merge directly to main (same reason)
#   - Squash/no-squash enforcement per source branch type (merge method is repo-wide only)
#   - Merges to main restricted to assigned team (bypass actors require team IDs)
#   - Auto-delete branches after 90/180 days (needs cron workflow)
#   - delete_branch_on_merge per-merge-target (repo-level binary only)
#   - Same-org-only fork restriction (GHEC UI only, no API field)
#   - Members cannot change repo visibility (no API field)
#   - CRLF rejection (needs .gitattributes per repo)
#   - Repository naming enforcement (needs GitHub Actions webhook on repo.created)
#   - README.md requirement (needs Actions check)
#   - dev/lab branch existence (handled in repos.tf for Terraform-managed repos)

set -euo pipefail

ORG="${1:?Usage: $0 <org-name> [--dry-run]}"
DRY_RUN="${2:-}"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN environment variable is not set."
  echo ""
  echo "Required scopes: admin:org"
  echo "Usage:"
  echo "  export GITHUB_TOKEN=\"ghp_your_token\""
  echo "  $0 ${ORG}"
  exit 1
fi

if ! command -v python3 &>/dev/null; then
  echo "ERROR: python3 is required but not found."
  exit 1
fi

API="https://api.github.com"
AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
ACCEPT="Accept: application/vnd.github+json"
API_VERSION="X-GitHub-Api-Version: 2022-11-28"

APPLIED=0
SKIPPED=0
FAILED=0

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------

pyjq() {
  python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
except:
    d = None
$1
"
}

gh_api_get() {
  curl -sL -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" "${API}/${1}"
}

gh_api_patch() {
  curl -sL -X PATCH -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" \
    -H "Content-Type: application/json" -d "$2" "${API}/${1}"
}

gh_api_put() {
  curl -sL -X PUT -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" \
    -H "Content-Type: application/json" -d "$2" "${API}/${1}"
}

gh_api_post() {
  curl -sL -X POST -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" \
    -H "Content-Type: application/json" -d "$2" "${API}/${1}"
}

confirm() {
  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "  [DRY RUN] Skipping: ${1}"
    return 1
  fi
  echo ""
  read -r -p "  ${1} [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# Create or update a named org-level ruleset.
# Usage: apply_ruleset <name> <json-payload>
apply_ruleset() {
  local name="$1"
  local payload="$2"

  # Fetch all rulesets once, find if this name exists
  local existing_id
  existing_id=$(gh_api_get "orgs/${ORG}/rulesets" 2>/dev/null | python3 -c "
import sys, json
name = '''$name'''
try:
    d = json.load(sys.stdin)
    match = next((r for r in (d if isinstance(d, list) else []) if r.get('name') == name), None)
    print(match['id'] if match else '')
except:
    print('')
")

  if [ "$DRY_RUN" = "--dry-run" ]; then
    if [ -n "$existing_id" ]; then
      echo "  [DRY RUN] Would update ruleset '${name}' (id: ${existing_id})"
    else
      echo "  [DRY RUN] Would create ruleset '${name}'"
    fi
    return 0
  fi

  local result action
  if [ -n "$existing_id" ]; then
    result=$(gh_api_put "orgs/${ORG}/rulesets/${existing_id}" "$payload")
    action="Updated"
  else
    result=$(gh_api_post "orgs/${ORG}/rulesets" "$payload")
    action="Created"
  fi

  local ok
  ok=$(echo "$result" | pyjq 'print("yes" if d and "id" in d else "no")')
  if [ "$ok" = "yes" ]; then
    echo "  [OK] ${action}: ${name}"
    APPLIED=$((APPLIED + 1))
  else
    local msg detail
    msg=$(echo "$result" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
    detail=$(echo "$result" | pyjq '
errs = d.get("errors", []) if d else []
if errs: print("; ".join(str(e) for e in errs[:3]))
else: print("")
')
    echo "  [FAIL] ${name}: ${msg}"
    [ -n "$detail" ] && echo "         ${detail}"
    FAILED=$((FAILED + 1))
  fi
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo "=== Apply Full Org Policy ==="
echo "    Org:  ${ORG}"
[ "$DRY_RUN" = "--dry-run" ] && echo "    Mode: DRY RUN (no changes will be made)"
echo ""

echo "Verifying API access..."
ORG_DATA=$(gh_api_get "orgs/${ORG}")
ORG_LOGIN=$(echo "$ORG_DATA" | pyjq 'print(d.get("login","") if d else "")')
if [ -z "$ORG_LOGIN" ]; then
  echo "ERROR: Cannot access org '${ORG}'. Check GITHUB_TOKEN (needs admin:org)."
  exit 1
fi
echo "  Authenticated. Org: ${ORG_LOGIN}"
echo ""

# ---------------------------------------------------------------------------
# Section 1: Member privileges
# Policy source: "Org settings" image
# Includes [NON-TF] fields the Terraform provider v6 doesn't expose.
# ---------------------------------------------------------------------------
echo "================================================================"
echo "[1/3] Member Privileges"
echo "================================================================"
echo ""
echo "  Settings to apply:"
echo "    default_repository_permission          = read"
echo "    members_can_create_repositories        = false   (admins only)"
echo "    members_can_create_public_repositories = false"
echo "    members_can_create_private_repositories= false"
echo "    members_can_create_internal_repositories=false   (private-only org)"
echo "    members_can_fork_private_repositories  = true    (same-org forks allowed)"
echo "    web_commit_signoff_required            = true"
echo "    members_can_create_teams               = false   [NON-TF] admins only"
echo "    members_can_delete_repositories        = false   [NON-TF] admins only"
echo ""

if confirm "Apply member privilege settings to ${ORG}?"; then
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'default_repository_permission':           'read',
    'members_can_create_repositories':         False,
    'members_can_create_public_repositories':  False,
    'members_can_create_private_repositories': False,
    'members_can_create_internal_repositories':False,
    'members_can_fork_private_repositories':   True,
    'web_commit_signoff_required':             True,
    'members_can_create_teams':                False,
    'members_can_delete_repositories':         False,
}))
")
  RESULT=$(gh_api_patch "orgs/${ORG}" "$PAYLOAD")
  HAS_LOGIN=$(echo "$RESULT" | pyjq 'print("yes" if d and "login" in d else "no")')
  if [ "$HAS_LOGIN" = "yes" ]; then
    echo "  [OK] Member privileges applied."
    # Check if non-TF fields were accepted
    GOT_TEAMS=$(echo "$RESULT" | pyjq 'print(d.get("members_can_create_teams","not returned"))')
    GOT_DELETE=$(echo "$RESULT" | pyjq 'print(d.get("members_can_delete_repositories","not returned"))')
    [ "$GOT_TEAMS" = "not returned" ] && echo "  [WARN] members_can_create_teams not returned — may need GitHub UI: Settings > Member privileges > Team creation"
    [ "$GOT_DELETE" = "not returned" ] && echo "  [WARN] members_can_delete_repositories not returned — may need GitHub UI: Settings > Member privileges > Repository deletion"
    APPLIED=$((APPLIED + 1))
  else
    MSG=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
    echo "  [FAIL] ${MSG}"
    FAILED=$((FAILED + 1))
  fi
else
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------------------
# Section 2: Security defaults for new repositories
# Policy source: "Org settings" image (implied — GHEC standard hardening)
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "[2/3] Security Defaults for New Repositories"
echo "================================================================"
echo ""
echo "  Settings to apply:"
echo "    advanced_security_enabled_for_new_repositories               = true"
echo "    dependabot_alerts_enabled_for_new_repositories               = true"
echo "    dependabot_security_updates_enabled_for_new_repositories     = true"
echo "    dependency_graph_enabled_for_new_repositories                = true"
echo "    secret_scanning_enabled_for_new_repositories                 = true"
echo "    secret_scanning_push_protection_enabled_for_new_repositories = true"
echo ""

if confirm "Apply security defaults to ${ORG}?"; then
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'advanced_security_enabled_for_new_repositories':               True,
    'dependabot_alerts_enabled_for_new_repositories':               True,
    'dependabot_security_updates_enabled_for_new_repositories':     True,
    'dependency_graph_enabled_for_new_repositories':                True,
    'secret_scanning_enabled_for_new_repositories':                 True,
    'secret_scanning_push_protection_enabled_for_new_repositories': True,
}))
")
  RESULT=$(gh_api_patch "orgs/${ORG}" "$PAYLOAD")
  HAS_LOGIN=$(echo "$RESULT" | pyjq 'print("yes" if d and "login" in d else "no")')
  if [ "$HAS_LOGIN" = "yes" ]; then
    echo "  [OK] Security defaults applied."
    APPLIED=$((APPLIED + 1))
  else
    MSG=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
    echo "  [FAIL] ${MSG}"
    FAILED=$((FAILED + 1))
  fi
else
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------------------
# Section 3: Org-level rulesets
# Policy source: "Github Rulesets" image
# All 7 rulesets mirror org-governance/github/rulesets.tf exactly.
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "[3/3] Org-Level Rulesets"
echo "================================================================"
echo ""
echo "  Rulesets to apply:"
echo "    1. baseline              — main branch: 2 approvals, status checks, no force-push"
echo "    2. lab-branch-protection — lab branch:  2 approvals, no force-push"
echo "    3. non-default-branch-pr — all other branches: 1 approval"
echo "    4. branch-naming         — all branches: Jira-prefixed slug pattern"
echo "    5. commit-message-jira   — all branches: Jira key prefix on every commit"
echo "    6. aft-strict            — aft-* repos: 2 approvals + 3 required checks"
echo "    7. pipeline-strict       — pipeline-* repos: 2 approvals + 2 required checks"
echo ""

if confirm "Apply all 7 org-level rulesets to ${ORG}?"; then

  # ── 1. baseline ────────────────────────────────────────────────────────────
  # Protects the default branch (main) on all repos except migration-tooling.
  # Rules from image:
  #   • ≥2 approvals before merge
  #   • Stale reviews dismissed on new push
  #   • Last-push approval required
  #   • All review threads must be resolved
  #   • CODEOWNERS review (alerts owners; does not restrict who can approve)
  #   • terraform-compliance status check required (strict — branch must be up-to-date)
  #   • No force-pushes (non_fast_forward)
  #   • Main branch cannot be deleted (deletion)
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'baseline',
    'target': 'branch',
    'enforcement': 'active',
    'conditions': {
        'ref_name': {
            'include': ['~DEFAULT_BRANCH'],
            'exclude': []
        },
        'repository_name': {
            'include': ['~ALL'],
            'exclude': ['migration-tooling'],
            'protected': False
        }
    },
    'rules': [
        {
            'type': 'pull_request',
            'parameters': {
                'required_approving_review_count':   2,
                'dismiss_stale_reviews_on_push':     True,
                'require_last_push_approval':        True,
                'required_review_thread_resolution': True,
                'require_code_owner_review':         True
            }
        },
        {
            'type': 'required_status_checks',
            'parameters': {
                'required_status_checks': [
                    {'context': 'terraform-compliance'}
                ],
                'strict_required_status_checks_policy': True
            }
        },
        {'type': 'non_fast_forward'},
        {'type': 'deletion'}
    ]
}))
")
  apply_ruleset "baseline" "$PAYLOAD"

  # ── 2. lab-branch-protection ───────────────────────────────────────────────
  # Lab branch has same strictness as main — only assigned team may merge.
  # Rules from image:
  #   • ≥2 approvals (same restriction as main)
  #   • Stale reviews dismissed, last-push approval required, thread resolution
  #   • No force-pushes, lab branch cannot be deleted
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'lab-branch-protection',
    'target': 'branch',
    'enforcement': 'active',
    'conditions': {
        'ref_name': {
            'include': ['refs/heads/lab'],
            'exclude': []
        },
        'repository_name': {
            'include': ['~ALL'],
            'exclude': [],
            'protected': False
        }
    },
    'rules': [
        {
            'type': 'pull_request',
            'parameters': {
                'required_approving_review_count':   2,
                'dismiss_stale_reviews_on_push':     True,
                'require_last_push_approval':        True,
                'required_review_thread_resolution': True,
                'require_code_owner_review':         False
            }
        },
        {'type': 'non_fast_forward'},
        {'type': 'deletion'}
    ]
}))
")
  apply_ruleset "lab-branch-protection" "$PAYLOAD"

  # ── 3. non-default-branch-pr ───────────────────────────────────────────────
  # All branches except main and lab.
  # Rules from image:
  #   • Any team member with edit access may merge — ≥1 approval sufficient
  #   • Stale reviews dismissed on push
  #   • No force-pushes (keeps linear history on feature/release branches too)
  # Note: spike branches are covered by branch-naming (only allowed prefixes are
  #       feature/release/hotfix/spike) but cannot be BLOCKED from merging here
  #       — that requires a GitHub Actions check (see gap summary).
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'non-default-branch-pr',
    'target': 'branch',
    'enforcement': 'active',
    'conditions': {
        'ref_name': {
            'include': ['~ALL'],
            'exclude': ['~DEFAULT_BRANCH', 'refs/heads/lab']
        },
        'repository_name': {
            'include': ['~ALL'],
            'exclude': ['migration-tooling'],
            'protected': False
        }
    },
    'rules': [
        {
            'type': 'pull_request',
            'parameters': {
                'required_approving_review_count':   1,
                'dismiss_stale_reviews_on_push':     True,
                'require_last_push_approval':        False,
                'required_review_thread_resolution': False,
                'require_code_owner_review':         False
            }
        },
        {'type': 'non_fast_forward'}
    ]
}))
")
  apply_ruleset "non-default-branch-pr" "$PAYLOAD"

  # ── 4. branch-naming ───────────────────────────────────────────────────────
  # Enforces naming on all user-created branches (main/dev/lab exempt).
  # Rules from image:
  #   • Lowercase only, hyphens as word separators, no consecutive hyphens
  #   • One of four prefixes: feature | release | hotfix | spike
  #   • "/" separates prefix from the Jira issue key slug
  #   • Must begin with a Jira issue key, e.g. ecpaws-1001
  #   • No underscores, no capital letters, no other special chars
  #   • Only one prefix and one "/" character
  # Pattern: feature/ecpaws-1001  or  feature/ecpaws-1001-create-sandbox-vpc
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'branch-naming',
    'target': 'branch',
    'enforcement': 'active',
    'conditions': {
        'ref_name': {
            'include': ['~ALL'],
            'exclude': [
                'refs/heads/main',
                'refs/heads/dev',
                'refs/heads/lab'
            ]
        },
        'repository_name': {
            'include': ['~ALL'],
            'exclude': ['migration-tooling'],
            'protected': False
        }
    },
    'rules': [
        {
            'type': 'branch_name_pattern',
            'parameters': {
                'name':     'jira-prefix-naming',
                'operator': 'regex',
                'pattern':  r'^(feature|release|hotfix|spike)/[a-z]+-[0-9]+(-[a-z0-9]+)*$',
                'negate':   False
            }
        }
    ]
}))
")
  apply_ruleset "branch-naming" "$PAYLOAD"

  # ── 5. commit-message-jira ─────────────────────────────────────────────────
  # Every commit on every branch must start with a Jira issue key.
  # Rules from image (github_action.jpeg + Team standards.jpeg):
  #   • Commit messages must begin with the Jira issue key followed by ": "
  #   • e.g. "ECPAWS-1001: add S3 bucket"
  # Note: The "-jmp" suffix and ≤100-char length from Team standards are style
  #       guidelines that cannot be enforced by regex ruleset patterns.
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'commit-message-jira',
    'target': 'branch',
    'enforcement': 'active',
    'conditions': {
        'ref_name': {
            'include': ['~ALL'],
            'exclude': []
        },
        'repository_name': {
            'include': ['~ALL'],
            'exclude': ['migration-tooling'],
            'protected': False
        }
    },
    'rules': [
        {
            'type': 'commit_message_pattern',
            'parameters': {
                'name':     'jira-issue-key-prefix',
                'operator': 'regex',
                'pattern':  r'^[A-Za-z]+-[0-9]+: ',
                'negate':   False
            }
        }
    ]
}))
")
  apply_ruleset "commit-message-jira" "$PAYLOAD"

  # ── 6. aft-strict ──────────────────────────────────────────────────────────
  # Stricter rules on AFT (Account Factory for Terraform) repositories.
  # aft-* repos must pass three CI checks and require code-owner sign-off.
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'aft-strict',
    'target': 'branch',
    'enforcement': 'active',
    'conditions': {
        'ref_name': {
            'include': ['~DEFAULT_BRANCH'],
            'exclude': []
        },
        'repository_name': {
            'include': ['aft-*'],
            'exclude': [],
            'protected': False
        }
    },
    'rules': [
        {
            'type': 'pull_request',
            'parameters': {
                'required_approving_review_count':   2,
                'dismiss_stale_reviews_on_push':     True,
                'require_last_push_approval':        True,
                'required_review_thread_resolution': True,
                'require_code_owner_review':         True
            }
        },
        {
            'type': 'required_status_checks',
            'parameters': {
                'required_status_checks': [
                    {'context': 'terraform-compliance'},
                    {'context': 'terraform-validate'},
                    {'context': 'opa-policy-check'}
                ],
                'strict_required_status_checks_policy': True
            }
        },
        {'type': 'non_fast_forward'},
        {'type': 'deletion'}
    ]
}))
")
  apply_ruleset "aft-strict" "$PAYLOAD"

  # ── 7. pipeline-strict ─────────────────────────────────────────────────────
  # Stricter rules on pipeline repositories.
  # pipeline-* repos must pass terraform-compliance and repo-compliance-check.
  PAYLOAD=$(python3 -c "
import json
print(json.dumps({
    'name': 'pipeline-strict',
    'target': 'branch',
    'enforcement': 'active',
    'conditions': {
        'ref_name': {
            'include': ['~DEFAULT_BRANCH'],
            'exclude': []
        },
        'repository_name': {
            'include': ['pipeline-*'],
            'exclude': [],
            'protected': False
        }
    },
    'rules': [
        {
            'type': 'pull_request',
            'parameters': {
                'required_approving_review_count':   2,
                'dismiss_stale_reviews_on_push':     True,
                'require_last_push_approval':        True,
                'required_review_thread_resolution': True,
                'require_code_owner_review':         True
            }
        },
        {
            'type': 'required_status_checks',
            'parameters': {
                'required_status_checks': [
                    {'context': 'terraform-compliance'},
                    {'context': 'repo-compliance-check'}
                ],
                'strict_required_status_checks_policy': True
            }
        },
        {'type': 'non_fast_forward'},
        {'type': 'deletion'}
    ]
}))
")
  apply_ruleset "pipeline-strict" "$PAYLOAD"

else
  SKIPPED=$((SKIPPED + 7))
fi

# ---------------------------------------------------------------------------
# Summary
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "=== Complete ==="
echo "================================================================"
echo ""
echo "  Applied: ${APPLIED}"
echo "  Skipped: ${SKIPPED}"
echo "  Failed:  ${FAILED}"
[ "$DRY_RUN" = "--dry-run" ] && echo "" && echo "  This was a DRY RUN. Remove --dry-run to apply changes."
echo ""
echo "================================================================"
echo "  Rules from policy images NOT covered here (require alternatives)"
echo "================================================================"
echo ""
echo "  From 'Github Rulesets' image:"
echo ""
echo "  [GA] spike/* branches cannot merge anywhere"
echo "       → GitHub Actions: check source branch on pull_request event"
echo "         Workflow: org-shared-workflows/spike-merge-block.yml"
echo ""
echo "  [GA] feature/* branches cannot merge directly to main"
echo "       → GitHub Actions: check source branch when PR targets main"
echo ""
echo "  [GA] release→main PRs must use squash; feature PRs must NOT squash"
echo "       → GitHub Actions: validate merge method before merge is allowed"
echo ""
echo "  [UI] Merges to main restricted to assigned merging team only"
echo "       → Add bypass actors to 'baseline' ruleset once team IDs are known:"
echo "         GitHub UI: Rulesets > baseline > Bypass list > add team"
echo ""
echo "  From 'Org settings' image:"
echo ""
echo "  [UI] Forks restricted to same org only"
echo "       → GitHub UI: Settings > Member privileges > Forking"
echo "                    Select 'Only within this organization'"
echo ""
echo "  [UI] Members cannot change repo visibility"
echo "       → GitHub UI: Settings > Member privileges > Repository visibility change"
echo ""
echo "  [GA] feature/* branches auto-deleted after merge to non-main branch"
echo "       → GitHub Actions: delete source branch on pull_request closed+merged"
echo "         (Cannot be set per merge-target — delete_branch_on_merge is binary per repo)"
echo ""
echo "  [GA] Stale branches auto-deleted after 90/180 days"
echo "       → Scheduled GitHub Actions workflow (cron) on stale-branch cleanup"
echo ""
echo "  From 'github_action' image:"
echo ""
echo "  [GA] Repository naming convention (lowercase, hyphens, a-z0-9 only)"
echo "       → GitHub Actions: webhook on repository.created event"
echo ""
echo "  [GA] Every repo must have a README.md"
echo "       → Extend org-shared-workflows/repo-compliance-check.yml"
echo ""
echo "  [GA] Every repo must have dev and lab branches"
echo "       → For Terraform-managed repos: add github_branch resources in repos.tf"
echo "       → For portal-created repos: add to repo-setup automation"
echo ""
echo "  [REPO] Unix line endings only (CRLF rejected)"
echo "       → Add .gitattributes to every repo template:"
echo "         * text=auto eol=lf"
echo ""
echo "  From 'Team standards' image:"
echo ""
echo "  [STYLE] Commit messages: imperative mood, ≤100 chars, end with ' -jmp'"
echo "          → commitlint client-side hook (commit-msg) — cannot enforce via org rulesets"
echo ""
echo "  See docs/not-terraform-enforceable.md for full list and implementation notes."
echo ""
echo "  Legend: [GA]=GitHub Actions  [UI]=GitHub UI  [REPO]=per-repo config  [STYLE]=convention"
