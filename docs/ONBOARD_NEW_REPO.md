# Onboard a new GitHub repository into fast/safe Samloryx GitOps

This procedure applies to new Samloryx products and websites; never copy production secrets or services between repositories.

## 1 — Classify before creating workflows

Choose one of: product application with user data; static marketing/client site; operational automation with side effects; private personal-data tooling; or reusable infrastructure. The review, security scanning and production delivery boundaries differ. GitHub Free private repos do not have enforceable server-side branch protection in the current account.

## 2 — Get secret-free CI green first

- Copy and adapt `templates/github/workflows/quality.example.yml`; keep triggers for PR and **main push**, and cancel only stale PR-head runs. Replace `scripts/check.sh` with real, complete repository checks. A skipped required job is not success.
- Use the installed repo-scoped CI runner selector (e.g. `NABOR_CI_RUNNERS`, `SAMLORYX_CI_RUNNERS`) and ensure it targets an isolated **CI-only** service account. Do not run external-fork PR code on the persistent Docker-capable VM.
- Keep security scans and credential scans secret-free (Gitleaks + OSV + Semgrep where applicable), use SonarCloud only while its free tier is suitable, or maintain equivalent self-hosted checks without weakening release policy.
- Add the read-only, reviewed `scripts/release-eligible.sh` and `tests/test-release-eligible.sh`, require all jobs in the product workflow and independent quality gate when configured. CI validates the helper using fake `gh`, no live deployment.
- A single PR's green checks are **not** production evidence; validate the exact new main merge commit with `push` events before promotion.

## 3 — Keep deployment separate from PR code

- Use default-OFF CD. No deployment identity, SSH key, API token or writable production Docker socket may exist on a PR runner. Require an explicit trusted `*-deploy` label and runner selector; no fallback to a CI VM.
- Gate current main SHA, merged PR provenance, full exact-SHA push tests/security, independent quality, and live-server/registry consistency. Recheck current main before a side effect and under a deployment lock.
- Deployment from an untrusted `git fetch origin main` poller is **forbidden without a trusted gate installed outside the fetched checkout**.
- Do not perform `curl | bash` or execute an unpinned remote script. Vendor a reviewed gate at a known commit, and verify its tests before changing production.
- Make a backup, restore drill, exact SHA ledger, health/smoke check, rollback and change-failure alert mandatory for applications with databases. Never force production database restore automatically.
- Pin host authenticity and least-privilege deploy identity. Restrict Cloudflare/CRM/SMTP tokens to the corresponding trusted deployment job, not the whole workflow job on PRs.
- Use small PRs and feature flags (new user-facing features default OFF). Maintain independent lanes for QA, preview, staging and production when infrastructure capacity exists.

## 4 — Hardware capacity and scaling

Today, six GitHub runner registrations share a ~5.8 GiB Multipass VM and a one-slot mutex. Separate registered runners do not equal parallel compute. Leave the mutex in place until another physical host or isolated adequately sized VM is commissioned; then split Java, Node/mobile, scanners, and trusted deployment workers onto distinct capacity. Never mount the production Docker socket into a PR CI worker.

Measure PR wait time, full test time, release lead time, change-failure rate, rollout duration and recovery time. Create a dedicated builder only when measured latency and capacity warrant it; there is no recurring software subscription required.

## 5 — Definition of done for each new repo

- [ ] PR CI and exact-main CI fully green and mandatory checks named in release gate
- [ ] Security scan and independent quality gate or approved equivalent with no unresolved critical findings
- [ ] Trusted deploy runner/host provisioned and isolated from PR workloads
- [ ] Production deploy default OFF until dry-run, backup and rollback evidence exist
- [ ] Exact SHA built/tested and reused (prefer immutable OCI artifact digest)
- [ ] Live API/website smoke, release ledger, monitoring, rollback and on-call action verified
- [ ] Billing, runner resources, secrets and ownership reviewed
- [ ] New repo added to infrastructure audit/watchdog and documented in the GitOps fleet status

For deferred Nabor dedicated builder and offsite R2/age backups, retain the block state until the owner's planned server migration; do not mark them complete.

See [FAST_SAFE_DELIVERY.md](FAST_SAFE_DELIVERY.md) for the cross-repo release contract.
