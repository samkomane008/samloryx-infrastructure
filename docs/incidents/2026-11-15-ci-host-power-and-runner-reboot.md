# 15 November 2026 — the host slept, then the listener came back without Nabor

Two separate failures looked like one broken build. Neither was a defect in the application.

## What happened

| Time (SAST) | Time (UTC) | Event |
|---|---|---|
| 14 Nov 23:20 | 21:20 | Samloryx OS PR #392 platform build starts on `samloryx-ci` |
| 14 Nov 23:25 / 23:30 | 21:25 / 21:30 | Runner answers two GitHub heartbeats |
| 14 Nov 23:34 | 21:34 | The Ubuntu host **suspends** (lid/idle); the VM freezes mid-Maven |
| 14 Nov 23:43 | 21:43 | GitHub marks the job failed (missed heartbeats) |
| 15 Nov 03:04 | 01:04 | Host resumes; the worker kills Maven (`exit 143`), then gets HTTP 401 on log upload and `completejob` because its job credentials expired |
| 15 Nov 08:58 | 06:58 | Host reboots. The Nabor listener does **not** start: its unit was never `enable`d |
| 15 Nov 09:12 | 07:12 | Owner masks `sleep/suspend/hibernate/hybrid-sleep.target` and writes `/etc/systemd/logind.conf.d/90-samloryx-ci.conf` |
| 15 Nov 09:16 | 07:16 | SonarCloud run 43635987821 succeeds on `a79ddb9f` |
| 15 Nov 09:22 | 07:22 | The long-queued `ci-gate` run 43652269442 finally gets the runner |
| 15 Nov 09:35 | 07:35 | Its platform build passes (full Maven `verify`) |
| 15 Nov 09:36 | 07:36 | Nabor listener enabled and started; queued run 43686079752 passes |

Clock note: early boot messages in the host journal are stamped 10:58 SAST because the clock was two
hours ahead until NTP corrected it. `/proc/uptime` puts the real boot at 08:58 SAST. Correlate host
logs with the VM's journal (which stayed in SAST) rather than trusting the first host lines.

## Root causes

1. **Host suspend.** Power management, not the Java suite. Suspension froze the VM, so the worker
   missed heartbeats and its credentials expired; the resume handler then terminated Maven with
   `SIGTERM` (exit 143) and every result upload returned 401.
2. **The lid policy was never applied to the running service.** The drop-in at
   `/etc/systemd/logind.conf.d/90-samloryx-ci.conf` has the correct `HandleLidSwitch=ignore`
   values, but its mtime is 09:12 SAST — *after* the 08:58 boot. `busctl get-property` on the live
   `systemd-logind` still reports `HandleLidSwitch=suspend` and an empty
   `HandleLidSwitchExternalPower`. What actually prevents a repeat today is the second, independent
   control: all four sleep targets are `masked`, so a suspend request cannot complete. The drop-in
   needs a `systemd-logind` restart (which can end desktop sessions) or a planned reboot to take
   effect — an owner decision in an idle window.
3. **A listener that was started by hand and never enabled.** `systemctl start` does not survive a
   reboot. Nabor's only runner was `disabled`, so after every boot its jobs queued forever while
   the acceptance matrix still claimed six healthy listeners: nothing checked `enabled`.

## What was fixed, and the evidence

| Fix | Evidence |
|---|---|
| Nabor listener enabled and started | `nabor` run [43686079752](https://github.com/samkomane008/nabor/actions/runs/43686079752) succeeded 15 Nov 07:36Z on `samloryx-ci-nabor-ci` |
| Installer enables every unit and fails closed (exit 7) if any is not `active` **and** `enabled` | PR [#21](https://github.com/samkomane008/samloryx-infrastructure/pull/21), merged `3144926` |
| `scripts/runner-doctor.sh` reports `active`/`enabled`/registration per repository and exits non-zero on drift | PR #21; live run before the fix printed `UNHEALTHY nabor active=inactive enabled=enabled` |
| 15-minute watchdog outside the VM, one `ci-health` issue as the alert channel | PR [#24](https://github.com/samkomane008/samloryx-infrastructure/pull/24), merged `2189d0a`; lifecycle proven in issue [#23](https://github.com/samkomane008/samloryx-infrastructure/issues/23) |
| This repository gets CI (shell parsing, all suites, vendored mutex 19/19, gitleaks) | PR [#22](https://github.com/samkomane008/samloryx-infrastructure/pull/22), merged `162ccfb`; first main run green |
| `main` is now protected: PR required, three checks required and up to date, no force push, no deletion, admins included | `GET /repos/samkomane008/samloryx-infrastructure/branches/main/protection`, 15 Nov 2026 |

## Capacity measurement

During the platform build (the heaviest job on this VM) `free -h` showed 3.7–3.8 GiB used with
~2.1 GiB available on a 5.8 GiB VM, and no OOM kill in the kernel log for the surrounding hours.
During a Node test run afterwards it showed 1.6 GiB used and 4.3 GiB available. One heavy Java job
at a time fits; the single-slot mutex is what keeps it that way. The 13 November OOM incident
remains the reason overlapping heavy jobs are not permitted.

## Rules this incident leaves behind

1. Every runner unit must be `enabled`, not merely started.
2. A listener is healthy only when systemd and GitHub both say so; `runner-doctor.sh` checks both.
3. A queued run older than 30 minutes is an alert, not a curiosity.
4. A host power setting is not "applied" until the running process reports it — verify with
   `busctl`, not by reading the file.
5. Never re-run a job because it "looks broken" before checking the host's boot and suspend log.
