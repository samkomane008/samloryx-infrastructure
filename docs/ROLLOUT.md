# Rollout checklist

## Stage 0 — Baseline
- [ ] Collect repository inventories privately and review workflow triggers, runner labels, and secret access.
- [ ] Inspect backup, recovery, production deployment, and current branch protections.
- [ ] Avoid production changes until a repeatable test and rollback are established.

## Stage 1 — Runner recovery
- [ ] Confirm the `samloryx-ci` VM is reachable.
- [ ] Confirm Actions listener health and runner registration per repository.
- [ ] Inspect the prior serial gate installation; do not blindly rerun its installer.
- [ ] Execute one harmless, secret-free canary workflow.
- [ ] Verify concurrency, memory, and disk controls.

## Stage 2 — Standard CI
- [ ] Pilot a non-deploying workflow.
- [ ] Run build, tests, and free vulnerability scanning.
- [ ] Enforce required checks where available; otherwise document a fail-closed manual release gate.
- [ ] Apply a tested workflow policy to each repository with PR review.

## Stage 3 — Delivery hardening
- [ ] Separate production deployment identities and host from the PR runner.
- [ ] Pin deployment artifacts by digest or immutable version.
- [ ] Smoke test, roll back, verify backup restore, and add alerts.
