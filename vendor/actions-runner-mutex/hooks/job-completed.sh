#!/usr/bin/env bash
# Shared setgid lock directory requires group-writable entries.
umask 0007
# ACTIONS_RUNNER_HOOK_JOB_COMPLETED hook.
# Releases the job slot, then optionally runs a site-specific script
# (JOB_LOCK_POST_COMPLETED). Always exits 0 so it can never change the
# outcome of the job.
JOB_LOCK_BIN="${JOB_LOCK_BIN:-$(dirname "${BASH_SOURCE[0]}")/../job-lock.sh}"

"$JOB_LOCK_BIN" release

if [ -n "${JOB_LOCK_POST_COMPLETED:-}" ]; then
  "$JOB_LOCK_POST_COMPLETED" || true
fi
exit 0
