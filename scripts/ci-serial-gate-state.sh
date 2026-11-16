#!/usr/bin/env bash
# Read-only: inspect whether runner serialization is actually wired in.
# Does not display environment values or installer source. Does not restart services.
set -euo pipefail
VM="${CI_VM_NAME:-samloryx-ci}"
command -v multipass >/dev/null || { echo "multipass is unavailable" >&2; exit 1; }

multipass exec "$VM" -- bash -s <<'GUEST'
set -euo pipefail
sudo python3 - <<'PY'
from pathlib import Path
import subprocess
import re

def command(*argv):
    return subprocess.run(argv, capture_output=True, text=True, check=False).stdout

installer = Path("/home/ubuntu/install_ci_serial_gate.py")
print("=== Installer file (source not disclosed) ===")
print(f"present: {installer.is_file()}")
if installer.is_file():
    code = installer.read_text(errors="replace")
    for name, regex in {
        "references flock": r"\bflock\b",
        "references job started hooks": r"ACTIONS_RUNNER_HOOK_JOB_STARTED",
        "references job completed hooks": r"ACTIONS_RUNNER_HOOK_JOB_COMPLETED",
        "references ExecStartPre": r"ExecStartPre",
        "references per-repo lock": r"(lockfile|\.lock|LOCK_FILE)",
    }.items():
        print(f"  {name}: {bool(re.search(regex,code))}")

print("\n=== Runner systemd units (read-only summary) ===")
units = [
    line.split()[0]
    for line in command("systemctl","list-unit-files","--type=service",
                        "--no-legend","actions.runner.*.service").splitlines()
    if line and line.split()[0].startswith("actions.runner.")
]
print(f"runner units: {len(units)}")
for unit in units:
    raw = command("systemctl","show",unit,
                  "-p","FragmentPath","-p","DropInPaths","-p","ActiveState",
                  "-p","MemoryMax","-p","MemoryHigh","-p","MemorySwapMax",
                  "-p","Restart","-p","OOMPolicy")
    props = dict(line.split("=",1) for line in raw.splitlines() if "=" in line)
    fragments = [props.get("FragmentPath","")]
    fragments += props.get("DropInPaths","").split()
    body = "\n".join(Path(p).read_text(errors="replace") for p in fragments
                     if p and Path(p).is_file())
    print(f"\n{unit}")
    for p in ["ActiveState","MemoryMax","MemoryHigh","MemorySwapMax","Restart","OOMPolicy"]:
        print(f"  {p}: {props.get(p,'unknown')}")
    print(f"  drop-in count: {len(fragments)-1}")
    print(f"  unit files mention flock/serial lock: {bool(re.search(r'flock|serial.*lock|ci.*lock',body,re.I))}")
    print(f"  unit files mention job hooks: {'ACTIONS_RUNNER_HOOK_JOB_STARTED' in body}")
    print(f"  unit files mention ExecStartPre: {'ExecStartPre=' in body}")

print("\n=== Guest system processes ===")
for line in command("pgrep","-af","[R]unner.Worker").splitlines():
    # Do not expose arbitrary process arguments or paths: show count only.
    pass
workers = command("pgrep","-f","[R]unner.Worker").splitlines()
print(f"active worker processes: {len(workers)}")
print("\nNote: static configuration alone cannot prove exclusive execution.")
PY
GUEST
