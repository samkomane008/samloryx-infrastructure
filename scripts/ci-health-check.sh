#!/usr/bin/env bash
# CI health watchdog for the shared self-hosted runners.
#
# Reads only: VM state, systemd listener state (active + enabled), GitHub
# registration and queue age. Nothing is restarted, cancelled or cleaned.
# With --notify it keeps one GitHub issue in this repository as the alert
# channel: created on the first alert, commented when the alert set changes,
# and closed automatically once everything is healthy again.
#
# Usage: bash scripts/ci-health-check.sh [--notify] [--quiet]
# Exit: 0 healthy · 1 at least one alert · 2 missing tooling.
set -uo pipefail

REPO="${CI_HEALTH_REPO:-samkomane008/samloryx-infrastructure}"
VM="${CI_VM_NAME:-samloryx-ci}"
REPOS="${CI_REPOS:-nabor personal-career samloryx-consultancy-platform samloryx-engineering-website samloryx-os samloryx-workspace}"
QUEUE_MAX_MIN="${CI_QUEUE_MAX_MIN:-30}"
# GitHub keeps some 11 Nov 2026 runs in a limbo state that it refuses to cancel
# ("has not been queued yet", HTTP 409) or force-cancel. They never reach a
# runner and do not block assignment, so they are reported as orphaned once a
# day old rather than alerted on every cycle.
QUEUE_ORPHAN_MIN="${CI_QUEUE_ORPHAN_MIN:-1440}"
STUCK_MAX_H="${CI_STUCK_MAX_H:-3}"
DISK_MAX_PCT="${CI_DISK_MAX_PCT:-85}"
MEM_MIN_MB="${CI_MEM_MIN_MB:-250}"
STATE_DIR="${CI_HEALTH_STATE:-${XDG_STATE_HOME:-$HOME/.local/state}/samloryx-ci-health}"

notify=0
quiet=0
for arg in "$@"; do
  case "$arg" in
    --notify) notify=1 ;;
    --quiet) quiet=1 ;;
    *) echo "Usage: $0 [--notify] [--quiet]" >&2; exit 2 ;;
  esac
done
command -v gh >/dev/null || { echo "gh not found" >&2; exit 2; }
command -v multipass >/dev/null || { echo "multipass not found" >&2; exit 2; }

alerts=()
alert() { alerts+=("$1"); [[ $quiet -eq 1 ]] || echo "ALERT $1"; }
ok() { [[ $quiet -eq 1 ]] || echo "ok    $1"; }

# --- VM ----------------------------------------------------------------------
vm_state="$(multipass info "$VM" --format csv 2>/dev/null | awk -F, 'NR==2 {print $2}')"
if [[ "$vm_state" != "RUNNING" && "$vm_state" != "Running" ]]; then
  alert "vm: $VM is ${vm_state:-unreachable}, so every self-hosted job is queued"
else
  ok "vm: $VM running"

  # --- listeners: must be active AND enabled, or a reboot drops them silently
  matrix="$(multipass exec "$VM" -- bash -lc '
for name in '"$REPOS"'; do
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  printf "%s %s %s\n" "$name" \
    "$(systemctl is-active "$unit" 2>/dev/null || true)" \
    "$(systemctl is-enabled "$unit" 2>/dev/null || true)"
done')" || alert "vm: cannot read listener units"
  while read -r name active enabled; do
    [[ -n "${name:-}" ]] || continue
    if [[ "$active" != active ]]; then
      alert "listener: $name is $active (enabled=$enabled)"
    elif [[ "$enabled" != enabled ]]; then
      alert "listener: $name is enabled=$enabled, so it will not restart after a reboot"
    else
      ok "listener: $name active and enabled"
    fi
  done <<< "${matrix:-}"

  # --- capacity
  disk="$(multipass exec "$VM" -- df --output=pcent / 2>/dev/null | tail -1 | tr -dc '0-9')"
  if [[ -n "$disk" ]] && (( disk >= DISK_MAX_PCT )); then
    alert "disk: root filesystem at ${disk}% (threshold ${DISK_MAX_PCT}%)"
  else
    ok "disk: ${disk:-unknown}% used"
  fi
  mem="$(multipass exec "$VM" -- bash -lc "free -m | awk '/^Mem:/ {print \$7}'" 2>/dev/null | tr -dc '0-9')"
  if [[ -n "$mem" ]] && (( mem < MEM_MIN_MB )); then
    alert "memory: ${mem} MiB available (floor ${MEM_MIN_MB} MiB)"
  else
    ok "memory: ${mem:-unknown} MiB available"
  fi
fi

