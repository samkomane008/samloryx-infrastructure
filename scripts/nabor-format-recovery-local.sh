#!/usr/bin/env bash
# One-time Nabor formatting repair from a fresh, isolated worktree.
# Does not change the active checkout, production server, or main branch.
set -Eeuo pipefail

NABOR_REPO="$HOME/Desktop/Workstation/Nabor"
if (( $# > 0 )); then NABOR_REPO="$1"; fi
REPO="samkomane008/nabor"
command -v git >/dev/null || { echo "git required" >&2; exit 1; }
command -v gh >/dev/null || { echo "gh required" >&2; exit 1; }
command -v pnpm >/dev/null || { echo "pnpm required (CI uses pnpm 10.34.9)" >&2; exit 1; }
[[ -d "$NABOR_REPO/.git" ]] || { echo "STOP: Nabor clone not found at $NABOR_REPO. Pass its path as argument." >&2; exit 2; }
git -C "$NABOR_REPO" remote get-url origin | grep -Eq '(^|[:/])samkomane008/nabor(\.git)?$' || {
  echo 'STOP: origin does not appear to be samkomane008/nabor' >&2; exit 2;
}
gh auth status >/dev/null || { echo 'STOP: GitHub CLI not authenticated' >&2; exit 2; }

echo 'Fetching latest main without modifying your active Nabor checkout...'
git -C "$NABOR_REPO" fetch origin main
PARENT="$(dirname "$(realpath "$NABOR_REPO")")"
BRANCH="fix/ci-format-$(date -u +%Y%m%d%H%M%S)"
WT="$PARENT/nabor-format-recovery-$(date -u +%Y%m%d%H%M%S)"
echo "Isolated worktree: $WT"
git -C "$NABOR_REPO" worktree add -b "$BRANCH" "$WT" origin/main
cd "$WT"

echo 'Installing pinned workspace dependencies...'
pnpm install --frozen-lockfile

echo 'Applying repository Prettier rules to a clean worktree...'
pnpm exec prettier --write .
pnpm exec prettier --check .
git diff --check

echo 'Changed tracked files:'
git diff --name-only
if git diff --quiet; then
  echo 'No formatting changes needed on current main. No PR created.'
  exit 0
fi

if git status --porcelain | grep -qE '^\?\?'; then
  echo 'NOTICE: Untracked build/cache files present; these will NOT be committed.'
fi
git add -u
if git diff --cached --quiet; then
  echo 'No tracked formatting changes to commit.'
  exit 0
fi

# Attribution belongs to the owner's logged-in GitHub profile, not an agent.
git config user.name "Samuel Komane"
git config user.email "159257666+samkomane008@users.noreply.github.com"
echo 'Committing tracked formatting-only changes...'
git commit -m "style: apply Prettier to restore Nabor quality gate"
git push -u origin "$BRANCH"

echo 'Opening a pull request; required CI tests will run on the self-hosted runner...'
gh pr create --repo "$REPO" --base main --head "$BRANCH" \
  --title 'style: restore Prettier formatting gate for current Nabor main' \
  --body '## Scope
Prettier-only formatting from a fresh origin/main worktree. No manual changes to behavior, permissions, payments, or infrastructure.

## Verified locally
- pnpm install --frozen-lockfile
- pnpm exec prettier --write .
- pnpm exec prettier --check .
- git diff --check

Closes #193 only when the exact-head full quality and browser checks pass and the fix is merged.

## Release requirements
Do not merge before required CI is green. A merged code formatting PR is not a verified deployment. Preview release still requires exact-main SHA quality/Sonar and trusted deployment credentials.

Tracked in samkomane008/samloryx-infrastructure#3.'

echo
echo 'SUCCESS: formatting PR created. Inspect the PR and exact-head CI results before merge.'
echo "Worktree retained for review: $WT"
