#!/usr/bin/env bash
# Offline tests for scripts/runner-doctor.sh using fake multipass and gh binaries.
# Proves the doctor exits non-zero when a listener is not active+enabled or not
# registered online, and zero only when every expected listener is healthy.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/runner-doctor.sh"
DIR="$(mktemp -d)"
trap 'rm -rf -- "$DIR"' EXIT
mkdir -p "$DIR/bin"

cat > "$DIR/bin/multipass" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info) echo "Name: samloryx-ci"; echo "State: Running"; exit 0 ;;
  exec)
    case "$*" in
      *is-enabled*) printf '%s' "${MOCK_MATRIX:-}" ;;
      *) echo "Workers:"; echo "  none"; echo "Serial gate:"; echo "  slot-1"; echo "Mem: 5.8Gi"; echo "Disk: 30G"; echo "Prior installer:"; echo "  not found at expected path" ;;
    esac
    exit 0 ;;
  *) echo "unexpected multipass invocation: $*" >&2; exit 1 ;;
esac
MOCK

cat > "$DIR/bin/gh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
repo=""
for arg in "$@"; do
  case "$arg" in
    repos/*/actions/runners) repo="$(cut -d/ -f3 <<< "$arg")" ;;
  esac
done
[[ -n "$repo" ]] || { echo "fake gh: unexpected arguments: $*" >&2; exit 1; }
if [[ "${MOCK_GH_FAIL_REPO:-}" == "$repo" ]]; then exit 1; fi
status="online"
[[ "${MOCK_GH_OFFLINE_REPO:-}" == "$repo" ]] && status="offline"
echo "samloryx-ci-$repo-ci $status busy=false labels=self-hosted,Linux,X64,$repo-ci"
MOCK

chmod +x "$DIR/bin/multipass" "$DIR/bin/gh"
export PATH="$DIR/bin:$PATH"

healthy_matrix='nabor active enabled
samloryx-consultancy-platform active enabled
samloryx-engineering-website active enabled
samloryx-os active enabled
samloryx-workspace active enabled'

run() {
  local label=$1 expected=$2
  shift 2
  set +e
  env MOCK_MATRIX="$healthy_matrix" "$@" bash "$SCRIPT" > "$DIR/out" 2>&1
  local rc=$?
  set -e
  if { [[ "$expected" == pass && $rc -ne 0 ]] || [[ "$expected" == fail && $rc -eq 0 ]]; }; then
    echo "FAIL $label: expected $expected, got $rc"
    cat "$DIR/out"
    exit 1
  fi
  echo "PASS $label ($expected, rc=$rc)"
}

run all-healthy pass

disabled_matrix="$(printf '%s\n' "$healthy_matrix" | sed 's/^nabor active enabled$/nabor inactive disabled/')"
run inactive-disabled-listener fail env MOCK_MATRIX="$disabled_matrix"
grep -q "UNHEALTHY nabor" "$DIR/out" || { echo "FAIL: expected UNHEALTHY nabor line"; cat "$DIR/out"; exit 1; }

run offline-registration fail MOCK_GH_OFFLINE_REPO=samloryx-workspace
grep -q "DOCTOR: attention required" "$DIR/out" || { echo "FAIL: expected attention line"; cat "$DIR/out"; exit 1; }

run registration-query-failure fail MOCK_GH_FAIL_REPO=nabor

echo "runner-doctor tests: PASS"
