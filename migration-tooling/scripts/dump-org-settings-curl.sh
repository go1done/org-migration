#!/usr/bin/env bash
# migration-tooling/scripts/dump-org-settings-curl.sh
# Dumps the current GitHub org's rulesets, security settings, and compliance config.
# Uses curl + GitHub REST API — no gh CLI required.
#
# Usage:
#   export GITHUB_TOKEN="ghp_your_personal_access_token"
#   ./dump-org-settings-curl.sh <org-name> [output-dir]
#
# Required token scopes: admin:org, repo, read:org
#
# Rate limiting: GitHub API allows 5000 requests/hour with a token.
# Large orgs (50+ repos) may take a few minutes.

set -euo pipefail

ORG="${1:?Usage: $0 <org-name> [output-dir]}"
OUTPUT_DIR="${2:-org-dump-${ORG}-$(date -u +%Y%m%d-%H%M%S)}"

if [ -z "${GITHUB_TOKEN:-}" ]; then
  echo "ERROR: GITHUB_TOKEN environment variable is not set."
  echo ""
  echo "Create a Personal Access Token at: https://github.com/settings/tokens"
  echo "Required scopes: admin:org, repo, read:org"
  echo ""
  echo "Usage:"
  echo "  export GITHUB_TOKEN=\"ghp_your_token\""
  echo "  $0 ${ORG}"
  exit 1
fi

API="https://api.github.com"
AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
ACCEPT="Accept: application/vnd.github+json"
API_VERSION="X-GitHub-Api-Version: 2022-11-28"

# Helper: make an authenticated API call
gh_api() {
  local endpoint="$1"
  local url
  if [[ "$endpoint" == http* ]]; then
    url="$endpoint"
  else
    url="${API}/${endpoint}"
  fi
  curl -sL -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" "$url"
}

# Helper: paginated API call (follows Link headers)
gh_api_paginated() {
  local endpoint="$1"
  local url="${API}/${endpoint}"
  local all_results="[]"

  while [ -n "$url" ]; do
    local response_headers
    response_headers=$(mktemp)
    local body
    body=$(curl -sL -D "$response_headers" -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" "$url")

    # Merge results (handle both array and object-with-array responses)
    if echo "$body" | jq -e 'type == "array"' > /dev/null 2>&1; then
      all_results=$(echo "$all_results" "$body" | jq -s '.[0] + .[1]')
    else
      # Some endpoints return {total_count, items/secrets/variables: [...]}
      all_results=$(echo "$all_results" "$body" | jq -s '.[0] + [.[1]]')
    fi

    # Check for next page in Link header
    url=$(grep -i '^link:' "$response_headers" | sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p' || true)
    rm -f "$response_headers"
  done

  echo "$all_results"
}

# Verify token works
echo "=== Dumping org settings: ${ORG} ==="
echo "    Output: ${OUTPUT_DIR}/"
echo ""

echo "Verifying API access..."
TOKEN_CHECK=$(gh_api "orgs/${ORG}" | jq -r '.login // empty' 2>/dev/null || true)
if [ -z "$TOKEN_CHECK" ]; then
  echo "ERROR: Cannot access org '${ORG}'. Check your GITHUB_TOKEN and org name."
  echo "  - Token needs admin:org and repo scopes"
  echo "  - Org name is case-sensitive"
  exit 1
fi
echo "  Authenticated. Org: ${TOKEN_CHECK}"
echo ""

mkdir -p "${OUTPUT_DIR}"/{org,rulesets,repos,teams,security}

# ---------------------------------------------------------------
# 1. Organization settings
# ---------------------------------------------------------------
echo "[1/8] Organization settings..."
gh_api "orgs/${ORG}" | jq '{
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
}' > "${OUTPUT_DIR}/org/settings.json" 2>/dev/null || echo '{}' > "${OUTPUT_DIR}/org/settings.json"

# Security defaults for new repos
gh_api "orgs/${ORG}" | jq '{
  advanced_security_enabled_for_new_repositories,
  dependabot_alerts_enabled_for_new_repositories,
  dependabot_security_updates_enabled_for_new_repositories,
  dependency_graph_enabled_for_new_repositories,
  secret_scanning_enabled_for_new_repositories,
  secret_scanning_push_protection_enabled_for_new_repositories
}' > "${OUTPUT_DIR}/org/security-defaults.json" 2>/dev/null || echo '{}' > "${OUTPUT_DIR}/org/security-defaults.json"

echo "  Done."

# ---------------------------------------------------------------
# 2. Organization rulesets
# ---------------------------------------------------------------
echo "[2/8] Organization rulesets..."
RULESETS=$(gh_api "orgs/${ORG}/rulesets" 2>/dev/null || echo "[]")

