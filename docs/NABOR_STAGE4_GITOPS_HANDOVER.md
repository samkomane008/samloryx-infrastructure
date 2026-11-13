# Nabor Stage 4 — GitOps validation handover

**Owner directive:** 13 November 2026, ~20:27 SAST. Infrastructure owns **all GitOps, self-hosted CI/CD, test execution/orchestration, observability, deployment safety and evidence handoff** for `samkomane008/nabor`. Nabor product engineering continues to own application defects and prototype parity. **This handover does not approve release/deployment**; Nabor remains non-production-ready.

## Source of truth and responsibility

- [Nabor #182](https://github.com/samkomane008/nabor/issues/182): 77 web-first checklist items; **0 accepted** as of handover. Web marketing, customer, provider, admin + seven web-wide gates. Prototype: `prototype/index.html`; screen mapping: `docs/reference/roles-and-screens.md`.
- [Nabor #193](https://github.com/samkomane008/nabor/issues/193): known failing Prettier gate, 47 files on locally validated SHA.
- [Nabor #176](https://github.com/samkomane008/nabor/issues/176): production admin invitation-email deliverability requires real provider and recipient evidence, not API-only tests.
- [Infrastructure #5](https://github.com/samkomane008/samloryx-infrastructure/issues/5): working validation and evidence tracker.
- [Infrastructure #2](https://github.com/samkomane008/samloryx-infrastructure/issues/2): VM-wide serialization and memory budgets; [#3](https://github.com/samkomane008/samloryx-infrastructure/issues/3) sequencing originally deferred Nabor **production rollout**. Owner now explicitly prioritizes Nabor **validation and GitOps handoff**, **not Nabor production deployment**.
- [Shared VM global OOM incident](../incidents/2026-11-13-global-oom.md): runner/resource incident unresolved. Never stop or restart QEMU/Multipass, active runner jobs or unrelated Docker services without verifying workload ownership.

## Validated evidence (owner Ubuntu laptop, 13 Nov 2026)

All tests used a **clean detached Git worktree** `~/Desktop/Workstation/nabor-validation-lXuv33`; active owner feature checkout is `feat/customer-eligible-provider-choice-20261112` and must not be overwritten.

| Commit | Test/check | Actual observation |
| --- | --- | --- |
| `bfb3f7c` | `pnpm install --frozen-lockfile` | PASS (Node 22.22.1, pnpm 10.34.9) |
| `bfb3f7c` | `pnpm run format:check` | FAIL — 47 files, historical #193 had only 23 |
| `bfb3f7c` | `pnpm run lint` | FAIL — one unused local in `apps/admin/src/components/AccountAccess.tsx` |
| `bfb3f7c` | `node scripts/check-brand.mjs` | PASS |
| `bfb3f7c` | `pnpm exec turbo run typecheck --concurrency=1` | PASS |
| `6981bbf` | `pnpm run lint` after merged Nabor PR #227 | PASS |
| `6981bbf` | `pnpm exec turbo run test --concurrency=1` | PASS — 19/19 Turbo tasks, **7 cached**. Web Vitest 12 files/50 tests; admin Vitest 4 files/25 tests included |
| `0ec1e4c` | `pnpm --filter @nabor/site run build` | PASS — 28/28 prerendered; export verifier **23 pages and 26 HTML files** |
| `20f7717` | marketing Playwright 3 projects, single worker, alternate port 4599 | **36 PASS / 3 FAIL**: unreleased App Store link unexpectedly present in footer; application defect fixed in #231 |
| `6aae7f3` | marketing build | PASS — same 23-page/26-HTML export verifier |
| `6aae7f3` | focused marketing Playwright 3 projects | **3 FAIL**: locator ambiguity after valid second web portal link was added to footer; test fixed in #232 |
| `b4cf0aa` | focused Playwright after #232 | **NOT RUN** — available RAM below 4 GiB safety threshold |

The **latest source commit used in this ledger may no longer be current**. Pin each future run to the actual `origin/main` SHA and do not transplant PASS results across commits as if they were executed there. No full 39-test marketing rerun on #232; no customer/provider/admin Playwright, real protected API/DB, keyboard/screen-reader, release smoke or verified production invite delivery. Nothing in #182 is accepted yet.

## Resource diagnosis and safety

- Owner Ubuntu laptop: 14 GiB RAM, 8 CPUs, ~80 GiB disk free. Healthy local PostGIS `nabor-postgres-1`, Redis `nabor-redis-1`, SeaweedFS `nabor-storage-1`.
- Host memory **fluctuates**: 10 GiB available after Maven exited, ~4.1 GiB or less once Multipass and Chrome workloads active; swap about 3 GiB used.
- Observed largest `qemu-system-x86` process ~5.83 GiB RSS, parent `multipassd` (likely CI VM; verify before any action). Chrome also substantial. No active build process in most recent diagnostic. **Do not kill workload owners** or run resource-heavy tests concurrently.
- User's last attempted focused test skipped because only **3.7 GiB available**. Hand off test scheduling to infrastructure instead of repeatedly asking user to rerun identical checks.
- Shared CI VM previously suffered global OOM; stage resource budgets and one heavy job **across all repositories** at a time. Isolate untrusted PR runners from privileged deployment workers. Do not buy subscriptions.

## GitOps execution plan for infrastructure agents

1. **Read-only readiness:** confirm owner feature worktree is untouched, clean detached validation checkout, latest source SHA, host/guest available RAM, active workers, cross-repo serial mutex, runner online status and safe alternate loopback port. Never expose exact host/credentials/PII in this public repository.
2. **Restore gate:** resolve Prettier 47-file drift with an isolated *formatting-only* PR using existing recovery worktree/script and coordinate Nabor #193; run exact-head quality gates; no force push or bypass of required checks. Verify `format:check`, lint, approved logo, typecheck, full unit and bounded integration suite. Full `scripts/check.sh` manipulates **local** test databases; never inherit production `DATABASE_URL`.
3. **Resume marketing targeted test first**, on latest exact main after #232: build static export then run the focused browser assertion across desktop/mobile/compact, single worker on a confirmed free test port. Entry point:
   ```bash
   pnpm --filter @nabor/site run build
   NABOR_SITE_TEST_PORT=4599 pnpm --dir apps/site exec playwright test \
     marketing.e2e.ts \
     -g "marketing accurately gates payments, ETA and unreleased store downloads" \
     --workers=1
   ```
   The port is configurable by PR #230; choose an actually free port. Before running, check memory and other workloads; do **not** assume a particular free port, current checkout or compiled output.
4. **Full marketing Playwright** once targeted checks pass: `NABOR_SITE_TEST_PORT=<free-port> pnpm --dir apps/site exec playwright test --workers=1`; preserve Playwright three projects at 1440/390/320. Evidence in last full run: 36/39 before #231. Run full suite on **latest main**, not a historic build.
5. **Customer/provider** `pnpm --dir apps/web exec playwright test --workers=1` and **admin** `pnpm --dir apps/admin exec playwright test --workers=1` under isolated prechecked loopback ports. Their configs may use fixed ports and synthetic fixtures; inspect/adjust safely rather than stopping unrelated listeners. These suites **alone cannot establish real protected API/DB parity**.
6. **Real integration and acceptance:** sandbox authenticated API sessions, role boundaries, forbidden cross-user access, real persistence, failure/offline UX; compare each of 77 #182 checklist anchors with prototype desktop and mobile; verify keyboard, screen reader, navigation and production-preview claims. Separate finance/legal/payment/identity/email/vendor owner gates as explicit blockers. Owner must approve policy/release decisions and any genuine vendor credentials where required.
7. **Release gate only after acceptance:** self-hosted CI (isolated and serialized), exact-SHA mandatory checks, restricted deploy keys, documented environment and rollback, production smoke/health/version, release evidence. **Do not deploy or advertise Nabor as live just because tests start passing.** Stage 5 Android/iOS remains blocked until owner explicitly lifts web-first gate.

## Evidence ledger format

For each execution record: local SAST timestamp, repository and exact SHA, environment (local CI VM or safe preview), sanitized command, exit code, passed/failed/skipped counts, cache use, memory availability/peak if known, artifact link, known blockers, product bug PR/issue and which #182 acceptance criteria are *actually* satisfied. Post concise updates to [Nabor #182](https://github.com/samkomane008/nabor/issues/182) and [Infrastructure #5](https://github.com/samkomane008/samloryx-infrastructure/issues/5). **No pass without executed evidence, no checks ticked merely from source merges.**

## Ownership boundary

**Infrastructure**: runner/CI/GitOps, safe builds/testing, quality and Sonar, browser/accessibility and deployment evidence, secrets/monitoring/backup/rollback governance. **Nabor product engineering**: fix application defects and prototype screens via focused PRs; no unauthorized CI/runner/deployment changes. **Owner**: real legal/payment/vendor approval, production email delivery test identities and physical-device approval. No owner action required just to schedule already-documented local nonprivileged validation; ask only when actual host permissions or approvals block progress.
