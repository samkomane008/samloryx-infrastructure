# Fast, safe delivery standard — Samloryx

**Revision:** 15 November 2026. **Mode:** staged adoption, fail closed, no paid subscriptions.

## Non-negotiable release contract

Every production or preview deployment must identify an immutable, full 40-character Git SHA and require all of:

1. The candidate is the *current* `main` head at release verification and immediately before deployment.
2. An already merged PR has that SHA as its merge commit; direct pushes do not qualify.
3. An exact-SHA `push` workflow successfully completes its full test suite. PR-only success does not qualify.
4. Each *named* mandatory build, test and security check is `completed/success`. Missing, skipped, neutral, cancelled, failed, pending, timed-out, or API-unavailable required checks block release.
5. Independent SonarCloud quality gate or approved local self-hosted equivalent is mandatory where the product currently relies on it; do not confuse scanner success with the server-side quality result.
6. The deployer is isolated from PR code, verifies host authenticity, rechecks SHA under a deployment lock, deploys the exact build artifact/revision, validates live health, and preserves a rollback target and database backups.
7. Only one release authority may be on at a time: server cron **or** isolated GitHub CD, never both. No `workflow_dispatch` bypass.
8. Credentials never enter PR-capable CI, public docs, logs, committed `.env` files or local development runner snapshots.

`scripts/release-eligible.sh` is the read-only common contract. Treat it as a **source template**, not something to curl and execute from an unpinned `main`. Copy to a product repo via code-reviewed PR, add its offline regression suite, and require the product's actual named CI jobs. A passing eligibility check does **not** authorize access to a server; all local server checks still apply.

## Fast parallel feature workflow

```text
small isolated feature branches (Samloryx OS / Nabor / Consultancy / Engineering)
    -> parallel fast local checks, pre-commit and targeted unit tests
    -> PR exact-head full CI + security + quality gates
    -> reviewed SHA-pinned merge to main (private GitHub Free: operator guard only)
    -> exact-main full push build + security + optional independent Sonar
    -> immutable artifact / image digest + signed release manifest (future phase)
    -> trusted deployer promotes only fully eligible SHA
    -> smoke / canary / rollback, release ledger and health telemetry
```

**Fast feedback never replaces release acceptance.** On changed PR heads, cancel stale PR checks only. For `main`, do not cancel an unverified current-head release check; avoid duplicate expensive runs. A docs-only optimization is allowed only when the skipped check is *not* required for that release and the release contract is updated, reviewed and tested before enabling it.

## Capacity lanes (not yet deployed)

| Lane | Isolation and gate | Required compute |
|---|---|---|
| Java backend | CI-only service account, Maven cache and Testcontainers | Dedicated Java builder / memory cgroup |
| TypeScript web + mobile | CI-only, persistent pnpm/npm stores | Separate Node builder |
| Security / analysis | Gitleaks, OSV, Semgrep; Sonar if enabled | Isolated workers / no production key |
| Small repositories / documentation | Fast secret-free CI | Lightweight shared lane |
| Production CD | **Never** executes PR code or shares a writable Docker socket with PR runners | Dedicated trusted deploy host |

**Current state:** six runner identities are on one approximately 5.8 GiB Multipass VM, serialized with one slot to avoid OOM. **Do not raise mutex slots on that VM.** Parallel capacity becomes real only when another host/VM with adequate cores, memory, storage and isolation is provisioned. Existing `*_CI_RUNNERS` repository variables already permit per-repo label selection later. Keep a per-lane wait-time histogram and adjust timeouts to include queue waits.

## Repository adoption matrix

| Repository | Immediate policy | Release boundary |
|---|---|---|
| `samloryx-os` | Existing exact-head full Java/web/mobile/security gates; draft #399 local merge gate; draft #402 cron release gate | Live five-minute poller must be disabled before guarded-cutover; do not merge drafts on incomplete checks |
| `nabor` | Full quality+OSV, Sonar and browser acceptance; existing preview workflow checks exact SHA | Preview default OFF and separate trusted `nabor-deploy` required; store launch is independent |
| `samloryx-consultancy-platform` | Backend+frontend CI + security/Sonar; legacy Lightsail auto-poller needs fail-closed exact-SHA gate | Disable cron before trusted GitHub-CD cutover; no unverified main deployment |
| `samloryx-engineering-website` | Web build and Sonar; existing atomic server release rollback | Cloudflare CD must check current exact SHA and security gate; publishing content approval remains separate |
| `personal-career` | Synthetic tests only on untrusted CI; no personal data on scanners | No automatic job submissions or private-data exports via CI |
| `samloryx-workspace` | Secret-free validation; restrict CRM ingestion to reviewed `main` inputs | CRM ingest token is production-only, not available on PR CI |
| `samloryx-infrastructure` | Shell regression suite, Gitleaks, independent SonarCloud | Public repo branch protection must remain intact; main Sonar C finding tracked in issue #28 |

## Release migration, measured in evidence rather than percentages

- **P0 — live safety:** record current production release SHA and public API health; verify backups; stop any poller that can deploy unchecked `main`; validate #402/analogous cron guards in offline tests before adoption.
- **P1 — parallel CI:** acquire dedicated capacity without subscription, register isolated CI-only runners, test per-lane concurrent jobs and memory bounds; preserve one-slot mutex until then.
- **P1 — immutable artifacts:** compile once; publish versioned artifact/image by digest; stage and production must promote exactly the same digest (no new build during promotion). Verify SBOM/provenance.
- **P1 — secure CD:** isolate trusted deployer, pin host keys, approve one deployment authority, enforce this contract both at workflow start and on server; exercise API smoke and application rollback.
- **P2 — low-risk progressive rollout:** feature flags default OFF; optional canary traffic, health thresholds, alerting and automatic application-only rollback when database schema is compatible.
- **P2 — operations:** add lead-time, queue-time, change-failure, MTTR and rollback drill evidence. Offsite Nabor R2/age and dedicated server were intentionally deferred to server migration, and must not be called complete.

GitHub Free private repositories cannot currently enforce server-side required PR checks in this account. The local merge guard cannot prevent a person with write access from using GitHub's web/API merge or direct push; an **independent production release gate** is mandatory. A future self-hosted Forgejo pilot is a separate evaluated option, not a production migration decision.

**Never automatically switch `AUTO_DEPLOY`, `NABOR_DEPLOY_ENABLED`, Cloudflare publishing or production secrets during a code-only rollout.** Release activation requires verified credentials, backups, restore evidence, trusted deployment runner, host-key pinning, and live SHA / smoke-test validation.
