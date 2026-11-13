#!/usr/bin/env bash
# Install pinned, multi-user runner mutex on the CI VM. Default --check is read-only.
set -Eeuo pipefail
MODE="$1"
[[ "$MODE" == --check || "$MODE" == --apply ]] || { echo "Usage: $0 --check|--apply"; exit 2; }
[[ "$(id -u)" == 0 ]] || { echo "Must run as root inside CI VM" >&2; exit 1; }
BASE="$(cd "$(dirname "$0")/.." && pwd)"
SOURCE="$BASE/vendor/actions-runner-mutex"
TARGET="/opt/samloryx-ci-tools/actions-runner-mutex"
ROOT="/opt/samloryx-runners/ci"
LOCK_DIR="/run/samloryx-ci-mutex"
GROUP="samloryx-ci-mutex"
REPOS="nabor personal-career samloryx-consultancy-platform samloryx-engineering-website samloryx-os samloryx-workspace"
exec 9>/run/lock/samloryx-ci-mutex-installer.lock
flock -n 9 || { echo 'Mutex installation already in progress' >&2; exit 1; }
workers() { ps -eo comm= | awk '$1=="Runner.Worker"{n++} END{print n+0}'; }
echo "Runner.Worker count: $(workers)"
for name in $REPOS; do
  dir="$ROOT/$name"
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  [[ -f "$dir/.runner" && -f "$dir/.env" ]] || { echo "STOP: No runner directory for $name" >&2; exit 1; }
  systemctl cat "$unit" >/dev/null || { echo "STOP: No service for $name" >&2; exit 1; }
  user="$(systemctl show -P User "$unit")"
  [[ -n "$user" && "$user" != root ]] || { echo "STOP: Unsafe service user for $name" >&2; exit 1; }
  id "$user" >/dev/null
  for kind in STARTED COMPLETED; do
    key="ACTIONS_RUNNER_HOOK_JOB_$kind"
    existing="$(sed -n "s/^$key=//p" "$dir/.env" | head -n1)"
    expected="$TARGET/hooks/job-started.sh"
    [[ "$kind" == COMPLETED ]] && expected="$TARGET/hooks/job-completed.sh"
    [[ -z "$existing" || "$existing" == "$expected" ]] || { echo "STOP: Existing $key for $name" >&2; exit 1; }
  done
  inherited="$(systemctl show -P Environment "$unit")"
  [[ "$inherited" != *ACTIONS_RUNNER_HOOK_JOB_STARTED* && "$inherited" != *ACTIONS_RUNNER_HOOK_JOB_COMPLETED* ]] || {
    echo "STOP: inherited hook for $name; review before applying" >&2; exit 1;
  }
  printf '%-36s %s\n' "$name" "$(systemctl is-active "$unit" || true)"
done
if [[ "$MODE" == --check ]]; then
  echo 'CHECK COMPLETE: no changes made. Apply only when the host is idle.'
  exit 0
fi
[[ "$(workers)" == 0 ]] || { echo 'STOP: Active CI job; no changes made' >&2; exit 3; }
for f in LICENSE job-lock.sh hooks/job-started.sh hooks/job-completed.sh test/run-tests.sh; do
  [[ -s "$SOURCE/$f" ]] || { echo "STOP: Missing $f" >&2; exit 1; }
