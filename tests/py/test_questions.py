# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[2] / "container" / "claude-question"


class QuestionsTest(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.root = Path(self.tmp.name) / "ask"
        self.events = Path(self.tmp.name) / "events"
        self.env = dict(
            os.environ,
            CLAUDE_QUESTIONS_DIR=str(self.root),
            CLAUDE_EVENTS=str(self.events),
        )

    def run_tool(self, *args):
        return subprocess.run(
            [sys.executable, str(TOOL), *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )

    def add(self, *args):
        result = self.run_tool("add", *args)
        self.assertEqual(result.returncode, 0, result.stderr)
        return result.stdout.strip()

    def test_add_list_show(self):
        qid = self.add(
            "Which?",
            "--option",
            "a",
            "--option",
            "b",
            "--blocks",
            "#21",
            "--asker",
            "manager",
        )
        self.assertTrue((self.root / "pending" / f"{qid}.json").exists())
        self.assertIn(f"{qid}\tWhich?", self.run_tool("list").stdout)
        shown = json.loads(self.run_tool("show", qid).stdout)
        self.assertEqual(
            (shown["options"], shown["blocks"], shown["asker"]),
            (["a", "b"], "#21", "manager"),
        )

    def test_answer_moves_and_writes_event(self):
        qid = self.add("Which?", "--option", "a", "--option", "b")
        before = int(time.time())
        self.assertEqual(self.run_tool("answer", qid, "--choice", "b").returncode, 0)
        self.assertFalse((self.root / "pending" / f"{qid}.json").exists())
        done = json.loads((self.root / "answered" / f"{qid}.json").read_text())
        self.assertEqual(done["answer"]["choices"], ["b"])
        self.assertEqual(list(self.root.glob("*/.*.tmp")), [])
        lines = self.events.read_text().splitlines()
        self.assertEqual(len(lines), 1)
        event = json.loads(lines[0])
        self.assertEqual(set(event), {"ts", "alarm", "msg", "bus"})
        self.assertGreaterEqual(event["ts"], before)
        self.assertEqual(
            (event["alarm"], event["msg"]), ("answered", f"answered: {qid}")
        )

    def test_invalid_choice(self):
        qid = self.add("Which?", "--option", "a")
        result = self.run_tool("answer", qid, "--choice", "z")
        self.assertEqual(result.returncode, 1)
        self.assertEqual(len(result.stderr.splitlines()), 1)
        self.assertTrue((self.root / "pending" / f"{qid}.json").exists())
        self.assertFalse(self.events.exists())

    def test_free_text_only(self):
        qid = self.add("Why?", "--free-text")
        self.assertEqual(
            self.run_tool("answer", qid, "--text", "because").returncode, 0
        )
        done = json.loads((self.root / "answered" / f"{qid}.json").read_text())
        self.assertEqual(done["answer"], {"choices": [], "text": "because"})
        self.assertNotIn("because", self.events.read_text())

    def test_expired(self):
        qid = self.add("Late?", "--expires", str(time.time() - 10))
        result = self.run_tool("answer", qid, "--text", "x")
        self.assertEqual(result.returncode, 1)
        self.assertIn("expired", result.stderr)

    def test_already_answered_and_unknown(self):
        qid = self.add("Once?")
        self.run_tool("answer", qid, "--text", "x")
        again = self.run_tool("answer", qid, "--text", "y")
        self.assertEqual(again.returncode, 1)
        self.assertIn("already answered", again.stderr)
        self.assertEqual(self.run_tool("answer", "nope").returncode, 1)
        self.assertEqual(len(self.events.read_text().splitlines()), 1)


if __name__ == "__main__":
    unittest.main()
