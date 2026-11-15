#!/usr/bin/env bash
# actions-runner-mutex — host-wide mutual exclusion for GitHub Actions
# self-hosted runners.
#
# Usage: job-lock.sh acquire|release|status
#
# Multiple runner processes on one machine have no built-in coordination:
# each takes one job at a time, but N runners run N jobs in parallel.
# This script implements a host-wide semaphore using the runner's job hooks
# (ACTIONS_RUNNER_HOOK_JOB_STARTED / _COMPLETED).
#
# Design notes:
# - The started hook and the completed hook are separate short-lived
#   processes, so flock(2) (whose locks die with the fd) cannot be used.
#   Instead each slot is a directory taken atomically with mkdir, plus an
#   "owner" file recording the Runner.Worker PID.
# - The owner PID is found by walking up the process tree to the nearest
#   Runner.Worker: the hook script's $PPID is NOT the worker (it is the
#   hook's own shell, which dies as soon as the hook returns).
# - If the recorded worker PID is dead, waiters steal the slot. This is the
#   safety net for every case where the completed hook does not run
#   (force-killed runner, reboot, runner bugs — see actions/runner#1847).
#
# Configuration (set in each runner's .env, or in the environment):
#   JOB_LOCK_DIR             lock directory, must be shared by all runners on
#                            the host (default: $HOME/.actions-runner-mutex)
#   JOB_LOCK_SLOTS           max concurrent jobs on the host (default: 1)
#   JOB_LOCK_MAX_WAIT_SECS   give up (exit 1, failing the job) after this many
#                            seconds of waiting (default: 7200)
#   JOB_LOCK_OWNERLESS_GRACE seconds before a slot with no owner file is
#                            considered stale (default: 60)
#   JOB_LOCK_OWNER_PID       override the recorded owner PID (tests only)
#   JOB_LOCK_COMM            process name used for liveness checks
#                            (default: Runner.Worker; tests only)
set -u

LOCK_BASE="${JOB_LOCK_DIR:-$HOME/.actions-runner-mutex}"
SLOTS="${JOB_LOCK_SLOTS:-1}"
MAX_WAIT="${JOB_LOCK_MAX_WAIT_SECS:-7200}"
OWNERLESS_GRACE="${JOB_LOCK_OWNERLESS_GRACE:-60}"
OWNER_COMM="${JOB_LOCK_COMM:-Runner.Worker}"

log() { echo "[job-lock] $*"; }

# mtime that works on both GNU/Linux (stat -c) and BSD/macOS (stat -f)
dir_mtime() {
  stat -c %Y "$1" 2>/dev/null || stat -f %m "$1" 2>/dev/null || date +%s
}

# Find the PID to record as the slot owner. This script runs as a child of
# the hook script (a shell), which itself is a child of Runner.Worker — and
# only the worker stays alive for the whole job. Walk up the process tree to
# the nearest process whose comm matches $OWNER_COMM.
find_worker_pid() {
  local pid=$PPID hops=0 comm
  while [ -n "$pid" ] && [ "$pid" -gt 1 ] && [ "$hops" -lt 6 ]; do
    comm=$(ps -o comm= -p "$pid" 2>/dev/null) || break
    case "$comm" in
      *"$OWNER_COMM"*) echo "$pid"; return 0 ;;
    esac
    pid=$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d ' ')
    hops=$((hops + 1))
  done
  echo "$PPID"
}

OWNER_PID="${JOB_LOCK_OWNER_PID:-$(find_worker_pid)}"

slot_pid() { sed -n 's/^pid=//p' "$1/owner" 2>/dev/null | head -n1; }
slot_repo() { sed -n 's/^repo=//p' "$1/owner" 2>/dev/null | head -n1; }

# Is the recorded owner of slot $1 still alive? Checks comm as well as the
# PID so that PID reuse after a reboot cannot make a dead owner look alive.
slot_alive() {
  local pid
  pid=$(slot_pid "$1")
  [ -n "$pid" ] || return 1
  # Cross-service-user fix: kill -0 can fail with EPERM for a live worker.
  ps -o comm= -p "$pid" >/dev/null 2>&1 || return 1
  case "$(ps -o comm= -p "$pid" 2>/dev/null)" in
    *"$OWNER_COMM"*) return 0 ;;
    *) return 1 ;;
  esac
}

