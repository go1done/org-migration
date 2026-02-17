#!/usr/bin/env bash
# migration-tooling/scripts/bulk-migrate.sh
# Migrates all repos in a given wave from repo-manifest.yaml.
#
# Usage: ./bulk-migrate.sh <wave-number> <manifest-file>
# Requires: yq, gh CLI, git

set -euo pipefail

WAVE="${1:?Usage: $0 <wave-number> <manifest-file>}"
MANIFEST="${2:?Usage: $0 <wave-number> <manifest-file>}"
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"

echo "=== Bulk Migration: Wave ${WAVE} ==="

REPOS=$(yq eval ".repos[] | select(.wave == ${WAVE} and .status == \"pending\")" "$MANIFEST")
if [ -z "$REPOS" ]; then
  echo "No pending repos found for wave ${WAVE}."
  exit 0
fi

REPO_COUNT=$(yq eval "[.repos[] | select(.wave == ${WAVE} and .status == \"pending\")] | length" "$MANIFEST")
echo "Found ${REPO_COUNT} repos to migrate in wave ${WAVE}."
echo ""

INDEX=0
yq eval -o=json ".repos[] | select(.wave == ${WAVE} and .status == \"pending\")" "$MANIFEST" | jq -c '.' | while read -r repo; do
  INDEX=$((INDEX + 1))
  NAME=$(echo "$repo" | jq -r '.name')
  SOURCE=$(echo "$repo" | jq -r '.source')
  TARGET=$(echo "$repo" | jq -r '.target')

  echo "--- [${INDEX}/${REPO_COUNT}] Migrating: ${NAME} ---"

  # Update status to migrating
  yq eval -i "(.repos[] | select(.name == \"${NAME}\")).status = \"migrating\"" "$MANIFEST"

  if "${SCRIPT_DIR}/migrate-repo.sh" "$SOURCE" "$TARGET"; then
    yq eval -i "(.repos[] | select(.name == \"${NAME}\")).status = \"migrated\"" "$MANIFEST"
    echo "SUCCESS: ${NAME} migrated."
  else
    yq eval -i "(.repos[] | select(.name == \"${NAME}\")).status = \"failed\"" "$MANIFEST"
    echo "FAILED: ${NAME} migration failed. Continuing with remaining repos."
  fi
  echo ""
done

echo "=== Wave ${WAVE} Complete ==="
echo "Results:"
yq eval ".repos[] | select(.wave == ${WAVE}) | .name + \": \" + .status" "$MANIFEST"
