#!/usr/bin/env bash
# Offline tests for scripts/ci-health-check.sh using fake gh and multipass.
# Covers the alert paths that matter: a stopped VM, a listener that would not
# survive a reboot, an offline registration, a real queue delay, and the
# uncancellable orphan runs that must not page on every cycle.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/ci-health-check.sh"
DIR="$(mktemp -d)"
trap 'rm -rf -- "$DIR"' EXIT
mkdir -p "$DIR/bin" "$DIR/state"

cat > "$DIR/bin/multipass" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "$*" in
  "info "*--format*csv*)
    echo "Name,State,IPv4"
    echo "samloryx-ci,${MOCK_VM_STATE:-RUNNING},10.97.0.42"
    ;;
  *is-enabled*) printf '%s' "${MOCK_LISTENERS:-}" ;;
  *"df --output=pcent"*) echo "Use%"; echo "${MOCK_DISK_PCT:-52}%" ;;
  *"free -m"*) echo "Mem:"; echo "${MOCK_MEM_MB:-2400}" ;;
  *) echo "unexpected multipass call: $*" >&2; exit 1 ;;
esac
MOCK

cat > "$DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
args="$*"
case "$args" in
  *"/actions/runners "*) printf '%s' "${MOCK_RUNNERS:-}" ;;
  *"status=queued"*) [[ "${MOCK_QUEUE_ERROR:-0}" != 1 ]] || exit 17; printf '%s' "${MOCK_QUEUED:-}" ;;
  *"status=in_progress"*) [[ "${MOCK_RUNNING_ERROR:-0}" != 1 ]] || exit 17; printf '%s' "${MOCK_RUNNING:-}" ;;
  *"/jobs "*) [[ "${MOCK_JOBS_ERROR:-0}" != 1 ]] || exit 17; printf '%s' "${MOCK_JOB_STARTED:-}" ;;
  *"issue list"*)
    if [[ -f "$MOCK_STATE/issue" ]]; then cat "$MOCK_STATE/issue"; else echo ""; fi
    ;;
  *"issue create"*) echo "123" > "$MOCK_STATE/issue"; echo "created" >> "$MOCK_STATE/log" ;;
  *"issue comment"*) echo "commented" >> "$MOCK_STATE/log" ;;
  *"issue close"*) rm -f "$MOCK_STATE/issue"; echo "closed" >> "$MOCK_STATE/log" ;;
  *"label create"*) ;;
  *) echo "unexpected gh call: $*" >&2; exit 1 ;;
esac
MOCK

chmod +x "$DIR/bin/multipass" "$DIR/bin/gh"
export PATH="$DIR/bin:$PATH"
export MOCK_STATE="$DIR/state"
export CI_HEALTH_STATE="$DIR/state/h"

listeners_all='nabor active enabled
personal-career active enabled
samloryx-consultancy-platform active enabled
samloryx-engineering-website active enabled
samloryx-os active enabled
samloryx-workspace active enabled'
runners_all='samloryx-ci-nabor-ci online
samloryx-ci-personal-career-ci online
samloryx-ci-samloryx-consultancy-platform-ci online
samloryx-ci-samloryx-engineering-website-ci online
samloryx-ci-samloryx-os-ci online
samloryx-ci-samloryx-workspace-ci online'

run() {
  local label=$1 expected=$2
  shift 2
  set +e
  env MOCK_LISTENERS="$listeners_all" MOCK_RUNNERS="$runners_all" "$@" \
    bash "$SCRIPT" --quiet > "$DIR/out" 2>&1
  local rc=$?
  set -e
  if { [[ "$expected" == pass && $rc -ne 0 ]] || [[ "$expected" == fail && $rc -eq 0 ]]; }; then
    echo "FAIL $label: expected $expected, got $rc"
    cat "$DIR/out"
    exit 1
  fi
  echo "PASS $label ($expected, rc=$rc)"
}

run healthy pass

run vm-stopped fail MOCK_VM_STATE=STOPPED

run listener-not-enabled fail MOCK_LISTENERS="$(printf '%s\n' "$listeners_all" | sed 's/^nabor active enabled$/nabor inactive enabled/')"

run registration-offline fail MOCK_RUNNERS="$(printf '%s\n' "$runners_all" | sed 's/^samloryx-ci-nabor-ci online$/samloryx-ci-nabor-ci offline/')"

queued_old="$(date -u -d '45 minutes ago' +%Y-%m-%dT%H:%M:%SZ)"
run queue-delay fail MOCK_QUEUED="43095570489 $queued_old ci-gate"

orphan_old="$(date -u -d '3 days ago' +%Y-%m-%dT%H:%M:%SZ)"
run orphan-runs pass MOCK_QUEUED="43095570489 $orphan_old ci-gate"

stuck_start="$(date -u -d '5 hours ago' +%Y-%m-%dT%H:%M:%SZ)"
run stuck-job fail MOCK_RUNNING="43636060857 ci-gate" MOCK_JOB_STARTED="$stuck_start"

# A failed GitHub API read must never be interpreted as an empty (healthy)
# queue or job list. These are failure-injection regressions for issue #7.
run queue-api-unavailable fail MOCK_QUEUE_ERROR=1
run running-api-unavailable fail MOCK_RUNNING_ERROR=1
run jobs-api-unavailable fail MOCK_RUNNING="43636060857 ci-gate" MOCK_JOBS_ERROR=1

# Notification path: one alert opens an issue, an unchanged alert set does not
# comment again, and recovery closes the issue.
rm -f "$MOCK_STATE/issue" "$MOCK_STATE/log"
set +e
env MOCK_LISTENERS="$listeners_all" MOCK_RUNNERS="$runners_all" MOCK_VM_STATE=STOPPED \
  bash "$SCRIPT" --notify > "$DIR/n1" 2>&1
rc1=$?
cp "$MOCK_STATE/log" "$DIR/log-after-first"
env MOCK_LISTENERS="$listeners_all" MOCK_RUNNERS="$runners_all" MOCK_VM_STATE=STOPPED \
  bash "$SCRIPT" --notify > "$DIR/n2" 2>&1
rc2=$?
cp "$MOCK_STATE/log" "$DIR/log-after-second"
env MOCK_LISTENERS="$listeners_all" MOCK_RUNNERS="$runners_all" \
  bash "$SCRIPT" --notify > "$DIR/n3" 2>&1
rc3=$?
set -e
[[ $rc1 -eq 1 && $rc2 -eq 1 && $rc3 -eq 0 ]] || { echo "FAIL notify exit codes: $rc1 $rc2 $rc3"; exit 1; }
[[ "$(grep -c 'created' "$MOCK_STATE/log")" == 1 ]] || { echo "FAIL notify: expected exactly one issue created"; cat "$MOCK_STATE/log"; exit 1; }
cmp -s "$DIR/log-after-first" "$DIR/log-after-second" \
  || { echo "FAIL notify: unchanged alert set produced a second notification"; cat "$MOCK_STATE/log"; exit 1; }
[[ "$(grep -c 'closed' "$MOCK_STATE/log")" == 1 ]] || { echo "FAIL notify: recovery did not close the issue"; cat "$MOCK_STATE/log"; exit 1; }
[[ ! -f "$MOCK_STATE/issue" ]] || { echo "FAIL notify: issue not closed after recovery"; exit 1; }
echo "PASS notify create/dedupe/close"

echo "ci-health-check tests: PASS"
