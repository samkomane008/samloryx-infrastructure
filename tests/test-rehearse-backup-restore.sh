#!/usr/bin/env bash
# Offline tests for scripts/rehearse-backup-restore.sh using fake ssh/scp/docker.
# The mock never starts a container and touches no host or database.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/rehearse-backup-restore.sh"
DIR="$(mktemp -d)"
trap 'rm -rf -- "$DIR"' EXIT
mkdir -p "$DIR/bin"

cat > "$DIR/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
cmd="${*: -1}"
if [[ "$cmd" == *"pg_restore --list"* ]]; then
  if [[ "$cmd" == *samloryx* ]]; then n="${MOCK_SAMLORYX_TOC:-160}"; else n="${MOCK_NABOR_TOC:-47}"; fi
  for ((i = 0; i < n; i++)); do echo "1; 0 0 TABLE DATA public t$i owner"; done
elif [[ "$cmd" == *"ls -t"*samloryx* ]]; then
  echo "/backup/samloryx-fixture.dump"
elif [[ "$cmd" == *"ls -t"*nabor* ]]; then
  echo "/backup/nabor-fixture.dump"
else
  echo "unexpected ssh command: $cmd" >&2
  exit 1
fi
MOCK

cat > "$DIR/bin/scp" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
dest="${*: -1}"
printf 'fixture-dump-bytes' > "$dest"
MOCK

cat > "$DIR/bin/docker" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
case "${1:-}" in
  info) exit 0 ;;
  run) echo 'mock-container-id' ;;
  logs) printf 'database system is ready to accept connections\n%.0s' 1 2 ;;
  rm) exit 0 ;;
  exec)
    shift
    [[ "${1:-}" == "-i" ]] && shift
    container="${1:-}"; shift || true
    case "${1:-}" in
      pg_isready) exit 0 ;;
      createdb) exit 0 ;;
      pg_restore)
        if [[ "$container" == *samloryx* ]]; then exit "${MOCK_SAMLORYX_RC:-0}"; else exit "${MOCK_NABOR_RC:-0}"; fi ;;
      psql)
        if [[ "$*" == *samloryx_restore* ]]; then echo "${MOCK_SAMLORYX_TABLES:-160}"; else echo "${MOCK_NABOR_TABLES:-47}"; fi ;;
      *) echo "unexpected docker exec: $*" >&2; exit 1 ;;
    esac
    ;;
  *) echo "unexpected docker command: $*" >&2; exit 1 ;;
esac
MOCK

chmod +x "$DIR/bin/ssh" "$DIR/bin/scp" "$DIR/bin/docker"
export PATH="$DIR/bin:$PATH"
export BACKUP_HOST=fake

run() {
  local label=$1 expected=$2
  shift 2
  set +e
  env "$@" bash "$SCRIPT" > "$DIR/out" 2>&1
  local rc=$?
  set -e
  if [[ "$expected" == pass && $rc -ne 0 ]] || [[ "$expected" == fail && $rc -eq 0 ]]; then
    echo "FAIL $label: expected $expected, got $rc"
    cat "$DIR/out"
    exit 1
  fi
  echo "PASS $label ($expected, rc=$rc)"
}

run healthy-both pass
run samloryx-restore-error fail MOCK_SAMLORYX_RC=1
run nabor-table-mismatch fail MOCK_NABOR_TABLES=40
run empty-archive-toc fail MOCK_NABOR_TOC=0
run missing-backup-host fail -u BACKUP_HOST

if grep -Eq '([0-9]{1,3}\.){3}[0-9]{1,3}' "$SCRIPT"; then
  echo 'FAIL host-literal: script contains an IPv4 address'
  exit 1
fi
echo 'PASS host-literal (none)'
