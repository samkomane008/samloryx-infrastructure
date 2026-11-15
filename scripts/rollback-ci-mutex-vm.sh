#!/usr/bin/env bash
# Restore original runner .env files. Does not delete the vendor code or Linux group.
# Requires the CI VM to be idle. Root-only backups never leave the VM.
set -Eeuo pipefail
MODE=--check
if (( $# > 0 )); then MODE="$1"; fi
[[ "$MODE" == --check || "$MODE" == --apply ]] || { echo "Usage: $0 [--check|--apply]" >&2; exit 2; }
[[ "$(id -u)" == 0 ]] || { echo 'Run as root inside samloryx-ci guest' >&2; exit 1; }
BASE=/var/backups/samloryx-ci-mutex
REPOS="nabor personal-career samloryx-consultancy-platform samloryx-engineering-website samloryx-os samloryx-workspace"
[[ -d "$BASE" ]] || { echo 'No CI mutex backup directory found' >&2; exit 1; }
# The oldest snapshot preserves the pre-mutex state, even after later reinstalls.
backup="$(find "$BASE" -mindepth 1 -maxdepth 1 -type d | sort | head -n 1)"
[[ -n "$backup" ]] || { echo 'No saved configuration found' >&2; exit 1; }
for name in $REPOS; do
  [[ -s "$backup/$name.env" ]] || { echo "Missing backup for $name" >&2; exit 1; }
  systemctl cat "actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service" >/dev/null
done
workers="$(ps -eo comm= | awk '$1=="Runner.Worker"{n++} END{print n+0}')"
echo "Runner workers: $workers"
echo "Restoration source: $(basename "$backup") (contents withheld)"
if [[ "$MODE" == --check ]]; then
  echo 'READ-ONLY: backup available, no files changed.'
  exit 0
fi
[[ "$workers" == 0 ]] || { echo 'STOP: Active CI job; no changes made' >&2; exit 3; }
for name in $REPOS; do
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  if [[ "$(systemctl is-active "$unit" || true)" == active ]]; then systemctl stop "$unit"; fi
done
[[ "$(ps -eo comm= | awk '$1=="Runner.Worker"{n++} END{print n+0}')" == 0 ]] || {
  echo 'STOP: Worker still running after stopping listeners. Manual inspection required' >&2
  exit 4
}
for name in $REPOS; do
  cp -p "$backup/$name.env" "/opt/samloryx-runners/ci/$name/.env"
done
for name in $REPOS; do
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  systemctl reset-failed "$unit" || true
  systemctl start "$unit" || echo "WARNING: Failed to start $name" >&2
done
echo 'Runner .env files restored from private backup; vendor code retained for inspection.'
