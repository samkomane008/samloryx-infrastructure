# Rollout acceptance matrix

The single record of what is actually proven for the three repositories, with the evidence and
the remaining work. Update it only with observed results. An item is **VERIFIED** only when the
evidence column names a run, a restore or a live read-only check from a specific date.

Legend: **VERIFIED** — proven by recorded evidence · **PARTIAL** — some evidence, a named gap
remains · **OPEN** — not started or no evidence · **BLOCKED** — cannot proceed without an owner
decision or a paid feature.

Last verified: **14 November 2026**.

## Stage 0 — Baseline

| Requirement | Status | Evidence | Remaining work |
|---|---|---|---|
| Review workflow triggers, runner labels and secret access | VERIFIED | All workflows in Nabor, Samloryx OS and this repository reviewed during the 14 Nov sessions; runner labels are `self-hosted,linux,x64,<repo>-ci` | Re-review when a workflow is added |
| Inspect backups, recovery, production deployment and branch protections | VERIFIED | Samloryx nightly + hourly backup cron and dumps observed; Nabor local pre-deploy dumps only; CD default-off; no branch protection on any of the three repositories | Re-check before each release |
| No production change before a repeatable test and rollback exist | VERIFIED | No production service, database, runner or deployment switch was changed in the 14 Nov sessions | Keep the rule |

## Stage 1 — Runner recovery

| Requirement | Status | Evidence | Remaining work |
|---|---|---|---|
| `samloryx-ci` VM reachable | VERIFIED | Read-only `multipass exec` and `deploy-ci-mutex.sh --check` succeeded on 14 Nov | None |
| Listener health and registration per repository | VERIFIED | `deploy-ci-mutex.sh --check` reported six active units: nabor, personal-career, samloryx-consultancy-platform, samloryx-engineering-website, samloryx-os, samloryx-workspace | Re-run the check after any host change |
| Serial gate inspected, not blindly reinstalled | VERIFIED | Installer now fails closed (PR #15, `971b8fcb`); `--check` executed read-only | Apply only in a quiet window if ever needed |
| Harmless canary workflow | OPEN | No dedicated canary workflow exists | Add one secret-free canary per runner |
| Concurrency, memory and disk controls | PARTIAL | One-slot mutex enforced; the 13 Nov global OOM incident is documented; VM has 5.9 GiB RAM and 52% disk use | Add memory/queue alerting; re-measure after each incident |

## Stage 2 — Standard CI

| Requirement | Status | Evidence | Remaining work |
|---|---|---|---|
| Non-deploying workflow pilot | VERIFIED | Nabor `nabor-quality` and `sonarcloud`; Samloryx `ci-gate` and `security-scan` | None |
| Build, test and vulnerability gates | PARTIAL | Nabor #236 passed all three exact-head gates and merged (`2ce2fa20`); Samloryx #391 runs the full Java suite and is not yet green | Merge #391 only when every required check passes |
| Required checks enforced by GitHub | BLOCKED | GitHub Free provides no branch protection on any of the three repositories | Owner decision: paid plan, or keep the procedural `guarded-merge.sh` gate |
| Workflow policy applied per repository with review | PARTIAL | Nabor merged; Samloryx #392 is staged and default-off | Revalidate #392 on post-#391 main |

## Stage 3 — Delivery hardening

| Requirement | Status | Evidence | Remaining work |
|---|---|---|---|
| Continuous deployment from `main` | PARTIAL | **Samloryx: VERIFIED 14 Nov 20:16Z.** Server-side pull deploy (no production key on the PR runner) installed as a five-minute cron; `a79ddb9f` deployed with the full backup guard, 14/14 smoke checks and public release match; next cycle observed as a silent no-op. **Nabor: OPEN** — guarded preview pipeline exists but stays default-off because no dedicated always-on builder exists | Nabor needs an isolated builder host or runner |
| Deployment identity separated from the PR runner | PARTIAL | Samloryx deploys by the host pulling `main` and using its own SSH identity, so no production key is installed on the CI VM; Nabor's deploy key would still need a builder identity | Nabor builder identity; keep production keys off PR runners |
| Deployment artifacts pinned | PARTIAL | Local Nabor preview images carry commit-SHA tags (`cfb39cf`, `c8e23ec`); registry digest pinning was not verified | Pin by digest before any production promotion |
| Smoke test | PARTIAL | `deploy/smoke.sh` exists; production web, api and app returned 200 on 14 Nov | Run smoke as a recorded release step, not by hand only |
| Rollback drill | OPEN | No rollback has been executed or recorded | Drill on an isolated host with a disposable release |
| Backup restore | VERIFIED | Isolated restore on 14 Nov: Samloryx 160/160 tables (`postgres:18`), Nabor 47/47 public tables (`postgis:16-3.6`), both `pg_restore` exit 0; see `docs/BACKUP_EVIDENCE.md` | Repeat quarterly and after schema changes |
| Alerts | PARTIAL | Samloryx watchdog runs every five minutes; backup freshness warns after 26 h | Nabor backup alert, CI queue alert and restore-age alert |

## Open gates, in dependency order

1. **Branch protection** — unavailable on the current GitHub plan; guarded merge stays procedural.
2. **Nabor dedicated builder** — Samloryx now deploys from the host by pulling `main`, so it needs no separate executor. Nabor's guarded preview pipeline still needs an always-on builder that is neither the live Nabor host nor the shared PR runner.
3. **Nabor offsite backup** — no timer, unit or cron installed and no R2 credentials or age
   identity; the offsite restore path is therefore untested.
4. **Rollback drill** — nothing has been rolled back under test.
5. **Queue and memory alerting** — single-slot mutex works, but saturation is only visible by
   inspection.

## Definition of done

A stage is complete only when every row in it is **VERIFIED**. Green workflows, merged PRs and
readable archives alone do not close a row.
