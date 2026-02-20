#!/usr/bin/env bash
# check-prerequisites.sh — Validate environment before terraform init/plan/apply
# Run after: source proxy-env.sh
set -euo pipefail

PASS=0
FAIL=0
WARN=0

pass() { echo "  PASS  $1"; ((PASS++)); }
fail() { echo "  FAIL  $1"; ((FAIL++)); }
warn() { echo "  WARN  $1"; ((WARN++)); }

echo "=== org-governance prerequisite checks ==="
echo ""

# --- Required tools ---
echo "-- Tools --"
for cmd in terraform curl python3; do
  if command -v "$cmd" &>/dev/null; then
    pass "$cmd found ($(command -v "$cmd"))"
  else
    fail "$cmd not found in PATH"
  fi
done

# --- px-proxy ---
echo ""
echo "-- Proxy (px-proxy) --"
if pgrep -f "px --proxy" &>/dev/null || pgrep -f "px.pyz" &>/dev/null; then
  pass "px-proxy process running"
else
  fail "px-proxy not running — start it with: px --proxy"
fi

if curl -sf --max-time 5 -o /dev/null http://127.0.0.1:3128 2>/dev/null || \
   curl -sf --max-time 5 -x http://127.0.0.1:3128 -o /dev/null https://github.com 2>/dev/null; then
  pass "proxy at 127.0.0.1:3128 is reachable"
else
  fail "cannot connect through proxy at 127.0.0.1:3128"
fi

# --- Kerberos ticket ---
echo ""
echo "-- Kerberos --"
if command -v klist &>/dev/null; then
  if klist -s 2>/dev/null; then
    pass "valid Kerberos ticket found"
  else
    fail "no valid Kerberos ticket — run kinit"
  fi
else
  warn "klist not found — cannot verify Kerberos ticket"
fi

# --- Proxy connectivity to GitHub API ---
echo ""
echo "-- GitHub API connectivity --"
if [ -n "${HTTPS_PROXY:-}" ]; then
  pass "HTTPS_PROXY set ($HTTPS_PROXY)"
else
  fail "HTTPS_PROXY not set — source proxy-env.sh first"
fi

if curl -sf --max-time 10 -o /dev/null https://api.github.com/zen 2>/dev/null; then
  pass "api.github.com reachable through proxy"
else
  fail "api.github.com not reachable — check px-proxy and proxy config"
fi

# --- GITHUB_TOKEN ---
echo ""
echo "-- GitHub token --"
if [ -n "${GITHUB_TOKEN:-}" ]; then
  pass "GITHUB_TOKEN is set"
  # Validate token against API
  HTTP_CODE=$(curl -sf -o /dev/null -w "%{http_code}" \
    -H "Authorization: token ${GITHUB_TOKEN}" \
    https://api.github.com/user 2>/dev/null || true)
  if [ "$HTTP_CODE" = "200" ]; then
    pass "GITHUB_TOKEN is valid (authenticated to api.github.com)"
  else
    fail "GITHUB_TOKEN rejected by API (HTTP $HTTP_CODE)"
  fi
else
  fail "GITHUB_TOKEN not set — source proxy-env.sh first"
fi

# --- AWS credentials ---
echo ""
echo "-- AWS credentials --"
if [ -n "${AWS_ACCESS_KEY_ID:-}" ] || [ -n "${AWS_PROFILE:-}" ] || [ -n "${AWS_DEFAULT_PROFILE:-}" ]; then
  pass "AWS credentials configured"
else
  warn "no AWS_ACCESS_KEY_ID or AWS_PROFILE set — needed for aws/ module only"
fi

if command -v aws &>/dev/null; then
  if aws sts get-caller-identity &>/dev/null; then
    pass "AWS STS identity verified"
  else
    warn "aws sts get-caller-identity failed — AWS features may not work"
  fi
else
  warn "aws CLI not found — skipping STS check"
fi

# --- Terraform vars ---
echo ""
echo "-- Terraform variables --"
if [ -n "${TF_VAR_github_org:-}" ]; then
  pass "TF_VAR_github_org set ($TF_VAR_github_org)"
else
  fail "TF_VAR_github_org not set — source proxy-env.sh first"
fi

# --- Summary ---
echo ""
echo "=== Results: $PASS passed, $FAIL failed, $WARN warnings ==="
if [ "$FAIL" -gt 0 ]; then
  echo "Fix failures before running terraform."
  exit 1
else
  echo "Ready to proceed."
  exit 0
fi
