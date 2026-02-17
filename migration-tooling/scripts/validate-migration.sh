#!/usr/bin/env bash
# migration-tooling/scripts/validate-migration.sh
# Validates a migrated repo meets compliance requirements.
#
# Usage: ./validate-migration.sh <org/repo>
# Requires: gh CLI

set -euo pipefail

REPO="${1:?Usage: $0 <org/repo>}"

echo "=== Validating: ${REPO} ==="

PASS=0
FAIL=0

check() {
  local name="$1" result="$2"
  if [ "$result" = "true" ] || [ "$result" = "PASS" ]; then
    echo "  [PASS] ${name}"
    PASS=$((PASS + 1))
  else
    echo "  [FAIL] ${name}"
    FAIL=$((FAIL + 1))
  fi
}

# Check vulnerability alerts
VULN=$(gh api "repos/${REPO}" --jq '.security_and_analysis.secret_scanning.status' 2>/dev/null || echo "disabled")
check "Secret scanning enabled" "$([ "$VULN" = "enabled" ] && echo true || echo false)"

# Check push protection
PUSH_PROT=$(gh api "repos/${REPO}" --jq '.security_and_analysis.secret_scanning_push_protection.status' 2>/dev/null || echo "disabled")
check "Push protection enabled" "$([ "$PUSH_PROT" = "enabled" ] && echo true || echo false)"

# Check default branch protection (via rulesets)
RULESETS=$(gh api "repos/${REPO}/rulesets" --jq 'length' 2>/dev/null || echo "0")
check "Rulesets applied (count: ${RULESETS})" "$([ "$RULESETS" -gt 0 ] && echo true || echo false)"

# Check CODEOWNERS exists
CODEOWNERS=$(gh api "repos/${REPO}/contents/CODEOWNERS" --jq '.name' 2>/dev/null || \
  gh api "repos/${REPO}/contents/.github/CODEOWNERS" --jq '.name' 2>/dev/null || echo "")
check "CODEOWNERS file exists" "$([ -n "$CODEOWNERS" ] && echo true || echo false)"

# Check topics
TOPICS=$(gh api "repos/${REPO}" --jq '.topics | length' 2>/dev/null || echo "0")
check "Topics assigned (count: ${TOPICS})" "$([ "$TOPICS" -gt 0 ] && echo true || echo false)"

echo ""
echo "Results: ${PASS} passed, ${FAIL} failed"
[ "$FAIL" -eq 0 ] && echo "Status: ALL CHECKS PASSED" || echo "Status: SOME CHECKS FAILED"
exit "$FAIL"
