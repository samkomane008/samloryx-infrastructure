# Persistent pnpm CI and bounded network resilience

## Why

Nabor's `sonarcloud` workflow failed on 14 Nov 2026 during a frozen pnpm
install, after DNS errors (`EAI_AGAIN`) and connection resets (`ECONNRESET`)
from `registry.npmjs.org`. The shared single-slot self-hosted runner mutex
worked correctly. GitHub workflow age was older than the running job: do not
cancel jobs based on creation time without checking actual job `started_at`.

## Design

- Each **self-hosted runner** uses its own writable `RUNNER_TOOL_CACHE/pnpm-store`.
  This directory lives outside the checked-out repository and persists across jobs.
- The helper attempts `pnpm install --offline --frozen-lockfile` on an existing
  store first, then falls back to a normal frozen install when packages are missing.
- Network operations use 4 concurrent requests, 4 per-request retries,
  5-30s retry delays, and 90s fetch timeout. The entire pnpm command is bounded
  to 900s by default (override `CI_PNPM_STEP_SECONDS` up to 1500s).
- DNS (getent) and verified HTTPS (curl) preflight messages help distinguish
  resolution, TLS, connection and package issues; a temporary probe failure
  is not treated as a passing build, and does not prevent pnpm's own retries.
- GitHub-hosted runners retain the Actions pnpm cache. Self-hosted runners skip
  the extra remote Actions dependency-cache download.
- Existing frozen lockfile, formatting, unit and DB tests, OpenAPI checks,
  OSV advisories, SonarCloud quality gates, and Playwright acceptance stay required.
- Keep separate non-deploy runners and separate production credentials. Do not
  share a writable pnpm store across unrelated repositories or trust boundaries.
- Preserve the shared mutex. Do not restart VMs, kill active jobs, or cancel
  workflows as part of installing this helper.

## Canary / rollout

1. Make a dedicated Nabor PR from **latest main**; don't amend an unrelated
   recovery or queue-janitor PR.
2. Run `bash -n scripts/ci-pnpm.sh scripts/check.sh` and review the workflow diff.
3. Run local `bash scripts/check.sh` and confirm all original stages pass.
4. Open draft PR (under Samuel Komane's Git identity), watch its exact commit
   checks. Browser acceptance and security must succeed before merge.
5. Observe the second CI install to confirm that the persistent store is reused,
   using logs and store size. Expect a cold first run to download dependencies.
6. After Nabor succeeds, copy or vendor the *reviewed* helper to individual
   application repos, preserving each one's tests and deployment boundaries.
7. Consider migrating coverage provider addition to a committed lockfile in a
   separate PR. Don't silently change production dependency versions here.

## Verify cache after a runner is idle

`pnpm store path` inside the job confirms the active store path. Inspect it via
`du -sh "$RUNNER_TOOL_CACHE/pnpm-store"` under the **runner service account**.
Do not run `pnpm store prune` while a job is using the store. GitHub's own
runner checkouts may be cleaned, but the tool-cache location must be retained.

## Failure response

If `EAI_AGAIN` or `ECONNRESET` recurs, inspect the failing job logs, DNS from
host and VM, gateway, HTTPS to npm, and actual execution timestamps. Do not
bypass frozen lockfiles, disable OSV/browser checks, force merge, or remove the
runner mutex to clear a queue. Local checks do not substitute for GitHub
exact-head status checks.
