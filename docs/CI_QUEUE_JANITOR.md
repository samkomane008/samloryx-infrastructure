# CI queue janitor: dry-run first

Samloryx OS and Nabor share a one-slot self-hosted CI mutex. Old PR workflows may continue running after merging, or obsolete queued runs can prevent latest-main validation.

Usage from the Infrastructure repository:

```bash
bash scripts/prune-obsolete-ci-runs.sh samkomane008/nabor --dry-run
bash scripts/prune-obsolete-ci-runs.sh samkomane008/samloryx-os --dry-run
```

Review every candidate. Then apply up to 20 guarded cancellations, without cancelling running jobs:

```bash
bash scripts/prune-obsolete-ci-runs.sh samkomane008/nabor --apply
```

To cancel **in-progress** runs, additionally require explicit opt-in; only runs on exact heads of **already merged PRs** qualify:

```bash
bash scripts/prune-obsolete-ci-runs.sh samkomane008/nabor --apply --include-merged-active
```

The script paginates all candidate workflows and PRs and rechecks each run's status/identity, matching current open PR heads, merged PR heads, latest main SHA and exact-current-main replacement workflow before cancellation. It refuses when main changes during execution, skips active jobs in queued workflows, limits a batch to 20 and never selects production deployment workflows. It does **not** bypass builds, tests, security, protection rules or release checks. Cancellation requests are asynchronous: inspect final status in GitHub. Never kill a runner or delete the VM mutex just to clear a queue.

Validation before merging this change: Bash syntax, shellcheck if installed, dry-run output on both repos, manual verification of candidate classification against GitHub API. Existing per-repository prune scripts remain available.