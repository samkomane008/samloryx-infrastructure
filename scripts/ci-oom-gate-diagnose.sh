#!/usr/bin/env bash
# Inspect OOM evidence and cross-runner serialization. READ ONLY.
# Run from a trusted workstation. Review output for sensitive details before sharing.
set -euo pipefail
VM="${CI_VM_NAME:-samloryx-ci}"
command -v multipass >/dev/null || { echo "multipass not installed" >&2; exit 1; }

multipass exec "$VM" -- bash -s <<'VM_SCRIPT'
set -u
UNIT='actions.runner.samkomane008-nabor.samloryx-ci-nabor-ci.service'

echo '=== Memory, swap, pressure ==='
free -h
cat /proc/pressure/memory 2>/dev/null || true

echo
echo '=== Runner unit resource limits ==='
sudo systemctl show "$UNIT" \
  -p ActiveState -p SubState -p Result -p MemoryCurrent -p MemoryPeak \
  -p MemoryHigh -p MemoryMax -p MemorySwapMax \
  -p OOMPolicy -p OOMScoreAdjust -p TasksMax \
  -p ExecMainStatus -p NRestarts --no-pager || true

echo
echo '=== Kernel OOM evidence (current boot, filtered) ==='
sudo journalctl -k -b --no-pager -o short-iso 2>/dev/null |
  grep -Ei 'oom|out of memory|killed process|memory cgroup' | tail -35 || true

echo
echo '=== Last Nabor runner service transitions ==='
sudo journalctl -u "$UNIT" -b --no-pager -o short-iso |
  grep -Ei 'oom|killed|failed|start|stop' | tail -30 || true

echo
echo '=== Active runner services and workers ==='
systemctl list-units --all --plain --no-legend 'actions.runner.*.service' |
  awk '{print $1, $3, $4}' || true
pgrep -af '[R]unner.Worker' || true

echo
echo '=== Serialization installation evidence (names only, no secret values) ==='
if test -f /home/ubuntu/install_ci_serial_gate.py; then
  sha256sum /home/ubuntu/install_ci_serial_gate.py
fi
sudo find /usr/local/bin /usr/local/sbin /etc/systemd/system /opt/samloryx-runners \
  -maxdepth 3 \
  \( -iname '*serial*gate*' -o -iname '*runner*lock*' -o -iname '*ci*semaphore*' \) \
  -print 2>/dev/null | head -45 || true

echo
echo '=== systemd unit drop-in names (not content) ==='
sudo systemctl show "$UNIT" -p DropInPaths --no-pager || true
VM_SCRIPT
echo 'This is inspection only; no runner restarted or reconfigured.'
