#!/usr/bin/env bash
# Dry-run-first cleanup for the two repositories sharing samloryx-ci's one-slot mutex.
# Never cancel an open PR's current commit, current main, or a deployment workflow.
set -Eeuo pipefail
usage() {
  echo 'Usage: bash scripts/prune-obsolete-ci-runs.sh <samkomane008/nabor|samkomane008/samloryx-os> [--dry-run|--apply] [--include-merged-active]' >&2
}
if (( $# < 1 || $# > 3 )); then usage; exit 2; fi
repo="$1"; shift
case "$repo" in samkomane008/nabor|samkomane008/samloryx-os) ;; *) usage; exit 2;; esac
mode=--dry-run; include_active=0
for arg in "$@"; do
  case "$arg" in
    --dry-run|--apply) mode="$arg";;
    --include-merged-active) include_active=1;;
    *) usage; exit 2;;
  esac
done
for cmd in gh jq; do command -v "$cmd" >/dev/null || exit 2; done
gh auth status >/dev/null
temp="$(mktemp -d)"
trap 'rm -rf -- "$temp"' EXIT
main="$(gh api "repos/$repo/branches/main" --jq '.commit.sha')"
[[ "$main" =~ ^[0-9a-f]{40}$ ]] || exit 1

pages() {
  gh api --paginate "$1" | jq -s --arg k "$3" \
    '[.[] | if $k == "array" then .[] else .[$k][] end]' > "$2"
}
pages "repos/$repo/pulls?state=open&per_page=100" "$temp/open" array
pages "repos/$repo/pulls?state=closed&per_page=100" "$temp/closed" array
pages "repos/$repo/actions/runs?status=queued&per_page=100" "$temp/queued" workflow_runs
pages "repos/$repo/actions/runs?status=in_progress&per_page=100" "$temp/active" workflow_runs
pages "repos/$repo/actions/runs?head_sha=$main&event=push&per_page=100" "$temp/latest" workflow_runs

jq -nr --slurpfile open "$temp/open" --slurpfile closed "$temp/closed" \
  --slurpfile queued "$temp/queued" --slurpfile active "$temp/active" \
  --slurpfile latest "$temp/latest" --arg main "$main" '
    ($open[0] | map(.head.ref + ":" + .head.sha)) as $openHeads |
    ($closed[0] | map(select(.merged_at != null) | .head.ref + ":" + .head.sha)) as $mergedHeads |
    ($latest[0] | map(select(.event == "push" and .head_branch == "main" and .head_sha == $main) | .workflow_id)) as $currentIds |
    (
      $queued[0][] as $r | select($r.status == "queued") |
      (
        if $r.event == "pull_request" and $r.head_branch != "main" then
          ($r.head_branch + ":" + $r.head_sha) as $key |
          if ($openHeads | index($key)) == null then "queued-pr" else empty end
        elif $r.event == "push" and $r.head_branch == "main" and $r.head_sha != $main then
          if ($currentIds | index($r.workflow_id)) != null then "queued-old-main" else empty end
        else empty end
      ) as $kind |
      [$kind, ($r.id | tostring), $r.head_branch, $r.head_sha, ($r.workflow_id | tostring), $r.name] | @tsv
    ),
    (
      $active[0][] as $r |
      select($r.status == "in_progress" and $r.event == "pull_request" and $r.head_branch != "main") |
      ($r.head_branch + ":" + $r.head_sha) as $key |
      select(($mergedHeads | index($key)) != null and ($openHeads | index($key)) == null) |
      ["merged-pr-active", ($r.id | tostring), $r.head_branch, $r.head_sha, ($r.workflow_id | tostring), $r.name] | @tsv
    )
  ' > "$temp/candidates"

