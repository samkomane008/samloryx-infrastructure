# CI health watchdog

The shared self-hosted runners are watched from outside the VM by
`scripts/ci-health-check.sh`, run from the owner's workstation by a systemd user timer every 15
minutes. It is the alert channel that was missing while a listener sat offline after a reboot.

## What it checks

| Check | Alert condition |
|---|---|
| VM | `samloryx-ci` is not running |
| Listener state | a repository's unit is not `active`, or not `enabled` (so a reboot would drop it) |
| GitHub registration | the repository's runner is `offline`, missing, or the API call fails |
| Queue | a queued run is older than 30 minutes |
| Stuck job | an in-progress job started more than 3 hours ago |
| Disk | root filesystem at 85% or more |
| Memory | under 250 MiB available |

It is read-only: nothing is restarted, cancelled, retried or cleaned. Thresholds are environment
variables (`CI_QUEUE_MAX_MIN`, `CI_STUCK_MAX_H`, `CI_DISK_MAX_PCT`, `CI_MEM_MIN_MB`).

## Alert channel

With `--notify` it maintains exactly one GitHub issue in this repository, labelled `ci-health`:

- created on the first alert, with each alert on its own line;
- commented only when the alert set changes (a fingerprint is kept under
  `~/.local/state/samloryx-ci-health/`), so a long outage does not post every 15 minutes;
- commented with a recovery note and closed as soon as a run reports healthy.

The issue is the audit trail: when a job was queued, when the listener came back and who was told.
Issue #23 is the first full cycle (created on an injected alert, closed on recovery).

## Install (owner workstation, not the VM)

```bash
mkdir -p ~/.config/systemd/user
cat > ~/.config/systemd/user/samloryx-ci-health.service <<'EOF'
[Unit]
Description=SAMLORYX CI runner and queue watchdog (read-only checks, alerts via GitHub issue)

[Service]
Type=oneshot
Nice=10
ExecStart=/usr/bin/bash /home/samloryx/Desktop/Workstation/samloryx-infrastructure/scripts/ci-health-check.sh --notify --quiet
TimeoutStartSec=10min
EOF
cat > ~/.config/systemd/user/samloryx-ci-health.timer <<'EOF'
[Unit]
Description=Run the SAMLORYX CI watchdog every 15 minutes

[Timer]
OnCalendar=*:0/15
RandomizedDelaySec=60
AccuracySec=30s
Unit=samloryx-ci-health.service

[Install]
WantedBy=timers.target
EOF
systemctl --user daemon-reload
systemctl --user enable --now samloryx-ci-health.timer
systemctl --user list-timers samloryx-ci-health.timer
```

Manual run and drill (this is how issue #23 was produced):

```bash
bash scripts/ci-health-check.sh                 # human-readable, exit 1 on any alert
CI_MEM_MIN_MB=999999 bash scripts/ci-health-check.sh --notify   # force one alert cycle
bash scripts/ci-health-check.sh --notify --quiet                # record recovery and close
```

## Limits, stated plainly

- **The watchdog runs on the same laptop that hosts the VM.** If the laptop is off, suspended or
  its user session is not active, nothing is watching and no alert is sent during that window. The
  next run reports the state that it finds, including "VM not running".
- The systemd user timer is not enabled with `loginctl enable-linger` on purpose: the `gh` CLI uses
  the desktop keyring, which is locked outside a logged-in session, so a lingering timer would fail
  its own authentication and produce false alerts.
- GitHub only reports a runner as `offline` after its heartbeat expires, so an alert can arrive a
  minute or two after the listener dies.
- Queued runs older than a day that GitHub refuses to cancel (HTTP 409 on both `cancel` and
  `force-cancel`) are reported as `orphan` lines, not alerts. Six such runs from 11 November 2026
  are known; they never reach a runner.
- This is monitoring, not remediation. Restarting a listener, cancelling a run or resizing the VM
  stays a human decision recorded in issue #12.
