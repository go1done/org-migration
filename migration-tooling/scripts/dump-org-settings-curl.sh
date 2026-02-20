#!/usr/bin/env bash
# migration-tooling/scripts/dump-org-settings-curl.sh
# Dumps the current GitHub org's rulesets, security settings, and compliance config.
# Uses curl + GitHub REST API — no gh CLI or jq required (uses python3 for JSON).
#
# Usage:
#   export GITHUB_TOKEN="ghp_your_personal_access_token"
#   ./dump-org-settings-curl.sh <org-name> [output-dir]
#
# Required token scopes: admin:org, repo, read:org
# Requires: curl, python3
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

if ! command -v python3 &> /dev/null; then
  echo "ERROR: python3 is required but not found."
  exit 1
fi

API="https://api.github.com"
AUTH_HEADER="Authorization: Bearer ${GITHUB_TOKEN}"
ACCEPT="Accept: application/vnd.github+json"
API_VERSION="X-GitHub-Api-Version: 2022-11-28"

# Helper: python3 replacement for jq
# Usage: echo "$json" | pyjq 'expression'
#   expression is a Python expression where 'd' is the parsed JSON
# Examples:
#   echo "$json" | pyjq 'd.get("login","")'
#   echo "$json" | pyjq 'len(d)'
#   echo "$json" | pyjq 'json.dumps({k: d[k] for k in ["name","email"] if k in d}, indent=2)'
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

# Helper: format JSON (pretty-print)
json_pp() {
  python3 -c "import sys,json; json.dump(json.load(sys.stdin),sys.stdout,indent=2); print()"
}

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
  local tmpfile pagefile
  tmpfile=$(mktemp)
  echo "[]" > "$tmpfile"

  while [ -n "$url" ]; do
    local response_headers
    response_headers=$(mktemp)
    pagefile=$(mktemp)
    curl -sL -D "$response_headers" -H "$AUTH_HEADER" -H "$ACCEPT" -H "$API_VERSION" "$url" > "$pagefile"

    # Merge results using temp files (avoids arg list too long)
    python3 -c "
import json
with open('$tmpfile') as f:
    acc = json.load(f)
with open('$pagefile') as f:
    page = json.load(f)
if isinstance(page, list):
    acc.extend(page)
else:
    acc.append(page)
with open('$tmpfile', 'w') as f:
    json.dump(acc, f)
" 2>/dev/null || true
    rm -f "$pagefile"

    # Check for next page in Link header
    url=$(grep -i '^link:' "$response_headers" | sed -n 's/.*<\([^>]*\)>; rel="next".*/\1/p' || true)
    rm -f "$response_headers"
  done

  cat "$tmpfile"
  rm -f "$tmpfile"
}

# Verify token works
echo "=== Dumping org settings: ${ORG} ==="
echo "    Output: ${OUTPUT_DIR}/"
echo ""

