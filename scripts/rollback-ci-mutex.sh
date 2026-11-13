#!/usr/bin/env bash
# Trusted Ubuntu workstation: stage the rollback script inside the CI VM.
set -Eeuo pipefail
MODE=--check
if (( $# > 0 )); then MODE="$1"; fi
[[ "$MODE" == --check || "$MODE" == --apply ]] || { echo "Usage: $0 [--check|--apply]" >&2; exit 2; }
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
VM=samloryx-ci
# Multipass installed via Snap cannot access the host's private /tmp.
# Stream the archive through stdin; no host staging path is required.
ARCHIVE="samloryx-ci-mutex-rollback-$$.tar.gz"
tar -C "$ROOT" -czf - scripts/rollback-ci-mutex-vm.sh \
  | multipass transfer - "$VM:/home/ubuntu/$ARCHIVE"
multipass exec "$VM" -- sudo install -d -m 0700 /root/samloryx-ci-mutex-stage
multipass exec "$VM" -- sudo tar -xzf "/home/ubuntu/$ARCHIVE" -C /root/samloryx-ci-mutex-stage
multipass exec "$VM" -- rm -f "/home/ubuntu/$ARCHIVE"
multipass exec "$VM" -- sudo bash /root/samloryx-ci-mutex-stage/scripts/rollback-ci-mutex-vm.sh "$MODE"
