"""A stub `homun-msg` for tests: `send <to> <alarm> <msg>` appends a JSON line to a log."""

import json
import os
from pathlib import Path

SCRIPT = """#!/bin/sh
[ "$1" = send ] || exit 2
jq -cn --arg to "$2" --arg a "$3" --arg m "$4" '{to:$to,alarm:$a,msg:$m}' >>"$0.log"
"""


def install(root):
    """Env additions that put the stub first on PATH; read the sends with sent()."""
    bindir = Path(root) / "stubbin"
    bindir.mkdir(exist_ok=True)
    script = bindir / "homun-msg"
    script.write_text(SCRIPT)
    script.chmod(0o755)
    return {"PATH": f"{bindir}:{os.environ['PATH']}"}


def sent(root):
    log = Path(root) / "stubbin/homun-msg.log"
    if not log.exists():
        return []
    return [json.loads(line) for line in log.read_text().splitlines()]
