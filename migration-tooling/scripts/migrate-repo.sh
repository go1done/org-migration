#!/usr/bin/env bash
# migration-tooling/scripts/migrate-repo.sh
# Mirrors a single repo from source org to target org.
#
# DUAL-ORG MODEL: Both orgs coexist permanently. Some repos move to the new
# org, some stay. Repos in the new org may source modules from repos that
# remain in the old org. This script does NOT blindly replace all old-org
# references — it only updates SELF-references (this repo's own org) and
# flags cross-org references for manual review.
#
# Usage: ./migrate-repo.sh <source-org/repo> <target-org/repo> [manifest-file]
# Requires: gh CLI, git, authenticated to both orgs
# Optional: yq (if manifest-file provided, used to read depends_on for cross-org detection)

set -euo pipefail

SOURCE="${1:?Usage: $0 <source-org/repo> <target-org/repo> [manifest-file]}"
TARGET="${2:?Usage: $0 <source-org/repo> <target-org/repo> [manifest-file]}"
MANIFEST="${3:-}"

SOURCE_ORG="${SOURCE%%/*}"
SOURCE_REPO="${SOURCE##*/}"
TARGET_ORG="${TARGET%%/*}"
TARGET_REPO="${TARGET##*/}"

WORK_DIR=$(mktemp -d)
trap 'rm -rf "$WORK_DIR"' EXIT

echo "=== Migration: ${SOURCE} -> ${TARGET} ==="
echo "    Mode: Dual-org coexistence (both orgs remain active)"

# Build list of repos that are staying in the old org (if manifest provided)
STAYING_REPOS=""
if [ -n "$MANIFEST" ] && command -v yq &> /dev/null; then
  # Repos with wave: 0 or status: skip are staying in the old org
  STAYING_REPOS=$(yq eval '.repos[] | select(.wave == 0 or .status == "skip") | .name' "$MANIFEST" 2>/dev/null || true)
  if [ -n "$STAYING_REPOS" ]; then
    echo "    Repos staying in old org (from manifest): $(echo "$STAYING_REPOS" | wc -l) repos"
  fi
fi

# Step 1: Pre-flight checks
echo ""
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

# Step 4: Analyze org references (classify, don't blindly replace)
echo "[4/5] Analyzing org references..."
cd "$WORK_DIR"
git clone "https://github.com/${TARGET}.git" "${TARGET_REPO}"
cd "${TARGET_REPO}"

git checkout -b "migration/update-org-refs"

ALL_REFS=$(grep -rn "${SOURCE_ORG}" \
  --include='*.tf' --include='*.tfvars' --include='*.hcl' \
  --include='*.yml' --include='*.yaml' --include='*.json' \
  . 2>/dev/null || true)

if [ -z "$ALL_REFS" ]; then
  echo "No references to '${SOURCE_ORG}' found. Nothing to update."
