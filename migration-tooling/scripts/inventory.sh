#!/usr/bin/env bash
# migration-tooling/scripts/inventory.sh
# Enumerates all repos in the source org and generates a manifest template.
#
# Usage: ./inventory.sh <source-org> [output-file]
# Requires: gh CLI authenticated to the source org

set -euo pipefail

SOURCE_ORG="${1:?Usage: $0 <source-org> [output-file]}"
OUTPUT="${2:-repo-manifest.yaml}"

echo "Fetching repos from ${SOURCE_ORG}..."

echo "repos:" > "$OUTPUT"

gh repo list "$SOURCE_ORG" \
  --limit 200 \
  --json name,description,visibility,defaultBranchRef,isArchived,hasWikiEnabled \
  --jq '.[] | select(.isArchived == false)' \
  | jq -s '.' \
  | jq -r '.[] | "  - name: \(.name)\n    description: \"\(.description // "")\"\n    visibility: \(.visibility | ascii_downcase)\n    default_branch: \(.defaultBranchRef.name // "main")\n    source: '"$SOURCE_ORG"'/\(.name)\n    target: CHANGEME-NEW-ORG/\(.name)\n    wave: 0  # CHANGEME: assign to wave 1-4\n    status: pending\n    type: unknown  # CHANGEME: aft-core | aft-customization | module | pipeline | other\n    ci_coupled: false  # CHANGEME\n    depends_on: []  # CHANGEME\n"' \
  >> "$OUTPUT"

echo ""
echo "Wrote ${OUTPUT} with $(grep -c '  - name:' "$OUTPUT") repos."
echo ""
echo "Next steps:"
echo "  1. Assign each repo to a wave (1-4)"
echo "  2. Set the type for each repo"
echo "  3. Set ci_coupled to true for repos with org-coupled CI/CD"
echo "  4. Add depends_on for repos with cross-repo Terraform module refs"
echo "  5. Replace CHANGEME-NEW-ORG with your target org name"
