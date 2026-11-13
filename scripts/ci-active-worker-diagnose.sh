#!/usr/bin/env bash
# Read-only: identify the live worker preventing a safe CI mutex installation.
# Deliberately omit environment values, command arguments, and tokens.
set -euo pipefail
VM=samloryx-ci
command -v multipass >/dev/null || { echo 'multipass unavailable' >&2; exit 1; }

multipass exec "$VM" -- bash -s <<'GUEST'
set -u
echo '=== GitHub Actions Runner.Worker processes ==='
pids="$(pgrep -x Runner.Worker || true)"
if [[ -z "$pids" ]]; then echo 'No active Runner.Worker processes'; fi
for pid in $pids; do
  echo
  ps -p "$pid" -o pid=,ppid=,user=,stat=,etime=,rss=,comm= || true
  exe="$(readlink -f "/proc/$pid/exe" 2>/dev/null || true)"
  runner="$(printf '%s\n' "$exe" | sed -n 's#^/opt/samloryx-runners/ci/\([^/]*\)/.*#\1#p')"
  echo "Runner repository directory: $(printf '%s\n' "$runner" | sed 's/^$/unknown/')"
  echo 'Service cgroup:'
  sed -n 's#^[0-9]*::/system.slice/\(actions.runner[^/]*\).*#\1#p' "/proc/$pid/cgroup" 2>/dev/null | head -1
  echo 'Direct child process names (and RSS):'
  ps -eo pid,ppid,stat,etime,rss,comm | awk -v parent="$pid" '$2==parent {print}' | head -15
done
echo
echo '=== Memory state ==='
free -h
echo 'No process has been interrupted.'
GUEST

if command -v gh >/dev/null && gh auth status >/dev/null 2>&1; then
  echo
  echo '=== GitHub running jobs (up to 30 recent workflow runs per repo) ==='
  for repo in nabor samloryx-os samloryx-consultancy-platform personal-career samloryx-engineering-website samloryx-workspace; do
    printf '%s: ' "$repo"
    gh run list --repo "samkomane008/$repo" --limit 30 \
      --json databaseId,name,status \
      --jq '[.[] | select(.status == "in_progress") | (.name + " #" + (.databaseId|tostring))] | join("; ")' \
      2>/dev/null || echo 'GitHub query unavailable'
  done
fi
