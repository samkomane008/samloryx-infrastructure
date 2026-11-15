#!/usr/bin/env bash
# Read-only inspection of the CI VM. Does not install, stop or restart anything.
# Prints a per-repository health matrix and exits non-zero when any expected
# listener is not active and enabled, or not registered online with GitHub.
#
# Exit codes: 0 healthy · 1 unhealthy listener or registration · 2 missing tooling.
set -uo pipefail

VM="${CI_VM_NAME:-samloryx-ci}"
REPOS="${CI_REPOS:-nabor personal-career samloryx-consultancy-platform samloryx-engineering-website samloryx-os samloryx-workspace}"
command -v multipass >/dev/null || { echo "multipass not found" >&2; exit 2; }

echo "=== VM information ==="
multipass info "$VM"

echo "=== Runner listeners (active/enabled) ==="
matrix="$(multipass exec "$VM" -- bash -lc '
for name in '"$REPOS"'; do
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  printf "%s %s %s\n" "$name" \
    "$(systemctl is-active "$unit" 2>/dev/null || true)" \
    "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
done
')" || { echo "ERROR: cannot read runner units in $VM" >&2; exit 1; }
printf '%s\n' "$matrix"

echo "=== Jobs, gate, memory and disk ==="
multipass exec "$VM" -- bash -lc '
  echo "Workers:"
  pgrep -af "[R]unner.Worker spawnclient" || echo "  none"
  echo "Serial gate:"
  sudo ls -1 /run/samloryx-ci-mutex 2>/dev/null || echo "  lock directory unreadable (expected unless root or in the mutex group)"
  free -h | sed -n "1,3p"
  df -h / | tail -1
  echo "Prior installer:"
  if test -f /home/ubuntu/install_ci_serial_gate.py; then
    sha256sum /home/ubuntu/install_ci_serial_gate.py
  else
    echo "  not found at expected path"
  fi
'

echo "=== GitHub runner registration ==="
unhealthy=0
if command -v gh >/dev/null; then
  for name in $REPOS; do
    runners="$(gh api "repos/samkomane008/$name/actions/runners" \
      --jq '.runners[] | select(.name | startswith("samloryx-ci")) | "\(.name) \(.status) busy=\(.busy) labels=\([.labels[].name] | join(","))"' 2>/dev/null)" \
      || { printf '%-32s query-failed\n' "$name"; unhealthy=1; continue; }
    if [[ -z "$runners" ]]; then
      printf '%-32s none-registered\n' "$name"
      unhealthy=1
      continue
    fi
    while read -r runner_name runner_status rest; do
      [[ -n "${runner_name:-}" ]] || continue
      printf '%-32s %s %s\n' "$name" "$runner_status" "$rest"
      [[ "$runner_status" == online ]] || unhealthy=1
    done <<< "$runners"
  done
else
  echo 'gh not installed: check the repository Actions runner pages instead' >&2
  unhealthy=1
fi

echo "=== Listener verdict ==="
while read -r name active enabled; do
  [[ -n "${name:-}" ]] || continue
  if [[ "$active" != active || "$enabled" != enabled ]]; then
    echo "UNHEALTHY $name active=$active enabled=$enabled"
    unhealthy=1
  fi
done <<< "$matrix"

if (( unhealthy )); then
  echo 'DOCTOR: attention required (see UNHEALTHY lines above)'
  exit 1
fi
echo 'DOCTOR: all expected listeners are active, enabled and online'