# Handle 404 (rulesets not available on this plan)
if echo "$RULESETS" | jq -e '.message' > /dev/null 2>&1; then
  echo "  Rulesets not available (may require Enterprise Cloud)."
  RULESETS="[]"
fi

echo "$RULESETS" | jq '.' > "${OUTPUT_DIR}/rulesets/org-rulesets-summary.json"

RULESET_COUNT=$(echo "$RULESETS" | jq 'if type == "array" then length else 0 end')
echo "  Found ${RULESET_COUNT} org-level rulesets."

if [ "$RULESET_COUNT" -gt 0 ]; then
  echo "$RULESETS" | jq -r '.[].id' | while read -r id; do
    RULESET=$(gh_api "orgs/${ORG}/rulesets/${id}" 2>/dev/null || echo "{}")
    NAME=$(echo "$RULESET" | jq -r '.name // "unknown"')
    echo "$RULESET" | jq '.' > "${OUTPUT_DIR}/rulesets/ruleset-${NAME}.json"
    echo "  - ${NAME} (id: ${id})"
  done
fi

# ---------------------------------------------------------------
# 3. Repository list with security settings
# ---------------------------------------------------------------
echo "[3/8] Repository settings..."

# Fetch all repos (paginated, 100 per page)
REPOS="[]"
PAGE=1
while true; do
  BATCH=$(gh_api "orgs/${ORG}/repos?type=all&per_page=100&page=${PAGE}")
  BATCH_COUNT=$(echo "$BATCH" | jq 'length')
  if [ "$BATCH_COUNT" -eq 0 ]; then
    break
  fi
  REPOS=$(echo "$REPOS" "$BATCH" | jq -s '.[0] + .[1]')
  if [ "$BATCH_COUNT" -lt 100 ]; then
    break
  fi
  PAGE=$((PAGE + 1))
done

# Filter out archived repos
REPOS=$(echo "$REPOS" | jq '[.[] | select(.archived == false)]')
REPO_COUNT=$(echo "$REPOS" | jq 'length')
echo "  Found ${REPO_COUNT} active repos."

# Save repo list
echo "$REPOS" | jq '[.[] | {name, visibility, default_branch, description}]' > "${OUTPUT_DIR}/repos/repo-list.json"

echo "$REPOS" | jq -r '.[].name' | while read -r repo; do
  mkdir -p "${OUTPUT_DIR}/repos/${repo}"

  # Repo settings + security analysis
  gh_api "repos/${ORG}/${repo}" | jq '{
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
    security_and_analysis
  }' > "${OUTPUT_DIR}/repos/${repo}/settings.json" 2>/dev/null || echo '{}' > "${OUTPUT_DIR}/repos/${repo}/settings.json"

  # Branch protection on default branch
  DEFAULT_BRANCH=$(echo "$REPOS" | jq -r ".[] | select(.name == \"${repo}\") | .default_branch")
  BP=$(gh_api "repos/${ORG}/${repo}/branches/${DEFAULT_BRANCH}/protection" 2>/dev/null || true)
  if echo "$BP" | jq -e '.message' > /dev/null 2>&1; then
    echo '{"status": "not configured"}' > "${OUTPUT_DIR}/repos/${repo}/branch-protection.json"
  else
    echo "$BP" | jq '.' > "${OUTPUT_DIR}/repos/${repo}/branch-protection.json"
  fi

  # Repo-level rulesets
  RS=$(gh_api "repos/${ORG}/${repo}/rulesets" 2>/dev/null || echo "[]")
  if echo "$RS" | jq -e '.message' > /dev/null 2>&1; then
    echo '[]' > "${OUTPUT_DIR}/repos/${repo}/rulesets.json"
  else
    echo "$RS" | jq '.' > "${OUTPUT_DIR}/repos/${repo}/rulesets.json"
  fi

  # CODEOWNERS existence
  CODEOWNERS="none"
  if gh_api "repos/${ORG}/${repo}/contents/CODEOWNERS" | jq -e '.name' > /dev/null 2>&1; then
    CODEOWNERS="root"
  elif gh_api "repos/${ORG}/${repo}/contents/.github/CODEOWNERS" | jq -e '.name' > /dev/null 2>&1; then
    CODEOWNERS=".github"
  elif gh_api "repos/${ORG}/${repo}/contents/docs/CODEOWNERS" | jq -e '.name' > /dev/null 2>&1; then
    CODEOWNERS="docs"
  fi
  echo "{\"codeowners_location\": \"${CODEOWNERS}\"}" > "${OUTPUT_DIR}/repos/${repo}/codeowners.json"

  # Webhooks (names only, not secrets)
  WH=$(gh_api "repos/${ORG}/${repo}/hooks" 2>/dev/null || echo "[]")
  if echo "$WH" | jq -e '.message' > /dev/null 2>&1; then
    echo '[]' > "${OUTPUT_DIR}/repos/${repo}/webhooks.json"
  else
    echo "$WH" | jq '[.[] | {id, name, active, events, config: {url: .config.url, content_type: .config.content_type}}]' \
      > "${OUTPUT_DIR}/repos/${repo}/webhooks.json"
  fi

  echo "  - ${repo}"
