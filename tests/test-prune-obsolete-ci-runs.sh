#!/usr/bin/env bash
# Offline tests for scripts/prune-obsolete-ci-runs.sh using a fake gh.
#
# The janitor cancels workflow runs, so the tests concentrate on the guard rails:
# it never touches the current main SHA, never touches an open PR head, never
# cancels a run whose identity changed after it was listed, needs the explicit
# flag for a running job on a merged PR, refuses repositories outside the
# allowlist, and does nothing at all in the default dry-run mode.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/prune-obsolete-ci-runs.sh"
DIR="$(mktemp -d)"
trap 'rm -rf -- "$DIR"' EXIT
mkdir -p "$DIR/bin" "$DIR/fixtures"

MAIN=1111111111111111111111111111111111111111
OLDMAIN=2222222222222222222222222222222222222222
OPENPR=3333333333333333333333333333333333333333
MERGED=4444444444444444444444444444444444444444

# --- fixtures ---------------------------------------------------------------
cat > "$DIR/fixtures/open.json" <<JSON
[{"head":{"ref":"open-branch","sha":"$OPENPR"}}]
JSON
cat > "$DIR/fixtures/closed.json" <<JSON
[{"merged_at":"2026-11-14T10:00:00Z","head":{"ref":"merged-branch","sha":"$MERGED"}}]
JSON
cat > "$DIR/fixtures/queued.json" <<JSON
{"workflow_runs":[
 {"id":1001,"status":"queued","event":"pull_request","head_branch":"stale-branch","head_sha":"aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa","workflow_id":11,"name":"ci-gate"},
 {"id":1002,"status":"queued","event":"pull_request","head_branch":"open-branch","head_sha":"$OPENPR","workflow_id":11,"name":"ci-gate"},
 {"id":1003,"status":"queued","event":"push","head_branch":"main","head_sha":"$OLDMAIN","workflow_id":12,"name":"ci-gate"},
 {"id":1004,"status":"queued","event":"push","head_branch":"main","head_sha":"$MAIN","workflow_id":12,"name":"ci-gate"}
]}
JSON
cat > "$DIR/fixtures/active.json" <<JSON
{"workflow_runs":[
 {"id":1005,"status":"in_progress","event":"pull_request","head_branch":"merged-branch","head_sha":"$MERGED","workflow_id":11,"name":"ci-gate"}
]}
JSON
cat > "$DIR/fixtures/latest.json" <<JSON
{"workflow_runs":[
 {"event":"push","head_branch":"main","head_sha":"$MAIN","workflow_id":12}
]}
JSON

# Per-run detail. 1004 is the current main run and must never be cancelled.
write_run() {
  local id=$1 branch=$2 sha=$3 wid=$4 event=$5 status=$6
  printf '{"id":%s,"head_branch":"%s","head_sha":"%s","workflow_id":%s,"event":"%s","status":"%s"}\n' \
    "$id" "$branch" "$sha" "$wid" "$event" "$status" > "$DIR/fixtures/run-$id.json"
}
write_run 1001 stale-branch aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaa 11 pull_request queued
write_run 1002 open-branch "$OPENPR" 11 pull_request queued
write_run 1003 main "$OLDMAIN" 12 push queued
write_run 1004 main "$MAIN" 12 push queued
write_run 1005 merged-branch "$MERGED" 11 pull_request in_progress

cat > "$DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
FIX="$MOCK_FIXTURES"
args="$*"
case "$args" in
  "auth status") exit 0 ;;
  *"/branches/main --jq .commit.sha") cat "$FIX/main-sha";;
  *"actions/runs/"*"/jobs?per_page=100")
    id="$(sed -E 's#.*actions/runs/([0-9]+)/jobs.*#\1#' <<< "$args")"
    printf '{"total_count":1,"jobs":[{"id":1,"status":"queued"}]}\n' > "$FIX/jobs-$id.json"
    cat "$FIX/jobs-$id.json";;
  *"actions/runs?"*"head_sha="*) cat "$FIX/latest.json";;
  *"pulls?state=open"*) cat "$FIX/open.json";;
  *"pulls?state=closed"*) cat "$FIX/closed.json";;
  *"actions/runs?status=queued"*) cat "$FIX/queued.json";;
  *"actions/runs?status=in_progress"*) cat "$FIX/active.json";;
  *"actions/runs/"*)
    id="$(sed -E 's#.*actions/runs/([0-9]+).*#\1#' <<< "$args")"
    if [[ "${MOCK_RUN_CHANGED:-}" == "$id" ]]; then
      printf '{"id":%s,"head_branch":"other","head_sha":"%s","workflow_id":9,"event":"push","status":"queued"}\n' \
        "$id" "bbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbbb"
    else
      cat "$FIX/run-$id.json"
    fi;;
  "run cancel "*)
    id="$(awk '{print $3}' <<< "$args")"
    echo "$id" >> "$FIX/cancelled"
    echo "✓ Requested cancellation of workflow run $id";;
  *) echo "fake gh: unexpected call: $args" >&2; exit 1 ;;