else
  echo ""
  echo "Found references to '${SOURCE_ORG}'. Classifying..."
  echo ""

  # ---------------------------------------------------------------
  # SELF-REFERENCES: This repo referring to itself in the old org.
  # These are safe to auto-replace.
  # ---------------------------------------------------------------
  echo "--- Self-references (auto-replace) ---"

  # This repo's own URL (e.g., github.com/old-org/this-repo)
  SELF_REFS=$(grep -rn "github\.com/${SOURCE_ORG}/${SOURCE_REPO}" \
    --include='*.tf' --include='*.tfvars' --include='*.hcl' \
    --include='*.yml' --include='*.yaml' --include='*.json' \
    . 2>/dev/null || true)
  if [ -n "$SELF_REFS" ]; then
    echo "  Self-repo URL references:"
    echo "$SELF_REFS"
    grep -rl "github\.com/${SOURCE_ORG}/${SOURCE_REPO}" \
      --include='*.tf' --include='*.tfvars' --include='*.hcl' \
      --include='*.yml' --include='*.yaml' --include='*.json' \
      . 2>/dev/null | while read -r file; do
      sed -i "s|github\.com/${SOURCE_ORG}/${SOURCE_REPO}|github.com/${TARGET_ORG}/${TARGET_REPO}|g" "$file"
    done
  fi

  # github_org variable set to old org (this repo's own pipeline config)
  GITHUB_ORG_REFS=$(grep -rn "github_org\s*=\s*\"${SOURCE_ORG}\"" \
    --include='*.tf' --include='*.tfvars' --include='*.hcl' \
    . 2>/dev/null || true)
  if [ -n "$GITHUB_ORG_REFS" ]; then
    echo "  github_org variable assignments:"
    echo "$GITHUB_ORG_REFS"
    echo ""
    echo "  NOTE: Only replacing github_org for THIS repo's own pipeline."
    echo "  Cross-org module sources are left intact (see below)."
    # Only replace in tfvars and pipeline config, not in module source blocks
    grep -rl "github_org\s*=\s*\"${SOURCE_ORG}\"" \
      --include='*.tfvars' \
      . 2>/dev/null | while read -r file; do
      sed -i "s|github_org\s*=\s*\"${SOURCE_ORG}\"|github_org = \"${TARGET_ORG}\"|g" "$file"
    done
  fi

  # FullRepositoryId for THIS repo specifically
  SELF_FULLREPO=$(grep -rn "FullRepositoryId.*\"${SOURCE_ORG}/${SOURCE_REPO}\"" \
    --include='*.tf' --include='*.json' \
    . 2>/dev/null || true)
  if [ -n "$SELF_FULLREPO" ]; then
    echo "  FullRepositoryId self-references:"
    echo "$SELF_FULLREPO"
    grep -rl "FullRepositoryId.*\"${SOURCE_ORG}/${SOURCE_REPO}\"" \
      --include='*.tf' --include='*.json' \
      . 2>/dev/null | while read -r file; do
      sed -i "s|${SOURCE_ORG}/${SOURCE_REPO}|${TARGET_ORG}/${TARGET_REPO}|g" "$file"
    done
  fi

  # ---------------------------------------------------------------
  # CROSS-ORG REFERENCES: This repo referencing OTHER repos in old org.
  # These must be reviewed — the referenced repo may be staying.
  # DO NOT auto-replace.
  # ---------------------------------------------------------------
  echo ""
  echo "--- Cross-org references (MANUAL REVIEW REQUIRED) ---"

  # Terraform module sources pointing to old org (but not this repo)
  MODULE_REFS=$(grep -rn "source.*=.*\"git::https://github\.com/${SOURCE_ORG}/" \
    --include='*.tf' --include='*.hcl' \
    . 2>/dev/null | grep -v "/${SOURCE_REPO}" || true)
  if [ -n "$MODULE_REFS" ]; then
    echo ""
    echo "  Terraform module sources referencing other repos in '${SOURCE_ORG}':"
    echo "$MODULE_REFS"
    echo ""
    echo "  ACTION: For each module source, determine if the referenced repo is:"
    echo "    - MIGRATING to new org -> update source URL to ${TARGET_ORG}"
    echo "    - STAYING in old org   -> leave as-is (cross-org reference is correct)"
  else
    echo "  No cross-org Terraform module sources found."
  fi

  # FullRepositoryId for OTHER repos in old org
  OTHER_FULLREPO=$(grep -rn "FullRepositoryId.*\"${SOURCE_ORG}/" \
    --include='*.tf' --include='*.json' \
    . 2>/dev/null | grep -v "/${SOURCE_REPO}" || true)
  if [ -n "$OTHER_FULLREPO" ]; then
    echo ""
    echo "  FullRepositoryId references to other repos in '${SOURCE_ORG}':"
    echo "$OTHER_FULLREPO"
    echo ""
    echo "  ACTION: For each reference, determine if the repo is migrating or staying."
    echo "    - If migrating: update org to ${TARGET_ORG}"
    echo "    - If staying: leave as-is, ensure old org's CodeStar Connection is used"
  fi

  # Any remaining old-org references not yet classified
  REMAINING=$(grep -rn "${SOURCE_ORG}" \
    --include='*.tf' --include='*.tfvars' --include='*.hcl' \
    --include='*.yml' --include='*.yaml' --include='*.json' \
    . 2>/dev/null || true)
  if [ -n "$REMAINING" ]; then
    echo ""
    echo "  Remaining references to '${SOURCE_ORG}' (review each):"
    echo "$REMAINING"
    echo ""
    echo "  These may be intentional cross-org references. Do NOT auto-replace."
  fi

  # ---------------------------------------------------------------
  # CONNECTION REFERENCES: Flag but never auto-replace.
  # Both connections stay active permanently.
  # ---------------------------------------------------------------
  echo ""
  echo "--- CodeStar Connection references (KEEP BOTH) ---"

  CONN_REFS=$(grep -rn "ConnectionArn\|connection_arn\|codestar.*arn" \
    --include='*.tf' --include='*.tfvars' \
    . 2>/dev/null || true)
  if [ -n "$CONN_REFS" ]; then
    echo "$CONN_REFS"
    echo ""
    echo "  Both CodeStar Connections remain active. Pipelines that source from"
    echo "  repos in ${SOURCE_ORG} must use the old connection. Pipelines that"
    echo "  source from repos in ${TARGET_ORG} use the new connection."
    echo "  If using the pipeline-source module, set github_org per source repo."
  else
    echo "  No ConnectionArn references found."
  fi

  # Env vars that may contain org names
  ENV_REFS=$(grep -rn "GITHUB_ORG\|GH_ORG\|REPO_OWNER" \
    --include='*.yml' --include='*.yaml' --include='*.json' --include='*.tf' \
    . 2>/dev/null || true)
  if [ -n "$ENV_REFS" ]; then
    echo ""
    echo "  Environment variable references (review for org-specific values):"
    echo "$ENV_REFS"
  fi
