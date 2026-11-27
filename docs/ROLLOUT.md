# Rollout acceptance matrix

The single record of what is actually proven for the three repositories, with the evidence and
the remaining work. Update it only with observed results. An item is **VERIFIED** only when the
evidence column names a run, a restore or a live read-only check from a specific date.

Legend: **VERIFIED** — proven by recorded evidence · **PARTIAL** — some evidence, a named gap
remains · **OPEN** — not started or no evidence · **BLOCKED** — cannot proceed without an owner
decision or a paid feature.

Last verified: **16 November 2026** (CD rows); **15 November 2026** (others).

## Stage 0 — Baseline

| Requirement | Status | Evidence | Remaining work |
|---|---|---|---|
| Review workflow triggers, runner labels and secret access | VERIFIED | All workflows in Nabor, Samloryx OS, this repository and the four supporting repositories reviewed on 14–15 Nov; labels are `self-hosted,linux,x64,samloryx-ci` (Nabor: `nabor-ci`), and every repository carries its label list in a repository variable | Re-review when a workflow is added |
| Inspect backups, recovery, production deployment and branch protections | VERIFIED | Samloryx nightly + hourly backup cron and dumps observed; Nabor local pre-deploy dumps only; CD default-off (`NABOR_DEPLOY_ENABLED=false`, `SAMLORYX_GITHUB_DEPLOY_ENABLED` unset); protection read on 15 Nov: 404 (available, now enabled) for this public repository, 403 "upgrade to GitHub Pro" for `samloryx-os` and `nabor` | Re-check before each release |
| No production change before a repeatable test and rollback exist | VERIFIED | No production service, database or deploy switch was changed on 14–15 Nov; the only host changes were runner enablement, monitoring and power-management settings | Keep the rule |

## Stage 1 — Runner recovery

