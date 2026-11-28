"""Detection of stray processes, for the status page: no killing, only a list.

A stray is a process re-parented to PID 1 for at least STRAY_HOURS (default 3) that is not the
runit tree, the Claude session or an ssh control master. A gpu.lock holder is also flagged when it
is a stray or older than STRAY_HOURS (an inherited lock fd keeps the lock after its job ends).
"""

import os
import re

HOURS = float(os.environ.get("STRAY_HOURS", "3"))
LOCK = os.path.expanduser("~/claude/.services/locks/gpu.lock")
EXPECTED = re.compile(r"^(sh /opt/homun/|runsvdir |claude |ssh: )")
HZ = os.sysconf("SC_CLK_TCK")


def proc(pid):
    """(ppid, age in seconds, cmdline) of a pid, or None when it is gone."""
    try:
        with open(f"/proc/{pid}/stat") as f:
            rest = f.read().rsplit(")", 1)[1].split()
        with open("/proc/uptime") as f:
            up = float(f.read().split()[0])
        with open(f"/proc/{pid}/cmdline") as f:
            cmd = f.read().replace("\0", " ").strip()
    except (OSError, IndexError, ValueError):
        return None
    return int(rest[1]), up - int(rest[19]) / HZ, cmd[:160] or f"[{pid}]"


def lock_holders():
    try:
        ino = os.stat(LOCK).st_ino
    except OSError:
        return set()
    held = set()
    for pid in filter(str.isdigit, os.listdir("/proc")):
        try:
            for fd in os.listdir(f"/proc/{pid}/fd"):
                if os.stat(f"/proc/{pid}/fd/{fd}").st_ino == ino:
                    held.add(int(pid))
        except OSError:
            continue
    return held


def strays():
    """Rows {pid, age_s, cmd, why} for every flagged process."""
    holders = lock_holders()
    out = []
    for pid in sorted(int(p) for p in filter(str.isdigit, os.listdir("/proc"))):
        info = proc(pid)
        if not info or pid == 1:
            continue
        ppid, age, cmd = info
        old = age >= HOURS * 3600
        orphan = ppid == 1 and old and not EXPECTED.match(cmd)
        holder = pid in holders and (old or ppid == 1)
        if orphan or holder:
            out.append(
                {
                    "pid": pid,
                    "age_s": int(age),
                    "cmd": cmd,
                    "why": "holds gpu.lock" if holder else "orphan",
                }
            )
    return out


if __name__ == "__main__":
    for s in strays():
        print(s["pid"], f"{s['age_s'] // 60}m", s["why"], s["cmd"])
