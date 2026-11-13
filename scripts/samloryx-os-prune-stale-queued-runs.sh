#!/usr/bin/env bash
# List/cancel only obsolete QUEUED pull_request runs for Samloryx OS.
# Never cancel in-progress, main, or any current open PR head. Dry-run by default.
set -Eeuo pipefail
REPO=samkomane008/samloryx-os
MODE="${1:---dry-run}"
if [[ "$MODE" != --dry-run && "$MODE" != --apply ]]; then
  echo "Usage: $0 [--dry-run|--apply]" >&2
  exit 2
fi
for bin in gh jq; do
  command -v "$bin" >/dev/null || { echo "Missing $bin" >&2; exit 2; }
done
gh auth status >/dev/null
tmp="$(mktemp -d)"
trap 'rm -rf "$tmp"' EXIT

gh api "repos/$REPO/pulls?state=open&per_page=100" > "$tmp/prs.json"
gh api "repos/$REPO/actions/runs?status=queued&per_page=100" > "$tmp/runs.json"
pr_count="$(jq 'length' "$tmp/prs.json")"
total="$(jq '.total_count' "$tmp/runs.json")"
if (( pr_count >= 100 || total > 100 )); then
  echo 'STOP: API pagination needed; refusing to use incomplete data.' >&2
  exit 3
fi
echo "Open PRs: $pr_count | queued runs: $total | mode: $MODE"

jq -nr --slurpfile prs "$tmp/prs.json" --slurpfile runs "$tmp/runs.json" '
  ($prs[0] | map(.head.ref + ":" + .head.sha)) as $current |
  $runs[0].workflow_runs[] |
  select(.status == "queued" and .event == "pull_request" and .head_branch != "main") |
  (.head_branch + ":" + .head_sha) as $key |
  select(($current | index($key)) == null) |
  [(.id | tostring), .head_branch, .head_sha, .name] | @tsv
' > "$tmp/stale.tsv"

count="$(wc -l < "$tmp/stale.tsv")"
echo "Obsolete queued PR workflow runs: $count"
while IFS=$'\t' read -r run_id branch sha workflow; do
  [[ -n "$run_id" ]] || continue
  echo "$run_id | $workflow | $branch | $(printf '%.12s' "$sha")"
  if [[ "$MODE" == --apply ]]; then
    # Never cancel an active job. Recheck exact target before each request.
    latest="$(gh api "repos/$REPO/actions/runs/$run_id" --jq '[.status,.event,.head_branch,.head_sha]|@tsv')"
    expected="$(printf 'queued\tpull_request\t%s\t%s' "$branch" "$sha")"
    if [[ "$latest" != "$expected" ]]; then
      echo '  SKIP: run state or target changed'
      continue
    fi
    fresh_count="$(gh api "repos/$REPO/pulls?state=open&per_page=100" |
      jq --arg branch "$branch" --arg sha "$sha" '
        [.[] | select(.head.ref == $branch and .head.sha == $sha)] | length')"
    if [[ "$fresh_count" != 0 ]]; then
      echo '  SKIP: exact head now belongs to an open PR'
      continue
    fi
    gh run cancel "$run_id" --repo "$REPO"
  fi
done < "$tmp/stale.tsv"
if [[ "$MODE" == --dry-run ]]; then
  echo 'No changes made. Review the list; use --apply for eligible stale runs.'
else
  echo 'Cancellation requests submitted for still-eligible stale queued runs.'
fi