done

# ---------------------------------------------------------------
# 4. Teams
# ---------------------------------------------------------------
echo "[4/8] Teams..."
TEAMS=$(gh_api_paginated "orgs/${ORG}/teams?per_page=100" 2>/dev/null || echo "[]")

# Clean up — gh_api_paginated may wrap objects in array
if echo "$TEAMS" | jq -e '.[0] | type == "object" and has("slug")' > /dev/null 2>&1; then
  # Already an array of team objects
  true
else
  # Flatten nested arrays
  TEAMS=$(echo "$TEAMS" | jq 'flatten')
fi

echo "$TEAMS" | jq '[.[] | {name, slug, description, privacy, permission}]' \
  > "${OUTPUT_DIR}/teams/teams.json" 2>/dev/null || echo '[]' > "${OUTPUT_DIR}/teams/teams.json"

TEAM_COUNT=$(jq 'length' "${OUTPUT_DIR}/teams/teams.json")
echo "  Found ${TEAM_COUNT} teams."

jq -r '.[].slug' "${OUTPUT_DIR}/teams/teams.json" 2>/dev/null | while read -r slug; do
  # Team members
  MEMBERS=$(gh_api "orgs/${ORG}/teams/${slug}/members?per_page=100" 2>/dev/null || echo "[]")
  if echo "$MEMBERS" | jq -e '.message' > /dev/null 2>&1; then
    echo '[]' > "${OUTPUT_DIR}/teams/team-${slug}-members.json"
  else
    echo "$MEMBERS" | jq '[.[] | {login}]' > "${OUTPUT_DIR}/teams/team-${slug}-members.json"
  fi

  # Team repos
  TREPOS=$(gh_api "orgs/${ORG}/teams/${slug}/repos?per_page=100" 2>/dev/null || echo "[]")
  if echo "$TREPOS" | jq -e '.message' > /dev/null 2>&1; then
    echo '[]' > "${OUTPUT_DIR}/teams/team-${slug}-repos.json"
  else
    echo "$TREPOS" | jq '[.[] | {name, permissions}]' > "${OUTPUT_DIR}/teams/team-${slug}-repos.json"
  fi

  MEMBER_COUNT=$(jq 'length' "${OUTPUT_DIR}/teams/team-${slug}-members.json")
  echo "  - ${slug} (${MEMBER_COUNT} members)"
done

# ---------------------------------------------------------------
# 5. Organization secrets (names only, never values)
# ---------------------------------------------------------------
echo "[5/8] Organization Actions secrets..."
SECRETS=$(gh_api "orgs/${ORG}/actions/secrets" 2>/dev/null || echo '{"total_count": 0, "secrets": []}')
if echo "$SECRETS" | jq -e '.message' > /dev/null 2>&1; then
  echo '{"total_count": 0, "secrets": []}' > "${OUTPUT_DIR}/org/actions-secrets.json"
  SECRET_COUNT=0
else
  echo "$SECRETS" | jq '{total_count, secrets: [.secrets[] | {name, visibility, selected_repositories_url}]}' \
    > "${OUTPUT_DIR}/org/actions-secrets.json"
  SECRET_COUNT=$(echo "$SECRETS" | jq '.total_count')
fi
echo "  Found ${SECRET_COUNT} org-level secrets."

# Organization variables
VARS=$(gh_api "orgs/${ORG}/actions/variables" 2>/dev/null || echo '{"total_count": 0, "variables": []}')
if echo "$VARS" | jq -e '.message' > /dev/null 2>&1; then
  echo '{"total_count": 0, "variables": []}' > "${OUTPUT_DIR}/org/actions-variables.json"
  VAR_COUNT=0
else
  echo "$VARS" | jq '{total_count, variables: [.variables[] | {name, value, visibility}]}' \
    > "${OUTPUT_DIR}/org/actions-variables.json"
  VAR_COUNT=$(echo "$VARS" | jq '.total_count')
fi
echo "  Found ${VAR_COUNT} org-level variables."

