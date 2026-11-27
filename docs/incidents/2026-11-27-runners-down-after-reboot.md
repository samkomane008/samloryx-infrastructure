# 2026-11-27 — Every runner listener down after a VM reboot

Status: **recovered and fixed**. Public summary. Host addresses, tokens and full logs are left out.

## What happened

- The `samloryx-ci` VM booted with its clock **two hours fast**: it logged the boot at 11:03 SAST, and NTP stepped the clock back to 09:04 SAST about a minute later.
- All five listeners started before that correction. GitHub refused each session with "The runner registration has been deleted from the server". That message was misleading: the registrations still existed and showed as `offline`.
- Each listener then exited with code 0 ("no retry needed"). The hand-written `90-infra-recovery.conf` drop-in only had `Restart=on-failure`, so systemd left every unit `inactive`. They were still `enabled`, which only matters at boot.
- Every queued run in every repository waited until the listeners were started by hand at about 09:50 SAST.

## Fix

`scripts/install-runner-boot-recovery.sh --apply` installs `95-boot-recovery.conf` on every `actions.runner.*` unit:

| Setting | Effect |
|---|---|
| `After=` / `Wants=` `time-sync.target`, plus `systemd-time-wait-sync` enabled | Listeners start only after NTP has synchronised the clock |
| `Restart=always`, `RestartSec=60s` | A listener comes back 60 s after any exit, including a clean one |
| `StartLimitIntervalSec=0` | systemd never gives up retrying. The 15-minute `ci-health` watchdog still alerts on an offline listener |

`systemctl stop` still stops a listener for good. Applying the drop-in does not restart running listeners or jobs.

## Evidence it works (27 Nov 2026)

- `--apply` verified all five units as `Restart=always`, `enabled` and ordered after `time-sync.target`, with `systemd-time-wait-sync` enabled.
- On the idle `samloryx-workspace` listener, a SIGTERM made the unit exit cleanly ("Deactivated successfully"). systemd scheduled a restart 60 s later, the unit was `Listening for Jobs`, and GitHub showed it `online`.
- A full VM reboot has **not** been rehearsed yet: it would interrupt running CI jobs. Rehearse it in an idle window and check it with `runner-doctor.sh`.
