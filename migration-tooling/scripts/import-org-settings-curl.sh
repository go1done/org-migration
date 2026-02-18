#!/usr/bin/env bash
# migration-tooling/scripts/import-org-settings-curl.sh
# Imports org settings from a dump directory into a target GitHub org.
# Reverse of dump-org-settings-curl.sh — reads the dump and applies via API.
#
# Usage:
#   export GITHUB_TOKEN="ghp_your_personal_access_token"
#   ./import-org-settings-curl.sh <target-org> <dump-dir> [--dry-run]
#
# Required token scopes: admin:org, repo, read:org
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

API="https://api.github.com"
AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
ACCEPT="Accept: application/vnd.github+json"
API_VERSION="X-GitHub-Api-Version: 2022-11-28"

IMPORTED=0
SKIPPED=0
FAILED=0

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
TARGET_CHECK=$(gh_api_get "orgs/${TARGET_ORG}" | jq -r '.login // empty' 2>/dev/null || true)
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
  jq -r '
    "    default_repository_permission: \(.default_repository_permission // "N/A")",
    "    members_can_create_repositories: \(.members_can_create_repositories // "N/A")",
    "    members_can_create_public_repositories: \(.members_can_create_public_repositories // "N/A")",
    "    members_can_create_private_repositories: \(.members_can_create_private_repositories // "N/A")",
    "    members_can_fork_private_repositories: \(.members_can_fork_private_repositories // "N/A")",
    "    web_commit_signoff_required: \(.web_commit_signoff_required // "N/A")"
  ' "${DUMP_DIR}/org/settings.json"

  if confirm "Apply organization settings to ${TARGET_ORG}?"; then
    PAYLOAD=$(jq '{
      default_repository_permission,
      members_can_create_repositories,
      members_can_create_public_repositories,
      members_can_create_private_repositories,
      members_can_create_internal_repositories,
      members_can_fork_private_repositories,
      web_commit_signoff_required,
      has_organization_projects,
      has_repository_projects
    } | with_entries(select(.value != null))' "${DUMP_DIR}/org/settings.json")

    RESULT=$(gh_api_patch "orgs/${TARGET_ORG}" "$PAYLOAD")
    if echo "$RESULT" | jq -e '.login' > /dev/null 2>&1; then
      echo "  [OK] Organization settings applied."
      IMPORTED=$((IMPORTED + 1))
    else
      echo "  [FAIL] $(echo "$RESULT" | jq -r '.message // "Unknown error"')"
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
  jq -r 'to_entries[] | "    \(.key): \(.value // "N/A")"' "${DUMP_DIR}/org/security-defaults.json"

  if confirm "Apply security defaults to ${TARGET_ORG}?"; then
    PAYLOAD=$(jq '{
      advanced_security_enabled_for_new_repositories,
      dependabot_alerts_enabled_for_new_repositories,
      dependabot_security_updates_enabled_for_new_repositories,
      dependency_graph_enabled_for_new_repositories,
      secret_scanning_enabled_for_new_repositories,
      secret_scanning_push_protection_enabled_for_new_repositories
    } | with_entries(select(.value != null))' "${DUMP_DIR}/org/security-defaults.json")

    RESULT=$(gh_api_patch "orgs/${TARGET_ORG}" "$PAYLOAD")
    if echo "$RESULT" | jq -e '.login' > /dev/null 2>&1; then
      echo "  [OK] Security defaults applied."
      IMPORTED=$((IMPORTED + 1))
    else
      echo "  [FAIL] $(echo "$RESULT" | jq -r '.message // "Unknown error"')"
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
  TEAM_COUNT=$(jq 'length' "${DUMP_DIR}/teams/teams.json")
  echo "  Found ${TEAM_COUNT} teams in dump."
  jq -r '.[] | "    - \(.name) (\(.privacy)): \(.description // "no description")"' "${DUMP_DIR}/teams/teams.json"

  if confirm "Create/update ${TEAM_COUNT} teams in ${TARGET_ORG}?"; then
    jq -c '.[]' "${DUMP_DIR}/teams/teams.json" | while read -r team; do
      TEAM_NAME=$(echo "$team" | jq -r '.name')
      TEAM_SLUG=$(echo "$team" | jq -r '.slug')
      TEAM_DESC=$(echo "$team" | jq -r '.description // ""')
      TEAM_PRIVACY=$(echo "$team" | jq -r '.privacy // "closed"')

      # Check if team already exists
      EXISTING=$(gh_api_get "orgs/${TARGET_ORG}/teams/${TEAM_SLUG}" 2>/dev/null)
      if echo "$EXISTING" | jq -e '.id' > /dev/null 2>&1; then
        # Update existing team
        PAYLOAD=$(jq -n --arg name "$TEAM_NAME" --arg desc "$TEAM_DESC" --arg priv "$TEAM_PRIVACY" \
          '{name: $name, description: $desc, privacy: $priv}')
        RESULT=$(gh_api_patch "orgs/${TARGET_ORG}/teams/${TEAM_SLUG}" "$PAYLOAD")
        if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
          echo "  [OK] Updated team: ${TEAM_NAME}"
        else
          echo "  [FAIL] Update team ${TEAM_NAME}: $(echo "$RESULT" | jq -r '.message // "Unknown error"')"
          FAILED=$((FAILED + 1))
          continue
        fi
      else
        # Create new team
        PAYLOAD=$(jq -n --arg name "$TEAM_NAME" --arg desc "$TEAM_DESC" --arg priv "$TEAM_PRIVACY" \
          '{name: $name, description: $desc, privacy: $priv}')
        RESULT=$(gh_api_post "orgs/${TARGET_ORG}/teams" "$PAYLOAD")
        if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
          echo "  [OK] Created team: ${TEAM_NAME}"
        else
          echo "  [FAIL] Create team ${TEAM_NAME}: $(echo "$RESULT" | jq -r '.message // "Unknown error"')"
          FAILED=$((FAILED + 1))
          continue
        fi
      fi

      # Add members
      MEMBERS_FILE="${DUMP_DIR}/teams/team-${TEAM_SLUG}-members.json"
      if [ -f "$MEMBERS_FILE" ]; then
        jq -r '.[].login' "$MEMBERS_FILE" 2>/dev/null | while read -r login; do
          RESULT=$(gh_api_put "orgs/${TARGET_ORG}/teams/${TEAM_SLUG}/memberships/${login}" '{"role":"member"}')
          if echo "$RESULT" | jq -e '.state' > /dev/null 2>&1; then
            echo "    [OK] Added member: ${login}"
          else
            echo "    [WARN] Could not add ${login}: $(echo "$RESULT" | jq -r '.message // "Unknown error"')"
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
  RULESET_COUNT=$(jq 'if type == "array" then length else 0 end' "${DUMP_DIR}/rulesets/org-rulesets-summary.json")
  echo "  Found ${RULESET_COUNT} rulesets in dump."

  if [ "$RULESET_COUNT" -gt 0 ]; then
    jq -r '.[] | "    - \(.name) (enforcement: \(.enforcement), target: \(.target))"' \
      "${DUMP_DIR}/rulesets/org-rulesets-summary.json"

    if confirm "Create ${RULESET_COUNT} rulesets in ${TARGET_ORG}?"; then
      for ruleset_file in "${DUMP_DIR}"/rulesets/ruleset-*.json; do
        [ -f "$ruleset_file" ] || continue

        RULESET_NAME=$(jq -r '.name' "$ruleset_file")

        # Check if ruleset already exists by name
        EXISTING_RULESETS=$(gh_api_get "orgs/${TARGET_ORG}/rulesets" 2>/dev/null || echo "[]")
        EXISTING_ID=$(echo "$EXISTING_RULESETS" | jq -r ".[] | select(.name == \"${RULESET_NAME}\") | .id // empty" 2>/dev/null || true)

        # Build payload — strip id, node_id, _links, source, and other read-only fields
        PAYLOAD=$(jq 'del(.id, .node_id, ._links, .source, .created_at, .updated_at, .current_user_can_bypass)' "$ruleset_file")

        if [ -n "$EXISTING_ID" ]; then
          RESULT=$(gh_api_put "orgs/${TARGET_ORG}/rulesets/${EXISTING_ID}" "$PAYLOAD")
          if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
            echo "  [OK] Updated ruleset: ${RULESET_NAME}"
            IMPORTED=$((IMPORTED + 1))
          else
            echo "  [FAIL] Update ruleset ${RULESET_NAME}: $(echo "$RESULT" | jq -r '.message // "Unknown error"')"
            FAILED=$((FAILED + 1))
          fi
        else
          RESULT=$(gh_api_post "orgs/${TARGET_ORG}/rulesets" "$PAYLOAD")
          if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
            echo "  [OK] Created ruleset: ${RULESET_NAME}"
            IMPORTED=$((IMPORTED + 1))
          else
            echo "  [FAIL] Create ruleset ${RULESET_NAME}: $(echo "$RESULT" | jq -r '.message // "Unknown error"')"
            echo "    Detail: $(echo "$RESULT" | jq -r '.errors // empty')"
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
  REPO_COUNT=$(jq 'length' "${DUMP_DIR}/repos/repo-list.json")
  echo "  Found ${REPO_COUNT} repos in dump."
  echo ""
  echo "  NOTE: This applies security settings and branch protection to repos"
  echo "  that ALREADY EXIST in ${TARGET_ORG}. It does NOT create repos."

  if confirm "Apply repo settings to existing repos in ${TARGET_ORG}?"; then
    jq -r '.[].name' "${DUMP_DIR}/repos/repo-list.json" | while read -r repo; do
      REPO_DIR="${DUMP_DIR}/repos/${repo}"
      [ -d "$REPO_DIR" ] || continue

      # Check if repo exists in target org
      EXISTING=$(gh_api_get "repos/${TARGET_ORG}/${repo}" 2>/dev/null)
      if ! echo "$EXISTING" | jq -e '.id' > /dev/null 2>&1; then
        echo "  [SKIP] ${repo} — does not exist in ${TARGET_ORG}"
        continue
      fi

      CHANGES_MADE=false

      # Apply repo settings (security, merge options)
      if [ -f "${REPO_DIR}/settings.json" ]; then
        PAYLOAD=$(jq '{
          has_issues,
          has_wiki,
          has_projects,
          delete_branch_on_merge,
          allow_squash_merge,
          allow_merge_commit,
          allow_rebase_merge,
          allow_auto_merge
        } | with_entries(select(.value != null))' "${REPO_DIR}/settings.json")

        RESULT=$(gh_api_patch "repos/${TARGET_ORG}/${repo}" "$PAYLOAD")
        if echo "$RESULT" | jq -e '.id' > /dev/null 2>&1; then
          CHANGES_MADE=true
        fi

        # Apply topics
        TOPICS=$(jq -r '.topics // []' "${REPO_DIR}/settings.json")
        if [ "$TOPICS" != "[]" ] && [ "$TOPICS" != "null" ]; then
          gh_api_put "repos/${TARGET_ORG}/${repo}/topics" "{\"names\": ${TOPICS}}" > /dev/null 2>&1 || true
        fi

        # Enable security features
        SS=$(jq -r '.security_and_analysis.secret_scanning.status // "disabled"' "${REPO_DIR}/settings.json" 2>/dev/null)
        PP=$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // "disabled"' "${REPO_DIR}/settings.json" 2>/dev/null)

        SECURITY_PAYLOAD=$(jq -n \
          --arg ss "$SS" --arg pp "$PP" \
          '{security_and_analysis: {secret_scanning: {status: $ss}, secret_scanning_push_protection: {status: $pp}}}')
        gh_api_patch "repos/${TARGET_ORG}/${repo}" "$SECURITY_PAYLOAD" > /dev/null 2>&1 || true
      fi

      # Apply branch protection
      if [ -f "${REPO_DIR}/branch-protection.json" ]; then
        BP_STATUS=$(jq -r '.status // empty' "${REPO_DIR}/branch-protection.json" 2>/dev/null)
        if [ "$BP_STATUS" != "not configured" ] && [ -n "$BP_STATUS" ] || [ -z "$BP_STATUS" ]; then
          DEFAULT_BRANCH=$(jq -r '.default_branch // "main"' "${REPO_DIR}/settings.json" 2>/dev/null || echo "main")

          # Build branch protection payload from dump
          BP_PAYLOAD=$(jq '{
            required_status_checks: (if .required_status_checks then {
              strict: .required_status_checks.strict,
              contexts: .required_status_checks.contexts
            } else null end),
            enforce_admins: .enforce_admins.enabled,
            required_pull_request_reviews: (if .required_pull_request_reviews then {
              dismiss_stale_reviews: .required_pull_request_reviews.dismiss_stale_reviews,
              require_code_owner_reviews: .required_pull_request_reviews.require_code_owner_reviews,
              required_approving_review_count: .required_pull_request_reviews.required_approving_review_count,
              require_last_push_approval: .required_pull_request_reviews.require_last_push_approval
            } else null end),
            restrictions: null,
            required_linear_history: .required_linear_history.enabled,
            allow_force_pushes: .allow_force_pushes.enabled,
            allow_deletions: .allow_deletions.enabled,
            required_conversation_resolution: .required_conversation_resolution.enabled
          } | with_entries(select(.value != null))' "${REPO_DIR}/branch-protection.json" 2>/dev/null)

          if [ -n "$BP_PAYLOAD" ] && [ "$BP_PAYLOAD" != "{}" ]; then
            RESULT=$(gh_api_put "repos/${TARGET_ORG}/${repo}/branches/${DEFAULT_BRANCH}/protection" "$BP_PAYLOAD")
            if echo "$RESULT" | jq -e '.url' > /dev/null 2>&1; then
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
  TEAM_COUNT=$(jq 'length' "${DUMP_DIR}/teams/teams.json")
  echo "  Found ${TEAM_COUNT} teams with repo access mappings."

  if confirm "Apply team-repo access permissions in ${TARGET_ORG}?"; then
    jq -r '.[].slug' "${DUMP_DIR}/teams/teams.json" | while read -r slug; do
      REPOS_FILE="${DUMP_DIR}/teams/team-${slug}-repos.json"
      [ -f "$REPOS_FILE" ] || continue

      REPO_ACCESS_COUNT=$(jq 'length' "$REPOS_FILE")
      [ "$REPO_ACCESS_COUNT" -eq 0 ] && continue

      echo "  Team: ${slug} (${REPO_ACCESS_COUNT} repos)"
      jq -c '.[]' "$REPOS_FILE" | while read -r entry; do
        REPO_NAME=$(echo "$entry" | jq -r '.name')
        # Determine highest permission
        PERMISSION=$(echo "$entry" | jq -r '
          if .permissions.admin then "admin"
          elif .permissions.maintain then "maintain"
          elif .permissions.push then "push"
          elif .permissions.triage then "triage"
          else "pull"
          end
        ')

        # Check if repo exists in target
        EXISTING=$(gh_api_get "repos/${TARGET_ORG}/${REPO_NAME}" 2>/dev/null)
        if ! echo "$EXISTING" | jq -e '.id' > /dev/null 2>&1; then
          echo "    [SKIP] ${REPO_NAME} — repo not in ${TARGET_ORG}"
          continue
        fi

        RESULT=$(gh_api_put "orgs/${TARGET_ORG}/teams/${slug}/repos/${TARGET_ORG}/${REPO_NAME}" \
          "{\"permission\": \"${PERMISSION}\"}")
        # PUT returns 204 (no content) on success
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
  VAR_COUNT=$(jq '.total_count // 0' "${DUMP_DIR}/org/actions-variables.json")
  echo "  Found ${VAR_COUNT} org-level variables in dump."

  if [ "$VAR_COUNT" -gt 0 ]; then
    jq -r '.variables[] | "    - \(.name) = \(.value) (visibility: \(.visibility))"' \
      "${DUMP_DIR}/org/actions-variables.json"

    if confirm "Create/update ${VAR_COUNT} org variables in ${TARGET_ORG}?"; then
      jq -c '.variables[]' "${DUMP_DIR}/org/actions-variables.json" | while read -r var; do
        VAR_NAME=$(echo "$var" | jq -r '.name')
        VAR_VALUE=$(echo "$var" | jq -r '.value')
        VAR_VIS=$(echo "$var" | jq -r '.visibility // "private"')

        PAYLOAD=$(jq -n --arg name "$VAR_NAME" --arg value "$VAR_VALUE" --arg vis "$VAR_VIS" \
          '{name: $name, value: $value, visibility: $vis}')

        # Try update first, then create
        RESULT=$(gh_api_patch "orgs/${TARGET_ORG}/actions/variables/${VAR_NAME}" "$PAYLOAD" 2>/dev/null)
        if echo "$RESULT" | jq -e '.message' > /dev/null 2>&1; then
          # Doesn't exist, create it
          RESULT=$(gh_api_post "orgs/${TARGET_ORG}/actions/variables" "$PAYLOAD")
          if echo "$RESULT" | jq -e '.message' > /dev/null 2>&1; then
            echo "  [FAIL] ${VAR_NAME}: $(echo "$RESULT" | jq -r '.message')"
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
  SECRET_COUNT=$(jq '.total_count // 0' "${DUMP_DIR}/org/actions-secrets.json" 2>/dev/null || echo "0")
  if [ "$SECRET_COUNT" -gt 0 ]; then
    echo ""
    echo "  NOTE: ${SECRET_COUNT} org-level secrets were found in the dump (names only)."
    echo "  Secret VALUES are never exported. You must set them manually:"
    echo ""
    jq -r '.secrets[] | "    export SECRET_VALUE=\"...\"\n    curl -X PUT \\\n      -H \"Authorization: Bearer $GITHUB_TOKEN\" \\\n      -H \"Accept: application/vnd.github+json\" \\\n      \"https://api.github.com/orgs/'${TARGET_ORG}'/actions/secrets/\(.name)\" \\\n      -d \"{\\\"visibility\\\": \\\"\(.visibility)\\\", \\\"encrypted_value\\\": \\\"$SECRET_VALUE\\\"}\"\n"' \
      "${DUMP_DIR}/org/actions-secrets.json" 2>/dev/null || true
    echo "  See: https://docs.github.com/en/rest/actions/secrets"
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
RATE=$(gh_api_get "rate_limit" | jq '.rate | {remaining, limit, reset: (.reset | todate)}' 2>/dev/null || echo '{}')
echo ""
echo "API rate limit: $(echo "$RATE" | jq -r '"\(.remaining)/\(.limit) remaining (resets \(.reset))"' 2>/dev/null || echo "unknown")"
