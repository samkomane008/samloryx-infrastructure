# CI VM — host-wide job mutex recovery

**Status: staged in Git, not installed or validated on the owner's CI VM.**

## Problem

Six GitHub repository-level self-hosted Actions runners share one Multipass Ubuntu VM (~5.8 GiB RAM). Two global OOM kills affected Nabor and Samloryx OS on 13 November 2026. The registered runner services currently have no job-start/completion hooks in their local `.env` files. Existing scan workflows and Java builds can exceed available RAM when they overlap.

## Solution

Vendored, pinned [actions-runner-mutex](https://github.com/cathandnya/actions-runner-mutex) (MIT) at upstream revision `b3aa60a18b35d87701d01e3829954108d1deb7ec`, with small local modifications:

- Use process listing for cross-service-user liveness checking, because `kill -0` can return EPERM for a live worker owned by another service account.
- Use `umask 0007` so runners in a shared group can read/update lock owner records and safely release a stale slot.
- Configure `/run/samloryx-ci-mutex` as a root-owned setgid `2770` directory with a dedicated Linux group; restored by systemd-tmpfiles after reboot.
- Give each existing runner service account supplementary membership in that group.
- Enable both GitHub Actions runner job hooks on all six runners, with `JOB_LOCK_SLOTS=1`. The start hook waits for a slot; the completion hook releases it. Stale-worker checks allow recovery after unexpected termination.
- Preserve root-only backups of existing runner `.env` files for rollback.

This implementation is a **candidate, not yet verified in the live VM**. The upstream project is small; the vendored changes and cross-account permissions need in-VM testing, and an end-to-end two-repository job overlap test is mandatory before considering this complete.

## Deployment from the trusted Ubuntu workstation

```bash
cd ~/Desktop/Workstation/samloryx-infrastructure
git pull --ff-only

# Read-only preflight, including whether jobs are active
bash scripts/deploy-ci-mutex.sh --check

# Only when there are no active runner workers:
bash scripts/deploy-ci-mutex.sh --apply
```

The apply command re-runs preflight, executes the bundled upstream regression tests **before stopping any services**, then stops listeners, sets up the shared lock, backs up runner environments, installs hooks and starts services including Nabor. It stops without changing anything when a worker is detected before mutation. A race is still possible if a new job is assigned between the idle check and service stop, so prefer a genuinely quiet CI window. If a worker persists after stopping listeners, the script fails closed and leaves services stopped for investigation.

## Rollback

```bash
bash scripts/rollback-ci-mutex.sh --check
bash scripts/rollback-ci-mutex.sh --apply
```

Rollback requires no active workers and restores the oldest preinstallation snapshot of each runner's `.env` from a root-only directory **inside the CI VM**. It does not delete the shared group, vendor code or the running production server.

## Verify successful operation

1. Verify all six systemd runner services are active and GitHub runner registrations display online.
2. Run `bash scripts/ci-hook-wiring-diagnose.sh`. All six runner environment files should reference the same **started** and **completed** hook paths.
3. Run two small, non-deploying canary jobs in different repositories at nearly the same time. One should wait at `Set up runner` while the other completes. Do not initially use heavy build/scan jobs.
4. Inspect `journalctl -k` for new global OOM events; verify there are none during canaries.
5. Set Nabor's `NABOR_CI_RUNNERS` GitHub repository variable to `["self-hosted","Linux","X64","nabor-ci"]` only after its runner is confirmed healthy and isolated from production credentials. Existing workflows currently default to `ubuntu-latest` when the variable is absent.
6. Separately measure Java/Node/scanner memory consumption and add conservative heap, CPU and memory limits. **A mutex does not prevent a single oversized job from exhausting the VM.**

## Security cautions

- Production secrets and privileged Docker sockets must not be exposed to untrusted PR code.
- Each runner service account must be restricted to CI workloads; membership in a shared lock group does **not** authorize production access.
- A separate UNIX account is not a strong security boundary if the runner can access the host Docker daemon.
- Repositories with untrusted contributions should use an isolated disposable runner instead.
- The mutex is local to the VM; it does not serialize jobs on other VMs or machines.
- GitHub workflow `timeout-minutes` includes mutex waiting time; do not indiscriminately increase timeouts to mask capacity problems.
- The upstream component is MIT-licensed but is not a formally verified security control. Pin revisions, audit updates and test before production adoption.
