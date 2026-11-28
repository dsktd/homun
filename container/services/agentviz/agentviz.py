#!/usr/bin/env python3
"""Tail live Claude Code transcripts (main and subagent) into one tool-call event stream.

Run without arguments as the service. Reads each transcript incrementally by byte offset.
"""

import json
import os
import re
import time
from datetime import datetime
from pathlib import Path

HOME = Path(os.environ.get("HOME", "/root"))
ROOT = HOME / "claude"
PROJECTS = Path(os.environ.get("AGENTVIZ_PROJECTS") or HOME / ".claude/projects" / str(ROOT).replace("/", "-"))
OUT = Path(os.environ.get("AGENTVIZ_OUT") or ROOT / ".services/agentviz")
MAX_BYTES = 5 * 1024 * 1024
ACTIVE_S = 120
KINDS = {
    "Read": "read",
    "Edit": "edit",
    "MultiEdit": "edit",
    "NotebookEdit": "edit",
    "Write": "write",
    "Grep": "search",
    "Glob": "search",
}
BUILD = re.compile(r"\b(cargo\s+(build|check|clippy|run|install)|homun-compile|nix\s+build)\b")
TEST = re.compile(r"\b(cargo\s+test|nix\s+(flake\s+check|test)|nu\s+tests/run\.nu)\b")


def repo_of(path):
    """The repository root under ~/claude that holds path: <ws>/<repo>, _tools/<repo> or .bare/<repo>.git."""
    if not path:
        return None
    try:
        parts = Path(path).relative_to(ROOT).parts
    except ValueError:
        return None
    return str(ROOT.joinpath(*parts[:2])) if len(parts) >= 2 else None


def kind_of(tool, inp):
    if tool == "Bash":
        cmd = inp.get("command", "")
        return "test" if TEST.search(cmd) else "build" if BUILD.search(cmd) else "bash"
    return KINDS.get(tool)


def path_of(tool, inp, cwd):
    if tool == "Bash":
        return cwd
    return inp.get("file_path") or inp.get("notebook_path") or inp.get("path") or cwd


def stamp(rec):
    try:
        return datetime.fromisoformat(rec["timestamp"]).timestamp()
    except (KeyError, ValueError):
        return time.time()


class Agent:
    """Turns the records of one transcript into events; a tool call is emitted with its result."""

    def __init__(self, agent, label, model=None):
        self.agent, self.label, self.model = agent, label, model
        self.pending = {}

    def event(self, t, kind, path=None, ok=None):
        return {
            "t": t,
            "agent": self.agent,
            "label": self.label,
            "model": self.model,
            "kind": kind,
            "path": path,
            "repo": repo_of(path),
            "ok": ok,
        }

    def feed(self, rec):
        t, out = stamp(rec), []
        msg = rec.get("message") or {}
        content = msg.get("content")
        if not isinstance(content, list):
            return out
        if msg.get("model"):
            self.model = msg["model"]
        for part in content:
            if not isinstance(part, dict):
                continue
            if part.get("type") == "tool_use":
                inp = part.get("input") or {}
                kind = kind_of(part.get("name"), inp)
                if kind:
                    path = path_of(part["name"], inp, rec.get("cwd"))
                    self.pending[part["id"]] = self.event(t, kind, path)
            elif part.get("type") == "tool_result" and part.get("tool_use_id") in self.pending:
                ev = self.pending.pop(part["tool_use_id"])
                ev["ok"] = not part.get("is_error", False)
                out.append(ev)
        return out

    def flush(self, t):
        out = [dict(ev, t=t) for ev in self.pending.values()]
        self.pending.clear()
        return out


class Tail:
    def __init__(self, path, start):
        self.path, self.pos, self.buf = path, start, b""
        meta = path.with_suffix(".meta.json")
        info = json.loads(meta.read_text()) if meta.exists() else {}
        sub = path.parent.name == "subagents"
        self.agent = Agent(
            path.stem.removeprefix("agent-")[:8], info.get("description") or ("main" if not sub else "agent"), None
        )
        self.done = False

    def read(self):
        """New complete records since the last read."""
        with open(self.path, "rb") as f:
            f.seek(self.pos)
            data = self.buf + f.read()
            self.pos = f.tell()
        *lines, self.buf = data.split(b"\n")
        recs = []
        for line in lines:
            try:
                recs.append(json.loads(line))
            except ValueError:
                pass
        return recs

    def finished(self):
        meta = self.path.with_suffix(".meta.json")
        try:
            return bool(json.loads(meta.read_text()).get("finished"))
        except (OSError, ValueError):
            return False


class Sink:
    def __init__(self, out):
        out.mkdir(parents=True, exist_ok=True)
        self.path = out / "events.jsonl"

    def write(self, events):
        if not events:
            return
        if self.path.exists() and self.path.stat().st_size > MAX_BYTES:
            self.path.replace(self.path.with_suffix(".jsonl.1"))
        with open(self.path, "a") as f:
            f.writelines(json.dumps(e) + "\n" for e in events)


def main():
    sink, tails, first = Sink(OUT), {}, True
    while True:
        now = time.time()
        for p in [*PROJECTS.glob("*.jsonl"), *PROJECTS.glob("*/subagents/*.jsonl")]:
            try:
                st = p.stat()
            except OSError:
                continue
            if p not in tails and now - st.st_mtime < ACTIVE_S:
                tails[p] = Tail(p, st.st_size if first else 0)
                if not first or now - st.st_mtime < 5:
                    sink.write([tails[p].agent.event(now, "start")])
        first = False
        for p, tail in list(tails.items()):
            try:
                st = p.stat()
                events = [e for r in tail.read() for e in tail.agent.feed(r)] if st.st_size > tail.pos else []
            except OSError:
                events = []
                st = None
            idle = st is None or now - st.st_mtime > ACTIVE_S
            if idle or tail.finished():
                events += tail.agent.flush(now) + [tail.agent.event(now, "finish")]
                del tails[p]
            sink.write(events)
        time.sleep(1)


if __name__ == "__main__":
    main()
