#!/usr/bin/env bash
# Read-only diagnosis for the Nabor self-hosted runner service.
# Do not paste raw logs into a PUBLIC issue; redact sensitive values first.
set -euo pipefail
VM="${CI_VM_NAME:-samloryx-ci}"
UNIT="actions.runner.samkomane008-nabor.samloryx-ci-nabor-ci.service"

command -v multipass >/dev/null || { echo "multipass not installed" >&2; exit 1; }

echo "=== Nabor service state (read-only) ==="
multipass exec "$VM" -- bash -s -- "$UNIT" <<'VM_SCRIPT'
set -eu
unit="$1"
sudo systemctl show "$unit" --no-pager \
  -p LoadState -p ActiveState -p SubState \
  -p Result -p ExecMainCode -p ExecMainStatus \
  -p NRestarts -p StateChangeTimestamp
printf '\n=== Most recent Nabor runner journal lines ===\n'
sudo journalctl -u "$unit" -n 45 --no-pager -o short-iso || true
printf '\n=== Currently executing workers ===\n'
pgrep -af '/bin/Runner.Worker ' || true
VM_SCRIPT

echo
echo "=== GitHub registration status (read-only) ==="
if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  gh api repos/samkomane008/nabor/actions/runners \
    --jq '.runners[] | {name,status,busy,labels: [.labels[].name]}' \
    || echo "Runner API unavailable: check gh permissions or the repository Actions settings."
else
  echo "GitHub CLI unavailable or unauthenticated; inspect the GitHub Actions runners UI."
fi

echo
echo "Do not run a restart until any active CI job finishes."
echo "Redact credentials, internal addresses and sensitive paths before sharing diagnostic output."
