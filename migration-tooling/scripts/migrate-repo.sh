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

# Step 4: Scan for org references and CodeStar Connection configs
echo "[4/6] Scanning for source org references..."
cd "$WORK_DIR"
git clone "https://github.com/${TARGET}.git" "${TARGET_REPO}"
cd "${TARGET_REPO}"

CHANGES_MADE=false

# Create migration branch upfront
git checkout -b "migration/update-org-refs"

# --- 4a: General org name references ---
REFS_FOUND=$(grep -rn "${SOURCE_ORG}" --include='*.tf' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.md' --include='*.hcl' . 2>/dev/null || true)
if [ -n "$REFS_FOUND" ]; then
  echo ""
  echo "Found references to source org '${SOURCE_ORG}':"
  echo "$REFS_FOUND"
  echo ""

  grep -rl "${SOURCE_ORG}" --include='*.tf' --include='*.yml' --include='*.yaml' --include='*.json' --include='*.hcl' . 2>/dev/null | while read -r file; do
    sed -i "s|${SOURCE_ORG}|${TARGET_ORG}|g" "$file"
  done
  CHANGES_MADE=true
else
  echo "No general org references found."
fi

# --- 4b: CodeStar Connection / github_org variable references ---
echo ""
echo "[5/6] Scanning for CodeStar Connection and github_org references..."

# Detect github_org assignments pointing to old org (in .tf and .tfvars)
GITHUB_ORG_REFS=$(grep -rn "github_org.*=.*\"${SOURCE_ORG}\"" --include='*.tf' --include='*.tfvars' --include='*.hcl' . 2>/dev/null || true)
if [ -n "$GITHUB_ORG_REFS" ]; then
  echo "Found github_org variable references to '${SOURCE_ORG}':"
  echo "$GITHUB_ORG_REFS"
  grep -rl "github_org.*=.*\"${SOURCE_ORG}\"" --include='*.tf' --include='*.tfvars' --include='*.hcl' . 2>/dev/null | while read -r file; do
    sed -i "s|github_org.*=.*\"${SOURCE_ORG}\"|github_org = \"${TARGET_ORG}\"|g" "$file"
  done
  CHANGES_MADE=true
fi

# Detect CodeStarSourceConnection FullRepositoryId referencing old org
CODESTAR_REFS=$(grep -rn "FullRepositoryId.*${SOURCE_ORG}/" --include='*.tf' --include='*.json' . 2>/dev/null || true)
if [ -n "$CODESTAR_REFS" ]; then
  echo ""
  echo "Found CodeStar FullRepositoryId references to '${SOURCE_ORG}':"
  echo "$CODESTAR_REFS"
  grep -rl "FullRepositoryId.*${SOURCE_ORG}/" --include='*.tf' --include='*.json' . 2>/dev/null | while read -r file; do
    sed -i "s|${SOURCE_ORG}/|${TARGET_ORG}/|g" "$file"
  done
  CHANGES_MADE=true
fi

# Detect pipeline source configs with Owner referencing old org
OWNER_REFS=$(grep -rn "Owner.*=.*\"${SOURCE_ORG}\"" --include='*.tf' . 2>/dev/null || true)
if [ -n "$OWNER_REFS" ]; then
  echo ""
  echo "Found pipeline Owner references to '${SOURCE_ORG}':"
  echo "$OWNER_REFS"
  grep -rl "Owner.*=.*\"${SOURCE_ORG}\"" --include='*.tf' . 2>/dev/null | while read -r file; do
    sed -i "s|Owner.*=.*\"${SOURCE_ORG}\"|Owner = \"${TARGET_ORG}\"|g" "$file"
  done
  CHANGES_MADE=true
fi

# Detect CodePipeline source configuration blocks with old org in repo field
REPO_REFS=$(grep -rn "\"${SOURCE_ORG}/[a-zA-Z0-9_-]*\"" --include='*.tf' --include='*.json' . 2>/dev/null || true)
if [ -n "$REPO_REFS" ]; then
  echo ""
  echo "Found repo ID references to '${SOURCE_ORG}':"
  echo "$REPO_REFS"
  # Already handled by the general replacement above, but flag for review
fi

# --- 4c: Flag items that need manual review ---
echo ""
echo "Checking for items that need manual review..."

# ConnectionArn references (these should NOT be auto-replaced — different ARN per org)
CONN_ARN_REFS=$(grep -rn "ConnectionArn\|connection_arn\|codestar.*arn" --include='*.tf' --include='*.tfvars' . 2>/dev/null || true)
if [ -n "$CONN_ARN_REFS" ]; then
  echo ""
  echo "MANUAL REVIEW NEEDED — ConnectionArn references found:"
  echo "$CONN_ARN_REFS"
  echo ""
  echo "  These reference CodeStar Connection ARNs. After migration, pipelines"
  echo "  should use the new org's connection ARN. If using the pipeline-source"
  echo "  module from org-governance, just update github_org — the ARN resolves"
  echo "  automatically. Otherwise, update the ARN manually."
fi

# Buildspec or pipeline config referencing old org in environment variables
ENV_REFS=$(grep -rn "GITHUB_ORG\|GH_ORG\|REPO_OWNER" --include='*.yml' --include='*.yaml' --include='*.json' --include='*.tf' . 2>/dev/null || true)
if [ -n "$ENV_REFS" ]; then
  echo ""
  echo "MANUAL REVIEW NEEDED — Environment variable references found:"
  echo "$ENV_REFS"
  echo ""
  echo "  These may contain org-specific values in buildspec or pipeline configs."
fi

# --- Commit and push if changes were made ---
git add -A
if git diff --cached --quiet; then
  echo ""
  echo "No changes to commit after reference update."
else
  git commit -m "chore: update org references and pipeline configs from ${SOURCE_ORG} to ${TARGET_ORG}

Updates:
- GitHub org name references
- github_org variable assignments
- CodeStar FullRepositoryId references
- Pipeline Owner references

NOTE: Review ConnectionArn and environment variable references manually."

  git push -u origin "migration/update-org-refs"
  echo ""
  echo "Migration branch pushed. Create a PR to review the changes:"
  echo "  gh pr create --repo ${TARGET} --base main --head migration/update-org-refs --title 'Update org references and pipeline configs post-migration'"
fi

# Step 6: Validation summary
echo ""
echo "[6/6] Migration summary:"
echo "  Source:  ${SOURCE}"
echo "  Target:  ${TARGET}"
echo "  Status:  Mirror complete"
echo ""
echo "Post-migration checklist:"
echo "  [ ] Verify org rulesets applied (check branch protection)"
echo "  [ ] Open test PR to validate review requirements"
echo "  [ ] Run CI/CD end-to-end"
echo "  [ ] Review and merge org reference update PR (if created)"
echo "  [ ] Review ConnectionArn references (if flagged above)"
echo "  [ ] Review environment variable references (if flagged above)"
echo "  [ ] Verify CodePipeline source triggers work with new connection"
echo "  [ ] Archive source repo when satisfied"
