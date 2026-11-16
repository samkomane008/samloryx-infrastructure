#!/usr/bin/env bash
# Hermetic tests of the server release gate. No network: curl is a mock.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
WORK="$(mktemp -d)"
trap 'rm -rf "$WORK"' EXIT
BIN="$WORK/bin"
mkdir -p "$BIN"

cat > "$BIN/curl" <<'MOCK'
#!/usr/bin/env bash
set -Eeuo pipefail
url="${*: -1}"
# The token must arrive on stdin, never on the command line.
for a in "$@"; do [[ "$a" != *"$TEST_TOKEN"* ]] || { echo 'token leaked into argv' >&2; exit 97; }; done
grep -q "Authorization: Bearer $TEST_TOKEN" || { echo 'token missing from stdin' >&2; exit 98; }
[[ "$url" == https://api.github.com/repos/samkomane008/example/* ]] || { echo "unexpected url $url" >&2; exit 99; }
case "$url" in
  */git/ref/heads/main)
    n=$(( $(cat "$STATE/main_calls" 2>/dev/null || echo 0) + 1 )); echo "$n" > "$STATE/main_calls"
    head="$TEST_SHA"
    [[ "$CASE" == wrong_main ]] && head="$(printf 'f%.0s' {1..40})"
    [[ "$CASE" == main_moves && $n -gt 1 ]] && head="$(printf 'e%.0s' {1..40})"
    printf '{"object":{"sha":"%s"}}\n' "$head" ;;
  */pulls\?*)
    [[ "$CASE" != api_error ]] || exit 22
    if [[ "$CASE" == missing_pr ]]; then echo '[]'
    elif [[ "$CASE" == unmerged_pr ]]; then printf '[{"merged_at":null,"base":{"ref":"main"},"merge_commit_sha":"%s"}]\n' "$TEST_SHA"
    else printf '[{"merged_at":"2026-11-16T08:00:00Z","base":{"ref":"main"},"merge_commit_sha":"%s"}]\n' "$TEST_SHA"; fi ;;
  */actions/workflows/*)
    python3 - <<'PY'
import json, os
case = os.environ['CASE']; sha = os.environ['TEST_SHA']
run = {'head_sha': sha, 'event': 'push', 'head_branch': 'main', 'status': 'completed',
       'conclusion': 'success', 'created_at': '2026-11-16T08:01:00Z', 'run_attempt': 1}
runs = [run]
if case == 'workflow_failed': run['conclusion'] = 'failure'
if case == 'workflow_pending': run['status'] = 'in_progress'; run['conclusion'] = None
if case == 'workflow_missing': runs = []
if case == 'workflow_rerun_green':
    runs = [dict(run, conclusion='failure'), dict(run, run_attempt=2)]
if case == 'workflow_latest_red':
    runs = [run, dict(run, created_at='2026-11-16T09:00:00Z', conclusion='failure')]
print(json.dumps({'total_count': len(runs) + (200 if case == 'workflow_truncated' else 0), 'workflow_runs': runs}))
PY
    ;;
  */check-runs\?*)
    python3 - <<'PY'
import json, os
case = os.environ['CASE']; sha = os.environ['TEST_SHA']
names = ['backend-build', 'frontend-build', 'SonarCloud Code Analysis', 'deploy']
if case == 'missing_job': names.remove('frontend-build')
if case == 'missing_sonar': names.remove('SonarCloud Code Analysis')
checks = [{'name': n, 'head_sha': sha, 'status': 'completed', 'conclusion': 'success'} for n in names]
checks[-1]['conclusion'] = 'skipped'  # an unrelated skipped job must not block
if case == 'job_pending': checks[0]['status'] = 'in_progress'; checks[0]['conclusion'] = None
if case == 'job_failed': checks[1]['conclusion'] = 'failure'
if case == 'job_skipped': checks[1]['conclusion'] = 'skipped'
if case == 'job_neutral': checks[1]['conclusion'] = 'neutral'
if case == 'sonar_failed': checks[2]['conclusion'] = 'failure'
if case == 'job_wrong_sha': checks[1]['head_sha'] = 'f' * 40
total = len(checks) + (1 if case == 'checks_truncated' else 0)
print(json.dumps({'total_count': total, 'check_runs': checks}))
PY
    ;;
  */status)
    case "$CASE" in
      status_failed) echo '{"statuses":[{"context":"ext","state":"failure","updated_at":"2026-11-16T08:00:00Z"}]}' ;;
      status_recovered) echo '{"statuses":[{"context":"ext","state":"failure","updated_at":"2026-11-16T08:00:00Z"},{"context":"ext","state":"success","updated_at":"2026-11-16T08:05:00Z"}]}' ;;
      *) echo '{"statuses":[]}' ;;
    esac ;;
  *) echo "unexpected url $url" >&2; exit 99 ;;
