"""Record one git maintenance run of a repository in usage.sqlite (maint_runs).

Usage: collect.py <repo> <task> <duration_ms> <ok 0|1>

The database is $MAINT_DB, else usage-db/usage.sqlite under $CLAUDE_SERVICES_DIR
(default ~/claude/.services). Exits 1 with a message when git is missing or
fails, or when the database stays locked.
"""

import os
import sqlite3
import subprocess
import sys
import time

SCHEMA = """create table if not exists maint_runs (
  ts integer not null, repo text not null, task text not null,
  duration_ms integer not null, ok integer not null,
  loose integer, in_pack integer, packs integer, size_kib integer,
  garbage integer, refs integer)"""


def git(repo, *args):
    done = subprocess.run(
        ["git", "-C", repo, *args], capture_output=True, text=True, check=True
    )
    return done.stdout


def measure(repo):
    """Object counts of `git count-objects -v` plus the number of refs."""
    lines = git(repo, "count-objects", "-v").splitlines()
    c = {k: int(v) for k, v in (line.split(": ") for line in lines)}
    return {
        "loose": c["count"],
        "in_pack": c["in-pack"],
        "packs": c["packs"],
        "size_kib": c["size"] + c["size-pack"],
        "garbage": c["garbage"],
        "refs": len(git(repo, "for-each-ref").splitlines()),
    }


def record(db, repo, task, duration_ms, ok, now=None):
    row = {
        "ts": int(now or time.time()),
        "repo": os.path.basename(repo.rstrip("/")),
        "task": task,
        "duration_ms": duration_ms,
        "ok": int(ok),
        **measure(repo),
    }
    con = sqlite3.connect(db, timeout=5)
    try:
        with con:
            con.execute(SCHEMA)
            con.execute(
                f"insert into maint_runs ({', '.join(row)}) "
                f"values ({', '.join(':' + k for k in row)})",
                row,
            )
    finally:
        con.close()


def default_db():
    services = os.environ.get("CLAUDE_SERVICES_DIR") or os.path.expanduser(
        "~/claude/.services"
    )
    return os.environ.get("MAINT_DB") or os.path.join(
        services, "usage-db", "usage.sqlite"
    )


def main(argv):
    repo, task, duration_ms, ok = argv
    try:
        record(default_db(), repo, task, int(duration_ms), ok == "1")
    except FileNotFoundError:
        print("collect: git is not installed", file=sys.stderr)
        return 1
    except subprocess.CalledProcessError as e:
        print(f"collect: git failed: {e.stderr.strip()}", file=sys.stderr)
        return 1
    except sqlite3.OperationalError as e:
        print(f"collect: database: {e}", file=sys.stderr)
        return 1
    return 0


if __name__ == "__main__":
    sys.exit(main(sys.argv[1:]))
