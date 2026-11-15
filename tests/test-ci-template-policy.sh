#!/usr/bin/env bash
# Guard reusable CI template against regressions in release safety.
set -Eeuo pipefail
ROOT="$(cd "$(dirname "$0")/.." && pwd)"
FILE="$ROOT/templates/github/workflows/quality.example.yml"
grep -Fq '  push:' "$FILE" || { echo 'Main push tests missing' >&2; exit 1; }
grep -Fq '  pull_request:' "$FILE" || { echo 'PR tests missing' >&2; exit 1; }
grep -Fq '  cancel-in-progress: ${{ github.event_name == ' "$FILE" &&
  grep -Fq "'pull_request' }}" "$FILE" ||
  { echo 'Must preserve main validation' >&2; exit 1; }
grep -Fq 'github.event.pull_request.head.repo.full_name == github.repository' "$FILE" ||
  { echo 'Must reject untrusted fork code on persistent CI' >&2; exit 1; }
grep -Fq 'persist-credentials: false' "$FILE" ||
  { echo 'Checkout credential isolation missing' >&2; exit 1; }
grep -Fq '    timeout-minutes: 90' "$FILE" ||
  { echo 'CI timeout must allow mutex queue waits' >&2; exit 1; }
echo 'PASS reusable CI template release safety invariants'
