"""Tests of container/claude-busy, with a stub `claude`, a fake /proc and a temp workers dir."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import contextlib
import importlib.machinery
import importlib.util
import io
import json
import os
import tempfile
import time
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "container/claude-busy-legacy"
loader = importlib.machinery.SourceFileLoader("claude_busy", str(SCRIPT))
spec = importlib.util.spec_from_loader("claude_busy", loader)
busy = importlib.util.module_from_spec(spec)
loader.exec_module(busy)

AGENTS = [
    {"id": "m1", "kind": "interactive", "status": "busy", "name": "manager"},
    {"id": "a1", "kind": "background", "state": "running", "name": "builder"},
    {"id": "a2", "kind": "background", "state": "done", "name": "old"},
    {"id": "a3", "kind": "background", "state": "stopped", "name": "old2"},
    {"id": "a4", "kind": "background", "state": "failed", "name": "old3"},
]


class BusyTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.workers = self.dir / "workers"
        self.workers.mkdir()
        self.proc = self.dir / "proc"
        self.proc.mkdir()
        self.claude = self.dir / "claude"
        self.set_agents([])
        for name, value in (
            ("CLAUDE", str(self.claude)),
            ("PROC", self.proc),
            ("WORKERS", self.workers),
            ("PROJECTS", self.dir / "projects"),
            ("SESSIONS", self.dir / "sessions"),
        ):
            patcher = mock.patch.object(busy, name, value)
            patcher.start()
            self.addCleanup(patcher.stop)

    def set_agents(self, agents, raw=None):
        body = raw if raw is not None else json.dumps(agents)
        self.claude.write_text(f"#!/bin/sh\ncat <<'EOF'\n{body}\nEOF\n")
        self.claude.chmod(0o755)

    def ledger(self, *rows):
        text = "".join(json.dumps(r) + "\n" for r in rows)
        (self.workers / "ledger.jsonl").write_text(text)

    def process(self, pid, *argv):
        d = self.proc / str(pid)
        d.mkdir()
        (d / "cmdline").write_bytes(b"\0".join(a.encode() for a in argv) + b"\0")

    def live_session(self, session="session"):
        """Register `session` as run by this test process (pid and start time)."""
        stat = Path(f"/proc/{os.getpid()}/stat").read_text()
        d = self.dir / "sessions"
        d.mkdir(exist_ok=True)
        (d / f"{os.getpid()}.json").write_text(
            json.dumps(
                {
                    "pid": os.getpid(),
                    "sessionId": session,
                    "procStart": stat.rsplit(")", 1)[1].split()[19],
                }
            )
        )

    def subagent(self, name, finished=False, age=0, description="a task"):
        self.live_session()
        d = self.dir / "projects/p/session/subagents"
        d.mkdir(parents=True, exist_ok=True)
        meta = {"agentType": "implementer", "description": description}
        if finished:
            meta["finished"] = True
        (d / f"agent-{name}.meta.json").write_text(json.dumps(meta))
        transcript = d / f"agent-{name}.jsonl"
        transcript.write_text("{}\n")
        t = time.time() - age
        os.utime(transcript, (t, t))

    def run_main(self):
        out, err = io.StringIO(), io.StringIO()
        with contextlib.redirect_stdout(out), contextlib.redirect_stderr(err):
            rc = busy.main()
        return rc, out.getvalue(), err.getvalue()

    def test_idle(self):
        self.set_agents(AGENTS[:1] + AGENTS[2:])
        self.assertEqual(self.run_main(), (0, "", ""))

    def test_running_background_agent_is_busy_manager_is_not(self):
        self.set_agents(AGENTS)
        rc, out, err = self.run_main()
        self.assertEqual((rc, out, err), (1, "agent builder (running)\n", ""))

    def test_worker_needs_unfinished_row_and_live_process(self):
        self.ledger(
            {"name": "live", "exit": None},
            {"name": "crashed", "exit": None},
            {"name": "settled", "exit": 0},
        )
        self.process(7, "python3", "/x/bin/claude-worker", "run", "live", "impl")
        self.process(8, "python3", "/x/bin/claude-worker", "run", "settled", "impl")
        rc, out, err = self.run_main()
        self.assertEqual((rc, out, err), (1, "worker live (claude-worker run)\n", ""))

    def test_both_kinds_listed(self):
        self.set_agents(AGENTS)
        self.ledger({"name": "w", "exit": None})
        self.process(7, "claude-worker", "run", "w")
        rc, out, _ = self.run_main()
        self.assertEqual(rc, 1)
        self.assertEqual(len(out.splitlines()), 2)

    def test_missing_claude_is_noted_and_does_not_block(self):
        self.claude.unlink()
        rc, out, err = self.run_main()
        self.assertEqual((rc, out), (0, ""))
        self.assertIn("claude agents", err)

    def test_unparseable_agents_is_noted_and_does_not_block(self):
        self.set_agents(None, raw="not json")
        rc, out, err = self.run_main()
        self.assertEqual((rc, out), (0, ""))
        self.assertIn("claude agents", err)

    def test_bad_ledger_is_noted_and_agents_still_listed(self):
        self.set_agents(AGENTS)
        (self.workers / "ledger.jsonl").write_text("{broken\n")
        rc, out, err = self.run_main()
        self.assertEqual((rc, out), (1, "agent builder (running)\n"))
        self.assertIn("ledger.jsonl", err)

    def test_unfinished_recent_subagent_is_busy(self):
        self.subagent("a", description="Fix the thing")
        self.subagent("b", finished=True)
        rc, out, err = self.run_main()
        self.assertEqual(
            (rc, out, err), (1, "agent Fix the thing (implementer subagent)\n", "")
        )

    def test_subagent_of_an_ended_session_is_not_busy(self):
        self.subagent("a")
        (self.dir / "sessions" / f"{os.getpid()}.json").unlink()
        self.assertEqual(self.run_main(), (0, "", ""))

    def test_stale_or_unreadable_subagent_is_not_busy(self):
        self.subagent("old", age=3600, description="old")
        d = self.dir / "projects/p/session/subagents"
        (d / "agent-bad.meta.json").write_text("{not json")
        (d / "agent-bad.jsonl").write_text("{}\n")
        rc, out, err = self.run_main()
        self.assertEqual((rc, out), (0, ""))
        self.assertIn("agent old quiet", err)
        self.assertNotIn("bad", err)

    def test_killed_subagent_is_not_busy_at_once(self):
        self.subagent("live")
        fx = Path(__file__).resolve().parents[1] / "fixtures/busy"
        d = self.dir / "projects/p/session/subagents"
        (d / "agent-killed.meta.json").write_text(
            (fx / "killed-agent.meta.json").read_text()
        )
        (d / "agent-killed.jsonl").write_text((fx / "killed-agent.jsonl").read_text())
        rc, out, err = self.run_main()
        self.assertEqual(
            (rc, out, err), (1, "agent a task (implementer subagent)\n", "")
        )


if __name__ == "__main__":
    unittest.main()
