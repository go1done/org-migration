#!/usr/bin/env bash
# migration-tooling/scripts/apply-non-tf-org-settings.sh
# Applies GitHub org settings that are NOT manageable via the Terraform GitHub
# provider v6 but ARE settable via the GitHub REST API.
#
# Run this AFTER `terraform apply` has applied the org-governance configuration.
# All settings here correspond to items documented in docs/not-terraform-enforceable.md.
#
# Usage:
#   export GITHUB_TOKEN="ghp_your_personal_access_token"
#   ./apply-non-tf-org-settings.sh <org-name> [--dry-run]
#
# Required token scopes: admin:org
# Requires: curl, python3
#
# Settings applied by this script:
#   • members_can_create_teams = false   (#13 — not in TF provider v6)
#   • members_can_delete_repositories = false  (#14 — not in TF provider)
#
# Settings that require GitHub UI (documented but not API-settable):
#   • Same-org-only fork restriction       (#16 — no REST API field)
#   • Members cannot change repo visibility (#15 — implied; see notes below)

set -euo pipefail

ORG="${1:?Usage: $0 <org-name> [--dry-run]}"
DRY_RUN="${2:-}"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN environment variable is not set."
  echo ""
  echo "Required scopes: admin:org"
  echo ""
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
# Helpers (same pattern as import-org-settings-curl.sh)
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
  local endpoint="$1"
  curl -sL -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" "${API}/${endpoint}"
}

gh_api_patch() {
  local endpoint="$1"
  local data="$2"
  curl -sL -X PATCH -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" \
    -H "Content-Type: application/json" -d "$data" "${API}/${endpoint}"
}

confirm() {
  local msg="$1"
  if [ "$DRY_RUN" = "--dry-run" ]; then
    echo "  [DRY RUN] Would: ${msg}"
    return 1
  fi
  echo ""
  read -r -p "  ${msg} [y/N] " response
  case "$response" in
    [yY][eE][sS]|[yY]) return 0 ;;
    *) return 1 ;;
  esac
}

# ---------------------------------------------------------------------------
# Banner
# ---------------------------------------------------------------------------
echo "=== Apply Non-Terraform Org Settings ==="
echo "    Org:  ${ORG}"
if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "    Mode: DRY RUN (no changes will be made)"
fi
echo ""
echo "  These settings complement 'terraform apply' for org-governance."
echo "  See docs/not-terraform-enforceable.md for context."
echo ""

# Verify access
echo "Verifying API access..."
ORG_DATA=$(gh_api_get "orgs/${ORG}")
ORG_LOGIN=$(echo "$ORG_DATA" | pyjq 'print(d.get("login","") if d else "")')
if [ -z "$ORG_LOGIN" ]; then
  echo "ERROR: Cannot access org '${ORG}'. Check your GITHUB_TOKEN (needs admin:org)."
  exit 1
fi
echo "  Authenticated. Org: ${ORG_LOGIN}"
echo ""

# Show current state of the settings this script manages
echo "Current values:"
echo "$ORG_DATA" | pyjq '
for k in ["members_can_create_teams", "members_can_delete_repositories",
          "members_can_fork_private_repositories"]:
    v = d.get(k, "not returned by API")
    print("  {}: {}".format(k, v))
'
echo ""

# ---------------------------------------------------------------------------
# Section 1: Team creation — admins only
# Not in Terraform provider v6 (members_can_create_teams).
# Policy: only org admins may create teams (#13).
# ---------------------------------------------------------------------------
echo "================================================================"
echo "[1/2] Team creation restriction"
echo "================================================================"
echo ""
echo "  Policy:  members_can_create_teams = false"
echo "  Reason:  Terraform provider v6 does not expose this field."
echo "  Source:  not-terraform-enforceable.md #13"
echo ""

CURRENT_TEAMS=$(echo "$ORG_DATA" | pyjq 'print(d.get("members_can_create_teams", None) if d else None)')
echo "  Current value: ${CURRENT_TEAMS}"

