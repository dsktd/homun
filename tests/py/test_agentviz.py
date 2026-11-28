"""agentviz: transcript records to events, and events to gource lines."""

import importlib.machinery
import importlib.util
import os
import sys
import unittest
from pathlib import Path

os.environ["HOME"] = "/home/t"
REPO = Path(__file__).resolve().parents[2]
sys.path.insert(0, str(REPO / "container/services/agentviz"))
import agentviz

loader = importlib.machinery.SourceFileLoader("gource", str(REPO / "bin/agentviz-gource"))
spec = importlib.util.spec_from_loader("gource", loader)
gource = importlib.util.module_from_spec(spec)
loader.exec_module(gource)

T = "2026-11-27T19:12:06.000Z"


def use(i, name, **inp):
    block = {"type": "tool_use", "id": i, "name": name, "input": inp}
    return {"timestamp": T, "cwd": "/home/t/claude/ws/r", "message": {"model": "m1", "content": [block]}}


def result(i, err=False):
    block = {"type": "tool_result", "tool_use_id": i, "is_error": err, "content": "x"}
    return {"timestamp": T, "message": {"content": [block]}}


class Convert(unittest.TestCase):
    def run_calls(self, rec, err=False):
        a = agentviz.Agent("abc", "task")
        self.assertEqual(a.feed(rec), [])
        return a.feed(result(rec["message"]["content"][0]["id"], err))[0]

    def test_edit_in_repo(self):
        ev = self.run_calls(use("1", "Edit", file_path="/home/t/claude/ws/r/a.rs"))
        self.assertEqual((ev["kind"], ev["ok"], ev["model"]), ("edit", True, "m1"))
        self.assertEqual(ev["repo"], "/home/t/claude/ws/r")
        self.assertEqual(ev["t"], 1795806726.0)

    def test_bash_kinds(self):
        for cmd, kind in [
            ("cargo test -q", "test"),
            ("cargo build", "build"),
            ("homun-compile x", "build"),
            ("nix build .#a", "build"),
            ("ls", "bash"),
        ]:
            ev = self.run_calls(use("1", "Bash", command=cmd))
            self.assertEqual((ev["kind"], ev["path"]), (kind, "/home/t/claude/ws/r"))

    def test_failure_and_ignored_tools(self):
        self.assertFalse(self.run_calls(use("1", "Read", file_path="/etc/x"), err=True)["ok"])
        self.assertIsNone(agentviz.kind_of("TodoWrite", {}))
        self.assertIsNone(agentviz.repo_of("/etc/x"))

    def test_flush_unanswered(self):
        a = agentviz.Agent("abc", "task")
        a.feed(use("1", "Grep", pattern="x"))
        self.assertIsNone(a.flush(5.0)[0]["ok"])


class Gource(unittest.TestCase):
    def test_lines(self):
        seen = set()
        ev = {"t": 10.5, "label": "fix|it", "kind": "write", "path": gource.ROOT + "ws/r/a"}
        self.assertEqual(gource.convert(ev, seen), "10|fix/it|A|ws/r/a")
        self.assertEqual(gource.convert(dict(ev, kind="read"), seen), "10|fix/it|M|ws/r/a")
        self.assertIsNone(gource.convert(dict(ev, kind="bash"), seen))


if __name__ == "__main__":
    unittest.main()
