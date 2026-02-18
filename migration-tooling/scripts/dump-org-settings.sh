#!/usr/bin/env bash
# migration-tooling/scripts/dump-org-settings.sh
# Dumps the current GitHub org's rulesets, security settings, and compliance config.
#
# Usage: ./dump-org-settings.sh <org-name> [output-dir]
# Requires: gh CLI authenticated with admin:org scope
#
# Outputs a directory structure with JSON/YAML files for each category.

set -euo pipefail

ORG="${1:?Usage: $0 <org-name> [output-dir]}"
OUTPUT_DIR="${2:-org-dump-${ORG}-$(date -u +%Y%m%d-%H%M%S)}"
GH="${GH_CLI:-gh}"

# Check gh is available
if ! command -v "$GH" &> /dev/null; then
  # Try common locations
  for path in ~/.local/bin/gh /usr/local/bin/gh /usr/bin/gh; do
    if [ -x "$path" ]; then
      GH="$path"
      break
    fi
  done
fi

if ! command -v "$GH" &> /dev/null && [ ! -x "$GH" ]; then
  echo "ERROR: gh CLI not found. Set GH_CLI env var or install gh."
  exit 1
fi

echo "=== Dumping org settings: ${ORG} ==="
echo "    Output: ${OUTPUT_DIR}/"
echo ""

mkdir -p "${OUTPUT_DIR}"/{org,rulesets,repos,teams,security}

# ---------------------------------------------------------------
# 1. Organization settings
# ---------------------------------------------------------------
echo "[1/8] Organization settings..."
$GH api "orgs/${ORG}" \
  --jq '{
    name,
    description,
    company,
    blog,
    email,
    default_repository_permission,
    members_can_create_repositories,
    members_can_create_public_repositories,
    members_can_create_private_repositories,
    members_can_create_internal_repositories,
    members_can_fork_private_repositories,
    web_commit_signoff_required,
    two_factor_requirement_enabled,
    has_organization_projects,
    has_repository_projects,
    plan: .plan
  }' > "${OUTPUT_DIR}/org/settings.json" 2>/dev/null || echo "  WARNING: Could not fetch org settings (need admin:org scope)"

# Organization security settings
$GH api "orgs/${ORG}" \
  --jq '{
    advanced_security_enabled_for_new_repositories,
    dependabot_alerts_enabled_for_new_repositories,
    dependabot_security_updates_enabled_for_new_repositories,
    dependency_graph_enabled_for_new_repositories,
    secret_scanning_enabled_for_new_repositories,
    secret_scanning_push_protection_enabled_for_new_repositories
  }' > "${OUTPUT_DIR}/org/security-defaults.json" 2>/dev/null || echo "  WARNING: Could not fetch security defaults"

echo "  Done."

# ---------------------------------------------------------------
# 2. Organization rulesets
# ---------------------------------------------------------------
echo "[2/8] Organization rulesets..."
RULESETS=$($GH api "orgs/${ORG}/rulesets" --paginate 2>/dev/null || echo "[]")
echo "$RULESETS" | jq '.' > "${OUTPUT_DIR}/rulesets/org-rulesets-summary.json"

RULESET_COUNT=$(echo "$RULESETS" | jq 'length')
echo "  Found ${RULESET_COUNT} org-level rulesets."

if [ "$RULESET_COUNT" -gt 0 ]; then
  echo "$RULESETS" | jq -r '.[].id' | while read -r id; do
    RULESET=$($GH api "orgs/${ORG}/rulesets/${id}" 2>/dev/null || echo "{}")
    NAME=$(echo "$RULESET" | jq -r '.name // "unknown"')
    echo "$RULESET" | jq '.' > "${OUTPUT_DIR}/rulesets/ruleset-${NAME}.json"
    echo "  - ${NAME} (id: ${id})"
  done
fi

# ---------------------------------------------------------------
# 3. Repository list with security settings
# ---------------------------------------------------------------
echo "[3/8] Repository settings..."
REPOS=$($GH repo list "$ORG" --limit 200 --json name,visibility,defaultBranchRef,isArchived,description --jq '.[] | select(.isArchived == false)' | jq -s '.')
REPO_COUNT=$(echo "$REPOS" | jq 'length')
echo "  Found ${REPO_COUNT} active repos."

