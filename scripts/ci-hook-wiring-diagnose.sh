#!/usr/bin/env bash
# Read-only inspection of GitHub Actions pre/post-job hook configuration.
# Never prints hook paths, runner .env values, tokens, or credentials.
set -euo pipefail
VM="${CI_VM_NAME:-samloryx-ci}"
command -v multipass >/dev/null || { echo "multipass is required" >&2; exit 1; }
multipass exec "$VM" -- sudo python3 - <<'PY'
from pathlib import Path
import hashlib
import os
import re

root = Path("/opt/samloryx-runners/ci")
names = ("ACTIONS_RUNNER_HOOK_JOB_STARTED", "ACTIONS_RUNNER_HOOK_JOB_COMPLETED")
if not root.is_dir():
    raise SystemExit("Runner root not found; no files modified.")

summaries = []
for runner in sorted(p for p in root.iterdir() if p.is_dir()):
    envfile = runner / ".env"
    settings = {}
    if envfile.is_file():
        for line in envfile.read_text(errors="replace").splitlines():
            if "=" not in line:
                continue
            key, value = line.split("=", 1)
            if key.strip() in names:
                settings[key.strip()] = value.strip()
    info = {"runner": runner.name, "env_present": envfile.is_file()}
    for key in names:
        target = settings.get(key, "")
        label = "started" if key.endswith("_STARTED") else "completed"
        path = Path(target) if target else None
        info[label] = bool(target)
        info[label + "_absolute"] = bool(path and path.is_absolute())
        info[label + "_exists"] = bool(path and path.is_file())
        info[label + "_executable"] = bool(path and path.is_file() and os.access(path, os.X_OK))
        # Short opaque comparison fingerprint, not actual path.
        info[label + "_fingerprint"] = (
            hashlib.sha256(target.encode()).hexdigest()[:10] if target else "none"
        )
    summaries.append(info)

print("=== Runner .env job-hook configuration (no values) ===")
for info in summaries:
    print(info["runner"])
    print("  .env present:", info["env_present"])
    for label in ("started", "completed"):
        print(
            "  {}: configured={}, absolute={}, file_exists={}, executable={}, target_id={}".format(
                label, info[label], info[label + "_absolute"],
                info[label + "_exists"], info[label + "_executable"],
                info[label + "_fingerprint"]
            )
        )

print()
print("Shared job-start target identifiers:",
      len({x["started_fingerprint"] for x in summaries if x["started"]}))
print("Configured start hooks:", sum(1 for x in summaries if x["started"]))
print("Configured completion hooks:", sum(1 for x in summaries if x["completed"]))
print()
print("NOTE: values read from .env only. Environment variables inherited through")
print("a service manager or wrapper may require separate verification.")
print("A present start hook alone does not prove a lock survives for the entire job.")
print("Do not publish raw .env contents or execute an unknown hook to test it.")
PY
