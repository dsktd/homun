"""bin/claude-idea against a temp inbox only."""

import os
import subprocess
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-idea"


class Idea(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.inbox = Path(tmp.name) / "inbox"

    def idea(self, *args, stdin=None):
        return subprocess.run(
            ["python3", str(BIN), *args],
            check=False,
            input=stdin,
            env={**os.environ, "CLAUDE_IDEAS_DIR": str(self.inbox)},
            capture_output=True,
            text=True,
        )

    def add(self, text="make it faster", *args):
        proc = self.idea("add", *args, text)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def set_state(self, id, state):
        path = self.inbox / f"{id}.md"
        path.write_text(path.read_text().replace("state: new", f"state: {state}"))

    def test_add_list_show(self):
        id = self.add("make it\nfaster", "--source", "emacs")
        self.assertRegex(id, r"^\d{8}-\d{6}-[0-9a-f]{4}$")
        shown = self.idea("show", id).stdout
        self.assertIn("source: emacs\n", shown)
        self.assertIn("state: new\n\nmake it\nfaster", shown)
        self.assertEqual(self.idea("list").stdout, f"{id}  new  make it faster\n")
        self.assertEqual(self.idea("list", "--state", "dropped").stdout, "")

    def test_add_from_stdin(self):
        proc = self.idea("add", "-", stdin="from a pipe")
        id = proc.stdout.strip()
        self.assertTrue(self.idea("show", id).stdout.endswith("\n\nfrom a pipe"))

    def test_list_truncates(self):
        self.add("x" * 200)
        line = self.idea("list").stdout.split("  ", 2)[2].rstrip("\n")
        self.assertEqual(len(line), 80)

    def test_promote_needs_triage(self):
        id = self.add()
        proc = self.idea("promote", id, "http://x/1")
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stderr.count("\n"), 1)
        self.assertIn("new to promoted", proc.stderr)
        self.set_state(id, "triaged")
        self.assertEqual(self.idea("promote", id, "http://x/1").returncode, 0)
        shown = self.idea("show", id).stdout
        self.assertIn("state: promoted\n", shown)
        self.assertIn("issue: http://x/1\n", shown)
        self.assertEqual(self.idea("drop", id).returncode, 1)

    def test_drop(self):
        id = self.add()
        self.assertEqual(self.idea("drop", id).returncode, 0)
        self.assertIn("state: dropped", self.idea("show", id).stdout)
        self.assertEqual(self.idea("drop", id).returncode, 1)

    def test_errors(self):
        for args in (("show", "nope"), ("drop", "nope"), ("add", "  ")):
            proc = self.idea(*args)
            self.assertEqual(proc.returncode, 1, args)
            self.assertEqual(proc.stderr.count("\n"), 1, args)
        self.assertEqual(self.idea("add", "--source", "tv", "x").returncode, 1)

    def test_show_bad_file(self):
        self.inbox.mkdir()
        (self.inbox / "x.md").write_text("no colon here\n\ntext")
        proc = self.idea("show", "x")
        self.assertEqual(proc.returncode, 1)
        self.assertEqual(proc.stderr.count("\n"), 1)
        self.assertIn("x", proc.stderr)

    def test_list_skips_bad_files(self):
        id = self.add()
        (self.inbox / "x.md").write_text("no colon here\n\ntext")
        (self.inbox / "y.md").write_text("source: chat\n\nno state")
        proc = self.idea("list")
        self.assertEqual(proc.returncode, 0)
        self.assertEqual(proc.stdout, f"{id}  new  make it faster\n")
        self.assertEqual(proc.stderr, "2 unreadable\n")

    def test_no_temp_files_left(self):
        id = self.add()
        self.idea("drop", id)
        self.assertEqual(os.listdir(self.inbox), [f"{id}.md"])


if __name__ == "__main__":
    unittest.main()
