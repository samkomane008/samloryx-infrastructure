#!/usr/bin/env bash
# Portable pnpm CI entry point. Local workflows keep the normal pnpm behavior.
# A self-hosted runner keeps a per-runner content-addressed store across checkouts.
set -Eeuo pipefail

[[ $# -gt 0 ]] || { echo 'Usage: ci-pnpm.sh <pnpm arguments>' >&2; exit 2; }
if [[ "${GITHUB_ACTIONS:-false}" != true ]]; then
  exec pnpm "$@"
fi

is_selfhosted=false
if [[ "${RUNNER_ENVIRONMENT:-}" == "self-hosted" ]]; then
  is_selfhosted=true
fi

extra=(
  --network-concurrency=4
  --fetch-retries=4
  --fetch-retry-mintimeout=5000
  --fetch-retry-maxtimeout=30000
  --fetch-timeout=90000
)

if [[ "$is_selfhosted" == true ]]; then
  store_root="${RUNNER_TOOL_CACHE:-${HOME}/.cache/samloryx-ci}"
  store="${store_root%/}/pnpm-store"
  mkdir -p -- "$store"
  [[ -w "$store" ]] || { echo "CI ERROR: pnpm store is not writable: $store" >&2; exit 1; }
  extra+=(--store-dir="$store")
  echo "[ci-pnpm] persistent runner-local store: $store"

  # An offline hit avoids all registry requests on a warm self-hosted runner.
  # An offline miss is not a bypass: online install below must still succeed.
  if [[ "${1:-}" == install && -d "$store/v10" ]]; then
    echo '[ci-pnpm] attempting locked offline restore from existing store'
    if timeout --signal=TERM --kill-after=15s 120s \
      pnpm "$@" --offline --store-dir="$store"; then
      echo '[ci-pnpm] offline restore passed'
      exit 0
    fi
    echo '[ci-pnpm] offline restore unavailable; checking registry connectivity'
  fi
fi

# Network probe is informative rather than a bypass or permanent veto: DNS/TLS
# can be intermittent and pnpm may recover using its bounded retry settings.
registry='registry.npmjs.org'
if timeout 6s getent ahostsv4 "$registry" >/dev/null 2>&1; then
  echo '[ci-pnpm] npm registry DNS lookup passed'
else
  echo '[ci-pnpm] WARN: npm registry DNS lookup failed/timed out' >&2
fi
if command -v curl >/dev/null 2>&1; then
  if curl -4 -fsS -o /dev/null --connect-timeout 5 --max-time 10 \
    "https://${registry}/-/ping"; then
    echo '[ci-pnpm] npm registry HTTPS/TLS probe passed'
  else
    echo '[ci-pnpm] WARN: npm registry HTTPS/TLS probe failed/timed out' >&2
  fi
else
  echo '[ci-pnpm] WARN: curl missing; skipping HTTPS probe' >&2
fi

# Timeout affects only this pnpm command; never force-kill a runner or mutex.
limit="${CI_PNPM_STEP_SECONDS:-900}"
[[ "$limit" =~ ^[0-9]+$ ]] && (( limit >= 30 && limit <= 1500 )) || {
  echo 'CI ERROR: CI_PNPM_STEP_SECONDS must be 30-1500 seconds' >&2
  exit 2
}
echo "[ci-pnpm] bounded operation: ${limit}s; concurrency=4; fetch retries=4"
if timeout --signal=TERM --kill-after=15s "${limit}s" pnpm "$@" "${extra[@]}"; then
  echo '[ci-pnpm] pnpm operation passed'
else
  code=$?
  echo "[ci-pnpm] ERROR: pnpm failed (exit=$code); inspect DNS, TLS, and registry errors above" >&2
  exit "$code"
fi
