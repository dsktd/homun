"""Scan buildlog/*/latest.json; alarm once per new failing log and once per new nix warning."""

import json
import os
import re
import subprocess
import sys
import time
from pathlib import Path

ROOT = Path(os.environ.get("BUILDLOG_ROOT", Path.home() / "claude/.services/buildlog"))
SEEN = ROOT / ".seen.json"
WARNED = ROOT / ".warned.json"
ANSI = re.compile(r"\x1b\[[0-9;]*[A-Za-z]")


def first_error(log):
    lines = [ANSI.sub("", ln) for ln in Path(log).read_text(errors="replace").splitlines()]
    for i, ln in enumerate(lines):
        if re.match(r"error(\[\w+\])?:", ln) and "could not compile" not in ln:
            for nxt in lines[i + 1 : i + 4]:
                m = re.match(r"\s*--> (\S+)", nxt)
                if m:
                    return f"{m.group(1)} {ln}"
            return ln
    return next((ln for ln in lines if ln.startswith("error")), "no error line found")


def send(alarm, msg):
    subprocess.run([os.environ.get("HOMUN_MSG", "homun-msg"), "send", "manager", alarm, msg], check=False)


def warn(key, info, warned):
    """One build-warnings alarm for the warning lines of `key` not alarmed before."""
    new = [w for w in info.get("warnings", []) if w not in warned.setdefault(key, [])]
    if new:
        warned[key] += new
        send("build-warnings", f"{key}: {info['command']}: " + " | ".join(new) + f"; log {info['log']}")
        print(f"{time.strftime('%FT%T')} WARNINGS {key}: {len(new)} new", flush=True)


# Interrupted by the user (SIGINT, SIGTERM): not a failure.
CANCELLED = (130, 143)


def scan():
    seen = json.loads(SEEN.read_text()) if SEEN.exists() else {}
    warned = json.loads(WARNED.read_text()) if WARNED.exists() else {}
    for f in sorted(ROOT.glob("*/latest.json")):
        try:
            info = json.loads(f.read_text())
        except (OSError, ValueError):
            continue
        key = f.parent.name
        if seen.get(key) == info["log"]:
            continue
        seen[key] = info["log"]
        if key == "nix":
            warn(key, info, warned)
        if info["exit"] == 0:
            print(f"{time.strftime('%FT%T')} ok {key}: {info['command']}", flush=True)
            continue
        if info["exit"] in CANCELLED:
            print(f"{time.strftime('%FT%T')} cancelled {key}: {info['command']}", flush=True)
            continue
        msg = f"{key}: {info['command']} failed (exit {info['exit']}, {info.get('where') or info.get('cwd')}): {first_error(info['log'])}; log {info['log']}"
        send("build-failed", msg)
        print(f"{time.strftime('%FT%T')} FAILED {msg}", flush=True)
    SEEN.write_text(json.dumps(seen))
    WARNED.write_text(json.dumps(warned))


if __name__ == "__main__":
    ROOT.mkdir(parents=True, exist_ok=True)
    while True:
        scan()
        if sys.argv[1:] != ["loop"]:
            break
        time.sleep(10)