# ---------------------------------------------------------------
# 6. Dependabot alerts summary
# ---------------------------------------------------------------
echo "[6/8] Dependabot alerts summary..."
echo "$REPOS" | jq -r '.[].name' | while read -r repo; do
  ALERTS=$(gh_api "repos/${ORG}/${repo}/dependabot/alerts?state=open&per_page=1" 2>/dev/null || echo "[]")
  if echo "$ALERTS" | jq -e '.message' > /dev/null 2>&1; then
    ALERT_COUNT="N/A"
  else
    ALERT_COUNT=$(echo "$ALERTS" | jq 'length')
  fi
  echo "{\"repo\": \"${repo}\", \"open_alerts\": \"${ALERT_COUNT}\"}"
done | jq -s '.' > "${OUTPUT_DIR}/security/dependabot-summary.json"
echo "  Done."

# ---------------------------------------------------------------
# 7. Code scanning status
# ---------------------------------------------------------------
echo "[7/8] Code scanning status..."
echo "$REPOS" | jq -r '.[].name' | while read -r repo; do
  SCAN=$(gh_api "repos/${ORG}/${repo}/code-scanning/alerts?per_page=1" 2>/dev/null || echo '{"message":"not found"}')
  if echo "$SCAN" | jq -e '.message' > /dev/null 2>&1; then
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

{
  echo "# Org Compliance Dump Summary"
  echo ""
  echo "**Organization:** ${ORG}"
  echo "**Date:** $(date -u +%Y-%m-%d\ %H:%M\ UTC)"
  echo ""

  echo "## Organization Settings"
  echo ""
  echo '```json'
  cat "${OUTPUT_DIR}/org/settings.json"
  echo ""
  echo '```'
  echo ""

  echo "## Security Defaults (for new repos)"
  echo ""
  echo '```json'
  cat "${OUTPUT_DIR}/org/security-defaults.json"
  echo ""
  echo '```'
  echo ""

  echo "## Organization Rulesets (${RULESET_COUNT})"
  echo ""
  if [ "$RULESET_COUNT" -gt 0 ]; then
    echo "| Name | Enforcement | Target |"
    echo "|------|-------------|--------|"
    echo "$RULESETS" | jq -r '.[] | "| \(.name) | \(.enforcement) | \(.target) |"'
  else
    echo "No org-level rulesets configured."
  fi
  echo ""

  echo "## Per-Repo Compliance"
  echo ""
  echo "| Repo | Secret Scan | Push Protect | Branch Protect | CODEOWNERS | Rulesets |"
  echo "|------|------------|-------------|---------------|------------|---------|"

  echo "$REPOS" | jq -r '.[].name' | while read -r repo; do
    SS=$(jq -r '.security_and_analysis.secret_scanning.status // "off"' "${OUTPUT_DIR}/repos/${repo}/settings.json" 2>/dev/null || echo "unknown")
    PP=$(jq -r '.security_and_analysis.secret_scanning_push_protection.status // "off"' "${OUTPUT_DIR}/repos/${repo}/settings.json" 2>/dev/null || echo "unknown")
    BP_STATUS=$(jq -r 'if has("status") then "no" else "yes" end' "${OUTPUT_DIR}/repos/${repo}/branch-protection.json" 2>/dev/null || echo "unknown")
    CO=$(jq -r '.codeowners_location' "${OUTPUT_DIR}/repos/${repo}/codeowners.json" 2>/dev/null || echo "none")
    RS=$(jq 'if type == "array" then length else 0 end' "${OUTPUT_DIR}/repos/${repo}/rulesets.json" 2>/dev/null || echo "0")
    echo "| ${repo} | ${SS} | ${PP} | ${BP_STATUS} | ${CO} | ${RS} |"
  done
  echo ""

  echo "## Teams (${TEAM_COUNT})"
  echo ""
  jq -r '.[] | "- **\(.name)** (\(.privacy)) — \(.description // "no description")"' "${OUTPUT_DIR}/teams/teams.json" 2>/dev/null || true
  echo ""

  echo "## Organization Secrets (${SECRET_COUNT})"
  echo ""
  if [ "$SECRET_COUNT" -gt 0 ]; then
    jq -r '.secrets[] | "- \`\(.name)\` (visibility: \(.visibility))"' "${OUTPUT_DIR}/org/actions-secrets.json" 2>/dev/null || true
  else
    echo "No org-level secrets."
  fi
  echo ""

  echo "---"
  echo "*Generated by dump-org-settings-curl.sh*"
} > "${OUTPUT_DIR}/compliance-summary.md"

echo "  Done."

# ---------------------------------------------------------------
# API rate limit check
# ---------------------------------------------------------------
RATE=$(gh_api "rate_limit" | jq '.rate | {remaining, limit, reset: (.reset | todate)}')
echo ""
echo "API rate limit: $(echo "$RATE" | jq -r '"\(.remaining)/\(.limit) remaining (resets \(.reset))"')"

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
echo "    codeowners.json            CODEOWNERS file location"
echo "    webhooks.json              Webhook configs (no secrets)"
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
