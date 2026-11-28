"""Host-side state for status.json: presence, the GPU lock holder and running games.

Each field is None when its source is missing, so a reader shows unknown, never a default.
"""

import os
import subprocess
import threading
import time

SERVICES = os.environ.get("CLAUDE_SERVICES_DIR") or os.path.expanduser(
    "~/claude/.services"
)
LOCKS = os.path.join(SERVICES, "locks")


def read(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return None


def presence():
    state, since = read(os.path.join(SERVICES, "presence/state")), read(
        os.path.join(SERVICES, "presence/since")
    )
    age = int(time.time()) - int(since) if since and since.isdigit() else None
    return {"state": state, "age_s": age}


def holder(path):
    """The process holding a flock on path, from /proc/locks: {"pid", "cmd"}, or None when free."""
    ino = os.stat(path).st_ino
    with open("/proc/locks") as f:
        for line in f:
            parts = line.split()
            if "->" in parts or len(parts) < 6 or parts[1] != "FLOCK":
                continue
            if int(parts[5].rsplit(":", 1)[1]) == ino:
                cmd = read(f"/proc/{parts[4]}/cmdline")
                return {
                    "pid": int(parts[4]),
                    "cmd": (cmd or "").replace("\0", " ").strip()[:120],
                }
    return None


def gpu():
    path = os.path.join(LOCKS, "gpu.lock")
    if not os.path.exists(path):
        return {"held": None, "holder": None}
    h = holder(path)
    return {"held": h is not None, "holder": h}


class Games:
    """games-running in a background thread every INTERVAL s (it ssh-es to the Deck and settop, up to ~40 s).

    It prints one line per running game and exits 1 if any; a line with "unknown" means a device did not answer.
    """

    INTERVAL = 60

    def __init__(self):
        self.last = {"running": None, "lines": [], "age_s": None}
        self.at = None
        threading.Thread(target=self.loop, daemon=True).start()

    def probe(self):
        script = os.path.join(LOCKS, "games-running")
        if not os.path.exists(script):
            return {"running": None, "lines": []}
        out = subprocess.run(
            ["sh", script], check=False, capture_output=True, text=True, timeout=90
        )
        lines = [l for l in out.stdout.splitlines() if l.strip()]
        known = [l for l in lines if "unknown" not in l]
        running = (
            True
            if out.returncode == 1 and known
            else (False if out.returncode == 0 else None)
        )
        return {"running": running, "lines": lines}

    def loop(self):
        while True:
            try:
                self.last, self.at = self.probe(), time.time()
            except (OSError, subprocess.SubprocessError):
                self.last, self.at = {"running": None, "lines": []}, time.time()
            time.sleep(self.INTERVAL)

    def get(self):
        return {
            **self.last,
            "age_s": None if self.at is None else int(time.time() - self.at),
        }


_games = None


def games():
    global _games
    if _games is None:
        _games = Games()
    return _games.get()


def busy():
    """Work in flight per claude-busy, from the count the status line keeps (the file is removed at 0)."""
    n = read(os.path.join(SERVICES, "manager/busy"))
    return int(n) if n and n.isdigit() else 0


def jobs():
    """Jobs registered with claude-job (one <name>.json each), or None when the directory is missing."""
    d = os.path.join(SERVICES, "jobs/running")
    return (
        len([f for f in os.listdir(d) if f.endswith(".json")])
        if os.path.isdir(d)
        else None
    )


def host():
    return {
        "presence": presence(),
        "gpu": gpu(),
        "games": games(),
        "busy": busy(),
        "jobs": jobs(),
    }
