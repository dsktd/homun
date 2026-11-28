"""Fetch the PR lists of the repos in `repos` into prs-<owner>-<repo>.json beside this file."""

import os
import subprocess
import sys
import time
from pathlib import Path

PERIOD = 300
FIELDS = "number,title,url,state,additions,deletions,statusCheckRollup"


class Prs:
    """The cached PR list of one repo."""

    def __init__(self, repo, root):
        self.repo = repo
        self.path = root / f"prs-{repo.replace('/', '-')}.json"

    def mtime(self):
        return self.path.stat().st_mtime if self.path.exists() else 0.0

    def due(self, requested, now):
        return now - self.mtime() >= PERIOD or requested > self.mtime()

    def fetch(self):
        cmd = [
            "gh",
            "pr",
            "list",
            "-R",
            self.repo,
            "--state",
            "all",
            "--limit",
            "60",
            "--json",
            FIELDS,
        ]
        done = subprocess.run(cmd, capture_output=True, text=True, timeout=120, check=False)
        if done.returncode != 0:
            err = done.stderr.strip()
            print(f"{self.repo}: gh exit {done.returncode}: {err}", flush=True)
            return False
        tmp = self.path.with_suffix(".tmp")
        tmp.write_text(done.stdout)
        os.replace(tmp, self.path)
        return True


def repos(root):
    lines = (root / "repos").read_text().splitlines() if (root / "repos").exists() else []
    return [Prs(x.strip(), root) for x in lines if x.strip() and not x.startswith("#")]


def once(root, now=None):
    """Fetch every due repo; return the repos fetched."""
    now = time.time() if now is None else now
    req = root / "request"
    requested = req.stat().st_mtime if req.exists() else 0.0
    got = []
    for p in repos(root):
        if p.due(requested, now):
            # a failed fetch leaves the old cache; the request mtime would stay newer, so back off
            if p.fetch():
                got.append(p.repo)
            elif p.path.exists():
                os.utime(p.path)
    return got


def main():
    root = Path(__file__).resolve().parent
    while True:
        try:
            once(root)
        except Exception as e:  # noqa: BLE001  keep the loop alive
            print(f"error: {e}", flush=True)
        if sys.argv[1:2] != ["loop"]:
            return
        time.sleep(2)


if __name__ == "__main__":
    main()