done
TMP="$(mktemp -d)"
trap 'rm -rf "$TMP"' EXIT
cp -a "$SOURCE" "$TMP/mutex"
chmod +x "$TMP/mutex/job-lock.sh" "$TMP/mutex/hooks/"*.sh "$TMP/mutex/test/run-tests.sh"
(cd "$TMP/mutex" && bash test/run-tests.sh) > "$TMP/test.log" 2>&1 || {
  echo 'STOP: Mutex tests failed. No services changed.' >&2
  tail -25 "$TMP/test.log" >&2
  exit 1
}
echo 'Mutex regression tests: PASS'
[[ "$(workers)" == 0 ]] || { echo 'STOP: Job started during preflight; no changes made' >&2; exit 3; }
# Stop all idle listeners before configuring any to prevent mixed guarded/unguarded work.
for name in $REPOS; do
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  if [[ "$(systemctl is-active "$unit" || true)" == active ]]; then systemctl stop "$unit"; fi
done
[[ "$(workers)" == 0 ]] || { echo 'STOP: CI worker still active. Services left stopped for inspection.' >&2; exit 4; }
[[ ! -e "$TARGET" || -f "$TARGET/.samloryx-vendored" ]] || { echo 'STOP: Existing unrecognized mutex install' >&2; exit 5; }
if [[ ! -d "$TARGET" ]]; then
  install -d -m 0755 /opt/samloryx-ci-tools
  cp -a "$TMP/mutex" "$TARGET"
  touch "$TARGET/.samloryx-vendored"
  chown -R root:root "$TARGET"
  chmod -R go-w "$TARGET"
fi
groupadd -f "$GROUP"
for name in $REPOS; do
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  user="$(systemctl show -P User "$unit")"
  usermod -aG "$GROUP" "$user"
done
policy="d $LOCK_DIR 2770 root $GROUP -"
tmpfiles="/etc/tmpfiles.d/samloryx-ci-mutex.conf"
[[ ! -f "$tmpfiles" || "$(cat "$tmpfiles")" == "$policy" ]] || { echo 'STOP: Conflicting tmpfiles policy' >&2; exit 6; }
printf '%s\n' "$policy" > "$tmpfiles"
systemd-tmpfiles --create "$tmpfiles"
install -d -m 2770 -o root -g "$GROUP" "$LOCK_DIR"
chmod 2770 "$LOCK_DIR"
backup="/var/backups/samloryx-ci-mutex/$(date +%Y%m%d-%H%M%S)"
install -d -m 0700 "$backup"
for name in $REPOS; do
  f="$ROOT/$name/.env"
  cp -p "$f" "$backup/$name.env"
  python3 - "$f" "$TARGET" "$LOCK_DIR" <<'PY'
from pathlib import Path
import sys
p, t, lock = Path(sys.argv[1]), sys.argv[2], sys.argv[3]
changes = {
    'ACTIONS_RUNNER_HOOK_JOB_STARTED':f'{t}/hooks/job-started.sh',
    'ACTIONS_RUNNER_HOOK_JOB_COMPLETED':f'{t}/hooks/job-completed.sh',
    'JOB_LOCK_DIR':lock,
    'JOB_LOCK_SLOTS':'1',
    'JOB_LOCK_MAX_WAIT_SECS':'2700',
    'JOB_LOCK_OWNERLESS_GRACE':'90'
}
mode = p.stat().st_mode & 0o777
result, seen = [], set()
for line in p.read_text().splitlines():
    key = line.partition('=')[0]
    if key in changes:
        if key in seen: raise SystemExit('Duplicate .env key: manual review required')
        seen.add(key)
        result.append(f'{key}={changes[key]}')
    else: result.append(line)
for k,v in changes.items():
    if k not in seen: result.append(f'{k}={v}')
p.write_text('\n'.join(result) + '\n')
p.chmod(mode)
PY
done
for name in $REPOS; do
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  systemctl reset-failed "$unit" || true
  systemctl start "$unit" || echo "WARNING: start failed for $name" >&2
done
echo '=== Runner services after installation ==='
for name in $REPOS; do
  unit="actions.runner.samkomane008-$name.samloryx-ci-$name-ci.service"
  printf '%-36s %s\n' "$name" "$(systemctl is-active "$unit" || true)"
done
echo 'Host-wide mutex hooks installed. Prove serialization with two cross-repository canary jobs.'
echo 'Root-only .env backups: /var/backups/samloryx-ci-mutex/'