| Requirement | Status | Evidence | Remaining work |
|---|---|---|---|
| `samloryx-ci` VM reachable | VERIFIED | `bash scripts/runner-doctor.sh` on 15 Nov: VM running, 4 vCPU, 5.8 GiB, 30 GiB of 58 GiB used | None |
| Listener health and registration per repository | VERIFIED | 15 Nov: the Nabor listener was found `disabled`/`inactive` after the host reboot (queued run 43686079752 stalled); enabled and started, that run then succeeded at 07:36Z. All six units are now `active` **and** `enabled`, all six registrations `online` (doctor exit 0). 16 Nov: `personal-career` decommissioned by owner decision (no CI): service stopped and uninstalled, registration removed; five listeners remain | Re-run the doctor after any host change. 27 Nov: all five listeners stopped after a reboot with a fast clock; `scripts/install-runner-boot-recovery.sh` now orders them after time sync and restarts them after any exit ([incident](incidents/2026-11-27-runners-down-after-reboot.md)). A full reboot rehearsal is still pending |
| Serial gate inspected, not blindly reinstalled | VERIFIED | Installer fails closed (PR #15); live single slot held by worker PID 45788 during the Samloryx platform build, released on completion; `install-ci-mutex-vm.sh` now also `enable`s each unit and exits 7 unless every one is active and enabled (PR #21, `3144926`) | Apply only in a quiet window if ever needed |
| Harmless canary workflow | VERIFIED (5 of 6) | Secret-free canary merged and dispatched in nabor ([43692579980](https://github.com/samkomane008/nabor/actions/runs/43692579980)), samloryx-engineering-website ([43693148028](https://github.com/samkomane008/samloryx-engineering-website/actions/runs/43693148028)), samloryx-workspace ([43693422739](https://github.com/samkomane008/samloryx-workspace/actions/runs/43693422739)), personal-career ([43694108357](https://github.com/samkomane008/personal-career/actions/runs/43694108357)) and samloryx-consultancy-platform ([43693860699](https://github.com/samkomane008/samloryx-consultancy-platform/actions/runs/43693860699)) on 15 Nov, all successful; details in `docs/CI_CANARY.md` | samloryx-os canary is [draft PR #397](https://github.com/samkomane008/samloryx-os/pull/397): GitHub cannot dispatch a workflow that exists only on a branch, and merging it to `main` is a production release — owner decision |
| Concurrency, memory and disk controls | VERIFIED | One-slot mutex enforced and proven across repositories: the samloryx-workspace canary waited 185 s at `[job-lock]` while samloryx-consultancy-platform held slot-1, then ran in under a second ([43693422739](https://github.com/samkomane008/samloryx-workspace/actions/runs/43693422739)). A 15-minute watchdog alerts on queue age >30 min, stuck jobs >3 h, disk ≥85%, memory <250 MiB and missing listeners, through one deduplicated `ci-health` issue (PR #24, lifecycle in issue #23). Measured during the heaviest job: 3.7–3.8 GiB of 5.8 GiB used, ~2.1 GiB available, no OOM kill in any run on 15 Nov | Hard per-job memory/CPU limits are still not enforced; VM sizing stays provisional until the dedicated server |
| VM system packages for runner actions | VERIFIED | 16 Nov: `libatomic1` (14.2.0-4ubuntu2~24.04.1) installed with `apt-get install -y libatomic1`. `pnpm/action-setup@v6` bootstraps the standalone `@pnpm/exe` binary, which failed with `libatomic.so.1: cannot open shared object file` (Nabor #346, run 43742539687) | Include `libatomic1` in any rebuild of the VM |
| Host power management | PARTIAL | `sleep/suspend/hibernate/hybrid-sleep.target` all `masked`; drop-in present. **The running `systemd-logind` still reports `HandleLidSwitch=suspend`** because the drop-in was written after the last boot, so a lid close still issues a suspend request that the masked target then refuses | Apply the drop-in to the running service (restart `systemd-logind` or a planned reboot) in an idle window — owner decision |

## Stage 2 — Standard CI

| Requirement | Status | Evidence | Remaining work |
|---|---|---|---|
| Non-deploying workflow pilot | VERIFIED | Nabor `nabor-quality` and `sonarcloud`; Samloryx `ci-gate` and `security-scan`; this repository's new `infra-ci` (shell parsing, all suites, vendored mutex 19/19, gitleaks) | None |
| Build, test and vulnerability gates | VERIFIED | Samloryx #392 all seven checks green on exact head `1b5c0890` (15 Nov, platform-build 12m46s, 898 Java tests / 0 failures / 1 skipped, WebAuthn 10/10); Nabor #236 merged with all gates and #240 re-running them; this repository gated by `infra-ci` | Keep the rule: no merge without exact-head evidence |
| Required checks enforced by GitHub | PARTIAL | `samloryx-infrastructure` `main` is now protected: PR required, `shell syntax and regression suites`, `gitleaks (credentials in the history)` and `SonarCloud Code Analysis` required and up to date, force pushes and deletions refused, admins included. `samloryx-os` and `nabor` return 403 "Upgrade to GitHub Pro or make this repository public" | Private repositories stay procedural (`guarded-merge.sh`) unless the owner changes plan or visibility |
| Workflow policy applied per repository with review | PARTIAL | Nabor merged; this repository merged (#22, `162ccfb`); Samloryx #392 is green on its exact head but still **draft and unmerged** | Owner decision on #392 before any production deploy workflow is enabled |

## Stage 3 — Delivery hardening

| Requirement | Status | Evidence | Remaining work |
|---|---|---|---|
| Continuous deployment from `main` | PARTIAL | **16 Nov:** standard set to gated server pull ([SERVER_PULL_CD.md](SERVER_PULL_CD.md)). Read-only server check: the Samloryx `samloryx-autodeploy` cron was removed on 15 Nov 09:39Z and `AUTO_DEPLOY=off`, so production stays on `c8ec41b` while `main` `1b61c0ef` fails the SonarCloud gate; Consultancy's Hetzner cron is live but unguarded (deployed `7aa56a9`, which the gate rates eligible). Earlier: **Samloryx: VERIFIED 14 Nov 20:16Z.** Server-side pull deploy (no production key on the PR runner) as a five-minute cron; `a79ddb9f` deployed with the backup guard, 14/14 smoke checks and public release match. **Nabor: OPEN** — guarded preview pipeline exists but stays default-off because no dedicated always-on builder exists | Nabor needs an isolated builder host or runner |
| Deployment identity separated from the PR runner | PARTIAL | Samloryx deploys by the host pulling `main` with its own SSH identity, so no production key is installed on the CI VM; Nabor's deploy key would still need a builder identity | Nabor builder identity; keep production keys off PR runners |
| Deployment artifacts pinned | PARTIAL | Local Nabor preview images carry commit-SHA tags (`cfb39cf`, `c8e23ec`); registry digest pinning was not verified | Pin by digest before any production promotion |
| Smoke test | PARTIAL | `deploy/smoke.sh` exists; production web, api and app returned 200 on 14 Nov | Run smoke as a recorded release step, not by hand only |
| Rollback drill | OPEN | No rollback has been executed or recorded | Drill on an isolated host with a disposable release |
| Backup restore | VERIFIED | Isolated restore on 14 Nov: Samloryx 160/160 tables (`postgres:18`), Nabor 47/47 public tables (`postgis:16-3.6`), both `pg_restore` exit 0; see `docs/BACKUP_EVIDENCE.md` | Repeat quarterly and after schema changes |
| Alerts | PARTIAL | CI is now alerted end to end: watchdog timer every 15 min, one deduplicated `ci-health` issue, auto-closed on recovery (issue #23). Samloryx watchdog runs every five minutes and backup freshness warns after 26 h | Nabor backup alert, restore-age alert, and an alert path that survives the laptop being off |

## Open gates, in dependency order

1. **Private-repository branch protection** — unavailable on GitHub Free (403 on `samloryx-os` and
   `nabor`); guarded merge stays procedural there. This repository is protected because it is public.
2. **Nabor dedicated builder** — Samloryx deploys from the host by pulling `main`, so it needs no
   separate executor. Nabor's guarded preview pipeline still needs an always-on builder that is
   neither the live Nabor host nor the shared PR runner.
3. **Nabor offsite backup** — no timer, unit or cron installed and no R2 credentials or age
   identity; the offsite restore path is therefore untested.
4. **Rollback drill** — nothing has been rolled back under test.
5. **Host power policy applied at runtime** — the masked sleep targets prevent a suspend, but
   `systemd-logind` must be restarted (or the host rebooted) before the lid drop-in is in effect.
6. **Single-alert-path risk** — the CI watchdog shares the laptop that hosts the VM and needs the
   unlocked desktop keyring, so a laptop that is off is also unmonitored; see `docs/CI_HEALTH.md`.
7. **Hard resource limits** — the mutex serialises jobs but nothing caps a single oversized job
   (JVM heap flags exist per workflow; no cgroup limit).
8. **Mutex fairness** — the lock is a poll-and-grab loop with no FIFO order, so a later arrival can take
   the slot ahead of an earlier waiter. Observed on 15 Nov: `personal-career` waited from 08:06:15Z while
   `samloryx-consultancy-platform` acquired slot-1 at 08:08:33Z. Under sustained load this risks
   starvation of one repository.
9. **Job timeouts versus lock wait** — a job blocked at the hook has already started as far as GitHub is
   concerned, so `timeout-minutes` must exceed `JOB_LOCK_MAX_WAIT_SECS` (45 min) plus runtime, or a
   normal queue becomes a false red. The canary uses 50 minutes; the older workflows still carry 12–35
   minute timeouts and are only safe because the queue is currently short.

## Definition of done

A stage is complete only when every row in it is **VERIFIED**. Green workflows, merged PRs and
readable archives alone do not close a row.
