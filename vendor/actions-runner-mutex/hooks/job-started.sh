#!/usr/bin/env bash
# Shared setgid lock directory requires group-writable entries.
umask 0007
# ACTIONS_RUNNER_HOOK_JOB_STARTED hook.
# 1. Acquire a host-wide job slot (blocks until one is free).
# 2. Optionally run a site-specific script (JOB_LOCK_POST_ACQUIRE), e.g. a
#    keychain unlock on macOS. It runs AFTER the (possibly long) wait on
#    purpose: anything time-sensitive should happen right before the job.
set -euo pipefail

JOB_LOCK_BIN="${JOB_LOCK_BIN:-$(dirname "${BASH_SOURCE[0]}")/../job-lock.sh}"

"$JOB_LOCK_BIN" acquire

if [ -n "${JOB_LOCK_POST_ACQUIRE:-}" ]; then
  "$JOB_LOCK_POST_ACQUIRE"
fi