echo "Verifying API access..."
ORG_DATA=$(gh_api "orgs/${ORG}")
TOKEN_CHECK=$(echo "$ORG_DATA" | pyjq 'print(d.get("login","") if d else "")')
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
echo "$ORG_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = [
  'name','description','company','blog','email',
  'default_repository_permission','members_can_create_repositories',
  'members_can_create_public_repositories','members_can_create_private_repositories',
  'members_can_create_internal_repositories','members_can_fork_private_repositories',
  'web_commit_signoff_required','two_factor_requirement_enabled',
  'has_organization_projects','has_repository_projects'
]
out = {k: d.get(k) for k in keys}
out['plan'] = d.get('plan')
json.dump(out, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/org/settings.json" 2>/dev/null || echo '{}' > "${OUTPUT_DIR}/org/settings.json"

# Security defaults for new repos
echo "$ORG_DATA" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = [
  'advanced_security_enabled_for_new_repositories',
  'dependabot_alerts_enabled_for_new_repositories',
  'dependabot_security_updates_enabled_for_new_repositories',
  'dependency_graph_enabled_for_new_repositories',
  'secret_scanning_enabled_for_new_repositories',
  'secret_scanning_push_protection_enabled_for_new_repositories'
]
json.dump({k: d.get(k) for k in keys}, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/org/security-defaults.json" 2>/dev/null || echo '{}' > "${OUTPUT_DIR}/org/security-defaults.json"

echo "  Done."

# ---------------------------------------------------------------
# 2. Organization rulesets
# ---------------------------------------------------------------
echo "[2/8] Organization rulesets..."
RULESETS=$(gh_api "orgs/${ORG}/rulesets" 2>/dev/null || echo "[]")

# Handle 404 (rulesets not available on this plan)
HAS_ERROR=$(echo "$RULESETS" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d else "no")')
if [ "$HAS_ERROR" = "yes" ]; then
  echo "  Rulesets not available (may require Enterprise Cloud)."
  RULESETS="[]"
fi

echo "$RULESETS" | json_pp > "${OUTPUT_DIR}/rulesets/org-rulesets-summary.json"

RULESET_COUNT=$(echo "$RULESETS" | pyjq 'print(len(d) if isinstance(d, list) else 0)')
echo "  Found ${RULESET_COUNT} org-level rulesets."

if [ "$RULESET_COUNT" -gt 0 ]; then
  echo "$RULESETS" | pyjq '
for item in (d if isinstance(d, list) else []):
    print(item.get("id",""))
' | while read -r id; do
    [ -z "$id" ] && continue
    RULESET=$(gh_api "orgs/${ORG}/rulesets/${id}" 2>/dev/null || echo "{}")
    NAME=$(echo "$RULESET" | pyjq 'print(d.get("name","unknown") if d else "unknown")')
    echo "$RULESET" | json_pp > "${OUTPUT_DIR}/rulesets/ruleset-${NAME}.json"
    echo "  - ${NAME} (id: ${id})"
  done
fi

# ---------------------------------------------------------------
# 3. Repository list with security settings
# ---------------------------------------------------------------
echo "[3/8] Repository settings..."

# Use temp files to avoid "Argument list too long" for large orgs
REPOS_FILE=$(mktemp)
echo "[]" > "$REPOS_FILE"
trap "rm -f '$REPOS_FILE'" EXIT

# Fetch all repos (paginated, 100 per page)
PAGE=1
while true; do
  BATCH_FILE=$(mktemp)
  gh_api "orgs/${ORG}/repos?type=all&per_page=100&page=${PAGE}" > "$BATCH_FILE"
  BATCH_COUNT=$(python3 -c "
import json
try:
    d = json.load(open('$BATCH_FILE'))
    print(len(d) if isinstance(d, list) else 0)
except:
    print(0)
")
  if [ "$BATCH_COUNT" -eq 0 ]; then
    rm -f "$BATCH_FILE"
    break
  fi
  python3 -c "
import json
with open('$REPOS_FILE') as f:
    acc = json.load(f)
with open('$BATCH_FILE') as f:
    batch = json.load(f)
if isinstance(batch, list):
    acc.extend(batch)
with open('$REPOS_FILE', 'w') as f:
    json.dump(acc, f)
"
  rm -f "$BATCH_FILE"
  if [ "$BATCH_COUNT" -lt 100 ]; then
    break
  fi
  PAGE=$((PAGE + 1))
done

# Filter out archived repos
python3 -c "
import json
with open('$REPOS_FILE') as f:
    d = json.load(f)
out = [r for r in (d if isinstance(d, list) else []) if not r.get('archived', False)]
with open('$REPOS_FILE', 'w') as f:
    json.dump(out, f)
"
REPO_COUNT=$(python3 -c "import json; print(len(json.load(open('$REPOS_FILE'))))")
echo "  Found ${REPO_COUNT} active repos."

# Save repo list
python3 -c "
import json
d = json.load(open('$REPOS_FILE'))
out = [{'name': r.get('name'), 'visibility': r.get('visibility'), 'default_branch': r.get('default_branch'), 'description': r.get('description')} for r in d]
with open('${OUTPUT_DIR}/repos/repo-list.json', 'w') as f:
    json.dump(out, f, indent=2)
"

python3 -c "
import json
for r in json.load(open('$REPOS_FILE')):
    print(r.get('name',''))
" | while read -r repo; do
  [ -z "$repo" ] && continue
  mkdir -p "${OUTPUT_DIR}/repos/${repo}"

  # Repo settings + security analysis
  gh_api "repos/${ORG}/${repo}" | python3 -c "
import sys, json
d = json.load(sys.stdin)
keys = ['name','visibility','default_branch','has_issues','has_wiki','has_projects',
        'delete_branch_on_merge','allow_squash_merge','allow_merge_commit',
        'allow_rebase_merge','allow_auto_merge','topics','security_and_analysis']
json.dump({k: d.get(k) for k in keys}, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/repos/${repo}/settings.json" 2>/dev/null || echo '{}' > "${OUTPUT_DIR}/repos/${repo}/settings.json"

  # Branch protection on default branch
  DEFAULT_BRANCH=$(python3 -c "
import json
for r in json.load(open('$REPOS_FILE')):
    if r.get('name') == '$repo':
        print(r.get('default_branch','main'))
        break
else:
    print('main')
")
  BP=$(gh_api "repos/${ORG}/${repo}/branches/${DEFAULT_BRANCH}/protection" 2>/dev/null || true)
  BP_IS_ERROR=$(echo "$BP" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d else "no")' 2>/dev/null || echo "yes")
  if [ "$BP_IS_ERROR" = "yes" ]; then
    echo '{"status": "not configured"}' > "${OUTPUT_DIR}/repos/${repo}/branch-protection.json"
  else
    echo "$BP" | json_pp > "${OUTPUT_DIR}/repos/${repo}/branch-protection.json"
  fi

  # Repo-level rulesets
  RS=$(gh_api "repos/${ORG}/${repo}/rulesets" 2>/dev/null || echo "[]")
  RS_IS_ERROR=$(echo "$RS" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d else "no")' 2>/dev/null || echo "yes")
  if [ "$RS_IS_ERROR" = "yes" ]; then
    echo '[]' > "${OUTPUT_DIR}/repos/${repo}/rulesets.json"
  else
    echo "$RS" | json_pp > "${OUTPUT_DIR}/repos/${repo}/rulesets.json"
  fi

  # CODEOWNERS existence
  CODEOWNERS="none"
  CO_ROOT=$(gh_api "repos/${ORG}/${repo}/contents/CODEOWNERS" 2>/dev/null || echo "{}")
  CO_CHECK=$(echo "$CO_ROOT" | pyjq 'print("yes" if isinstance(d, dict) and "name" in d else "no")')
  if [ "$CO_CHECK" = "yes" ]; then
    CODEOWNERS="root"
  else
    CO_GH=$(gh_api "repos/${ORG}/${repo}/contents/.github/CODEOWNERS" 2>/dev/null || echo "{}")
    CO_CHECK=$(echo "$CO_GH" | pyjq 'print("yes" if isinstance(d, dict) and "name" in d else "no")')
    if [ "$CO_CHECK" = "yes" ]; then
      CODEOWNERS=".github"
    else
      CO_DOCS=$(gh_api "repos/${ORG}/${repo}/contents/docs/CODEOWNERS" 2>/dev/null || echo "{}")
      CO_CHECK=$(echo "$CO_DOCS" | pyjq 'print("yes" if isinstance(d, dict) and "name" in d else "no")')
      if [ "$CO_CHECK" = "yes" ]; then
        CODEOWNERS="docs"
      fi
    fi
  fi
  echo "{\"codeowners_location\": \"${CODEOWNERS}\"}" > "${OUTPUT_DIR}/repos/${repo}/codeowners.json"

  # Webhooks (names only, not secrets)
  WH=$(gh_api "repos/${ORG}/${repo}/hooks" 2>/dev/null || echo "[]")
  WH_IS_ERROR=$(echo "$WH" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d else "no")' 2>/dev/null || echo "yes")
  if [ "$WH_IS_ERROR" = "yes" ]; then
    echo '[]' > "${OUTPUT_DIR}/repos/${repo}/webhooks.json"
  else
    echo "$WH" | python3 -c "
import sys, json
d = json.load(sys.stdin)
out = []
for h in (d if isinstance(d, list) else []):
    cfg = h.get('config', {})
    out.append({
        'id': h.get('id'),
        'name': h.get('name'),
        'active': h.get('active'),
        'events': h.get('events'),
        'config': {'url': cfg.get('url'), 'content_type': cfg.get('content_type')}
    })
json.dump(out, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/repos/${repo}/webhooks.json"
  fi

  echo "  - ${repo}"
done

# ---------------------------------------------------------------
# 4. Teams
# ---------------------------------------------------------------
echo "[4/8] Teams..."
TEAMS=$(gh_api_paginated "orgs/${ORG}/teams?per_page=100" 2>/dev/null || echo "[]")

# Flatten and extract team info
echo "$TEAMS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
# Flatten if nested
flat = []
for item in (d if isinstance(d, list) else [d]):
    if isinstance(item, list):
        flat.extend(item)
    elif isinstance(item, dict) and 'slug' in item:
        flat.append(item)
out = [{'name': t.get('name'), 'slug': t.get('slug'), 'description': t.get('description'), 'privacy': t.get('privacy'), 'permission': t.get('permission')} for t in flat]
json.dump(out, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/teams/teams.json" 2>/dev/null || echo '[]' > "${OUTPUT_DIR}/teams/teams.json"

TEAM_COUNT=$(python3 -c "import json; d=json.load(open('${OUTPUT_DIR}/teams/teams.json')); print(len(d))")
echo "  Found ${TEAM_COUNT} teams."

python3 -c "import json; [print(t['slug']) for t in json.load(open('${OUTPUT_DIR}/teams/teams.json'))]" 2>/dev/null | while read -r slug; do
  [ -z "$slug" ] && continue

  # Team members
  MEMBERS=$(gh_api "orgs/${ORG}/teams/${slug}/members?per_page=100" 2>/dev/null || echo "[]")
  MEMBERS_IS_ERROR=$(echo "$MEMBERS" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d else "no")')
  if [ "$MEMBERS_IS_ERROR" = "yes" ]; then
    echo '[]' > "${OUTPUT_DIR}/teams/team-${slug}-members.json"
  else
    echo "$MEMBERS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
json.dump([{'login': m.get('login')} for m in (d if isinstance(d, list) else [])], sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/teams/team-${slug}-members.json"
  fi

  # Team repos
  TREPOS=$(gh_api "orgs/${ORG}/teams/${slug}/repos?per_page=100" 2>/dev/null || echo "[]")
  TREPOS_IS_ERROR=$(echo "$TREPOS" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d else "no")')
  if [ "$TREPOS_IS_ERROR" = "yes" ]; then
    echo '[]' > "${OUTPUT_DIR}/teams/team-${slug}-repos.json"
  else
    echo "$TREPOS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
json.dump([{'name': r.get('name'), 'permissions': r.get('permissions')} for r in (d if isinstance(d, list) else [])], sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/teams/team-${slug}-repos.json"
  fi

  MEMBER_COUNT=$(python3 -c "import json; print(len(json.load(open('${OUTPUT_DIR}/teams/team-${slug}-members.json'))))")
  echo "  - ${slug} (${MEMBER_COUNT} members)"
done

# ---------------------------------------------------------------
# 5. Organization secrets (names only, never values)
# ---------------------------------------------------------------
echo "[5/8] Organization Actions secrets..."
SECRETS=$(gh_api "orgs/${ORG}/actions/secrets" 2>/dev/null || echo '{"total_count": 0, "secrets": []}')
SECRETS_IS_ERROR=$(echo "$SECRETS" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d and "secrets" not in d else "no")')
if [ "$SECRETS_IS_ERROR" = "yes" ]; then
  echo '{"total_count": 0, "secrets": []}' > "${OUTPUT_DIR}/org/actions-secrets.json"
  SECRET_COUNT=0
else
  echo "$SECRETS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
out = {
    'total_count': d.get('total_count', 0),
    'secrets': [{'name': s.get('name'), 'visibility': s.get('visibility'), 'selected_repositories_url': s.get('selected_repositories_url')} for s in d.get('secrets', [])]
}
json.dump(out, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/org/actions-secrets.json"
  SECRET_COUNT=$(echo "$SECRETS" | pyjq 'print(d.get("total_count", 0) if d else 0)')
fi
echo "  Found ${SECRET_COUNT} org-level secrets."

# Organization variables
VARS=$(gh_api "orgs/${ORG}/actions/variables" 2>/dev/null || echo '{"total_count": 0, "variables": []}')
VARS_IS_ERROR=$(echo "$VARS" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d and "variables" not in d else "no")')
if [ "$VARS_IS_ERROR" = "yes" ]; then
  echo '{"total_count": 0, "variables": []}' > "${OUTPUT_DIR}/org/actions-variables.json"
  VAR_COUNT=0
else
  echo "$VARS" | python3 -c "
import sys, json
d = json.load(sys.stdin)
out = {
    'total_count': d.get('total_count', 0),
    'variables': [{'name': v.get('name'), 'value': v.get('value'), 'visibility': v.get('visibility')} for v in d.get('variables', [])]
}
json.dump(out, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/org/actions-variables.json"
  VAR_COUNT=$(echo "$VARS" | pyjq 'print(d.get("total_count", 0) if d else 0)')
fi
echo "  Found ${VAR_COUNT} org-level variables."

# ---------------------------------------------------------------
# 6. Dependabot alerts summary
# ---------------------------------------------------------------
echo "[6/8] Dependabot alerts summary..."
python3 -c "
import json
for r in json.load(open('$REPOS_FILE')):
    print(r.get('name',''))
" | while read -r repo; do
  [ -z "$repo" ] && continue
  ALERTS=$(gh_api "repos/${ORG}/${repo}/dependabot/alerts?state=open&per_page=1" 2>/dev/null || echo "[]")
  ALERTS_IS_ERROR=$(echo "$ALERTS" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d else "no")')
  if [ "$ALERTS_IS_ERROR" = "yes" ]; then
    ALERT_COUNT="N/A"
  else
    ALERT_COUNT=$(echo "$ALERTS" | pyjq 'print(len(d) if isinstance(d, list) else 0)')
  fi
  echo "{\"repo\": \"${repo}\", \"open_alerts\": \"${ALERT_COUNT}\"}"
done | python3 -c "
import sys, json
lines = [line.strip() for line in sys.stdin if line.strip()]
out = []
for line in lines:
    try:
        out.append(json.loads(line))
    except:
        pass
json.dump(out, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/security/dependabot-summary.json"
echo "  Done."

# ---------------------------------------------------------------
# 7. Code scanning status
# ---------------------------------------------------------------
echo "[7/8] Code scanning status..."
python3 -c "
import json
for r in json.load(open('$REPOS_FILE')):
    print(r.get('name',''))
" | while read -r repo; do
  [ -z "$repo" ] && continue
  SCAN=$(gh_api "repos/${ORG}/${repo}/code-scanning/alerts?per_page=1" 2>/dev/null || echo '{"message":"not found"}')
  SCAN_IS_ERROR=$(echo "$SCAN" | pyjq 'print("yes" if isinstance(d, dict) and "message" in d else "no")')
  if [ "$SCAN_IS_ERROR" = "yes" ]; then
    STATUS="not_enabled"
  else
    STATUS="enabled"
  fi
  echo "{\"repo\": \"${repo}\", \"code_scanning\": \"${STATUS}\"}"
done | python3 -c "
import sys, json
lines = [line.strip() for line in sys.stdin if line.strip()]
out = []
for line in lines:
    try:
        out.append(json.loads(line))
    except:
        pass
json.dump(out, sys.stdout, indent=2)
print()
" > "${OUTPUT_DIR}/security/code-scanning-status.json"
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
  echo '```'
  echo ""

  echo "## Security Defaults (for new repos)"
  echo ""
  echo '```json'
  cat "${OUTPUT_DIR}/org/security-defaults.json"
  echo '```'
  echo ""

  echo "## Organization Rulesets (${RULESET_COUNT})"
  echo ""
  if [ "$RULESET_COUNT" -gt 0 ]; then
    echo "| Name | Enforcement | Target |"
    echo "|------|-------------|--------|"
    echo "$RULESETS" | pyjq '
for r in (d if isinstance(d, list) else []):
    print("| {} | {} | {} |".format(r.get("name",""), r.get("enforcement",""), r.get("target","")))
'
  else
    echo "No org-level rulesets configured."
  fi
  echo ""

  echo "## Per-Repo Compliance"
  echo ""
  echo "| Repo | Secret Scan | Push Protect | Branch Protect | CODEOWNERS | Rulesets |"
  echo "|------|------------|-------------|---------------|------------|---------|"

  python3 -c "
import json
for r in json.load(open('$REPOS_FILE')):
    print(r.get('name',''))
" | while read -r repo; do
    [ -z "$repo" ] && continue
    SS=$(python3 -c "
import json
try:
    d = json.load(open('${OUTPUT_DIR}/repos/${repo}/settings.json'))
    sa = d.get('security_and_analysis') or {}
    ss = (sa.get('secret_scanning') or {}).get('status', 'off')
    print(ss)
except:
    print('unknown')
")
    PP=$(python3 -c "
import json
try:
    d = json.load(open('${OUTPUT_DIR}/repos/${repo}/settings.json'))
    sa = d.get('security_and_analysis') or {}
    pp = (sa.get('secret_scanning_push_protection') or {}).get('status', 'off')
    print(pp)
except:
    print('unknown')
")
    BP_STATUS=$(python3 -c "
import json
try:
    d = json.load(open('${OUTPUT_DIR}/repos/${repo}/branch-protection.json'))
    print('no' if 'status' in d else 'yes')
except:
    print('unknown')
")
    CO=$(python3 -c "
import json
try:
    d = json.load(open('${OUTPUT_DIR}/repos/${repo}/codeowners.json'))
    print(d.get('codeowners_location', 'none'))
except:
    print('none')
")
    RS_COUNT=$(python3 -c "
import json
try:
    d = json.load(open('${OUTPUT_DIR}/repos/${repo}/rulesets.json'))
    print(len(d) if isinstance(d, list) else 0)
except:
    print(0)
")
    echo "| ${repo} | ${SS} | ${PP} | ${BP_STATUS} | ${CO} | ${RS_COUNT} |"
  done
  echo ""

  echo "## Teams (${TEAM_COUNT})"
  echo ""
  python3 -c "
import json
try:
    teams = json.load(open('${OUTPUT_DIR}/teams/teams.json'))
    for t in teams:
        desc = t.get('description') or 'no description'
        print('- **{}** ({}) — {}'.format(t.get('name',''), t.get('privacy',''), desc))
except:
    pass
"
  echo ""

  echo "## Organization Secrets (${SECRET_COUNT})"
  echo ""
  if [ "$SECRET_COUNT" -gt 0 ]; then
    python3 -c "
import json
try:
    d = json.load(open('${OUTPUT_DIR}/org/actions-secrets.json'))
    for s in d.get('secrets', []):
        print('- \`{}\` (visibility: {})'.format(s.get('name',''), s.get('visibility','')))
except:
    pass
"
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
RATE_INFO=$(gh_api "rate_limit" | python3 -c "
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
