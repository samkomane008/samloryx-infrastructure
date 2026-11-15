#!/usr/bin/env bash
# Resume the Nabor formatter worktree after an interrupted Git commit.
# Only commits the existing staged Prettier changes on a fix/ci-format-* branch.
set -Eeuo pipefail

ROOT="$HOME/Desktop/Workstation/Nabor"
if (( $# > 0 )); then ROOT="$1"; fi
[[ -d "$ROOT/.git" ]] || { echo "STOP: Nabor checkout not found at $ROOT" >&2; exit 1; }
git -C "$ROOT" remote get-url origin | grep -Eq '(^|[:/])samkomane008/nabor(\.git)?$' || { echo "STOP: unexpected origin" >&2; exit 1; }
gh auth status >/dev/null || { echo "STOP: gh authentication missing" >&2; exit 1; }

WT="$(git -C "$ROOT" worktree list --porcelain | sed -n 's/^worktree //p' | grep '/nabor-format-recovery-' || true)"
[[ -n "$WT" ]] || { echo "STOP: no Nabor formatting-recovery worktree found" >&2; exit 1; }
if (( $(printf "%s\n" "$WT" | wc -l) != 1 )); then
  echo "STOP: multiple formatting-recovery worktrees found; inspect: git -C $ROOT worktree list" >&2
  exit 1
fi
BRANCH="$(git -C "$WT" branch --show-current)"
[[ "$BRANCH" == fix/ci-format-* ]] || { echo "STOP: wrong branch $BRANCH" >&2; exit 1; }
[[ -z "$(git -C "$WT" status --porcelain | grep '^??' || true)" ]] || { echo "STOP: unexpected untracked files in worktree" >&2; exit 1; }
git -C "$WT" diff --cached --check
git -C "$WT" diff --check
STAGED="$(git -C "$WT" diff --cached --name-only)"
[[ -n "$STAGED" ]] || { echo "STOP: no staged formatting changes found" >&2; exit 1; }
COUNT="$(printf "%s\n" "$STAGED" | wc -l)"
if (( COUNT > 100 )); then echo "STOP: $COUNT staged files; inspect unexpected size" >&2; exit 1; fi
if printf "%s\n" "$STAGED" | grep -Eq '(^\.github/|^scripts/|\.env|^pnpm-lock\.yaml$)'; then
  echo "STOP: staged changes include CI, scripts, environment or lockfile; manual review required" >&2; exit 1;
fi
echo "Resuming $BRANCH with $COUNT staged source files:"
printf "%s\n" "$STAGED"
git -C "$WT" config user.name "Samuel Komane"
git -C "$WT" config user.email "sam.komane8@gmail.com"
git -C "$WT" commit -m "style: apply Prettier to restore Nabor quality gate"
git -C "$WT" push -u origin "$BRANCH"
gh pr create --repo samkomane008/nabor --base main --head "$BRANCH" \
  --title "style: restore Nabor Prettier formatting gate" \
  --body "Automated formatting-only change from a fresh Nabor main worktree. Locally verified pnpm exec prettier --check . and git diff --check. Fixes #193 only after exact-head GitHub quality and browser acceptance checks pass, merging the PR, and verifying main. Never bypass mandatory CI or production launch gates. Infrastructure rollout tracking: samkomane008/samloryx-infrastructure#3."
echo "Done. Do not merge before required CI and Sonar quality checks pass."
