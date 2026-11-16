#!/usr/bin/env bash
# Isolated restore rehearsal for the newest Samloryx and Nabor backup dumps.
#
# Copies each dump read-only from the backup host, restores it into a disposable
# container with no network and no published ports, and compares the restored
# public table count with the archive's own table of contents. Nothing is
# printed except archive names, sizes, counts and pass/fail; every copied dump
# and container is removed on exit.
#
# BACKUP_HOST is intentionally unset by default: this repository is public and
# must not carry a real production host address. Supply it from your local
# environment, never from a committed file.
#
# Run only on a trusted workstation. The dumps are production data for the
# duration of the run; they are never uploaded anywhere by this script.
set -Eeuo pipefail
umask 077

usage() {
  cat >&2 <<'EOF'
Usage: BACKUP_HOST=user@host bash scripts/rehearse-backup-restore.sh

Environment:
  BACKUP_HOST                 SSH target holding the dumps (required, never committed)
  SAMLORYX_RESTORE_IMAGE      default postgres:18
  NABOR_RESTORE_IMAGE         default postgis/postgis:16-3.6
  SAMLORYX_BACKUP_DIR         default /opt/samloryx/app/ops/backup/out
  NABOR_BACKUP_DIR            default /opt/nabor/backups
EOF
}

[[ "${1:-}" == --help ]] && { usage; exit 0; }
: "${BACKUP_HOST:?Set BACKUP_HOST to the SSH target (never commit it)}"

SAMLORYX_IMAGE="${SAMLORYX_RESTORE_IMAGE:-postgres:18}"
NABOR_IMAGE="${NABOR_RESTORE_IMAGE:-postgis/postgis:16-3.6}"
SAMLORYX_DIR="${SAMLORYX_BACKUP_DIR:-/opt/samloryx/app/ops/backup/out}"
NABOR_DIR="${NABOR_BACKUP_DIR:-/opt/nabor/backups}"

for tool in ssh scp docker awk openssl; do
  command -v "$tool" >/dev/null || { echo "missing required tool: $tool" >&2; exit 2; }
done
docker info >/dev/null 2>&1 || { echo 'docker daemon unavailable' >&2; exit 2; }

DIR="$(mktemp -d "${TMPDIR:-/tmp}/restore-rehearsal.XXXXXX")"
SAMLORYX_CONT="samloryx-rehearsal-$$"
NABOR_CONT="nabor-rehearsal-$$"
SSH=(ssh -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10 "$BACKUP_HOST")
SCP=(scp -q -o BatchMode=yes -o StrictHostKeyChecking=yes -o ConnectTimeout=10)

cleanup() {
  docker rm -f "$SAMLORYX_CONT" "$NABOR_CONT" >/dev/null 2>&1 || true
  rm -rf -- "$DIR"
}
trap cleanup EXIT INT TERM

# The official images run a temporary server while initialising, then restart
# it. Wait for the second readiness banner before issuing any command, or the
# init server shut down mid-restore.
wait_for_final_server() {
  local container=$1 starts
  for _ in $(seq 1 180); do
    starts="$(docker logs "$container" 2>&1 | grep -c 'database system is ready to accept connections' || true)"
    if [[ "$starts" =~ ^[0-9]+$ ]] && (( starts >= 2 )) &&
       docker exec "$container" pg_isready -U restore -d postgres >/dev/null 2>&1; then
      return 0
    fi
    sleep 1
  done
  return 1
}

toc_public_tables() {
  local container=$1 dump=$2
  "${SSH[@]}" "docker exec -i '$container' pg_restore --list" < "$dump" |
    awk -F'; ' '$2 ~ /^[0-9]+ [0-9]+ TABLE DATA public / { n++ } END { print n+0 }'
}

rehearse() {
  local label=$1 image=$2 dump=$3 container=$4 source_container=$5
  local db="${label}_restore"
  local expected count rc status

  expected="$(toc_public_tables "$source_container" "$dump")"
  if [[ ! "$expected" =~ ^[0-9]+$ ]] || (( expected == 0 )); then
    printf '%-9s FAIL archive has no public table entries\n' "$label"
    return 1
  fi

  docker run --detach --rm --name "$container" --network none --shm-size 1g \
    -e POSTGRES_USER=restore -e POSTGRES_DB=postgres \
    -e "POSTGRES_PASSWORD=$(openssl rand -hex 24)" "$image" >/dev/null
  if ! wait_for_final_server "$container"; then
    printf '%-9s FAIL container did not reach a stable server\n' "$label"
    return 1
  fi
  if ! docker exec "$container" createdb -U restore -T template0 "$db"; then
    printf '%-9s FAIL could not create a clean database\n' "$label"
    return 1
  fi

  rc=0
  docker exec -i "$container" pg_restore --exit-on-error --no-owner --no-acl \
    --username=restore --dbname="$db" < "$dump" > "$DIR/$label-pg_restore.log" 2>&1 || rc=$?
  count="$(docker exec "$container" psql -U restore -d "$db" -tAc \
    "select count(*) from pg_catalog.pg_tables where schemaname='public'" | tr -d '[:space:]')"

  status=OK
  (( rc == 0 )) || status="FAIL restore-rc=$rc"
  [[ "$count" == "$expected" ]] || status="FAIL tables=$count expected=$expected"
  printf '%-9s image=%-24s rc=%-2s public_tables=%-4s expected=%-4s %s\n' \
    "$label" "$image" "$rc" "$count" "$expected" "$status"
  [[ "$status" == OK ]]
}

echo "Isolated restore rehearsal $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "Disposable containers, no network, no published ports; dumps deleted on exit."

samloryx_remote="$("${SSH[@]}" "ls -t '$SAMLORYX_DIR'/samloryx-*.dump | head -1")"
nabor_remote="$("${SSH[@]}" "ls -t '$NABOR_DIR'/*.dump | head -1")"
[[ -n "$samloryx_remote" && -n "$nabor_remote" ]] || { echo 'no archive found' >&2; exit 1; }

"${SCP[@]}" "$BACKUP_HOST:$samloryx_remote" "$DIR/samloryx.dump"
"${SCP[@]}" "$BACKUP_HOST:$nabor_remote" "$DIR/nabor.dump"
echo "samloryx $(basename "$samloryx_remote") $(stat -c%s "$DIR/samloryx.dump") bytes"
echo "nabor    $(basename "$nabor_remote") $(stat -c%s "$DIR/nabor.dump") bytes"
echo

fail=0
rehearse samloryx "$SAMLORYX_IMAGE" "$DIR/samloryx.dump" "$SAMLORYX_CONT" samloryx-prod-db-1 || fail=1
rehearse nabor "$NABOR_IMAGE" "$DIR/nabor.dump" "$NABOR_CONT" nabor-db-1 || fail=1

echo
if (( fail )); then
  echo 'RESULT: FAIL — a dump did not restore to its archive table count.' >&2
  exit 1
fi
echo 'RESULT: PASS — both dumps restored with --exit-on-error into isolated containers.'
echo 'Local dumps only: the encrypted Nabor offsite path is not exercised by this script.'