fi

# --- Commit and push if changes were made ---
git add -A
if git diff --cached --quiet; then
  echo ""
  echo "No auto-replaceable changes found."
  # Still push the branch if there are manual review items
  git checkout main 2>/dev/null || git checkout master 2>/dev/null
  git branch -D "migration/update-org-refs"
else
  git commit -m "chore: update self-references from ${SOURCE_ORG} to ${TARGET_ORG}

Auto-replaced:
- This repo's own URL references (${SOURCE_ORG}/${SOURCE_REPO} -> ${TARGET_ORG}/${TARGET_REPO})
- github_org variable in tfvars (for this repo's own pipeline)
- FullRepositoryId for this repo

NOT replaced (requires manual review):
- Cross-org module sources (referenced repos may stay in ${SOURCE_ORG})
- FullRepositoryId for other repos (may stay in ${SOURCE_ORG})
- ConnectionArn references (both connections remain active)
- Environment variables with org references"

  git push -u origin "migration/update-org-refs"
  echo ""
  echo "Migration branch pushed. Create a PR to review:"
  echo "  gh pr create --repo ${TARGET} --base main --head migration/update-org-refs --title 'Update self-references post-migration (review cross-org refs)'"
fi

# Step 5: Validation summary
echo ""
echo "[5/5] Migration summary:"
echo "  Source:   ${SOURCE}"
echo "  Target:   ${TARGET}"
echo "  Model:    Dual-org coexistence"
echo "  Status:   Mirror complete"
echo ""
echo "Post-migration checklist:"
echo "  [ ] Verify org rulesets applied (check branch protection)"
echo "  [ ] Open test PR to validate review requirements"
echo "  [ ] Review migration PR — check cross-org references carefully"
echo "  [ ] For each Terraform module source referencing ${SOURCE_ORG}:"
echo "      - If referenced repo is migrating: update to ${TARGET_ORG}"
echo "      - If referenced repo is staying: leave as-is"
echo "  [ ] For pipelines with multiple source repos:"
echo "      - Use old-org connection for repos staying in ${SOURCE_ORG}"
echo "      - Use new-org connection for repos moved to ${TARGET_ORG}"
echo "  [ ] Run terraform plan — confirm no unexpected changes"
echo "  [ ] Run CI/CD end-to-end"
echo "  [ ] Do NOT archive source repo if other repos still reference it"
