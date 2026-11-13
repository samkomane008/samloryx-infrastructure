# actions-runner-mutex

Host-wide concurrency limit for GitHub Actions **self-hosted runners** — run at
most N jobs (default: 1) on a machine, no matter how many runners live on it.
Works entirely on the runner host: **no workflow changes, no PATs, works across
repositories, organizations and even different GitHub accounts.**

```
Runner A (repo X) ─┐
Runner B (repo Y) ─┼─▶ [ job slot(s) on this host ] ─▶ jobs run one at a time
Runner C (org  Z) ─┘
```

## Why

A self-hosted runner process takes one job at a time — but if you register
several runners on one machine (a common setup: one Mac mini doing iOS/Android
CI for many repositories), nothing coordinates them, and they will happily run
builds in parallel. Xcode, the macOS keychain, simulators, Packer, embedded
toolchains and plain old RAM all disagree with that.

There is no native way to fix this:

- The runner has no `--limit`-style setting (GitLab Runner has one; the
  request for GitHub is [actions/runner#2355](https://github.com/actions/runner/issues/2355),
  closed unimplemented).
- The workflow-level [`concurrency:`](https://docs.github.com/en/actions/concepts/workflows-and-actions/concurrency)
  key cannot span repositories.
- Marketplace mutex actions (e.g. gh-action-mutex) require editing every
  workflow in every repository, plus cross-repo tokens.

This project implements the limit at the only place that sees every job on the
host: the runner's [job hooks](https://github.blog/changelog/2022-04-03-github-actions-job-management-hooks-for-self-hosted-runners/)
(`ACTIONS_RUNNER_HOOK_JOB_STARTED` / `ACTIONS_RUNNER_HOOK_JOB_COMPLETED`).

## How it works

1. When a job starts, the started hook runs `job-lock.sh acquire`, which takes
   a **slot** — a directory created atomically with `mkdir` — and records the
   job's `Runner.Worker` PID in it. If all slots are busy, it polls until one
   frees up. While waiting, the job shows as running its "Set up runner" step
   on GitHub, with a `waiting for a job slot` line logged every ~30 s.
2. When the job finishes (success, failure or cancellation), the completed
   hook releases the slot.
3. If a slot's recorded worker PID is dead, waiters **steal** the slot. This
   is the safety net for every case where the completed hook doesn't run —
   force-killed runners, reboots, runner bugs. A stale lock can never wedge
   the host.

## Install

```bash
git clone https://github.com/cathandnya/actions-runner-mutex.git
cd actions-runner-mutex

# point it at your runner directories and restart their services
./install.sh --restart /path/to/runner-repo1 /path/to/runner-repo2 ...
```

`install.sh` writes two lines into each runner's `.env` file:

```
ACTIONS_RUNNER_HOOK_JOB_STARTED=/path/to/actions-runner-mutex/hooks/job-started.sh
ACTIONS_RUNNER_HOOK_JOB_COMPLETED=/path/to/actions-runner-mutex/hooks/job-completed.sh
```

You can add them by hand instead — the runner reads `.env` at service start,
so restart the service either way. **When you add a new runner to the host
later, run `install.sh` for it too**; a runner without the hooks does not
participate in the limit.

Ephemeral / JIT runners work the same way: put the two lines in the `.env`
you launch `run.sh` with.

### Verify

```bash
./job-lock.sh status        # shows busy slots, their repo and PID liveness
```

Trigger jobs from two different repositories at the same time: the second one
should sit in "Set up runner" until the first finishes.

## Configuration

Set these in each runner's `.env` (they are read by the hooks):

| Variable | Default | Meaning |
|---|---|---|
| `JOB_LOCK_DIR` | `$HOME/.actions-runner-mutex` | Lock directory. Must be the **same path for every runner on the host**, on a local filesystem. |
| `JOB_LOCK_SLOTS` | `1` | Max concurrent jobs on the host. |
| `JOB_LOCK_MAX_WAIT_SECS` | `7200` | Give up waiting after this long and fail the job explicitly (instead of silently eating GitHub's 6-hour job timeout). |
| `JOB_LOCK_OWNERLESS_GRACE` | `60` | Seconds before a slot whose owner file was never written (hook killed mid-acquire) is considered stale. |
| `JOB_LOCK_POST_ACQUIRE` | – | Script to run after the slot is acquired, right before the job (e.g. a macOS keychain unlock). |
| `JOB_LOCK_POST_COMPLETED` | – | Script to run after the slot is released. |

If your runners already had job hooks, `install.sh` preserves them
automatically by moving them to `JOB_LOCK_POST_ACQUIRE` /
`JOB_LOCK_POST_COMPLETED`.

## Behavior you should know about

- **Waiting time counts against the job's timeout** (`timeout-minutes`,
  default 360). `JOB_LOCK_MAX_WAIT_SECS` exists so a hopeless wait fails with
  a clear error instead.
- **A waiting job occupies its runner.** The runner holds the job while the
  hook waits, which is what serializes the host. Queue ordering across
  waiters is polling-based (5–7 s with jitter), not FIFO — fine at small
  scale, no starvation observed in practice, but there is no strict fairness
  guarantee.
- **Cancelling a waiting job** works: the hook traps TERM/INT and exits
  without holding anything.

## Design notes (a.k.a. the traps, so you don't re-hit them)

These two cost us real debugging time; they are the reason this tool is
shaped the way it is. If you're building your own version, start here.

1. **The hook's `$PPID` is not `Runner.Worker`.** The runner spawns your hook
   script via a shell, and if your lock helper is a child of the hook script,
   its `$PPID` is the hook's shell — which dies the moment the hook returns.
   Record *that* PID as the lock owner and every waiter will immediately
   judge the lock stale and steal it: you get full parallelism with green
   logs. `job-lock.sh` walks up the process tree to the nearest process whose
   name matches `Runner.Worker` — the only process that lives exactly as long
   as the job.
2. **You cannot rely on the completed hook firing.** Force-killed runners,
   reboots, and assorted bugs ([actions/runner#1847](https://github.com/actions/runner/issues/1847))
   can all eat it. Any design that needs the release to run will eventually
   deadlock the host. Hence: liveness-checked stealing (PID **and** process
   name, so PID reuse after a reboot can't fake a live owner), plus a grace
   period for slots whose owner file never got written.

Other choices that follow from the constraints:

- `flock(2)` is unusable here — the started and completed hooks are separate
  short-lived processes, and flock's locks die with the file descriptor.
  Atomic `mkdir` + an owner file is the portable replacement.
- Stealing is done as atomic *rename-then-delete* (`mv` to a unique name,
  then `rm -rf`), so two concurrent stealers can never destroy a slot that a
  third process just re-acquired.
- The release path only removes a slot whose recorded PID matches the calling
  job's worker, and always exits 0 — a lock bug must never change a job's
  outcome.

## Limitations

- Linux and macOS runners only (hooks are bash; Windows would need a `.ps1`
  port — PRs welcome).
- All runners must share `JOB_LOCK_DIR` — in practice, run them as the same
  user, and keep the directory on a local disk (`mkdir` atomicity on network
  filesystems is not guaranteed).
- Serializes *jobs on one host*. It does not coordinate across machines.

## Testing

```bash
./test/run-tests.sh
```

Covers: basic acquire/release and ownership, contention and wait timeout,
stealing from dead holders, ownerless-slot grace, cancellation while waiting,
N-slot semantics, and worker-PID resolution through a realistic process chain.

## License

MIT
