"""bin/claude-mechanic: each check red and green against temp dirs."""

import json
import os
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-mechanic"


class Mechanic(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.svc = Path(self.tmp.name)
        self.env = {
            **os.environ,
            "CLAUDE_SERVICES_DIR": str(self.svc),
            "MECHANIC_SERVICES_CMD": "",
            "MECHANIC_STATUS_URL": "",
            "MECHANIC_ROOT": self.tmp.name,
            "MECHANIC_UPTIME": "999999",
        }
        (self.svc / "maint").mkdir()
        (self.svc / "maint/hygiene.jsonl").write_text("")
        (self.svc / "usage-db").mkdir()
        self.sample(time.time())

    def sample(self, ts):
        con = sqlite3.connect(self.svc / "usage-db/usage.sqlite")
        con.execute("create table if not exists samples (ts integer)")
        con.execute("delete from samples")
        con.execute("insert into samples values (?)", (int(ts),))
        con.commit()
        con.close()

    def run_m(self, *args, **env):
        r = subprocess.run(
            [str(BIN), *args],
            env={**self.env, **env},
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(r.returncode, 0)
        return r.stdout.splitlines()

    def service(self, name, **flags):
        d = self.svc / name
        d.mkdir()
        (d / "run").write_text("#!/bin/sh\n")
        (d / "run").chmod(0o755)
        for f in flags:
            (d / f).write_text(f"{os.getpid()}\n")

    def test_green(self):
        self.service("up", pid=1)
        self.service("off", disabled=1)
        self.assertEqual(self.run_m(), [])

    def test_services_red(self):
        self.service("down")
        self.assertEqual(self.run_m(), ["services: not running: down"])

    def status_page(self, **states):
        page = self.svc / "status.json"
        page.write_text(
            json.dumps(
                {"services": [{"name": n, "state": s} for n, s in states.items()]}
            )
        )
        return {"MECHANIC_STATUS_URL": page.as_uri()}

    def test_status_page(self):
        self.service("up", pid=1)
        self.assertEqual(self.run_m(**self.status_page(up="running")), [])
        self.assertEqual(
            self.run_m(**self.status_page(up="stopped")),
            ["status: page disagrees about: up"],
        )
        self.assertEqual(
            self.run_m(MECHANIC_STATUS_URL=(self.svc / "none").as_uri()),
            ["status: page unreadable"],
        )

    def test_logs(self):
        (self.svc / "up").mkdir()
        (self.svc / "up/log").write_bytes(b"x" * 9 * 1024 * 1024)
        self.assertEqual(self.run_m(), ["logs: up/log is 9 MB (over 8)"])

    def test_registered_logs(self):
        info = self.svc / "registry/log/big"
        info.mkdir(parents=True)
        (info / "info").write_text(f"kind: log\npath: {self.svc}/big.jsonl\n")
        (self.svc / "big.jsonl").write_bytes(b"x" * 9 * 1024 * 1024)
        self.assertEqual(self.run_m(), ["logs: big.jsonl is 9 MB (over 8)"])

    def schedules(self, enabled, last_fire):
        d = self.svc / "sched"
        d.mkdir(exist_ok=True)
        (d / "schedules.nuon").write_text(
            f"[[name, cron, prompt, enabled]; [nightly, '0 * * * *', 'p', {enabled}]]"
        )
        (self.svc / "scheduler").mkdir(exist_ok=True)
        rows = [{"ts": last_fire, "name": "nightly"}] if last_fire else []
        (self.svc / "scheduler/history.jsonl").write_text(
            "".join(json.dumps(r) + "\n" for r in rows)
        )

    def test_schedules(self):
        self.schedules("true", int(time.time()) - 3600)
        self.assertEqual(self.run_m(), [])
        self.schedules("true", int(time.time()) - 3 * 3600)
        out = self.run_m()
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith("schedules: nightly has not fired since "))

    def test_schedules_disabled_ignored(self):
        self.schedules("false", int(time.time()) - 3 * 3600)
        self.assertEqual(self.run_m(), [])

    def test_schedule_never_fired_counts_from_the_table(self):
        self.schedules("true", None)
        self.assertEqual(self.run_m(), [])

    def test_usage_lag(self):
        self.sample(time.time() - 3600)
        self.assertIn("usage-db", self.run_m()[0])
        self.assertEqual(self.run_m(MECHANIC_UPTIME="60"), [])

    def test_maint_missing_and_old(self):
        h = self.svc / "maint/hygiene.jsonl"
        h.unlink()
        self.assertEqual(self.run_m(), ["maint: hygiene.jsonl is missing"])
        h.write_text("")
        old = time.time() - 40 * 3600
        os.utime(h, (old, old))
        self.assertEqual(self.run_m(), ["maint: hygiene.jsonl is older than 36 h"])

    def test_maint_stale_worktrees(self):
        wt = self.svc / "wt"
        wt.mkdir()
        old = time.time() - 8 * 86400
        os.utime(wt, (old, old))
        row = {"worktrees": [{"path": str(wt), "dirty": True}]}
        (self.svc / "maint/hygiene.jsonl").write_text(json.dumps(row) + "\n")
        self.assertEqual(
            self.run_m(), ["maint: 1 dirty or merged worktrees older than 7 days"]
        )

    def test_disk(self):
        self.assertEqual(self.run_m(), [])
        free = os.statvfs(self.tmp.name)
        if free.f_bavail / free.f_blocks >= 0.10:
            return
        self.assertIn("disk", self.run_m()[0])

    def test_events(self):
        (self.svc / "scheduler").mkdir()
        ev = self.svc / "scheduler/events"
        ev.write_bytes(b"x" * 6 * 1024 * 1024)
        self.assertEqual(
            self.run_m(), ["events: scheduler events file is 6 MB (over 5)"]
        )

    def test_json_and_notify(self):
        self.service("down")
        out = self.run_m("--json", "--notify")
        self.assertEqual(
            json.loads(out[0]), {"check": "services", "msg": "not running: down"}
        )
        line = (self.svc / "scheduler/events").read_text().splitlines()
        self.assertEqual(
            json.loads(line[0]),
            {
                "alarm": "mechanic",
                "msg": "mechanic: 1 findings; run bin/claude-mechanic",
            },
        )

    def test_no_notify_when_green(self):
        self.run_m("--notify")
        self.assertFalse((self.svc / "scheduler/events").exists())

    def test_runs_history(self):
        runs = self.svc / "mechanic/runs.jsonl"
        self.run_m()
        self.service("down")
        self.run_m()
        rows = [json.loads(x) for x in runs.read_text().splitlines()]
        self.assertEqual(
            [(r["findings"], r["checks"]) for r in rows],
            [(0, {}), (1, {"services": 1})],
        )
        self.assertIsInstance(rows[0]["ts"], int)

    def test_runs_history_capped(self):
        runs = self.svc / "mechanic/runs.jsonl"
        runs.parent.mkdir()
        runs.write_text('{"x": 1}\n' * 200000)
        self.run_m()
        lines = runs.read_text().splitlines()
        self.assertEqual(len(lines), 2000)
        self.assertEqual(json.loads(lines[-1])["findings"], 0)


if __name__ == "__main__":
    unittest.main()
