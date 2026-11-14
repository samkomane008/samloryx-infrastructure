# Backup and restore evidence

Verified claims only. Each entry records what was run, where, and what it does and does not
prove. Never treat a green workflow or a readable archive as a passed restore.

## 14 November 2026 — isolated restore rehearsal

**Command:** `BACKUP_HOST=<local ssh target> bash scripts/rehearse-backup-restore.sh`
**Where:** owner workstation, Docker 29.1.3. Disposable containers, `--network none`, no
published ports, random superuser password, dumps copied read-only and deleted on exit.

| Product | Dump | Image | `pg_restore` rc | Public tables restored | Archive public tables | Result |
|---|---|---|---|---|---|---|
| Samloryx | `samloryx-20261113T231501Z.dump` (2,797,996 B) | `postgres:18` | 0 | 160 | 160 | PASS |
| Nabor | `pre-b6bd2ec-20261112T180310Z.dump` (205,716 B) | `postgis/postgis:16-3.6` | 0 | 47 | 47 | PASS |

Nabor's archive contains 54 `TABLE DATA` entries in total; 47 are in `public` and the rest are
PostGIS-managed schemas, so 47 is the correct comparison.

Reproduction was confirmed twice for each product, including once from the committed script.

## What this proves

- Both dumps are complete restorable archives, not merely listable ones.
- A clean `template0` database accepts the full restore with `--exit-on-error`.
- Restored public table counts match each archive's own table of contents.

## What this does not prove

- **The Nabor offsite path is untested.** It needs the R2 bucket credentials and the age
  private identity, neither of which exists on the workstation. Only the local pre-deploy
  dump was rehearsed.
- No point-in-time recovery, replication, migration or application-level check was performed.
- Samloryx offsite transfer is not part of this rehearsal; it verifies the local newest dump.

## Known failure modes (found during this rehearsal)

1. The official `postgres` and `postgis` images start a temporary server for initialisation,
   then restart it. `pg_isready` can succeed against the temporary server, after which the
   connection drops mid-restore. Wait for the **second** "database system is ready to accept
   connections" log line, as `scripts/rehearse-backup-restore.sh` does.
2. The `postgis` image pre-installs its extensions in `POSTGRES_DB`. Restoring a dump that
   creates the same extensions into that database fails on `pg_extension_name_index`. Create
   a fresh database from `template0` and restore into it.

## Schedule state (observed 14 November 2026)

- Samloryx: nightly cron at 01:15 UTC plus an hourly `--if-stale` catch-up; newest dump was
  20 hours old at verification. Watchdog warns when the newest dump exceeds 26 hours.
- Nabor: **no timer, unit or cron entry installed**, and no offsite upload. Only local
  pre-deploy dumps exist. This remains an open gate tracked by the Nabor backup runbook.

## Complementary check

`scripts/verify-backup-archives.sh` proves archive readability and freshness without restoring.
It is a cheaper, frequent check; this document records the full rehearsal that it cannot replace.