esac
MOCK
chmod +x "$DIR/bin/gh"
echo "$MAIN" > "$DIR/fixtures/main-sha"

run() {
  local label=$1 expected=$2 expected_cancels=$3
  shift 3
  rm -f "$DIR/fixtures/cancelled"
  set +e
  env PATH="$DIR/bin:$PATH" MOCK_FIXTURES="$DIR/fixtures" \
    bash "$SCRIPT" samkomane008/nabor "$@" > "$DIR/out" 2>&1
  local rc=$?
  set -e
  local cancels=0
  [[ -f "$DIR/fixtures/cancelled" ]] && cancels="$(wc -l < "$DIR/fixtures/cancelled")"
  if [[ "$rc" -ne "$expected" ]]; then
    echo "FAIL $label: expected exit $expected, got $rc"
    cat "$DIR/out"; exit 1
  fi
  if [[ "$cancels" -ne "$expected_cancels" ]]; then
    echo "FAIL $label: expected $expected_cancels cancellations, got $cancels"
    cat "$DIR/out"; exit 1
  fi
  echo "PASS $label (exit $rc, $cancels cancellations)"
}

# Dry run: lists the two cancellable runs and cancels nothing.
run dry-run 0 0 --dry-run
grep -q '^queued-pr | 1001' "$DIR/out" || { echo "FAIL: stale PR run not listed"; cat "$DIR/out"; exit 1; }
grep -q '^queued-old-main | 1003' "$DIR/out" || { echo "FAIL: stale main run not listed"; cat "$DIR/out"; exit 1; }
grep -q '1004' "$DIR/out" && { echo "FAIL: current main run was listed"; cat "$DIR/out"; exit 1; }
grep -q '1002' "$DIR/out" && { echo "FAIL: open PR run was listed"; cat "$DIR/out"; exit 1; }
grep -q 'DRY RUN' "$DIR/out" || { echo "FAIL: dry-run notice missing"; exit 1; }

# Apply: exactly the two stale runs, never the current main or an open PR head.
run apply 0 2 --apply
grep -qx '1001' "$DIR/fixtures/cancelled" || { echo "FAIL: stale PR run not cancelled"; exit 1; }
grep -qx '1003' "$DIR/fixtures/cancelled" || { echo "FAIL: stale main run not cancelled"; exit 1; }
grep -qE '^(1002|1004|1005)$' "$DIR/fixtures/cancelled" && { echo "FAIL: cancelled a protected run"; exit 1; }

# A running job on a merged PR needs the explicit flag.
rm -f "$DIR/fixtures/cancelled"
set +e
env PATH="$DIR/bin:$PATH" MOCK_FIXTURES="$DIR/fixtures" bash "$SCRIPT" samkomane008/nabor --apply > "$DIR/out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "FAIL merged-active-noflag exit $rc"; cat "$DIR/out"; exit 1; }
grep -q 'SKIP: include-merged-active required' "$DIR/out" || { echo "FAIL: running merged-PR job not skipped"; cat "$DIR/out"; exit 1; }
echo "PASS merged-active needs the flag"

# Identity changed between listing and cancelling: skip, do not cancel.
rm -f "$DIR/fixtures/cancelled"
set +e
env PATH="$DIR/bin:$PATH" MOCK_FIXTURES="$DIR/fixtures" MOCK_RUN_CHANGED=1001 \
  bash "$SCRIPT" samkomane008/nabor --apply > "$DIR/out" 2>&1
rc=$?
set -e
[[ $rc -eq 0 ]] || { echo "FAIL identity-change exit $rc"; cat "$DIR/out"; exit 1; }
grep -q 'SKIP: run identity changed' "$DIR/out" || { echo "FAIL: identity change not detected"; cat "$DIR/out"; exit 1; }
grep -qx '1001' "$DIR/fixtures/cancelled" 2>/dev/null && { echo "FAIL: cancelled a changed run"; exit 1; }
echo "PASS identity re-verification"

# Allowlist: a repository outside the two shared-runner repos is refused.
set +e
env PATH="$DIR/bin:$PATH" MOCK_FIXTURES="$DIR/fixtures" \
  bash "$SCRIPT" samkomane008/samloryx-infrastructure --dry-run > "$DIR/out" 2>&1
rc=$?
set -e
[[ $rc -eq 2 ]] || { echo "FAIL: non-allowlisted repo exit $rc (expected 2)"; cat "$DIR/out"; exit 1; }
echo "PASS allowlist refusal"

echo "prune-obsolete-ci-runs tests: PASS"