# --- GitHub registration, queue age and stuck jobs ---------------------------
now="$(date -u +%s)"
for name in $REPOS; do
  runners="$(gh api "repos/samkomane008/$name/actions/runners" \
    --jq '.runners[] | select(.name | startswith("samloryx-ci")) | "\(.name) \(.status)"' 2>/dev/null)" \
    || { alert "github: cannot read runners for $name"; continue; }
  if [[ -z "$runners" ]]; then
    alert "github: no runner registered for $name"
  else
    while read -r rname rstatus; do
      [[ -n "${rname:-}" ]] || continue
      [[ "$rstatus" == online ]] && ok "github: $rname online" || alert "github: $rname is $rstatus"
    done <<< "$runners"
  fi

  queued="$(gh api "repos/samkomane008/$name/actions/runs?status=queued&per_page=100" \
    --jq '.workflow_runs[] | "\(.id) \(.created_at) \(.name)"' 2>/dev/null)" || queued=""
  while read -r id created wname; do
    [[ -n "${id:-}" ]] || continue
    age_min=$(( (now - $(date -u -d "$created" +%s)) / 60 ))
    if (( age_min >= QUEUE_ORPHAN_MIN )); then
      ok "orphan: $name run $id ($wname) queued ${age_min}m and cannot be cancelled; see docs/ROLLOUT.md"
    elif (( age_min >= QUEUE_MAX_MIN )); then
      alert "queue: $name run $id ($wname) queued ${age_min}m, limit ${QUEUE_MAX_MIN}m"
    fi
  done <<< "$queued"

  running="$(gh api "repos/samkomane008/$name/actions/runs?status=in_progress&per_page=100" \
    --jq '.workflow_runs[] | "\(.id) \(.name)"' 2>/dev/null)" || running=""
  while read -r id wname; do
    [[ -n "${id:-}" ]] || continue
    # Judge age by the oldest running job, not by the run's creation time: a
    # rerun of an old run legitimately restarts the clock.
    started="$(gh api "repos/samkomane008/$name/actions/runs/$id/jobs" \
      --jq '[.jobs[] | select(.status == "in_progress") | .started_at // empty] | min // empty' 2>/dev/null)"
    [[ -n "$started" ]] || continue
    age_h=$(( (now - $(date -u -d "$started" +%s)) / 3600 ))
    if (( age_h >= STUCK_MAX_H )); then
      alert "stuck: $name run $id ($wname) running ${age_h}h, limit ${STUCK_MAX_H}h"
    fi
  done <<< "$running"
done

# --- alert channel -----------------------------------------------------------
if [[ $notify -eq 1 ]]; then
  mkdir -p "$STATE_DIR"
  fingerprint="$(printf "%s\n" "${alerts[@]}" | sort | sha256sum | cut -d' ' -f1)"
  last="$(cat "$STATE_DIR/last-fingerprint" 2>/dev/null || true)"
  host="$(hostname)"
  stamp="$(date -u '+%Y-%m-%d %H:%M UTC')"

  if (( ${#alerts[@]} == 0 )); then
    issue="$(gh issue list -R "$REPO" --state open --label ci-health --json number --jq '.[0].number // empty' 2>/dev/null)"
    if [[ -n "$issue" ]]; then
      gh issue comment "$issue" -R "$REPO" --body "<!-- ci-health -->
Recovered at $stamp from $host: every listener is active and enabled, all runner registrations are online and no run exceeds its queue or runtime limit. Closing." >/dev/null
      gh issue close "$issue" -R "$REPO" --reason completed >/dev/null
    fi
    printf '%s' "$fingerprint" > "$STATE_DIR/last-fingerprint"
    exit 0
  fi

  {
    echo "<!-- ci-health -->"
    echo "Watchdog on \`$host\` at $stamp."
    echo
    printf -- '- `%s`\n' "${alerts[@]}"
    echo
    echo "This issue is maintained automatically: it is commented when the alert set changes and closed when the host reports healthy again. It never restarts, cancels or cleans anything."
  } > "$STATE_DIR/body"
  if [[ "$fingerprint" != "$last" ]]; then
    issue="$(gh issue list -R "$REPO" --state open --label ci-health --json number --jq '.[0].number // empty' 2>/dev/null)"
    if [[ -z "$issue" ]]; then
      gh label create ci-health -R "$REPO" --color B60205 \
        --description "Automated CI runner and queue alert" >/dev/null 2>&1 || true
      gh issue create -R "$REPO" --title "CI health alert — $host" --label ci-health \
        --body-file "$STATE_DIR/body" >/dev/null
    else
      gh issue comment "$issue" -R "$REPO" --body-file "$STATE_DIR/body" >/dev/null
    fi
    printf '%s' "$fingerprint" > "$STATE_DIR/last-fingerprint"
  fi
fi

(( ${#alerts[@]} == 0 )) && { [[ $quiet -eq 1 ]] || echo 'DOCTOR: healthy'; exit 0; }
[[ $quiet -eq 1 ]] || echo "DOCTOR: ${#alerts[@]} alert(s)"
exit 1
