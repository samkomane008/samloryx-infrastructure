# Runner canary

A canary is the cheapest honest answer to "is this repository's self-hosted runner actually working?" It
runs in under a minute, needs no checkout, no Docker, no package manager and no secret, so it is safe to
run during an incident and tells you nothing about the application — only about the runner.

Template: [`templates/github/workflows/canary.example.yml`](../templates/github/workflows/canary.example.yml).
Each repository carries its own copy at `.github/workflows/ci-canary.yml`.

## What one run proves

1. The listener is online and accepts work for that repository's labels.
2. The repository variable (`NABOR_CI_RUNNERS`, `SAMLORYX_CI_RUNNERS`) matches a real runner label — a
   wrong label leaves the job queued forever, which is exactly the failure it is meant to catch.
3. The shared one-slot mutex serialises jobs **across** repositories: while another repository holds
   `/run/samloryx-ci-mutex/slot-1`, the canary waits inside the job-started hook before its first step.

A canary that stays queued is itself the alert: `scripts/ci-health-check.sh` opens a `ci-health` issue
when any run waits more than 30 minutes.

## Rollout

| Repository | Workflow merged | First live run | Result |
|---|---|---|---|
| nabor | [nabor#240](https://github.com/samkomane008/nabor/pull/240) `770569c` | [43692579980](https://github.com/samkomane008/nabor/actions/runs/43692579980) | success 15 Nov 08:07:15–08:08:39Z |
| samloryx-engineering-website | [#8](https://github.com/samkomane008/samloryx-engineering-website/pull/8) `d0ef348` | [43693148028](https://github.com/samkomane008/samloryx-engineering-website/actions/runs/43693148028) | success 15 Nov 08:11:21–08:11:49Z |
| samloryx-workspace | [#36](https://github.com/samkomane008/samloryx-workspace/pull/36) `f802af4` | [43693422739](https://github.com/samkomane008/samloryx-workspace/actions/runs/43693422739) | success 15 Nov 08:12:40–08:16:15Z (185 s of it at the mutex) |
| personal-career | [#87](https://github.com/samkomane008/personal-career/pull/87) `6c45ef4` | [43694108357](https://github.com/samkomane008/personal-career/actions/runs/43694108357) | success 15 Nov 08:22:05–08:22:17Z |
| samloryx-consultancy-platform | [#95](https://github.com/samkomane008/samloryx-consultancy-platform/pull/95) `7aa56a9` | [43693860699](https://github.com/samkomane008/samloryx-consultancy-platform/actions/runs/43693860699) | success 15 Nov 08:22:03–08:22:15Z |
| samloryx-os | [#397](https://github.com/samkomane008/samloryx-os/pull/397) — **draft, unmerged** | cannot dispatch yet (see below) | — |

Five of the six runners are proven. A canary that does no work takes about 12 seconds on an idle
mutex; the workspace run above took 3 m 35 s because another repository held the slot. That difference
**is** the serialisation proof, and it is visible in the job log:

```text
08:12:49 [job-lock] waiting for a job slot: slot-1=samkomane008/samloryx-consultancy-platform (0s elapsed, max 2700s)
08:15:54 [job-lock] waiting for a job slot: slot-1=samkomane008/samloryx-consultancy-platform (185s elapsed, max 2700s)
08:16:05 [job-lock] lock acquired (slot 1/1, worker pid=142186)
08:16:05 canary-ok
08:16:05 [job-lock] lock released (slot-1, worker pid=142186)
```

`samloryx-infrastructure` itself does not need a canary: its `infra-ci` runs on GitHub-hosted runners
because the repository is public, so it never touches the CI VM.

## Why samloryx-os stays a draft

GitHub only dispatches `workflow_dispatch` for a workflow that exists on the **default** branch, so the
canary cannot be triggered from the pull-request branch. Merging it to `main` is not a CI-only action:
the production host polls `main` every five minutes and deploys whatever it finds, so a merge is a
production release and belongs to the owner. Until then, the repository's own `security-scan` and
`ci-gate` runs on the branch are the evidence that the listener works there.

## Dispatch

```bash
gh workflow run ci-canary.yml --ref main -R samkomane008/nabor
gh run list -R samkomane008/nabor --workflow ci-canary.yml --limit 3
```

The scheduled run is Mondays 04:17 UTC, before a working day, so a weekend outage is known before
somebody waits for a build.

## The timeout rule that follows from the mutex

A job blocked at the hook has already "started" as far as GitHub is concerned, so its
`timeout-minutes` covers the wait. `JOB_LOCK_MAX_WAIT_SECS` is 2700 s (45 min), therefore any job that
can queue behind the lock needs a timeout comfortably above a legitimate wait, or a normal queue turns
into a false red. The canary uses 50 minutes for that reason; latency alerting belongs to the watchdog,
not to the job timeout.

The converse is worth stating: because the lock is a poll-and-grab loop with no FIFO order, a later
arrival can win the slot ahead of an earlier waiter. Observed on 15 November 2026: `personal-career`
waited from 08:06:15Z while `samloryx-consultancy-platform` acquired the slot at 08:08:33Z. Under
sustained load this is a starvation risk, recorded as an open gate in [`ROLLOUT.md`](ROLLOUT.md).