echo "$REPOS" | jq '.' > "${OUTPUT_DIR}/repos/repo-list.json"

echo "$REPOS" | jq -r '.[].name' | while read -r repo; do
  mkdir -p "${OUTPUT_DIR}/repos/${repo}"

  # Repo settings + security analysis
  $GH api "repos/${ORG}/${repo}" \
    --jq '{
      name,
      visibility,
      default_branch,
      has_issues,
      has_wiki,
      has_projects,
      delete_branch_on_merge,
      allow_squash_merge,
      allow_merge_commit,
      allow_rebase_merge,
      allow_auto_merge,
      topics,
      security_and_analysis: .security_and_analysis
    }' > "${OUTPUT_DIR}/repos/${repo}/settings.json" 2>/dev/null || true

  # Branch protection on default branch
  DEFAULT_BRANCH=$($GH api "repos/${ORG}/${repo}" --jq '.default_branch' 2>/dev/null || echo "main")
  $GH api "repos/${ORG}/${repo}/branches/${DEFAULT_BRANCH}/protection" \
    > "${OUTPUT_DIR}/repos/${repo}/branch-protection.json" 2>/dev/null || echo '{"status": "not configured"}' > "${OUTPUT_DIR}/repos/${repo}/branch-protection.json"

  # Repo-level rulesets
  $GH api "repos/${ORG}/${repo}/rulesets" \
    > "${OUTPUT_DIR}/repos/${repo}/rulesets.json" 2>/dev/null || echo '[]' > "${OUTPUT_DIR}/repos/${repo}/rulesets.json"

  # CODEOWNERS existence
  CODEOWNERS="none"
  $GH api "repos/${ORG}/${repo}/contents/CODEOWNERS" --jq '.name' > /dev/null 2>&1 && CODEOWNERS="root"
  $GH api "repos/${ORG}/${repo}/contents/.github/CODEOWNERS" --jq '.name' > /dev/null 2>&1 && CODEOWNERS=".github"
  $GH api "repos/${ORG}/${repo}/contents/docs/CODEOWNERS" --jq '.name' > /dev/null 2>&1 && CODEOWNERS="docs"
  echo "{\"codeowners_location\": \"${CODEOWNERS}\"}" > "${OUTPUT_DIR}/repos/${repo}/codeowners.json"

  # Webhooks (names only, not secrets)
  $GH api "repos/${ORG}/${repo}/hooks" \
    --jq '[.[] | {id, name, active, events, config: {url: .config.url, content_type: .config.content_type}}]' \
    > "${OUTPUT_DIR}/repos/${repo}/webhooks.json" 2>/dev/null || echo '[]' > "${OUTPUT_DIR}/repos/${repo}/webhooks.json"

  echo "  - ${repo}"
done

# ---------------------------------------------------------------
# 4. Teams
# ---------------------------------------------------------------
echo "[4/8] Teams..."
$GH api "orgs/${ORG}/teams" --paginate \
  --jq '[.[] | {name, slug, description, privacy, permission}]' \
  > "${OUTPUT_DIR}/teams/teams.json" 2>/dev/null || echo '[]' > "${OUTPUT_DIR}/teams/teams.json"

TEAM_COUNT=$(jq 'length' "${OUTPUT_DIR}/teams/teams.json")
echo "  Found ${TEAM_COUNT} teams."

jq -r '.[].slug' "${OUTPUT_DIR}/teams/teams.json" | while read -r slug; do
  # Team members
  $GH api "orgs/${ORG}/teams/${slug}/members" --paginate \
    --jq '[.[] | {login, role: "member"}]' \
    > "${OUTPUT_DIR}/teams/team-${slug}-members.json" 2>/dev/null || echo '[]' > "${OUTPUT_DIR}/teams/team-${slug}-members.json"

  # Team repos
  $GH api "orgs/${ORG}/teams/${slug}/repos" --paginate \
    --jq '[.[] | {name, permissions}]' \
    > "${OUTPUT_DIR}/teams/team-${slug}-repos.json" 2>/dev/null || echo '[]' > "${OUTPUT_DIR}/teams/team-${slug}-repos.json"

  MEMBERS=$(jq 'length' "${OUTPUT_DIR}/teams/team-${slug}-members.json")
  echo "  - ${slug} (${MEMBERS} members)"
