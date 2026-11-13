#!/usr/bin/env bash
# Test suite for job-lock.sh. Uses sleep processes as stand-ins for
# Runner.Worker (via the JOB_LOCK_OWNER_PID / JOB_LOCK_COMM test overrides)
# and an isolated JOB_LOCK_DIR, so it never touches a live installation.
set -u

REPO_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
JL="$REPO_DIR/job-lock.sh"
WORK=$(mktemp -d)
export JOB_LOCK_DIR="$WORK/lock"

PASS=0; FAIL=0
check() { # check <desc> <expected> <actual>
  if [ "$2" = "$3" ]; then echo "PASS: $1"; PASS=$((PASS+1));
  else echo "FAIL: $1 (expected=$2 actual=$3)"; FAIL=$((FAIL+1)); fi
}
cleanup() { pkill -P $$ sleep 2>/dev/null; rm -rf "$WORK"; }
trap cleanup EXIT

echo "=== single slot ==="
sleep 300 & H1=$!
JOB_LOCK_OWNER_PID=$H1 JOB_LOCK_COMM=sleep "$JL" acquire
check "acquire succeeds" 0 $?
check "slot exists" yes "$([ -d "$JOB_LOCK_DIR/slot-1" ] && echo yes || echo no)"
check "owner pid recorded" "pid=$H1" "$(head -n1 "$JOB_LOCK_DIR/slot-1/owner")"

sleep 300 & H2=$!
START=$(date +%s)
JOB_LOCK_OWNER_PID=$H2 JOB_LOCK_COMM=sleep JOB_LOCK_MAX_WAIT_SECS=8 "$JL" acquire
RC=$?; ELAPSED=$(( $(date +%s) - START ))
check "second acquire times out with 1" 1 $RC
check "waited at least 8s" yes "$([ "$ELAPSED" -ge 8 ] && echo yes || echo no)"

JOB_LOCK_OWNER_PID=$H2 JOB_LOCK_COMM=sleep "$JL" release
check "non-owner release keeps lock" yes "$([ -d "$JOB_LOCK_DIR/slot-1" ] && echo yes || echo no)"
JOB_LOCK_OWNER_PID=$H1 JOB_LOCK_COMM=sleep "$JL" release
check "owner release removes lock" no "$([ -d "$JOB_LOCK_DIR/slot-1" ] && echo yes || echo no)"

echo "=== stale stealing ==="
sleep 300 & H3=$!
JOB_LOCK_OWNER_PID=$H3 JOB_LOCK_COMM=sleep "$JL" acquire
kill -9 $H3; wait $H3 2>/dev/null
START=$(date +%s)
JOB_LOCK_OWNER_PID=$H2 JOB_LOCK_COMM=sleep JOB_LOCK_MAX_WAIT_SECS=30 "$JL" acquire
RC=$?; ELAPSED=$(( $(date +%s) - START ))
check "steal from dead holder" 0 $RC
check "steal is quick (<15s)" yes "$([ "$ELAPSED" -lt 15 ] && echo yes || echo no)"
JOB_LOCK_OWNER_PID=$H2 JOB_LOCK_COMM=sleep "$JL" release

echo "=== ownerless grace ==="
mkdir -p "$JOB_LOCK_DIR/slot-1"
sleep 3
JOB_LOCK_OWNERLESS_GRACE=2 JOB_LOCK_OWNER_PID=$H2 JOB_LOCK_COMM=sleep JOB_LOCK_MAX_WAIT_SECS=30 "$JL" acquire
check "ownerless slot stolen after grace" 0 $?
JOB_LOCK_OWNER_PID=$H2 JOB_LOCK_COMM=sleep "$JL" release

echo "=== cancel while waiting (TERM) ==="
sleep 300 & H4=$!
JOB_LOCK_OWNER_PID=$H4 JOB_LOCK_COMM=sleep "$JL" acquire
sleep 300 & H5=$!
JOB_LOCK_OWNER_PID=$H5 JOB_LOCK_COMM=sleep JOB_LOCK_MAX_WAIT_SECS=60 "$JL" acquire &
WAITER=$!
sleep 2
kill -TERM $WAITER
wait $WAITER
check "waiter exits non-zero on TERM" yes "$([ $? -ne 0 ] && echo yes || echo no)"
check "lock still held by H4" "pid=$H4" "$(head -n1 "$JOB_LOCK_DIR/slot-1/owner")"
JOB_LOCK_OWNER_PID=$H4 JOB_LOCK_COMM=sleep "$JL" release

echo "=== N slots (JOB_LOCK_SLOTS=2) ==="
sleep 300 & S1=$!
sleep 300 & S2=$!
sleep 300 & S3=$!
JOB_LOCK_SLOTS=2 JOB_LOCK_OWNER_PID=$S1 JOB_LOCK_COMM=sleep "$JL" acquire
check "slot 1 acquired" 0 $?
JOB_LOCK_SLOTS=2 JOB_LOCK_OWNER_PID=$S2 JOB_LOCK_COMM=sleep "$JL" acquire
check "slot 2 acquired concurrently" 0 $?
JOB_LOCK_SLOTS=2 JOB_LOCK_OWNER_PID=$S3 JOB_LOCK_COMM=sleep JOB_LOCK_MAX_WAIT_SECS=6 "$JL" acquire
check "third job waits then times out" 1 $?
JOB_LOCK_SLOTS=2 JOB_LOCK_OWNER_PID=$S1 JOB_LOCK_COMM=sleep "$JL" release
JOB_LOCK_SLOTS=2 JOB_LOCK_OWNER_PID=$S3 JOB_LOCK_COMM=sleep JOB_LOCK_MAX_WAIT_SECS=10 "$JL" acquire
check "third job gets freed slot" 0 $?
JOB_LOCK_SLOTS=2 JOB_LOCK_OWNER_PID=$S2 JOB_LOCK_COMM=sleep "$JL" release
JOB_LOCK_SLOTS=2 JOB_LOCK_OWNER_PID=$S3 JOB_LOCK_COMM=sleep "$JL" release

echo "=== worker-pid resolution through a process chain ==="
# Real chain is: Runner.Worker -> hook shell -> job-lock.sh. Simulate with:
# fake worker (bash) -> intermediate zsh/sh -c -> job-lock.sh, and make the
# lock look for "bash" ancestors. The recorded pid must be the fake worker,
# not the short-lived intermediate.
INTERMEDIATE_SHELL=$(command -v zsh || command -v sh)
FAKE="$WORK/fake-worker.sh"
cat > "$FAKE" <<EOF
#!/bin/bash
"$INTERMEDIATE_SHELL" -c '"$JL" acquire'
sleep 12
"$INTERMEDIATE_SHELL" -c '"$JL" release'
EOF
chmod +x "$FAKE"
JOB_LOCK_COMM=bash bash "$FAKE" &
FW=$!
sleep 3
check "owner resolves to fake worker" "pid=$FW" "$(head -n1 "$JOB_LOCK_DIR/slot-1/owner" 2>/dev/null)"
sleep 300 & COMP=$!
JOB_LOCK_OWNER_PID=$COMP JOB_LOCK_COMM=bash JOB_LOCK_MAX_WAIT_SECS=5 "$JL" acquire
check "no steal while fake worker alive" 1 $?
wait $FW
check "released after fake job ends" no "$([ -d "$JOB_LOCK_DIR/slot-1" ] && echo yes || echo no)"

echo ""
echo "RESULT: PASS=$PASS FAIL=$FAIL"
[ "$FAIL" -eq 0 ]
