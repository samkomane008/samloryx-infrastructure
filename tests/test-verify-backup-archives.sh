#!/usr/bin/env bash
# Offline tests for scripts/verify-backup-archives.sh using a fake ssh.
set -euo pipefail
SCRIPT="$(cd "$(dirname "$0")/.." && pwd)/scripts/verify-backup-archives.sh"
DIR="$(mktemp -d)"
trap 'rm -rf -- "$DIR"' EXIT
mkdir -p "$DIR/bin"
cat > "$DIR/bin/ssh" <<'MOCK'
#!/usr/bin/env bash
set -euo pipefail
now="$(date +%s)"
case "$*" in
  *samloryx*)
    if [[ -n "${MOCK_SAM_ERROR:-}" ]]; then echo "error=${MOCK_SAM_ERROR}"; exit 0; fi
    tables=${MOCK_SAM_TABLES:-160}; age=${MOCK_SAM_AGE_H:-1}
    ;;
  *nabor*)
    if [[ -n "${MOCK_NABOR_ERROR:-}" ]]; then echo "error=${MOCK_NABOR_ERROR}"; exit 0; fi
    tables=${MOCK_NABOR_TABLES:-54}; age=${MOCK_NABOR_AGE_H:-48}
    ;;
  *) echo "error=unexpected-target" ; exit 0 ;;
esac
echo "archive=fixture.dump"
echo "size=2797996"
echo "epoch=$(( now - age * 3600 ))"
echo "toc=1225"
echo "tables=${tables}"
echo "schemas=0"
echo "extensions=2"
MOCK
chmod +x "$DIR/bin/ssh"
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
run unreadable-samloryx fail MOCK_SAM_ERROR=pg_restore-unreadable
run low-samloryx-tables fail MOCK_SAM_TABLES=99
run stale-samloryx fail MOCK_SAM_AGE_H=40
run stale-nabor-warns pass MOCK_NABOR_AGE_H=1000
run unreadable-nabor fail MOCK_NABOR_ERROR=no-readable-archive
run low-nabor-tables fail MOCK_NABOR_TABLES=19
