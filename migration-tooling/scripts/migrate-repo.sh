#!/usr/bin/env bash
# migration-tooling/scripts/migrate-repo.sh
# Mirrors a single repo from source org to target org.
#
# Usage: ./migrate-repo.sh <source-org/repo> <target-org/repo>
# Requires: gh CLI, git, authenticated to both orgs

set -euo pipefail

SOURCE="${1:?Usage: $0 <source-org/repo> <target-org/repo>}"
TARGET="${2:?Usage: $0 <source-org/repo> <target-org/repo>}"

SOURCE_ORG="${SOURCE%%/*}"
SOURCE_REPO="${SOURCE##*/}"
TARGET_ORG="${TARGET%%/*}"
TARGET_REPO="${TARGET##*/}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Migration: ${SOURCE} -> ${TARGET} ==="

# Step 1: Pre-flight checks
echo "[1/5] Pre-flight checks..."
if ! gh repo view "$SOURCE" --json name -q '.name' > /dev/null 2>&1; then
  echo "ERROR: Source repo ${SOURCE} not found or not accessible"
  exit 1
fi

if ! gh repo view "$TARGET" --json name -q '.name' > /dev/null 2>&1; then
  echo "ERROR: Target repo ${TARGET} not found. Create it via Terraform first."
  exit 1
fi

# Step 2: Mirror clone
echo "[2/5] Cloning ${SOURCE} (mirror)..."
git clone --mirror "https://github.com/${SOURCE}.git" "${WORK_DIR}/${SOURCE_REPO}.git"

# Step 3: Push mirror to target
echo "[3/5] Pushing mirror to ${TARGET}..."
cd "${WORK_DIR}/${SOURCE_REPO}.git"
git push --mirror "https://github.com/${TARGET}.git"

# Step 4: Scan for org references
echo "[4/5] Scanning for source org references..."
cd "$WORK_DIR"
git clone "https://github.com/${TARGET}.git" "${TARGET_REPO}"
cd "${TARGET_REPO}"

REFS_FOUND=$(grep -rn "${SOURCE_ORG}" --include='*.tf' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.md' --include='*.hcl' . 2>/dev/null || true)
if [ -n "$REFS_FOUND" ]; then
  echo ""
  echo "WARNING: Found references to source org '${SOURCE_ORG}':"
  echo "$REFS_FOUND"
  echo ""
  echo "These need to be updated to '${TARGET_ORG}' in a migration PR."

  # Create migration branch with automated replacements
  git checkout -b "migration/update-org-refs"
  grep -rl "${SOURCE_ORG}" --include='*.tf' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.hcl' . 2>/dev/null | while read -r file; do
    sed -i "s|${SOURCE_ORG}|${TARGET_ORG}|g" "$file"
  done
  git add -A
  if git diff --cached --quiet; then
    echo "No changes to commit after reference update."
  else
    git commit -m "chore: update org references from ${SOURCE_ORG} to ${TARGET_ORG}"
    git push -u origin "migration/update-org-refs"
    echo ""
    echo "Migration branch pushed. Create a PR to review the changes:"
    echo "  gh pr create --repo ${TARGET} --base main --head migration/update-org-refs --title 'Update org references post-migration'"
  fi
else
  echo "No source org references found."
fi

# Step 5: Validation summary
echo ""
echo "[5/5] Migration summary:"
echo "  Source:  ${SOURCE}"
echo "  Target:  ${TARGET}"
echo "  Status:  Mirror complete"
echo ""
echo "Post-migration checklist:"
echo "  [ ] Verify org rulesets applied (check branch protection)"
echo "  [ ] Open test PR to validate review requirements"
echo "  [ ] Run CI/CD end-to-end"
echo "  [ ] Review and merge org reference update PR (if created)"
echo "  [ ] Archive source repo when satisfied"