slot_age() { echo $(( $(date +%s) - $(dir_mtime "$1") )); }

# Remove a slot via atomic rename-then-delete, so that two concurrent
# stealers can never delete a slot that was just re-acquired by a third.
remove_slot() {
  local tmp="$1.stale.$$"
  if mv "$1" "$tmp" 2>/dev/null; then
    rm -rf "$tmp"
    return 0
  fi
  return 1
}

acquire() {
  mkdir -p "$LOCK_BASE"
  trap 'log "canceled while waiting for lock"; exit 1' TERM INT
  local last_log=-999 i slot
  SECONDS=0
  while :; do
    for ((i = 1; i <= SLOTS; i++)); do
      slot="$LOCK_BASE/slot-$i"
      if mkdir "$slot" 2>/dev/null; then
        {
          echo "pid=$OWNER_PID"
          echo "runner=${RUNNER_NAME:-unknown}"
          echo "repo=${GITHUB_REPOSITORY:-unknown}"
          echo "acquired=$(date '+%Y-%m-%dT%H:%M:%S')"
        } > "$slot/owner"
        log "lock acquired (slot $i/$SLOTS, worker pid=$OWNER_PID)"
        return 0
      fi
      if [ -f "$slot/owner" ]; then
        if ! slot_alive "$slot"; then
          log "slot $i holder (pid=$(slot_pid "$slot"), repo=$(slot_repo "$slot")) is gone, removing stale lock"
          remove_slot "$slot" || true
          i=$((i - 1))   # retry this slot immediately
          continue
        fi
      elif [ -d "$slot" ] && [ "$(slot_age "$slot")" -ge "$OWNERLESS_GRACE" ]; then
        # mkdir succeeded but the owner file was never written (the hook was
        # killed in between) — stealable after a grace period
        log "slot $i is ownerless and older than ${OWNERLESS_GRACE}s, removing"
        remove_slot "$slot" || true
        i=$((i - 1))
        continue
      fi
    done

    if [ "$SECONDS" -ge "$MAX_WAIT" ]; then
      log "ERROR: gave up waiting for a job slot after ${SECONDS}s"
      exit 1
    fi
    if [ $((SECONDS - last_log)) -ge 30 ]; then
      log "waiting for a job slot: $(busy_slots_summary) (${SECONDS}s elapsed, max ${MAX_WAIT}s)"
      last_log=$SECONDS
    fi
    sleep $((5 + RANDOM % 3))
  done
}

busy_slots_summary() {
  local slot out=""
  for slot in "$LOCK_BASE"/slot-*; do
    [ -d "$slot" ] || continue
    out="$out${out:+, }${slot##*/}=$(slot_repo "$slot")"
  done
  echo "${out:-none}"
}

release() {
  local slot pid
  for slot in "$LOCK_BASE"/slot-*; do
    [ -d "$slot" ] || continue
    pid=$(slot_pid "$slot")
    if [ "$pid" = "$OWNER_PID" ]; then
      remove_slot "$slot" || true
      log "lock released (${slot##*/}, worker pid=$OWNER_PID)"
      exit 0
    fi
  done
  # Not found: our slot may have been stolen, or the started hook never ran.
  # Opportunistically collect dead slots so the host stays clean.
  for slot in "$LOCK_BASE"/slot-*; do
    [ -d "$slot" ] || continue
    if ! slot_alive "$slot"; then
      remove_slot "$slot" || true
      log "collected stale ${slot##*/}"
    fi
  done
  log "no slot owned by worker pid=$OWNER_PID"
  exit 0
}

status() {
  local slot found=0
  for slot in "$LOCK_BASE"/slot-*; do
    [ -d "$slot" ] || continue
    found=1
    echo "${slot##*/}: age $(slot_age "$slot")s"
    cat "$slot/owner" 2>/dev/null || echo "(no owner file)"
    if slot_alive "$slot"; then echo "holder: alive"; else echo "holder: dead (stale)"; fi
    echo ""
  done
  [ "$found" = 1 ] || echo "unlocked (0/$SLOTS slots busy)"
}

case "${1:-}" in
  acquire) acquire ;;
  release) release ;;
  status)  status ;;
  *) echo "Usage: $0 {acquire|release|status}" >&2; exit 2 ;;
esac