done

# ---------------------------------------------------------------
# 5. Organization secrets (names only, never values)
# ---------------------------------------------------------------
echo "[5/8] Organization Actions secrets..."
$GH api "orgs/${ORG}/actions/secrets" --paginate \
  --jq '{total_count, secrets: [.secrets[] | {name, visibility, selected_repositories_url}]}' \
  > "${OUTPUT_DIR}/org/actions-secrets.json" 2>/dev/null || echo '{"total_count": 0, "secrets": []}' > "${OUTPUT_DIR}/org/actions-secrets.json"

SECRET_COUNT=$(jq '.total_count' "${OUTPUT_DIR}/org/actions-secrets.json")
echo "  Found ${SECRET_COUNT} org-level secrets."

# Organization variables
$GH api "orgs/${ORG}/actions/variables" --paginate \
  --jq '{total_count, variables: [.variables[] | {name, value, visibility}]}' \
  > "${OUTPUT_DIR}/org/actions-variables.json" 2>/dev/null || echo '{"total_count": 0, "variables": []}' > "${OUTPUT_DIR}/org/actions-variables.json"

VAR_COUNT=$(jq '.total_count' "${OUTPUT_DIR}/org/actions-variables.json")
echo "  Found ${VAR_COUNT} org-level variables."

# ---------------------------------------------------------------
# 6. Dependabot alerts summary
# ---------------------------------------------------------------
echo "[6/8] Dependabot alerts summary..."
echo '[]' > "${OUTPUT_DIR}/security/dependabot-summary.json"
echo "$REPOS" | jq -r '.[].name' | while read -r repo; do
  ALERT_COUNT=$($GH api "repos/${ORG}/${repo}/dependabot/alerts?state=open&per_page=1" \
    --jq 'length' 2>/dev/null || echo "0")
  echo "{\"repo\": \"${repo}\", \"open_alerts\": ${ALERT_COUNT}}"
done | jq -s '.' > "${OUTPUT_DIR}/security/dependabot-summary.json"
echo "  Done."

# ---------------------------------------------------------------
# 7. Code scanning status
# ---------------------------------------------------------------
echo "[7/8] Code scanning status..."
echo "$REPOS" | jq -r '.[].name' | while read -r repo; do
  SCANNING=$($GH api "repos/${ORG}/${repo}/code-scanning/alerts?per_page=1" \
    --jq 'length' 2>/dev/null || echo "-1")
  if [ "$SCANNING" = "-1" ]; then
    STATUS="not_enabled"
  else
    STATUS="enabled"
  fi
  echo "{\"repo\": \"${repo}\", \"code_scanning\": \"${STATUS}\"}"
done | jq -s '.' > "${OUTPUT_DIR}/security/code-scanning-status.json"
echo "  Done."

# ---------------------------------------------------------------
# 8. Generate compliance summary report
# ---------------------------------------------------------------
echo "[8/8] Generating compliance summary..."

cat > "${OUTPUT_DIR}/compliance-summary.md" << 'HEADER'
# Org Compliance Dump Summary

HEADER

echo "**Organization:** ${ORG}" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "**Date:** $(date -u +%Y-%m-%d\ %H:%M\ UTC)" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"

# Org-level settings summary
echo "## Organization Settings" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"
echo '```json' >> "${OUTPUT_DIR}/compliance-summary.md"
cat "${OUTPUT_DIR}/org/settings.json" >> "${OUTPUT_DIR}/compliance-summary.md"
echo '```' >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"

# Security defaults
echo "## Security Defaults (for new repos)" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"
echo '```json' >> "${OUTPUT_DIR}/compliance-summary.md"
cat "${OUTPUT_DIR}/org/security-defaults.json" >> "${OUTPUT_DIR}/compliance-summary.md"
echo '```' >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"

