"""bin/claude-mechanic-request against a temp mechanic dir only."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-mechanic-request"

RECORD = {
    "woke_at": 1700000000,
    "trigger": "manager",
    "broken": "proxy-caddyfile",
    "detail": "Caddyfile had no auth block",
    "commits": ["abc1234", "0" * 40],
    "restart_requested": False,
    "outcome": "fixed",
    "repaired_at": 1700000300,
    "report": "/home/x/claude/.services/mechanic/reports/1.md",
}


class MechanicRequest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name) / "mechanic"

    def run_bin(self, *args, stdin=None, role=None):
        env = {
            **os.environ,
            "MECHANIC_DIR": str(self.dir),
            "IDENTITIES_DIR": str(self.dir),
        }
        env.pop("CLAUDE_ROLE", None)
        if role:
            env["CLAUDE_ROLE"] = role
        return subprocess.run(
            ["python3", str(BIN), *args],
            check=False,
            input=stdin,
            env=env,
            capture_output=True,
            text=True,
        )

    def ok(self, *args, **kw):
        proc = self.run_bin(*args, **kw)
        self.assertEqual(proc.returncode, 0, proc.stderr)
        return proc.stdout.strip()

    def refused(self, *args, code=1, **kw):
        proc = self.run_bin(*args, **kw)
        self.assertEqual(proc.returncode, code, proc.stdout)
        self.assertTrue(proc.stderr.strip())
        return proc.stderr

    def lines(self, name):
        return [json.loads(x) for x in (self.dir / name).read_text().splitlines()]

    def test_repair_appends_a_request_line(self):
        self.ok("look at the proxy")
        self.ok("repair", "again", role="cal")
        rows = self.lines("requests")
        self.assertEqual(
            [(r["from"], r["alarm"], r["msg"]) for r in rows],
            [("manager", "repair", "look at the proxy"), ("cal", "repair", "again")],
        )
        self.assertIsInstance(rows[0]["ts"], int)
        self.assertEqual(oct(self.dir.stat().st_mode)[-3:], "700")

    def test_repair_refuses_bad_messages(self):
        self.assertIn("empty", self.refused("  "))
        self.assertIn("over 500", self.refused("x" * 501))
        self.assertIn("control", self.refused("two\nlines"))
        self.assertIn("control", self.refused("\x1b[31mred"))
        self.assertFalse((self.dir / "requests").exists())
        self.ok("x" * 500)

    def test_restart_writes_the_request_file_atomically(self):
        self.ok("restart", "manager heartbeat stale 12 min")
        path = self.dir / "restart-request"
        row = json.loads(path.read_text())
        self.assertEqual(
            (row["reason"], row["by"], row["force"]),
            ("manager heartbeat stale 12 min", "mechanic", False),
        )
        self.assertEqual(oct(path.stat().st_mode)[-3:], "600")
        self.assertFalse((self.dir / "restart-request.tmp").exists())
        self.ok("restart", "again", "force")
        self.assertTrue(json.loads(path.read_text())["force"])

    def test_retry_and_rollback_write_the_role_request(self):
        self.ok("rollback", "manager", "two retries failed the gate")
        path = self.dir / "role-request"
        row = json.loads(path.read_text())
        self.assertEqual(
            (row["action"], row["role"], row["by"]), ("rollback", "manager", "mechanic")
        )
        self.assertEqual(oct(path.stat().st_mode)[-3:], "600")
        self.ok("retry", "editor", "fixed the service script")
        self.assertEqual(json.loads(path.read_text())["action"], "retry")
        self.assertIn("role name", self.refused("retry", "../x", "r"))
        self.assertIn("empty", self.refused("retry", "manager", ""))
        self.refused("retry", "manager", code=2)

    def test_restart_refuses_bad_reasons_and_words(self):
        self.assertIn("over 200", self.refused("restart", "r" * 201))
        self.assertIn("empty", self.refused("restart", ""))
        self.refused("restart", "r", "please", code=2)
        self.assertFalse((self.dir / "restart-request").exists())

    def test_record_validates_and_appends(self):
        id = self.ok("record", json.dumps(RECORD))
        self.assertRegex(id, r"^20231114T221320Z-[0-9a-f]{4}$")
        self.ok("record", "-", stdin=json.dumps(RECORD))
        rows = self.lines("repairs.jsonl")
        self.assertEqual(rows[0]["id"], id)
        self.assertEqual(
            list(rows[0]),
            ["id", *RECORD, "reverted"],
        )
        self.assertIsNone(rows[0]["reverted"])
        self.assertEqual(rows[1]["commits"], RECORD["commits"])

    def test_record_refuses_bad_fields(self):
        def bad(**changes):
            data = {**RECORD, **changes}
            for k, v in changes.items():
                if v is ...:
                    del data[k]
            return self.refused("record", json.dumps(data))

        self.assertIn("missing: report", bad(report=...))
        self.assertIn("unknown record keys: extra", bad(extra=1))
        self.assertIn("trigger", bad(trigger="mechanic"))
        self.assertIn("outcome", bad(outcome="done"))
        self.assertIn("broken", bad(broken="Proxy Caddyfile"))
        self.assertIn("commits", bad(commits=["not-a-sha"]))
        self.assertIn("commits", bad(commits="abc1234"))
        self.assertIn("restart_requested", bad(restart_requested="no"))
        self.assertIn("woke_at", bad(woke_at="1700000000"))
        self.assertIn("before woke_at", bad(repaired_at=1))
        self.assertIn("detail", bad(detail="a\nb"))
        self.assertIn("not JSON", self.refused("record", "{"))
        self.assertIn("object", self.refused("record", "[1]"))
        self.assertFalse((self.dir / "repairs.jsonl").exists())

    def test_mark_sets_reverted_once(self):
        rid = self.ok("record", json.dumps(RECORD))
        self.ok("mark", rid, "1700001000")
        self.ok("mark", rid, "1700002000")
        row = json.loads((self.dir / "repairs.jsonl").read_text())
        self.assertEqual(row["reverted"], 1700001000)
        self.refused("mark", "nope", "1700001000")

    def test_repair_from_cal_is_refused(self):
        self.refused("repair", "from", "cal", "look at the proxy")
        self.assertFalse((self.dir / "requests").exists())

    def test_cal_writes_one_file_in_the_inbox(self):
        self.ok("cal", "hi mechanic")
        self.ok("cal", "-", stdin="again\n")
        files = sorted((self.dir / "cal-inbox").iterdir())
        self.assertEqual(len(files), 2)
        self.assertEqual(
            [json.loads(f.read_text())["msg"] for f in files], ["hi mechanic", "again"]
        )
        self.assertFalse((self.dir / "requests").exists())

    def test_who_follows_the_heartbeat(self):
        self.dir.mkdir()
        out = self.run_bin("who")
        self.assertEqual(out.returncode, 1)
        self.assertFalse(json.loads(out.stdout)["online"])
        (self.dir / "heartbeat").write_text("")
        got = json.loads(self.ok("who"))
        self.assertEqual((got["online"], got["name"]), (True, "Mechanic"))
        os.utime(self.dir / "heartbeat", (1, 1))
        got = json.loads(self.run_bin("who").stdout)
        self.assertIn("offline", got["reason"])

    def test_usage(self):
        self.refused(code=2)
        self.refused("record", code=2)
        self.refused("repair", "a", "b", code=2)
