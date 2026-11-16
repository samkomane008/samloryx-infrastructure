# Gated server-pull CD: the standard for every Samloryx product

**Decided:** Samuel, 16 November 2026. Applies to `samloryx-os`, `samloryx-consultancy-platform`
and `nabor`. It implements the release contract in [FAST_SAFE_DELIVERY.md](FAST_SAFE_DELIVERY.md).

## The model

```text
PR ──> exact-head CI on the self-hosted samloryx-ci / nabor-ci runner ──> guarded merge to main
                                                                              │
main push ──> full CI + security + SonarCloud on the exact merge SHA          │
                                                                              ▼
production host cron (every 5 min) ──> git fetch origin main
     └─> server release gate (installed OUTSIDE the fetched checkout)
            ├─ blocked: log the reason, deploy nothing, retry the same SHA next run
            └─ eligible: backup ──> deploy that exact SHA ──> smoke test ──> record release
```

One release authority per product: **the server cron**. The GitHub deploy workflows
(`deploy-production.yml`, `deploy-preview.yml`) stay in the repositories but switched off, because
no trusted deploy runner exists and none is planned on the shared CI VM. Never run both.

Why this model: nothing on the PR-capable CI VM holds a production credential, no extra host is
needed, and the server never ships a commit that has not passed every named check on its exact SHA.

## What every product needs

| Piece | Where | Notes |
|---|---|---|
| Self-hosted CI on PR **and** main push | `.github/workflows/` | Runner from the `*_CI_RUNNERS` repository variable. The fallback label is the self-hosted one, never `ubuntu-latest`, which cannot run on this account |
| Release gate | `scripts/server-release-gate.sh` (this repo) or the product's reviewed equivalent | Vendored into the product by PR with its offline tests. SamloryxOS already has `deploy/verify-release-checks.sh`, which enforces the same contract |
| Gated deploy script | The product repo, under `deploy/` | Versioned in Git. A script that exists only on the server is not reviewable |
| Read-only token | `0600` file on the server, outside every checkout | One fine-grained token per product (below). Never in `.env`, never in Git |
| Switch | The product's env or deploy config, default **off** | Only an explicit `on` deploys. Missing or malformed values fail closed |

## Gate contract (what blocks a release)

`server-release-gate.sh --repo OWNER/REPO --sha SHA --token-file FILE --workflow W.yml --job NAME [--require-sonar]`
ships a SHA only if:

1. it is the current `main` head, checked at the start and again at the end;
2. a merged PR into `main` has it as its merge commit (a direct push never qualifies);
3. the latest main-push run of each named workflow on that SHA succeeded;
4. each named job has a completed, successful check run on that SHA (skipped, neutral, pending and
   missing all block);
5. with `--require-sonar`, the independent `SonarCloud Code Analysis` quality gate passed;
6. no commit status context is failing or pending.

Any API error or truncated response blocks. The token reaches `curl` on stdin only. Offline
regression suite: `bash tests/test-server-release-gate.sh` (28 cases).

Required checks per product:

| Product | Workflows | Jobs | Sonar |
|---|---|---|---|
| `samloryx-os` | `ci-gate.yml`, `security-scan.yml` | `platform-build`, `web-build`, `marketing-build`, `mobile-typecheck`, `semgrep (the code itself)`, `osv (known vulnerable dependencies)`, `gitleaks (credentials in the history)` | When `apps/platform/` changed (built into `verify-release-checks.sh`) |
| `samloryx-consultancy-platform` | `ci-gate.yml` | `backend-build`, `frontend-build` | Always |
| `nabor` | `quality.yml`, `sonarcloud.yml` | `Format, lint, typecheck, test, build and OSV`, `scan` | Always |

## One-time owner setup per product

### 1. Create the read-only token (GitHub web, Samuel only)

GitHub → Settings → Developer settings → Fine-grained tokens → Generate new token.

- **Resource owner:** `samkomane008`. **Repository access:** only the one product repository.
- **Repository permissions, all read-only:** Contents, Pull requests, Actions, Checks, Commit statuses
  (Metadata is added automatically). Nothing else, and no write permission of any kind.
- **Expiry:** 90 days, with a calendar reminder to rotate.

One token per product. Nabor's token must never be on a Samloryx path, and the reverse.

### 2. Install it on the server

```bash
ssh deploy@<host>
install -d -m 700 ~/.config/release-gate
# Paste the token, then Ctrl-D. It is not echoed and not saved in shell history.
( umask 077; cat > ~/.config/release-gate/<product>.token )
stat -c '%a %U' ~/.config/release-gate/<product>.token   # expect: 600 deploy
```

### 3. Prove the gate reads GitHub before switching anything on

Run the installed gate by hand against current `main` and read the verdict. `RELEASE BLOCKED`
with a real reason (for example a failing quality gate) is a correct result. `GitHub API
unavailable` means the token or its permissions are wrong.

### 4. Switch on, per the product's runbook

Only after step 3 works, and only with the backup, smoke test and rollback target the product
runbook requires. The product's deploy script records each attempt and refuses to retry a failed
SHA until `main` moves.

## Status (16 November 2026)

| Product | CI | Gate in repo | Gate on server | Token | Switch |
|---|---|---|---|---|---|
| `samloryx-os` | Self-hosted, green | Yes (`#402`) | **No**: the live checkout `c8ec41b` predates the gate | Not created | `AUTO_DEPLOY=off`, cron removed 15 Nov |
| `samloryx-consultancy-platform` | Self-hosted, green | PR in progress | **No**: the live cron is unguarded | Not created | On (unguarded) |
| `nabor` | Self-hosted, queue-bound | PR in progress | No | Not created | Off by decision |

SamloryxOS `main` (`1b61c0ef`) currently fails the SonarCloud quality gate (52% coverage on new
code, 80% required) with 35 platform files changed since the live release. The gate correctly
refuses it. Production stays on `c8ec41b` until a fully green `main` exists.