# Rulesets summary
echo "## Organization Rulesets (${RULESET_COUNT})" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"
if [ "$RULESET_COUNT" -gt 0 ]; then
  echo "| Name | Enforcement | Target |" >> "${OUTPUT_DIR}/compliance-summary.md"
  echo "|------|-------------|--------|" >> "${OUTPUT_DIR}/compliance-summary.md"
  echo "$RULESETS" | jq -r '.[] | "| \(.name) | \(.enforcement) | \(.target) |"' >> "${OUTPUT_DIR}/compliance-summary.md"
else
  echo "No org-level rulesets configured." >> "${OUTPUT_DIR}/compliance-summary.md"
fi
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"

# Per-repo compliance table
echo "## Per-Repo Compliance" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "| Repo | Secret Scan | Push Protect | Branch Protect | CODEOWNERS | Rulesets |" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "|------|------------|-------------|---------------|------------|---------|" >> "${OUTPUT_DIR}/compliance-summary.md"

echo "$REPOS" | jq -r '.[].name' | while read -r repo; do
  SS=$(jq -r '.security_and_analysis.secret_scanning.status // "off"' "${OUTPUT_DIR}/repos/${repo}/settings.json" 2>/dev/null || echo "unknown")
  PP=$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // "off"' "${OUTPUT_DIR}/repos/${repo}/settings.json" 2>/dev/null || echo "unknown")
  BP=$(jq -r 'if .status then "no" else "yes" end' "${OUTPUT_DIR}/repos/${repo}/branch-protection.json" 2>/dev/null || echo "unknown")
  CO=$(jq -r '.codeowners_location' "${OUTPUT_DIR}/repos/${repo}/codeowners.json" 2>/dev/null || echo "none")
  RS=$(jq 'length' "${OUTPUT_DIR}/repos/${repo}/rulesets.json" 2>/dev/null || echo "0")

  echo "| ${repo} | ${SS} | ${PP} | ${BP} | ${CO} | ${RS} |"
done >> "${OUTPUT_DIR}/compliance-summary.md"

echo "" >> "${OUTPUT_DIR}/compliance-summary.md"

# Teams summary
echo "## Teams (${TEAM_COUNT})" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"
jq -r '.[] | "- **\(.name)** (\(.privacy)) — \(.description // "no description")"' "${OUTPUT_DIR}/teams/teams.json" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"

# Secrets summary (names only)
echo "## Organization Secrets (${SECRET_COUNT})" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"
jq -r '.secrets[] | "- `\(.name)` (visibility: \(.visibility))"' "${OUTPUT_DIR}/org/actions-secrets.json" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "" >> "${OUTPUT_DIR}/compliance-summary.md"

echo "---" >> "${OUTPUT_DIR}/compliance-summary.md"
echo "*Generated by dump-org-settings.sh*" >> "${OUTPUT_DIR}/compliance-summary.md"

echo "  Done."

# ---------------------------------------------------------------
# Summary
# ---------------------------------------------------------------
echo ""
echo "=== Dump Complete ==="
echo ""
echo "Output: ${OUTPUT_DIR}/"
echo ""
echo "  org/"
echo "    settings.json              Org-level settings"
echo "    security-defaults.json     Security defaults for new repos"
echo "    actions-secrets.json       Org secrets (names only)"
echo "    actions-variables.json     Org variables"
echo "  rulesets/"
echo "    org-rulesets-summary.json  All org-level rulesets"
echo "    ruleset-<name>.json        Individual ruleset details"
echo "  repos/<name>/"
echo "    settings.json              Repo settings + security analysis"
echo "    branch-protection.json     Default branch protection rules"
echo "    rulesets.json              Repo-level rulesets"
echo "    codeowners.json           CODEOWNERS file location"
echo "    webhooks.json             Webhook configs (no secrets)"
echo "  teams/"
echo "    teams.json                 All teams"
echo "    team-<slug>-members.json   Team membership"
echo "    team-<slug>-repos.json     Team repo access"
echo "  security/"
echo "    dependabot-summary.json    Open Dependabot alerts per repo"
echo "    code-scanning-status.json  Code scanning enabled/disabled"
echo "  compliance-summary.md        Human-readable compliance report"
echo ""
echo "Total: ${REPO_COUNT} repos, ${TEAM_COUNT} teams, ${RULESET_COUNT} rulesets, ${SECRET_COUNT} secrets"