echo "repo=$repo main=$main mode=$mode include_merged_active=$include_active"
echo "queued=$(jq length "$temp/queued") active=$(jq length "$temp/active") eligible=$(wc -l < "$temp/candidates")"
open_head_absent() {
  gh api --paginate "repos/$repo/pulls?state=open&per_page=100" |
    jq -s -e --arg branch "$1" --arg sha "$2" \
      'all(.[][]; .head.ref != $branch or .head.sha != $sha)' >/dev/null
}
merged_head_exists() {
  gh api --paginate "repos/$repo/pulls?state=closed&per_page=100" |
    jq -s -e --arg branch "$1" --arg sha "$2" \
      'any(.[][]; .merged_at != null and .head.ref == $branch and .head.sha == $sha)' >/dev/null
}
submitted=0
while IFS=$'\t' read -r kind id branch sha workflow_id workflow; do
  [[ -n "$id" ]] || continue
  printf '%s | %s | %s | %s\n' "$kind" "$id" "$sha" "$workflow"
  [[ "$mode" == --apply ]] || continue
  if [[ "$kind" == merged-pr-active && "$include_active" -ne 1 ]]; then
    echo '  SKIP: include-merged-active required for running jobs'
    continue
  fi
  if (( submitted >= 20 )); then echo 'BATCH LIMIT 20; review and rerun'; break; fi
  [[ "$(gh api "repos/$repo/branches/main" --jq '.commit.sha')" == "$main" ]] || { echo 'STOP: main changed' >&2; exit 1; }
  run="$(gh api "repos/$repo/actions/runs/$id")"
  jq -e --arg branch "$branch" --arg sha "$sha" --argjson wid "$workflow_id" \
    '.head_branch == $branch and .head_sha == $sha and .workflow_id == $wid' <<< "$run" >/dev/null || { echo '  SKIP: run identity changed'; continue; }
  case "$kind" in
    queued-pr)
      jq -e '.event == "pull_request" and .status == "queued"' <<< "$run" >/dev/null || { echo '  SKIP: run no longer queued'; continue; }
      open_head_absent "$branch" "$sha" || { echo '  SKIP: current open PR'; continue; }
      ;;
    queued-old-main)
      jq -e --arg main "$main" '.event == "push" and .status == "queued" and .head_branch == "main" and .head_sha != $main' <<< "$run" >/dev/null || { echo '  SKIP: no longer stale main'; continue; }
      latest="$(gh api --paginate "repos/$repo/actions/runs?head_sha=$main&event=push&per_page=100" | jq -s '[.[].workflow_runs[]]')"
      jq -e --arg main "$main" --argjson wid "$workflow_id" \
        'any(.[]; .event == "push" and .head_branch == "main" and .head_sha == $main and .workflow_id == $wid)' <<< "$latest" >/dev/null || { echo '  SKIP: no current-main replacement'; continue; }
      ;;
    merged-pr-active)
      jq -e '.event == "pull_request" and .status == "in_progress"' <<< "$run" >/dev/null || { echo '  SKIP: no longer running PR'; continue; }
      open_head_absent "$branch" "$sha" && merged_head_exists "$branch" "$sha" || { echo '  SKIP: merged PR not reverified'; continue; }
      ;;
  esac
  if [[ "$kind" != merged-pr-active ]]; then
    jobs="$(gh api "repos/$repo/actions/runs/$id/jobs?per_page=100")"
    jq -e '.total_count <= 100 and all(.jobs[]; .status != "in_progress")' <<< "$jobs" >/dev/null || { echo '  SKIP: active or incomplete job list'; continue; }
  fi
  if message="$(gh run cancel "$id" -R "$repo" 2>&1)"; then
    echo "  $message"
    submitted=$((submitted + 1))
  else
    state="$(gh api "repos/$repo/actions/runs/$id" --jq '.status')"
    [[ "$state" == completed ]] && { echo '  SKIP: completed concurrently'; continue; }
    echo "STOP: failed to cancel $id: $message" >&2
    exit 1
  fi
done < "$temp/candidates"
echo "Cancellation requests submitted: $submitted"
[[ "$mode" == --apply ]] || echo 'DRY RUN: no changes made.'