esac
MOCK
chmod +x "$BIN/curl"
export PATH="$BIN:$PATH"
export TEST_SHA TEST_TOKEN STATE
TEST_SHA="$(printf 'a%.0s' {1..40})"
TEST_TOKEN='github_pat_TESTONLY0123456789'
STATE="$WORK/state"
TOKEN_FILE="$WORK/token"
printf '%s\n' "$TEST_TOKEN" > "$TOKEN_FILE"
chmod 600 "$TOKEN_FILE"

failures=0
run_case() {
  local name="$1" expected="$2" token_file="${3:-$TOKEN_FILE}" code
  rm -rf "$STATE"; mkdir -p "$STATE"
  set +e
  CASE="$name" bash "$ROOT/scripts/server-release-gate.sh" \
    --repo samkomane008/example --sha "$TEST_SHA" --token-file "$token_file" \
    --workflow ci-gate.yml --job backend-build --job frontend-build --require-sonar \
    > "$WORK/out" 2>&1
  code=$?
  set -e
  if [[ "$expected" == pass && $code -ne 0 ]] || [[ "$expected" == fail && $code -ne 1 ]]; then
    printf 'FAIL: %-22s wanted %s, got exit %s\n' "$name" "$expected" "$code" >&2
    sed 's/^/      /' "$WORK/out" >&2
    failures=$((failures + 1))
    return
  fi
  printf 'PASS: %-22s %s\n' "$name" "$expected"
}

run_case happy pass
run_case workflow_rerun_green pass
run_case status_recovered pass
run_case wrong_main fail
run_case main_moves fail
run_case missing_pr fail
run_case unmerged_pr fail
run_case api_error fail
run_case workflow_failed fail
run_case workflow_pending fail
run_case workflow_missing fail
run_case workflow_latest_red fail
run_case workflow_truncated fail
run_case missing_job fail
run_case missing_sonar fail
run_case sonar_failed fail
run_case job_pending fail
run_case job_failed fail
run_case job_skipped fail
run_case job_neutral fail
run_case job_wrong_sha fail
run_case checks_truncated fail
run_case status_failed fail

# Token file hygiene.
chmod 644 "$TOKEN_FILE"; run_case token_world_readable fail; chmod 600 "$TOKEN_FILE"
run_case token_missing fail "$WORK/does-not-exist"
: > "$WORK/empty"; chmod 600 "$WORK/empty"; run_case token_empty fail "$WORK/empty"
ln -s "$TOKEN_FILE" "$WORK/link"; run_case token_symlink fail "$WORK/link"

# Usage errors exit 2, never 0.
set +e
bash "$ROOT/scripts/server-release-gate.sh" --repo samkomane008/example >/dev/null 2>&1; code=$?
bash "$ROOT/scripts/server-release-gate.sh" --bogus >/dev/null 2>&1; code2=$?
set -e
if [[ $code -eq 0 || $code2 -ne 2 ]]; then echo "FAIL: usage errors returned $code/$code2" >&2; failures=$((failures + 1)); else echo 'PASS: usage errors           fail'; fi

if ((failures)); then echo "$failures case(s) failed" >&2; exit 1; fi
echo 'server-release-gate: all cases passed'
