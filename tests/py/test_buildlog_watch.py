"""Tests of container/services/buildlog/watch.py (one scan) with a stub `homun-msg`."""

import isolate  # noqa: F401, I001
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

WATCH = Path(__file__).resolve().parents[2] / "container/services/buildlog/watch.py"


class WatchTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.root = Path(self.tmp.name)
        self.addCleanup(self.tmp.cleanup)
        self.msg = self.root / "msg"
        self.msg.write_text(f'#!/bin/sh\nprintf "%s|%s\\n" "$3" "$4" >>"{self.root}/bus.log"\n')
        self.msg.chmod(0o755)
        (self.root / "nix").mkdir()

    def latest(self, exit=0, warnings=(), log="a.log"):
        (self.root / "nix" / log).write_text("error: boom\n" if exit else "")
        info = {"command": "nix build", "cwd": "/x", "exit": exit, "duration": 1.0,
                "log": str(self.root / "nix" / log), "warnings": list(warnings)}
        (self.root / "nix" / "latest.json").write_text(json.dumps(info))

    def scan(self):
        env = {**os.environ, "BUILDLOG_ROOT": str(self.root), "HOMUN_MSG": str(self.msg)}
        subprocess.run(["python3", "-I", str(WATCH)], env=env, check=True)
        bus = self.root / "bus.log"
        return bus.read_text().splitlines() if bus.exists() else []

    def test_failure_alarms_once(self):
        self.latest(exit=1)
        out = self.scan()
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith("build-failed|nix: nix build failed (exit 1, /x)"))
        self.assertEqual(self.scan(), out)

    def test_success_is_silent(self):
        self.latest()
        self.assertEqual(self.scan(), [])

    def test_new_warnings_alarm_once(self):
        self.latest(warnings=["warning: a", "warning: b"], log="a.log")
        out = self.scan()
        self.assertEqual(len(out), 1)
        self.assertIn("warning: a | warning: b", out[0])
        self.latest(warnings=["warning: a", "warning: b"], log="b.log")
        self.assertEqual(self.scan(), out)
        self.latest(warnings=["warning: a", "warning: c"], log="c.log")
        out = self.scan()
        self.assertEqual(len(out), 2)
        self.assertTrue(out[1].startswith("build-warnings|") and "warning: c" in out[1])
        self.assertNotIn("warning: a", out[1])

    def test_other_projects_ignore_warnings(self):
        (self.root / "nix" / "latest.json").unlink(missing_ok=True)
        (self.root / "app").mkdir()
        info = {"command": "cargo build", "exit": 0, "where": "host", "log": "l", "warnings": ["warning: x"]}
        (self.root / "app" / "latest.json").write_text(json.dumps(info))
        self.assertEqual(self.scan(), [])


if __name__ == "__main__":
    unittest.main()
