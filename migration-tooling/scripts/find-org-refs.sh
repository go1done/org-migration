#!/usr/bin/env bash
# migration-tooling/scripts/find-org-refs.sh
# Scans a repo for references to the old org name.
#
# Usage: ./find-org-refs.sh <repo-path> <old-org-name>

set -euo pipefail

REPO_PATH="${1:?Usage: $0 <repo-path> <old-org-name>}"
OLD_ORG="${2:?Usage: $0 <repo-path> <old-org-name>}"

echo "Scanning ${REPO_PATH} for references to '${OLD_ORG}'..."
echo ""

RESULTS=$(grep -rn "$OLD_ORG" \
  --include='*.tf' \
  --include='*.tfvars' \
  --include='*.hcl' \
  --include='*.yml' \
  --include='*.yaml' \
  --include='*.json' \
  --include='*.md' \
  --include='*.sh' \
  --include='Makefile' \
  "$REPO_PATH" 2>/dev/null || true)

if [ -n "$RESULTS" ]; then
  echo "Found references:"
  echo "$RESULTS"
  echo ""
  echo "Total: $(echo "$RESULTS" | wc -l) occurrences"
else
  echo "No references found."
fi
