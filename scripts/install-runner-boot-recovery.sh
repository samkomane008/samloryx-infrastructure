#!/usr/bin/env bash
# Make every GitHub Actions runner listener on the CI VM come back by itself after a reboot.
#
#   bash scripts/install-runner-boot-recovery.sh --dry-run   show the drop-in and target units
#   bash scripts/install-runner-boot-recovery.sh --apply     install it, then verify
#
# Why (incident 2026-11-27-runners-down-after-reboot): the VM booted with its clock two hours
# fast. Each listener started before NTP corrected it, GitHub refused the session, and the
# listener exited 0 ("no retry needed"). The existing 90-infra-recovery.conf only restarts on
# failure, so every listener stayed down until restarted by hand.
#
# The drop-in (95-boot-recovery.conf, which overrides 90-infra-recovery.conf):
# - starts listeners only after time-sync.target, and enables systemd-time-wait-sync so that
#   target waits for a real NTP synchronisation;
# - restarts a listener 60 s after ANY exit, with no start-rate limit.
# A stopped unit (systemctl stop) is not restarted. Running listeners and jobs are not
# restarted by this script; the ordering applies from the next boot, Restart= at once.
#
# Exit codes: 0 done · 1 verification failed · 2 usage or missing tooling.
set -euo pipefail

VM="${CI_VM_NAME:-samloryx-ci}"
DROPIN_NAME="95-boot-recovery.conf"

usage() { sed -n '2,6p' "$0" | sed 's/^# \{0,1\}//'; }
mode="${1:-}"
case "$mode" in
  --dry-run|--apply) ;;
  -h|--help) usage; exit 0 ;;
  *) usage >&2; exit 2 ;;
esac
command -v multipass >/dev/null || { echo "multipass not found" >&2; exit 2; }

DROPIN='# Managed by samloryx-infrastructure/scripts/install-runner-boot-recovery.sh
[Unit]
Wants=network-online.target time-sync.target
After=network-online.target time-sync.target
StartLimitIntervalSec=0

[Service]
Restart=always
RestartSec=60s'

units="$(multipass exec "$VM" -- bash -c \
  "systemctl list-unit-files 'actions.runner.*.service' --no-legend | awk '{print \$1}'")" ||
  { echo "ERROR: cannot list runner units in $VM" >&2; exit 1; }
[[ -n "$units" ]] || { echo "ERROR: no actions.runner.* units found in $VM" >&2; exit 1; }

echo "=== Units in $VM ==="
printf '%s\n' "$units"
echo "=== Drop-in /etc/systemd/system/<unit>.d/$DROPIN_NAME ==="
printf '%s\n' "$DROPIN"

if [[ "$mode" == --dry-run ]]; then
  echo "DRY RUN: nothing written. Re-run with --apply."
  exit 0
fi

# Pass the drop-in and unit list over stdin/env so no value is interpolated into shell code.
multipass exec "$VM" -- sudo env DROPIN_NAME="$DROPIN_NAME" UNITS="$units" bash -c '
set -euo pipefail
dropin="$(cat)"
for unit in $UNITS; do
  dir="/etc/systemd/system/$unit.d"
  install -d -m 755 "$dir"
  printf "%s\n" "$dropin" > "$dir/$DROPIN_NAME.tmp"
  chmod 644 "$dir/$DROPIN_NAME.tmp"
  mv "$dir/$DROPIN_NAME.tmp" "$dir/$DROPIN_NAME"
  systemctl enable "$unit" >/dev/null 2>&1
done
systemctl enable systemd-time-wait-sync.service >/dev/null 2>&1
systemctl daemon-reload
' <<< "$DROPIN"

echo "=== Verify ==="
fail=0
for unit in $units; do
  props="$(multipass exec "$VM" -- systemctl show "$unit" -p Restart -p RestartUSec -p After -p UnitFileState -p StartLimitIntervalUSec)"
  restart="$(grep '^Restart=' <<< "$props" | cut -d= -f2)"
  enabled="$(grep '^UnitFileState=' <<< "$props" | cut -d= -f2)"
  after="$(grep '^After=' <<< "$props")"
  ok=yes
  [[ "$restart" == always ]] || ok=no
  [[ "$enabled" == enabled ]] || ok=no
  [[ "$after" == *time-sync.target* ]] || ok=no
  echo "$ok $unit restart=$restart enabled=$enabled time-sync=$([[ "$after" == *time-sync.target* ]] && echo yes || echo no)"
  [[ "$ok" == yes ]] || fail=1
done
wait_sync="$(multipass exec "$VM" -- systemctl is-enabled systemd-time-wait-sync.service 2>/dev/null || true)"
echo "systemd-time-wait-sync: $wait_sync"
[[ "$wait_sync" == enabled ]] || fail=1
if ((fail)); then echo "VERIFY FAILED" >&2; exit 1; fi
echo "APPLIED: listeners wait for time sync at boot and restart after any exit."
