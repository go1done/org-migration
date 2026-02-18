#!/usr/bin/env bash
# migration-tooling/scripts/import-org-settings-curl.sh
# Imports org settings from a dump directory into a target GitHub org.
# Reverse of dump-org-settings-curl.sh — reads the dump and applies via API.
# Uses curl + GitHub REST API — no gh CLI or jq required (uses python3 for JSON).
#
# Usage:
#   export GITHUB_TOKEN="ghp_your_personal_access_token"
#   ./import-org-settings-curl.sh <target-org> <dump-dir> [--dry-run]
#
# Required token scopes: admin:org, repo, read:org
# Requires: curl, python3
#
# SAFETY:
#   - Runs in --dry-run mode by default if flag is passed (shows what would change)
#   - Prompts for confirmation before each category
#   - Skips secrets (values are never in the dump)
#   - Does NOT delete existing resources — only creates/updates

set -euo pipefail

TARGET_ORG="${1:?Usage: $0 <target-org> <dump-dir> [--dry-run]}"
DUMP_DIR="${2:?Usage: $0 <target-org> <dump-dir> [--dry-run]}"
DRY_RUN="${3:-}"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN environment variable is not set."
  echo ""
  echo "Create a Personal Access Token at: https://github.com/settings/tokens"
  echo "Required scopes: admin:org, repo, read:org"
  exit 1
fi

if [ ! -d "$DUMP_DIR" ]; then
  echo "ERROR: Dump directory not found: ${DUMP_DIR}"
  exit 1
fi

if ! command -v python3 &> /dev/null; then
  echo "ERROR: python3 is required but not found."
  exit 1
fi

API="https://api.github.com"
AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
ACCEPT="Accept: application/vnd.github+json"
API_VERSION="X-GitHub-Api-Version: 2022-11-28"

IMPORTED=0
SKIPPED=0
FAILED=0

# Helper: python3 replacement for jq
# Usage: echo "$json" | pyjq 'python statements using d'
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

# Helper: read JSON file and extract value
# Usage: pyread <file> 'python expression using d'
pyread() {
  python3 -c "
import json
try:
    d = json.load(open('$1'))
except:
    d = None
$2
"
}

# Helper: format JSON (pretty-print)
json_pp() {
  python3 -c "import sys,json; json.dump(json.load(sys.stdin),sys.stdout,indent=2); print()"
}

# Helper: make an authenticated API call
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

gh_api_put() {
  local endpoint="$1"
  local data="$2"
  curl -sL -X PUT -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" \
    -H "Content-Type: application/json" -d "$data" "${API}/${endpoint}"
}

gh_api_post() {
  local endpoint="$1"
  local data="$2"
  curl -sL -X POST -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" \
    -H "Content-Type: application/json" -d "$data" "${API}/${endpoint}"
}

# Helper: prompt for confirmation
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

# Verify target org
echo "=== Import Org Settings ==="
echo "    Source dump: ${DUMP_DIR}"
echo "    Target org:  ${TARGET_ORG}"
if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "    Mode:        DRY RUN (no changes will be made)"
fi
echo ""

echo "Verifying API access to target org..."
TARGET_CHECK=$(gh_api_get "orgs/${TARGET_ORG}" | pyjq 'print(d.get("login","") if d else "")')
if [ -z "$TARGET_CHECK" ]; then
  echo "ERROR: Cannot access org '${TARGET_ORG}'. Check your GITHUB_TOKEN and org name."
  exit 1
fi
echo "  Authenticated. Target org: ${TARGET_CHECK}"
echo ""

# ---------------------------------------------------------------
# 1. Organization settings
# ---------------------------------------------------------------
echo "================================================================"
echo "[1/7] Organization Settings"
echo "================================================================"

if [ -f "${DUMP_DIR}/org/settings.json" ]; then
  echo "  Source settings:"
  pyread "${DUMP_DIR}/org/settings.json" '
if d:
    for k in ["default_repository_permission","members_can_create_repositories",
              "members_can_create_public_repositories","members_can_create_private_repositories",
              "members_can_fork_private_repositories","web_commit_signoff_required"]:
        print("    {}: {}".format(k, d.get(k, "N/A")))
