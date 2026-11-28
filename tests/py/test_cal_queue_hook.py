# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

HOOK = Path(__file__).resolve().parents[2] / "container" / "cal-queue-hook.sh"


class CalQueueHook(unittest.TestCase):
    def setUp(self):
        self._tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self._tmp.cleanup)
        self.dir = Path(self._tmp.name)
        (self.dir / "queue").mkdir()
        self.sess = self.dir / "session"
        self.sess.write_text("main-id\n")

    def put(self, name, text):
        (self.dir / "queue" / name).write_text(text)

    def run_hook(self, sid="main-id", **extra):
        env = dict(
            os.environ,
            CAL_CHANNEL_DIR=str(self.dir),
            MANAGER_SESSION_FILE=str(self.sess),
        )
        r = subprocess.run(
            ["sh", str(HOOK)],
            check=False,
            input=json.dumps({"session_id": sid, **extra}),
            capture_output=True,
            text=True,
            env=env,
        )
        self.assertEqual(r.returncode, 0)
        return r.stdout

    def test_empty_queue_no_output(self):
        self.assertEqual(self.run_hook(), "")

    def test_other_session_untouched(self):
        self.put("1700000000111", "hi")
        self.assertEqual(self.run_hook("other"), "")
        self.assertTrue((self.dir / "queue" / "1700000000111").exists())

    def test_subagent_untouched(self):
        self.put("1700000000111", "hi")
        self.assertEqual(self.run_hook(agent_id="a1"), "")
        self.assertTrue((self.dir / "queue" / "1700000000111").exists())

    def test_paused_delivers_nothing(self):
        self.put("1700000000111", "hi")
        (self.dir / "queue" / "paused").write_text("")
        self.assertEqual(self.run_hook(), "")
        self.assertTrue((self.dir / "queue" / "1700000000111").exists())

    def test_stale_pause_ignored_and_logged(self):
        self.put("1700000000111", "hi")
        paused = self.dir / "queue" / "paused"
        paused.write_text("")
        old = os.stat(paused).st_mtime - 3600
        os.utime(paused, (old, old))
        self.assertIn("hi", self.run_hook())
        self.assertFalse(paused.exists())
        self.assertIn("stale pause", (self.dir / "log.jsonl").read_text())

    def test_claims_and_shapes_json(self):
        self.put("1700000000111", 'one "q"\nline2')
        self.put("1700000000222", "two")
        out = json.loads(self.run_hook())["hookSpecificOutput"]
        self.assertEqual(out["hookEventName"], "PostToolUse")
        self.assertEqual(
            out["additionalContext"],
            '<channel source="cal" ts="1700000000">one "q"\nline2</channel>\n'
            '<channel source="cal" ts="1700000000">two</channel>\n',
        )
        self.assertEqual(list((self.dir / "queue").glob("[0-9]*")), [])
        self.assertEqual(list((self.dir / "queue" / "claimed").iterdir()), [])
        log = (self.dir / "log.jsonl").read_text().splitlines()
        self.assertEqual(len(log), 2)
        self.assertEqual(json.loads(log[0])["first"], 'one "q"')
        self.assertEqual(self.run_hook(), "")


if __name__ == "__main__":
    unittest.main()
