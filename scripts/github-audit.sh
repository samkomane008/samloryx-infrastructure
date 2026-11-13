#!/usr/bin/env bash
# Read-only GitHub inventory. Output stays on this machine, under .local/.
set -euo pipefail
OWNER="${GITHUB_OWNER:-samkomane008}"
command -v gh >/dev/null || { echo "Install and authenticate GitHub CLI" >&2; exit 1; }
mkdir -p .local
chmod 700 .local

gh repo list "$OWNER" --limit 1000 --json name,visibility,defaultBranchRef > .local/repositories.json
chmod 600 .local/repositories.json

printf 'Repository count: '
gh repo list "$OWNER" --limit 1000 --json name --jq 'length'
printf 'repository\tworkflow_count\n' > .local/workflows.tsv

while IFS= read -r name; do
  [[ -n "$name" ]] || continue
  count="$(gh api "repos/$OWNER/$name/actions/workflows" --jq '.total_count' 2>/dev/null || printf 'unavailable')"
  printf '%s\t%s\n' "$name" "$count" >> .local/workflows.tsv
done < <(gh repo list "$OWNER" --limit 1000 --json name --jq '.[].name')

chmod 600 .local/workflows.tsv
printf 'Private local-only inventory saved to .local/repositories.json and .local/workflows.tsv\n'
printf 'DO NOT COMMIT .local/\n'
