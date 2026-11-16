#!/usr/bin/env bash
# Run from your Ubuntu workstation, NOT from within the Multipass VM.
# Usage: bash scripts/deploy-ci-mutex.sh [--check|--apply]
set -Eeuo pipefail
MODE=--check
if (( $# > 0 )); then MODE="$1"; fi
[[ "$MODE" == --check || "$MODE" == --apply ]] || { echo "Usage: $0 [--check|--apply]" >&2; exit 2; }

ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM="samloryx-ci"
command -v multipass >/dev/null || { echo 'Multipass not installed' >&2; exit 1; }
command -v tar >/dev/null || { echo 'tar not installed' >&2; exit 1; }
[[ -s "$ROOT/scripts/install-ci-mutex-vm.sh" ]] || { echo 'Missing VM installer' >&2; exit 1; }
[[ -s "$ROOT/vendor/actions-runner-mutex/job-lock.sh" ]] || { echo 'Missing pinned vendor code' >&2; exit 1; }

# Validate bundled shell syntax on the workstation before staging privileged code.
for f in scripts/install-ci-mutex-vm.sh vendor/actions-runner-mutex/job-lock.sh \
  vendor/actions-runner-mutex/hooks/job-started.sh \
  vendor/actions-runner-mutex/hooks/job-completed.sh \
  vendor/actions-runner-mutex/test/run-tests.sh; do
  bash -n "$ROOT/$f" || { echo "STOP: invalid shell script: $f" >&2; exit 1; }
done

# Multipass installed via Snap cannot access the host's private /tmp.
# Stream the archive through stdin; no host staging path is required.
ARCHIVE="samloryx-ci-mutex-$$.tar.gz"
tar -C "$ROOT" -czf - scripts/install-ci-mutex-vm.sh vendor/actions-runner-mutex \
  | multipass transfer - "$VM:/home/ubuntu/$ARCHIVE"
multipass exec "$VM" -- sudo install -d -m 0700 /root/samloryx-ci-mutex-stage
multipass exec "$VM" -- sudo tar -xzf "/home/ubuntu/$ARCHIVE" -C /root/samloryx-ci-mutex-stage
multipass exec "$VM" -- rm -f "/home/ubuntu/$ARCHIVE"
multipass exec "$VM" -- sudo bash /root/samloryx-ci-mutex-stage/scripts/install-ci-mutex-vm.sh "$MODE"
