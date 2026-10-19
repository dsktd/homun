"""The mode_history, agent_runs and events writes of the usage-db service."""

import json
import os
import shutil
import sqlite3
import subprocess
import sys
import tempfile
import unittest
from pathlib import Path

USAGE_DB = Path(__file__).resolve().parents[2] / "container/services/usage-db"
sys.path.insert(0, str(USAGE_DB))
import forecast

HOUR = 3600


class RecordMode(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.db = str(Path(tmp.name) / "usage.sqlite")

    def record(self, now, mode="normal", slots=2):
        forecast.record_mode(
            self.db, now, mode, "normal", False, slots, "r", 10, 20, 60
        )

    def rows(self):
        con = sqlite3.connect(self.db)
        self.addCleanup(con.close)
        return con.execute("select ts, mode, slots from mode_history").fetchall()

    def test_first_call_creates_the_table_and_a_row(self):
        self.record(1000)
        self.assertEqual(self.rows(), [(1000, "normal", 2)])

    def test_unchanged_state_is_not_repeated_within_the_hour(self):
        self.record(1000)
        self.record(1000 + HOUR - 1)
        self.assertEqual(len(self.rows()), 1)

    def test_heartbeat_after_an_hour(self):
        self.record(1000)
        self.record(1000 + HOUR)
        self.assertEqual(len(self.rows()), 2)

    def test_a_change_is_recorded_at_once(self):
        self.record(1000)
        self.record(1010, mode="frugal", slots=1)
        self.assertEqual(self.rows(), [(1000, "normal", 2), (1010, "frugal", 1)])


@unittest.skipUnless(shutil.which("nu"), "nu not available")
class ImportAgents(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        self.db = self.dir / "usage.sqlite"
        (self.dir / "usage.jsonl").write_text("")
        (self.dir / "projects").mkdir()
        self.agents = self.dir / "agents.json"

    def run_import(self, runs):
        self.agents.write_text(runs if isinstance(runs, str) else json.dumps(runs))
        done = subprocess.run(
            [
                "nu",
                str(USAGE_DB / "import.nu"),
                str(self.dir / "usage.jsonl"),
                str(self.db),
                "--projects",
                str(self.dir / "projects"),
            ],
            capture_output=True,
            text=True,
            check=False,
            env={**os.environ, "USAGE_AGENTS_JSON": str(self.agents)},
        )
        self.assertEqual(done.returncode, 0, done.stderr)

    def query(self, sql):
        con = sqlite3.connect(self.db)
        self.addCleanup(con.close)
        return con.execute(sql).fetchall()

    @staticmethod
    def run_of(sid, state):
        return {
            "sessionId": sid,
            "name": "w",
            "kind": "background",
            "cwd": "/x",
            "startedAt": 1_700_000_000_000,
            "state": state,
            "pid": 7,
        }

    def test_first_import_only_backfills(self):
        self.run_import([self.run_of("a", "done")])
        self.assertEqual(
            self.query("select session_id, state, started_at from agent_runs"),
            [("a", "done", 1_700_000_000)],
        )
        self.assertEqual(self.query("select * from events"), [])

    def test_new_run_and_state_changes_become_events(self):
        self.run_import([self.run_of("a", "done")])
        self.run_import([self.run_of("a", "done"), self.run_of("b", "working")])
        self.run_import([self.run_of("a", "done"), self.run_of("b", "failed")])
        self.assertEqual(
            self.query("select source, kind, session_id from events order by rowid"),
            [("agents", "started", "b"), ("agents", "failed", "b")],
        )
        self.assertEqual(
            self.query("select state from agent_runs where session_id = 'b'"),
            [("failed",)],
        )

    def test_unavailable_agents_leave_the_tables_alone(self):
        self.run_import([self.run_of("a", "done")])
        self.run_import("not json")
        self.assertEqual(self.query("select count(*) from agent_runs"), [(1,)])


if __name__ == "__main__":
    unittest.main()
