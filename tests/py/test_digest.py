"""bin/claude-digest against temp dirs and fake ghd/claude-worker/claude-usage only."""

import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-digest"

GHD = """#!/bin/sh
case "$*" in
*"issue view"*) cat "$FAKE_BODY" ;;
*) cat "$FAKE_ISSUES" ;;
esac
"""


def script(path, body):
    path.write_text("#!/bin/sh\n" + body)
    path.chmod(0o755)


class Digest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        repo = self.root / "repo"
        repo.mkdir()
        git = ["git", "-C", str(repo)]
        subprocess.run([*git, "init", "-q", "-b", "main"], check=True)
        subprocess.run(
            [*git, "-c", "user.name=t", "-c", "user.email=t@t"]
            + ["commit", "-q", "--allow-empty", "-m", "Add a thing"],
            check=True,
        )
        now = time.time()
        stamp = lambda t: time.strftime("%Y-%m-%dT%H:%M:%SZ", time.gmtime(t))
        issues = [
            {
                "number": 7,
                "title": "x" * 200,
                "state": "CLOSED",
                "createdAt": stamp(now - 9 * 86400),
                "closedAt": stamp(now - 3600),
            },
            {
                "number": 8,
                "title": "old",
                "state": "CLOSED",
                "createdAt": stamp(now - 9 * 86400),
                "closedAt": stamp(now - 8 * 86400),
            },
        ]
        (self.root / "issues.json").write_text(json.dumps(issues))
        (self.root / "body.json").write_text(
            json.dumps({"body": "- [ ] a\n- [x] b\n  - [ ] c", "url": "http://x/46"})
        )
        script(self.root / "ghd", GHD.split("\n", 1)[1])
        script(self.root / "worker", "echo remaining \\$5.00\n")
        script(self.root / "usage", "exit 1\n")
        pending = self.root / "ask/pending"
        pending.mkdir(parents=True)
        (pending / "q1.json").write_text(json.dumps({"id": "q1", "text": "Hi\nthere"}))
        (self.root / "mechanic").mkdir()
        (self.root / "mechanic/runs.jsonl").write_text(
            json.dumps({"ts": int(now), "findings": 2, "checks": {"disk": 2}}) + "\n"
        )
        self.env = {
            **os.environ,
            "CLAUDE_SERVICES_DIR": str(self.root),
            "DIGEST_DIR": str(self.root / "out"),
            "SCHEDULER_DIR": str(self.root / "sched"),
            "DIGEST_REPO": str(repo),
            "DIGEST_GHD": f"sh {self.root / 'ghd'}",
            "DIGEST_WORKER": f"sh {self.root / 'worker'}",
            "DIGEST_USAGE": f"sh {self.root / 'usage'}",
            "FAKE_BODY": str(self.root / "body.json"),
            "FAKE_ISSUES": str(self.root / "issues.json"),
        }

    def run_digest(self, *args, **env):
        return subprocess.run(
            ["python3", str(BIN), *args],
            check=False,
            env={**self.env, **env},
            capture_output=True,
            text=True,
        )

    def text(self, proc):
        return Path(proc.stdout.strip()).read_text()

    def test_sections_and_quoting(self):
        proc = self.run_digest()
        self.assertEqual(proc.returncode, 0, proc.stderr)
        text = self.text(proc)
        self.assertIn("> Add a thing", text)
        self.assertIn("## Issues closed", text)
        self.assertIn("#7 x", text)
        self.assertNotIn("#8 old", text)
        self.assertNotIn("## Issues opened", text)
        self.assertIn("- mechanic: 2 findings in its last run (disk 2)", text)
        self.assertIn("remaining $5.00", text)
        self.assertIn("> q1: Hi there", text)
        self.assertIn("2 unchecked: http://x/46", text)
        self.assertTrue(all(len(x) <= 122 for x in text.splitlines()))
        self.assertFalse((self.root / "out/runs.jsonl").exists())
        self.assertFalse((self.root / "sched/events").exists())

    def test_quotes_drop_control_characters(self):
        (self.root / "ask/pending/q2.json").write_text(
            json.dumps({"id": "q2", "text": "a\x1b[31mb\x07\x00c"})
        )
        text = self.text(self.run_digest())
        self.assertIn("> q2: a[31mbc", text)
        self.assertFalse(any(c in text for c in "\x1b\x07\x00"))

    def test_ghd_failure_is_one_line(self):
        proc = self.run_digest(DIGEST_GHD="false")
        text = self.text(proc)
        self.assertIn("issues: unavailable", text)
        self.assertIn("assumptions: unavailable", text)

    def test_empty_sections_are_left_out(self):
        (self.root / "ask/pending/q1.json").unlink()
        (self.root / "mechanic/runs.jsonl").unlink()
        text = self.text(self.run_digest("--since", "1h", DIGEST_WORKER="false"))
        self.assertNotIn("Questions", text)
        self.assertNotIn("Findings", text)
        self.assertNotIn("Spend", text)

    def test_notify_logs_and_alarms(self):
        proc = self.run_digest("--notify")
        path = proc.stdout.strip()
        row = json.loads((self.root / "out/runs.jsonl").read_text())
        self.assertEqual(row["findings"], 0)
        event = json.loads((self.root / "sched/events").read_text())
        self.assertEqual(event, {"alarm": "digest", "msg": f"digest: {path}"})

    def test_ideas_section(self):
        inbox = self.root / "intake/inbox"
        inbox.mkdir(parents=True)
        (inbox / "a-1.md").write_text("state: new\n\nfresh")
        (inbox / "b-2.md").write_text(
            "state: triaged\ndraft_title: "
            + "t" * 200
            + "\nlabel: kind:idle\npriority: 2\nduplicate_of: 9\n\nraw"
        )
        text = self.text(self.run_digest())
        self.assertIn("## Ideas\n\n1 new, 1 triaged\n", text)
        self.assertIn("> b-2: ttt", text)
        self.assertTrue(all(len(x) <= 122 for x in text.splitlines()))
        (inbox / "a-1.md").unlink()
        (inbox / "b-2.md").unlink()
        self.assertNotIn("## Ideas", self.text(self.run_digest()))

    def test_bad_since(self):
        proc = self.run_digest("--since", "soon")
        self.assertEqual(proc.returncode, 1)
        self.assertIn("--since", proc.stderr)


if __name__ == "__main__":
    unittest.main()