'

  if confirm "Apply organization settings to ${TARGET_ORG}?"; then
    PAYLOAD=$(pyread "${DUMP_DIR}/org/settings.json" '
import json
keys = ["default_repository_permission","members_can_create_repositories",
        "members_can_create_public_repositories","members_can_create_private_repositories",
        "members_can_create_internal_repositories","members_can_fork_private_repositories",
        "web_commit_signoff_required","has_organization_projects","has_repository_projects"]
out = {k: d[k] for k in keys if k in d and d[k] is not None}
print(json.dumps(out))
')

    RESULT=$(gh_api_patch "orgs/${TARGET_ORG}" "$PAYLOAD")
    HAS_LOGIN=$(echo "$RESULT" | pyjq 'print("yes" if d and "login" in d else "no")')
    if [ "$HAS_LOGIN" = "yes" ]; then
      echo "  [OK] Organization settings applied."
      IMPORTED=$((IMPORTED + 1))
    else
      ERR=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
      echo "  [FAIL] ${ERR}"
      FAILED=$((FAILED + 1))
    fi
  else
    SKIPPED=$((SKIPPED + 1))
  fi
else
  echo "  No settings.json found in dump. Skipping."
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------
# 2. Security defaults for new repos
# ---------------------------------------------------------------
echo ""
echo "================================================================"
echo "[2/7] Security Defaults (for new repos)"
echo "================================================================"

if [ -f "${DUMP_DIR}/org/security-defaults.json" ]; then
  echo "  Source security defaults:"
  pyread "${DUMP_DIR}/org/security-defaults.json" '
if d:
    for k, v in d.items():
        print("    {}: {}".format(k, v if v is not None else "N/A"))
'

  if confirm "Apply security defaults to ${TARGET_ORG}?"; then
    PAYLOAD=$(pyread "${DUMP_DIR}/org/security-defaults.json" '
import json
keys = ["advanced_security_enabled_for_new_repositories",
        "dependabot_alerts_enabled_for_new_repositories",
        "dependabot_security_updates_enabled_for_new_repositories",
        "dependency_graph_enabled_for_new_repositories",
        "secret_scanning_enabled_for_new_repositories",
        "secret_scanning_push_protection_enabled_for_new_repositories"]
out = {k: d[k] for k in keys if k in d and d[k] is not None}
print(json.dumps(out))
')

    RESULT=$(gh_api_patch "orgs/${TARGET_ORG}" "$PAYLOAD")
    HAS_LOGIN=$(echo "$RESULT" | pyjq 'print("yes" if d and "login" in d else "no")')
    if [ "$HAS_LOGIN" = "yes" ]; then
      echo "  [OK] Security defaults applied."
      IMPORTED=$((IMPORTED + 1))
    else
      ERR=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
      echo "  [FAIL] ${ERR}"
      FAILED=$((FAILED + 1))
    fi
  else
    SKIPPED=$((SKIPPED + 1))
  fi
else
  echo "  No security-defaults.json found. Skipping."
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------
# 3. Teams
# ---------------------------------------------------------------
echo ""
echo "================================================================"
echo "[3/7] Teams"
echo "================================================================"

if [ -f "${DUMP_DIR}/teams/teams.json" ]; then
  TEAM_COUNT=$(pyread "${DUMP_DIR}/teams/teams.json" 'print(len(d) if d else 0)')
  echo "  Found ${TEAM_COUNT} teams in dump."
  pyread "${DUMP_DIR}/teams/teams.json" '
if d:
    for t in d:
        desc = t.get("description") or "no description"
        print("    - {} ({}): {}".format(t.get("name",""), t.get("privacy",""), desc))
'

  if confirm "Create/update ${TEAM_COUNT} teams in ${TARGET_ORG}?"; then
    pyread "${DUMP_DIR}/teams/teams.json" '
import json
if d:
    for t in d:
        print(json.dumps(t))
' | while read -r team_json; do
      [ -z "$team_json" ] && continue
      TEAM_NAME=$(echo "$team_json" | pyjq 'print(d.get("name",""))')
      TEAM_SLUG=$(echo "$team_json" | pyjq 'print(d.get("slug",""))')
      TEAM_DESC=$(echo "$team_json" | pyjq 'print(d.get("description","") or "")')
      TEAM_PRIVACY=$(echo "$team_json" | pyjq 'print(d.get("privacy","closed"))')

      # Check if team already exists
      EXISTING=$(gh_api_get "orgs/${TARGET_ORG}/teams/${TEAM_SLUG}" 2>/dev/null)
      HAS_ID=$(echo "$EXISTING" | pyjq 'print("yes" if d and "id" in d else "no")')

      PAYLOAD=$(python3 -c "
import json, sys
print(json.dumps({'name': '$TEAM_NAME', 'description': '$TEAM_DESC', 'privacy': '$TEAM_PRIVACY'}))
")

      if [ "$HAS_ID" = "yes" ]; then
        # Update existing team
        RESULT=$(gh_api_patch "orgs/${TARGET_ORG}/teams/${TEAM_SLUG}" "$PAYLOAD")
        R_ID=$(echo "$RESULT" | pyjq 'print("yes" if d and "id" in d else "no")')
        if [ "$R_ID" = "yes" ]; then
          echo "  [OK] Updated team: ${TEAM_NAME}"
        else
          ERR=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
          echo "  [FAIL] Update team ${TEAM_NAME}: ${ERR}"
          FAILED=$((FAILED + 1))
          continue
        fi
      else
        # Create new team
        RESULT=$(gh_api_post "orgs/${TARGET_ORG}/teams" "$PAYLOAD")
        R_ID=$(echo "$RESULT" | pyjq 'print("yes" if d and "id" in d else "no")')
        if [ "$R_ID" = "yes" ]; then
          echo "  [OK] Created team: ${TEAM_NAME}"
        else
          ERR=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
          echo "  [FAIL] Create team ${TEAM_NAME}: ${ERR}"
          FAILED=$((FAILED + 1))
          continue
        fi
      fi

      # Add members
      MEMBERS_FILE="${DUMP_DIR}/teams/team-${TEAM_SLUG}-members.json"
      if [ -f "$MEMBERS_FILE" ]; then
        pyread "$MEMBERS_FILE" '
if d:
    for m in d:
        print(m.get("login",""))
' | while read -r login; do
          [ -z "$login" ] && continue
          RESULT=$(gh_api_put "orgs/${TARGET_ORG}/teams/${TEAM_SLUG}/memberships/${login}" '{"role":"member"}')
          HAS_STATE=$(echo "$RESULT" | pyjq 'print("yes" if d and "state" in d else "no")')
          if [ "$HAS_STATE" = "yes" ]; then
            echo "    [OK] Added member: ${login}"
          else
            ERR=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
            echo "    [WARN] Could not add ${login}: ${ERR}"
          fi
        done
      fi

      IMPORTED=$((IMPORTED + 1))
    done
  else
    SKIPPED=$((SKIPPED + 1))
  fi
else
  echo "  No teams.json found. Skipping."
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------
# 4. Organization rulesets
# ---------------------------------------------------------------
echo ""
echo "================================================================"
echo "[4/7] Organization Rulesets"
echo "================================================================"

if [ -f "${DUMP_DIR}/rulesets/org-rulesets-summary.json" ]; then
  RULESET_COUNT=$(pyread "${DUMP_DIR}/rulesets/org-rulesets-summary.json" 'print(len(d) if isinstance(d, list) else 0)')
  echo "  Found ${RULESET_COUNT} rulesets in dump."

  if [ "$RULESET_COUNT" -gt 0 ]; then
    pyread "${DUMP_DIR}/rulesets/org-rulesets-summary.json" '
if d and isinstance(d, list):
    for r in d:
        print("    - {} (enforcement: {}, target: {})".format(r.get("name",""), r.get("enforcement",""), r.get("target","")))
'

    if confirm "Create ${RULESET_COUNT} rulesets in ${TARGET_ORG}?"; then
      for ruleset_file in "${DUMP_DIR}"/rulesets/ruleset-*.json; do
        [ -f "$ruleset_file" ] || continue

        RULESET_NAME=$(pyread "$ruleset_file" 'print(d.get("name","unknown") if d else "unknown")')

        # Check if ruleset already exists by name
        EXISTING_RULESETS=$(gh_api_get "orgs/${TARGET_ORG}/rulesets" 2>/dev/null || echo "[]")
        EXISTING_ID=$(echo "$EXISTING_RULESETS" | python3 -c "
import sys, json
try:
    d = json.load(sys.stdin)
    for r in (d if isinstance(d, list) else []):
        if r.get('name') == '$RULESET_NAME':
            print(r.get('id',''))
            break
    else:
        print('')
except:
    print('')
")

        # Build payload — strip read-only fields
        PAYLOAD=$(pyread "$ruleset_file" '
import json
if d:
    for k in ["id","node_id","_links","source","created_at","updated_at","current_user_can_bypass"]:
        d.pop(k, None)
    print(json.dumps(d))
else:
    print("{}")
')

        if [ -n "$EXISTING_ID" ]; then
          RESULT=$(gh_api_put "orgs/${TARGET_ORG}/rulesets/${EXISTING_ID}" "$PAYLOAD")
          R_ID=$(echo "$RESULT" | pyjq 'print("yes" if d and "id" in d else "no")')
          if [ "$R_ID" = "yes" ]; then
            echo "  [OK] Updated ruleset: ${RULESET_NAME}"
            IMPORTED=$((IMPORTED + 1))
          else
            ERR=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
            echo "  [FAIL] Update ruleset ${RULESET_NAME}: ${ERR}"
            FAILED=$((FAILED + 1))
          fi
        else
          RESULT=$(gh_api_post "orgs/${TARGET_ORG}/rulesets" "$PAYLOAD")
          R_ID=$(echo "$RESULT" | pyjq 'print("yes" if d and "id" in d else "no")')
          if [ "$R_ID" = "yes" ]; then
            echo "  [OK] Created ruleset: ${RULESET_NAME}"
            IMPORTED=$((IMPORTED + 1))
          else
            ERR=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
            echo "  [FAIL] Create ruleset ${RULESET_NAME}: ${ERR}"
            FAILED=$((FAILED + 1))
          fi
        fi
      done
    else
      SKIPPED=$((SKIPPED + 1))
    fi
  else
    echo "  No rulesets to import."
  fi
else
  echo "  No rulesets dump found. Skipping."
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------
# 5. Repository settings (security + branch protection)
# ---------------------------------------------------------------
echo ""
echo "================================================================"
echo "[5/7] Repository Settings"
echo "================================================================"

if [ -f "${DUMP_DIR}/repos/repo-list.json" ]; then
  REPO_COUNT=$(pyread "${DUMP_DIR}/repos/repo-list.json" 'print(len(d) if d else 0)')
  echo "  Found ${REPO_COUNT} repos in dump."
  echo ""
  echo "  NOTE: This applies security settings and branch protection to repos"
  echo "  that ALREADY EXIST in ${TARGET_ORG}. It does NOT create repos."

  if confirm "Apply repo settings to existing repos in ${TARGET_ORG}?"; then
    pyread "${DUMP_DIR}/repos/repo-list.json" '
if d:
    for r in d:
        print(r.get("name",""))
' | while read -r repo; do
      [ -z "$repo" ] && continue
      REPO_DIR="${DUMP_DIR}/repos/${repo}"
      [ -d "$REPO_DIR" ] || continue

      # Check if repo exists in target org
      EXISTING=$(gh_api_get "repos/${TARGET_ORG}/${repo}" 2>/dev/null)
      HAS_ID=$(echo "$EXISTING" | pyjq 'print("yes" if d and "id" in d else "no")')
      if [ "$HAS_ID" != "yes" ]; then
        echo "  [SKIP] ${repo} — does not exist in ${TARGET_ORG}"
        continue
      fi

      CHANGES_MADE=false

      # Apply repo settings (security, merge options)
      if [ -f "${REPO_DIR}/settings.json" ]; then
        PAYLOAD=$(pyread "${REPO_DIR}/settings.json" '
import json
if d:
    keys = ["has_issues","has_wiki","has_projects","delete_branch_on_merge",
            "allow_squash_merge","allow_merge_commit","allow_rebase_merge","allow_auto_merge"]
    out = {k: d[k] for k in keys if k in d and d[k] is not None}
    print(json.dumps(out))
else:
    print("{}")
')

        RESULT=$(gh_api_patch "repos/${TARGET_ORG}/${repo}" "$PAYLOAD")
        R_ID=$(echo "$RESULT" | pyjq 'print("yes" if d and "id" in d else "no")')
        if [ "$R_ID" = "yes" ]; then
          CHANGES_MADE=true
        fi

        # Apply topics
        TOPICS=$(pyread "${REPO_DIR}/settings.json" '
import json
topics = d.get("topics", []) if d else []
if topics:
    print(json.dumps(topics))
else:
    print("")
')
        if [ -n "$TOPICS" ]; then
          gh_api_put "repos/${TARGET_ORG}/${repo}/topics" "{\"names\": ${TOPICS}}" > /dev/null 2>&1 || true
        fi

        # Enable security features
        SECURITY_PAYLOAD=$(pyread "${REPO_DIR}/settings.json" '
import json
if d:
    sa = d.get("security_and_analysis") or {}
    ss = (sa.get("secret_scanning") or {}).get("status", "disabled")
    pp = (sa.get("secret_scanning_push_protection") or {}).get("status", "disabled")
    print(json.dumps({"security_and_analysis": {"secret_scanning": {"status": ss}, "secret_scanning_push_protection": {"status": pp}}}))
else:
    print("{}")
')
        gh_api_patch "repos/${TARGET_ORG}/${repo}" "$SECURITY_PAYLOAD" > /dev/null 2>&1 || true
      fi

      # Apply branch protection
      if [ -f "${REPO_DIR}/branch-protection.json" ]; then
        BP_HAS_PROTECTION=$(pyread "${REPO_DIR}/branch-protection.json" '
if d:
    print("no" if d.get("status") == "not configured" else "yes")
else:
    print("no")
')
        if [ "$BP_HAS_PROTECTION" = "yes" ]; then
          DEFAULT_BRANCH=$(pyread "${REPO_DIR}/settings.json" 'print(d.get("default_branch","main") if d else "main")')

          # Build branch protection payload from dump
          BP_PAYLOAD=$(pyread "${REPO_DIR}/branch-protection.json" '
import json
if d:
    out = {}
    rsc = d.get("required_status_checks")
    if rsc:
        out["required_status_checks"] = {"strict": rsc.get("strict", False), "contexts": rsc.get("contexts", [])}
    ea = d.get("enforce_admins")
    if isinstance(ea, dict):
        out["enforce_admins"] = ea.get("enabled", False)
    elif isinstance(ea, bool):
        out["enforce_admins"] = ea
    rpr = d.get("required_pull_request_reviews")
    if rpr:
        pr_out = {}
        for k in ["dismiss_stale_reviews","require_code_owner_reviews","required_approving_review_count","require_last_push_approval"]:
            if k in rpr and rpr[k] is not None:
                pr_out[k] = rpr[k]
        if pr_out:
            out["required_pull_request_reviews"] = pr_out
    out["restrictions"] = None
    for k in ["required_linear_history","allow_force_pushes","allow_deletions","required_conversation_resolution"]:
        v = d.get(k)
        if isinstance(v, dict):
            out[k] = v.get("enabled", False)
        elif isinstance(v, bool):
            out[k] = v
    print(json.dumps(out))
else:
    print("{}")
')

          if [ "$BP_PAYLOAD" != "{}" ]; then
            RESULT=$(gh_api_put "repos/${TARGET_ORG}/${repo}/branches/${DEFAULT_BRANCH}/protection" "$BP_PAYLOAD")
            HAS_URL=$(echo "$RESULT" | pyjq 'print("yes" if d and "url" in d else "no")')
            if [ "$HAS_URL" = "yes" ]; then
              CHANGES_MADE=true
            fi
          fi
        fi
      fi

      if [ "$CHANGES_MADE" = true ]; then
        echo "  [OK] ${repo}"
        IMPORTED=$((IMPORTED + 1))
      else
        echo "  [--] ${repo} (no changes needed)"
      fi
    done
  else
    SKIPPED=$((SKIPPED + 1))
  fi
else
  echo "  No repo-list.json found. Skipping."
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------
# 6. Team-repo access
# ---------------------------------------------------------------
echo ""
echo "================================================================"
echo "[6/7] Team Repository Access"
echo "================================================================"

if [ -f "${DUMP_DIR}/teams/teams.json" ]; then
  TEAM_COUNT=$(pyread "${DUMP_DIR}/teams/teams.json" 'print(len(d) if d else 0)')
  echo "  Found ${TEAM_COUNT} teams with repo access mappings."

  if confirm "Apply team-repo access permissions in ${TARGET_ORG}?"; then
    pyread "${DUMP_DIR}/teams/teams.json" '
if d:
    for t in d:
        print(t.get("slug",""))
' | while read -r slug; do
      [ -z "$slug" ] && continue
      REPOS_FILE="${DUMP_DIR}/teams/team-${slug}-repos.json"
      [ -f "$REPOS_FILE" ] || continue

      REPO_ACCESS_COUNT=$(pyread "$REPOS_FILE" 'print(len(d) if d else 0)')
      [ "$REPO_ACCESS_COUNT" -eq 0 ] && continue

      echo "  Team: ${slug} (${REPO_ACCESS_COUNT} repos)"
      pyread "$REPOS_FILE" '
import json
if d:
    for entry in d:
        print(json.dumps(entry))
' | while read -r entry_json; do
        [ -z "$entry_json" ] && continue
        REPO_NAME=$(echo "$entry_json" | pyjq 'print(d.get("name",""))')
        PERMISSION=$(echo "$entry_json" | pyjq '
perms = d.get("permissions", {}) if d else {}
if perms.get("admin"): print("admin")
elif perms.get("maintain"): print("maintain")
elif perms.get("push"): print("push")
elif perms.get("triage"): print("triage")
else: print("pull")
')

        # Check if repo exists in target
        EXISTING=$(gh_api_get "repos/${TARGET_ORG}/${REPO_NAME}" 2>/dev/null)
        HAS_ID=$(echo "$EXISTING" | pyjq 'print("yes" if d and "id" in d else "no")')
        if [ "$HAS_ID" != "yes" ]; then
          echo "    [SKIP] ${REPO_NAME} — repo not in ${TARGET_ORG}"
          continue
        fi

        gh_api_put "orgs/${TARGET_ORG}/teams/${slug}/repos/${TARGET_ORG}/${REPO_NAME}" \
          "{\"permission\": \"${PERMISSION}\"}" > /dev/null 2>&1
        echo "    [OK] ${REPO_NAME} -> ${PERMISSION}"
      done
      IMPORTED=$((IMPORTED + 1))
    done
  else
    SKIPPED=$((SKIPPED + 1))
  fi
else
  echo "  No teams dump found. Skipping."
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------
# 7. Org-level Actions variables (not secrets — values are in dump)
# ---------------------------------------------------------------
echo ""
echo "================================================================"
echo "[7/7] Organization Actions Variables"
echo "================================================================"

if [ -f "${DUMP_DIR}/org/actions-variables.json" ]; then
  VAR_COUNT=$(pyread "${DUMP_DIR}/org/actions-variables.json" 'print(d.get("total_count", 0) if d else 0)')
  echo "  Found ${VAR_COUNT} org-level variables in dump."

  if [ "$VAR_COUNT" -gt 0 ]; then
    pyread "${DUMP_DIR}/org/actions-variables.json" '
if d:
    for v in d.get("variables", []):
        print("    - {} = {} (visibility: {})".format(v.get("name",""), v.get("value",""), v.get("visibility","")))
'

    if confirm "Create/update ${VAR_COUNT} org variables in ${TARGET_ORG}?"; then
      pyread "${DUMP_DIR}/org/actions-variables.json" '
import json
if d:
    for v in d.get("variables", []):
        print(json.dumps(v))
' | while read -r var_json; do
        [ -z "$var_json" ] && continue
        VAR_NAME=$(echo "$var_json" | pyjq 'print(d.get("name",""))')
        VAR_VALUE=$(echo "$var_json" | pyjq 'print(d.get("value",""))')
        VAR_VIS=$(echo "$var_json" | pyjq 'print(d.get("visibility","private"))')

        PAYLOAD=$(python3 -c "
import json
print(json.dumps({'name': '$VAR_NAME', 'value': '$VAR_VALUE', 'visibility': '$VAR_VIS'}))
")

        # Try update first, then create
        RESULT=$(gh_api_patch "orgs/${TARGET_ORG}/actions/variables/${VAR_NAME}" "$PAYLOAD" 2>/dev/null)
        HAS_MSG=$(echo "$RESULT" | pyjq 'print("yes" if d and "message" in d else "no")')
        if [ "$HAS_MSG" = "yes" ]; then
          # Doesn't exist, create it
          RESULT=$(gh_api_post "orgs/${TARGET_ORG}/actions/variables" "$PAYLOAD")
          HAS_MSG2=$(echo "$RESULT" | pyjq 'print("yes" if d and "message" in d else "no")')
          if [ "$HAS_MSG2" = "yes" ]; then
            ERR=$(echo "$RESULT" | pyjq 'print(d.get("message","Unknown error") if d else "Unknown error")')
            echo "  [FAIL] ${VAR_NAME}: ${ERR}"
            FAILED=$((FAILED + 1))
          else
            echo "  [OK] Created variable: ${VAR_NAME}"
            IMPORTED=$((IMPORTED + 1))
          fi
        else
          echo "  [OK] Updated variable: ${VAR_NAME}"
          IMPORTED=$((IMPORTED + 1))
        fi
      done
    else
      SKIPPED=$((SKIPPED + 1))
    fi
  fi

  # Secrets reminder
  if [ -f "${DUMP_DIR}/org/actions-secrets.json" ]; then
    SECRET_COUNT=$(pyread "${DUMP_DIR}/org/actions-secrets.json" 'print(d.get("total_count", 0) if d else 0)')
    if [ "$SECRET_COUNT" -gt 0 ]; then
      echo ""
      echo "  NOTE: ${SECRET_COUNT} org-level secrets were found in the dump (names only)."
      echo "  Secret VALUES are never exported. You must set them manually:"
      echo ""
      pyread "${DUMP_DIR}/org/actions-secrets.json" "
if d:
    for s in d.get('secrets', []):
        name = s.get('name','')
        vis = s.get('visibility','')
        print('    # Secret: {} (visibility: {})'.format(name, vis))
        print('    # Use GitHub UI or API with encrypted_value to set')
        print()
"
      echo "  See: https://docs.github.com/en/rest/actions/secrets"
    fi
  fi
else
  echo "  No actions-variables.json found. Skipping."
  SKIPPED=$((SKIPPED + 1))
fi

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "================================================================"
echo "=== Import Complete ==="
echo "================================================================"
echo ""
echo "  Target org:  ${TARGET_ORG}"
echo "  Source dump:  ${DUMP_DIR}"
echo ""
echo "  Imported:  ${IMPORTED}"
echo "  Skipped:   ${SKIPPED}"
echo "  Failed:    ${FAILED}"
echo ""
if [ "$FAILED" -gt 0 ]; then
  echo "  WARNING: ${FAILED} operations failed. Review output above."
fi
if [ "$DRY_RUN" = "--dry-run" ]; then
  echo "  This was a DRY RUN. No changes were made."
  echo "  Remove --dry-run to apply changes."
fi
echo ""
echo "  Items NOT imported (require manual action):"
echo "    - Secrets (values are never in the dump)"
echo "    - Webhooks (contain external URLs and secrets)"
echo "    - Repos (use Terraform or create manually, then re-run this script)"
echo "    - CODEOWNERS files (committed in repo, migrated with git mirror)"

# Rate limit check
RATE_INFO=$(gh_api_get "rate_limit" | python3 -c "
import sys, json
from datetime import datetime, timezone
try:
    d = json.load(sys.stdin)
    r = d.get('rate', {})
    reset_ts = r.get('reset', 0)
    reset_dt = datetime.fromtimestamp(reset_ts, tz=timezone.utc).strftime('%Y-%m-%dT%H:%M:%SZ')
    print('{}/{} remaining (resets {})'.format(r.get('remaining','?'), r.get('limit','?'), reset_dt))
except:
    print('unknown')
")
echo ""
echo "API rate limit: ${RATE_INFO}"
