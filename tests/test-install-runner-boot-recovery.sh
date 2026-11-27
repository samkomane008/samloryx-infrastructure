#!/usr/bin/env bash
# Offline tests for scripts/install-runner-boot-recovery.sh with a fake multipass.
# Proves: --dry-run writes nothing; --apply sends the drop-in (Restart=always, time-sync
# ordering) and passes verification; verification fails when a unit is not Restart=always.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/install-runner-boot-recovery.sh"
DIR="$(mktemp -d)"
trap 'rm -rf -- "$DIR"' EXIT
mkdir -p "$DIR/bin"

cat > "$DIR/bin/multipass" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
[[ "${1:-}" == exec ]] || { echo "unexpected: $*" >&2; exit 1; }
case "$*" in
  *list-unit-files*)
    printf 'actions.runner.samkomane008-nabor.samloryx-ci-nabor-ci.service\n'
    printf 'actions.runner.samkomane008-samloryx-os.samloryx-ci-samloryx-os-ci.service\n' ;;
  *"sudo env"*)
    cat > "$MOCK_DIR/applied-dropin"
    echo apply >> "$MOCK_DIR/calls" ;;
  *"systemctl show"*)
    printf 'Restart=%s\nRestartUSec=1min\nAfter=network-online.target time-sync.target\nUnitFileState=enabled\nStartLimitIntervalUSec=0\n' "${MOCK_RESTART:-always}" ;;
  *"is-enabled systemd-time-wait-sync"*) echo enabled ;;
  *) echo "unexpected exec: $*" >&2; exit 1 ;;
esac
MOCK
chmod +x "$DIR/bin/multipass"
export PATH="$DIR/bin:$PATH" MOCK_DIR="$DIR"

pass() { echo "PASS $1"; }
fail() { echo "FAIL $1" >&2; exit 1; }

out="$(bash "$SCRIPT" --dry-run)"
[[ ! -e "$DIR/calls" ]] || fail "dry run must not write"
grep -q 'DRY RUN' <<< "$out" && grep -q 'Restart=always' <<< "$out" || fail "dry run output"
pass "dry run shows the drop-in and writes nothing"

out="$(bash "$SCRIPT" --apply)"
grep -q '^Restart=always$' "$DIR/applied-dropin" || fail "drop-in lacks Restart=always"
grep -q '^After=network-online.target time-sync.target$' "$DIR/applied-dropin" || fail "drop-in lacks time-sync ordering"
grep -q '^StartLimitIntervalSec=0$' "$DIR/applied-dropin" || fail "drop-in keeps a start limit"
grep -q '^APPLIED' <<< "$out" || fail "apply did not verify"
pass "apply installs the drop-in and verifies both units"

rm -f "$DIR/calls"
if MOCK_RESTART=on-failure bash "$SCRIPT" --apply >/dev/null 2>&1; then fail "verification accepted Restart=on-failure"; fi
pass "verification fails when a unit is not Restart=always"

if bash "$SCRIPT" >/dev/null 2>&1; then fail "no mode must be a usage error"; fi
pass "a mode is required"
echo "install-runner-boot-recovery tests passed (4 scenarios)."
