#!/usr/bin/env bash
# Read-only: prove the newest Nabor and Samloryx backup archives can be listed
# by pg_restore, and report table counts. Prints no table names, data or env
# values. Does not connect to a database or write to the remote host.
#
# BACKUP_HOST is intentionally unset by default: this repository is public and
# must not carry a real production host address. Supply it from your local
# environment, never from a committed file.
set -Eeuo pipefail

HOST="${BACKUP_HOST:?Set BACKUP_HOST to the SSH target of the backup host (never commit it)}"
SAMLORYX_DIR="${SAMLORYX_BACKUP_DIR:-/opt/samloryx/app/ops/backup/out}"
NABOR_DIR="${NABOR_BACKUP_DIR:-/opt/nabor/backups}"
SAMLORYX_CONTAINER="${SAMLORYX_DB_CONTAINER:-samloryx-prod-db-1}"
NABOR_CONTAINER="${NABOR_DB_CONTAINER:-nabor-db-1}"
SAMLORYX_MIN_TABLES="${SAMLORYX_MIN_TABLES:-100}"
NABOR_MIN_TABLES="${NABOR_MIN_TABLES:-20}"
SAMLORYX_MAX_AGE_HOURS="${SAMLORYX_MAX_AGE_HOURS:-30}"
NABOR_MAX_AGE_HOURS="${NABOR_MAX_AGE_HOURS:-720}"

command -v ssh >/dev/null || { echo 'ssh unavailable' >&2; exit 2; }

remote() {
  local app=$1 container=$2 dir=$3 pattern=$4
  ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$HOST" \
    "bash -s -- '$app' '$container' '$dir' '$pattern'" <<'REMOTE'
set -euo pipefail
app=$1 container=$2 dir=$3 pattern=$4
f="$(ls -t "$dir"/$pattern 2>/dev/null | head -n1 || true)"
if [[ -z "$f" || ! -r "$f" ]]; then
  printf 'error=no-readable-archive\n'
  exit 0
fi
size="$(stat -c%s "$f")"
epoch="$(stat -c%Y "$f")"
counts="$(docker exec -i "$container" pg_restore --list < "$f" 2>/dev/null | awk -F'; ' '
  /^;/ { next }
  { n++ }
  /TABLE DATA/ { t++ }
  / SCHEMA / { s++ }
  / EXTENSION / { e++ }
  END { printf "toc=%d\ntables=%d\nschemas=%d\nextensions=%d\n", n, t, s, e }
')" || {
  printf 'error=pg_restore-unreadable\n'
  exit 0
}
[[ -n "$counts" ]] || { printf 'error=empty-archive-list\n'; exit 0; }
printf 'archive=%s\nsize=%s\nepoch=%s\n%s\n' "$(basename "$f")" "$size" "$epoch" "$counts"
REMOTE
}

fail=0

check_app() {
  local app=$1 min_tables=$2 max_age_hours=$3 stale_fatal=$4
  local container dir pattern info error archive size epoch tables schemas age_h status
  if [[ "$app" == samloryx ]]; then
    container=$SAMLORYX_CONTAINER dir=$SAMLORYX_DIR pattern='samloryx-*.dump'
  else
    container=$NABOR_CONTAINER dir=$NABOR_DIR pattern='*.dump'
  fi

  info="$(remote "$app" "$container" "$dir" "$pattern")" || {
    printf '%-10s %-34s %10s %7s %7s %7s  %s\n' "$app" '-' '-' '-' '-' '-' 'FAIL ssh'
    fail=1
    return
  }
  error="$(sed -n 's/^error=//p' <<< "$info")"
  if [[ -n "$error" ]]; then
    printf '%-10s %-34s %10s %7s %7s %7s  FAIL %s\n' "$app" '-' '-' '-' '-' '-' "$error"
    fail=1
    return
  fi

  archive="$(sed -n 's/^archive=//p' <<< "$info")"
  size="$(sed -n 's/^size=//p' <<< "$info")"
  epoch="$(sed -n 's/^epoch=//p' <<< "$info")"
  tables="$(sed -n 's/^tables=//p' <<< "$info")"
  schemas="$(sed -n 's/^schemas=//p' <<< "$info")"
  [[ "$epoch" =~ ^[0-9]+$ && "$tables" =~ ^[0-9]+$ ]] || {
    printf '%-10s %-34s %10s %7s %7s %7s  FAIL malformed-output\n' "$app" "${archive:--}" "${size:--}" '-' '-' "${schemas:--}"
    fail=1
    return
  }
  age_h=$(( ( $(date +%s) - epoch ) / 3600 ))
  status=OK
  if (( tables < min_tables )); then
    status="FAIL tables<${min_tables}"
    fail=1
  elif (( age_h > max_age_hours )); then
    if [[ "$stale_fatal" == yes ]]; then
      status="FAIL age>${max_age_hours}h"
      fail=1
    else
      status="WARN age>${max_age_hours}h"
    fi
  fi
  printf '%-10s %-34s %10s %6sh %7s %7s  %s\n' "$app" "$archive" "$size" "$age_h" "$tables" "$schemas" "$status"
}

echo "Backup archive readability (read-only; no database connection)"
printf '%-10s %-34s %10s %7s %7s %7s  %s\n' app archive size age_h tables schemas status
check_app samloryx "$SAMLORYX_MIN_TABLES" "$SAMLORYX_MAX_AGE_HOURS" yes
check_app nabor "$NABOR_MIN_TABLES" "$NABOR_MAX_AGE_HOURS" no
echo
if (( fail )); then
  echo 'RESULT: FAIL. An archive is unreadable, below its table threshold, or (Samloryx) older than its limit.' >&2
  exit 1
fi
echo 'RESULT: PASS. Both newest archives are readable; Samloryx is within its freshness limit.'
echo 'This proves archive readability only. It is not a restore rehearsal.'
