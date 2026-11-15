#!/usr/bin/env bash
# Fail-closed owner-operated PR merge guard for GitHub Free private repositories.
# IMPORTANT: This does not enforce server-side branch protection. Authorized
# writers can still bypass the guard via the GitHub UI or direct pushes.
set -Eeuo pipefail

usage() {
  cat <<'HELP'
Usage: bash scripts/guarded-merge.sh --repo samkomane008/{nabor|samloryx-os} --pr NUMBER [--dry-run|--apply]
Defaults to --dry-run. --apply merges via GitHub only after exact-head checks pass.
Does not mark draft PRs ready, disable checks, change deployment settings, or force-merge.
HELP
}
repo='' pr='' mode=dry-run
while (($#)); do
  case "$1" in
    --repo) (($# >= 2)) || { usage >&2; exit 2; }; repo=$2; shift 2;;
    --pr) (($# >= 2)) || { usage >&2; exit 2; }; pr=$2; shift 2;;
    --dry-run) mode=dry-run; shift;;
    --apply) mode=apply; shift;;
    -h|--help) usage; exit 0;;
    *) echo "Unknown argument: $1" >&2; usage >&2; exit 2;;
  esac
done
[[ "$repo" == 'samkomane008/nabor' || "$repo" == 'samkomane008/samloryx-os' ]] || {
  echo 'STOP: unsupported repo; explicitly add and review its mandatory checks first' >&2; exit 2;
}
[[ "$pr" =~ ^[1-9][0-9]*$ ]] || { echo 'STOP: --pr must be a positive integer' >&2; exit 2; }
for cmd in gh jq; do command -v "$cmd" >/dev/null || { echo "STOP: missing $cmd" >&2; exit 2; }; done

fatal() { echo "STOP: $*" >&2; exit 1; }
main_sha() { gh api "repos/$repo/branches/main" --jq '.commit.sha'; }
pr_data() { gh api "repos/$repo/pulls/$pr"; }
checks_data() { gh api "repos/$repo/commits/$head/check-runs?per_page=100"; }

base=$(main_sha)
[[ "$base" =~ ^[a-f0-9]{40}$ ]] || fatal 'Could not resolve the exact main SHA'
payload=$(pr_data)
head=$(jq -r '.head.sha // empty' <<< "$payload")
[[ "$head" =~ ^[a-f0-9]{40}$ ]] || fatal 'Could not resolve an exact PR head SHA'

verify_pr() {
  local d=$1
  jq -e --arg head "$head" --arg base "$base" '
    .state == "open" and .draft == false and .base.ref == "main"
    and .head.sha == $head and .base.sha == $base
    and .mergeable == true and .mergeable_state == "clean"
  ' <<< "$d" >/dev/null || fatal 'PR draft, changed, conflicted, or not cleanly mergeable into current main'
}

# Workflows are repository-specific. Check the expected names, never just an
# aggregate "green" label. Sonar is path-scoped on Samloryx OS.
required=()
if [[ "$repo" == 'samkomane008/nabor' ]]; then
  required=(
    'Format, lint, typecheck, test, build and OSV'
    'scan'
    'SonarCloud Code Analysis'
  )
else
  required=(
    'platform-build' 'web-build' 'marketing-build' 'mobile-typecheck'
    'semgrep (the code itself)' 'osv (known vulnerable dependencies)'
    'gitleaks (credentials in the history)'
  )
  changed=$(gh api --paginate "repos/$repo/pulls/$pr/files?per_page=100" --jq '.[].filename')
  if grep -Eq '^(apps/platform/|\.github/workflows/sonarcloud\.yml$)' <<< "$changed"; then
    required+=('scan' 'SonarCloud Code Analysis')
  fi
fi
verify_checks() {
  local d
  d=$(checks_data)
  jq -e --arg head "$head" '
    .total_count > 0 and .total_count == (.check_runs | length)
    and all(.check_runs[]; .head_sha == $head
      and .status == "completed" and .conclusion == "success")
  ' <<< "$d" >/dev/null || fatal 'Missing, extra-paged, pending, cancelled, skipped, or failed check run'
  local n
  for n in "${required[@]}"; do
    jq -e --arg name "$n" '
      any(.check_runs[]; .name == $name and .status == "completed" and .conclusion == "success")
    ' <<< "$d" >/dev/null || fatal "Mandatory check absent or not green: $n"
  done
  # Check legacy commit statuses as well, if any exist.
  local old
  old=$(gh api "repos/$repo/commits/$head/status")
  jq -e '(.statuses | length) == 0 or .state == "success"' <<< "$old" >/dev/null \
    || fatal 'Legacy GitHub commit status is not successful'
}

verify_pr "$payload"
verify_checks
printf 'PASS: %s PR #%s\n  head: %s\n  main: %s\n  mandatory checks: %s\n' \
  "$repo" "$pr" "$head" "$base" "${required[*]}"

if [[ "$mode" == dry-run ]]; then
  echo 'DRY RUN: no merge performed. Use --apply only after reviewing this exact PR.'
  exit 0
fi

# Re-read current state immediately before the merge; the API `sha` parameter
# rejects a changed PR head. GitHub Free still cannot prevent a direct push.
[[ "$(main_sha)" == "$base" ]] || fatal 'Main advanced; rerun review'
verify_pr "$(pr_data)"
verify_checks
[[ "$(main_sha)" == "$base" ]] || fatal 'Main advanced before merge; rerun review'
result=$(gh api --method PUT "repos/$repo/pulls/$pr/merge" \
  -f "sha=$head" -f 'merge_method=merge')
jq -e '.merged == true' <<< "$result" >/dev/null || fatal 'GitHub did not confirm a successful merge'
jq -r '"MERGED: " + .sha' <<< "$result"
