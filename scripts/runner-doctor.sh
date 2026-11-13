#!/usr/bin/env bash
# Read-only inspection of the existing CI VM. Does not install, stop, or restart services.
set -euo pipefail

VM="${CI_VM_NAME:-samloryx-ci}"
command -v multipass >/dev/null || { echo "multipass not found" >&2; exit 1; }

echo "=== VM information ==="
multipass info "$VM"

echo "=== Runner processes, serial gate, memory and disk ==="
multipass exec "$VM" -- bash -lc '
  echo "Runner processes:"
  pgrep -af "Runner.Listener|Runner.Worker" || true
  echo "Relevant system units:"
  (systemctl list-units --all --no-pager || true) | grep -Ei "runner|serial|ci-gate" || true
  echo "Available memory:"
  free -h
  echo "Disk:"
  df -h /
  echo "Prior installer:"
  if test -f /home/ubuntu/install_ci_serial_gate.py; then
    sha256sum /home/ubuntu/install_ci_serial_gate.py
  else
    echo "not found at expected path"
  fi
'

echo "=== GitHub runner registration (separate verification) ==="
echo 'Check your repository or organization Actions runner page, or:'
echo 'gh api repos/OWNER/REPO/actions/runners --jq ".runners[] | {name,status,labels: [.labels[].name]}"'