if [ "$CURRENT_TEAMS" = "False" ] || [ "$CURRENT_TEAMS" = "false" ]; then
  echo "  [SKIP] Already set correctly."
  SKIPPED=$((SKIPPED + 1))
elif confirm "Set members_can_create_teams=false in ${ORG}?"; then
  RESULT=$(gh_api_patch "orgs/${ORG}" '{"members_can_create_teams": false}')
  HAS_LOGIN=$(echo "$RESULT" | pyjq 'print("yes" if d and "login" in d else "no")')
  if [ "$HAS_LOGIN" = "yes" ]; then
    NEW_VAL=$(echo "$RESULT" | pyjq 'print(d.get("members_can_create_teams", "not returned"))')
    echo "  [OK] members_can_create_teams = ${NEW_VAL}"
    APPLIED=$((APPLIED + 1))
  else
    MSG=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
    echo "  [FAIL] ${MSG}"
    echo "  NOTE: This field may not be writable via REST API on all GHEC plans."
    echo "        If it fails, set it in GitHub UI: Settings > Member privileges > Team creation."
    FAILED=$((FAILED + 1))
  fi
else
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------------------
# Section 2: Repository deletion — admins only
# Not in Terraform provider (members_can_delete_repositories).
# Policy: only org admins may delete or transfer repos (#14).
# ---------------------------------------------------------------------------
echo ""
echo "================================================================"
echo "[2/2] Repository deletion restriction"
echo "================================================================"
echo ""
echo "  Policy:  members_can_delete_repositories = false"
echo "  Reason:  Terraform provider does not expose this field."
echo "  Source:  not-terraform-enforceable.md #14"
echo ""

CURRENT_DELETE=$(echo "$ORG_DATA" | pyjq 'print(d.get("members_can_delete_repositories", None) if d else None)')
echo "  Current value: ${CURRENT_DELETE}"

if [ "$CURRENT_DELETE" = "False" ] || [ "$CURRENT_DELETE" = "false" ]; then
  echo "  [SKIP] Already set correctly."
  SKIPPED=$((SKIPPED + 1))
elif confirm "Set members_can_delete_repositories=false in ${ORG}?"; then
  RESULT=$(gh_api_patch "orgs/${ORG}" '{"members_can_delete_repositories": false}')
  HAS_LOGIN=$(echo "$RESULT" | pyjq 'print("yes" if d and "login" in d else "no")')
  if [ "$HAS_LOGIN" = "yes" ]; then
    NEW_VAL=$(echo "$RESULT" | pyjq 'print(d.get("members_can_delete_repositories", "not returned"))')
    echo "  [OK] members_can_delete_repositories = ${NEW_VAL}"
    APPLIED=$((APPLIED + 1))
  else
    MSG=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
    echo "  [FAIL] ${MSG}"
    echo "  NOTE: If this fails, set it in GitHub UI:"
    echo "        Settings > Member privileges > Repository deletion and transfer"
    FAILED=$((FAILED + 1))
  fi
else
  SKIPPED=$((SKIPPED + 1))
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
if [ "$DRY_RUN" = "--dry-run" ]; then
  echo ""
  echo "  This was a DRY RUN. Remove --dry-run to apply changes."
fi
echo ""
echo "  Settings that still require GitHub UI (no REST API support):"
echo ""
echo "  #15 — Members cannot change repo visibility"
echo "        GitHub UI: Settings > Member privileges > Repository visibility change"
echo "        Note: already partially enforced via Terraform (members cannot create"
echo "              public/internal repos). The explicit 'change visibility' toggle"
echo "              is not exposed in the REST API for org settings."
echo ""
echo "  #16 — Forks restricted to same org only"
echo "        GitHub UI: Settings > Member privileges > Forking"
echo "                   Select 'Only within this organization'"
echo "        Note: Terraform only sets binary fork on/off. The same-org restriction"
echo "              requires the UI dropdown (GitHub Enterprise Cloud feature)."
echo ""
echo "  See docs/not-terraform-enforceable.md for the full list and alternatives."
