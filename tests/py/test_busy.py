"""Tests of container/claude-busy, with a stub `claude`, a fake /proc and a temp workers dir."""

import contextlib
import importlib.machinery
import importlib.util
import io
import json
import tempfile
import unittest
from pathlib import Path
from unittest import mock

SCRIPT = Path(__file__).resolve().parents[2] / "container/claude-busy"
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


if __name__ == "__main__":
    unittest.main()
