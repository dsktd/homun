"""bin/claude-coach against temp dirs only."""

import json
import os
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-coach"


def schedules(days_old):
    created = time.strftime(
        "%Y-%m-%dT%H:%M:%S+00:00", time.gmtime(time.time() - days_old * 86400)
    )
    return (
        "[[name, cron, enabled, created]; "
        f'[mechanic, "0 8 * * *", true, "{created}"], '
        f'[auditor, "0 9 * * 1", false, "{created}"]]'
    )


class Coach(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.root = Path(tmp.name)
        roles = {
            "manager": {"status": "active"},
            "mechanic": {"status": "active"},
            "coach": {"status": "planned"},
        }
        (self.root / "roles.json").write_text(json.dumps(roles))
        (self.root / "sched").mkdir()
        self.schedule(20)
        self.entry("service", "a", "checked_by: mechanic\n")
        self.entry("service", "b", "purpose: x\n")
        self.auditor({})
        self.env = {
            **os.environ,
            "CLAUDE_SERVICES_DIR": str(self.root),
            "REGISTRY_DIR": str(self.root / "registry"),
            "CLAUDE_SCHED_DIR": str(self.root / "sched"),
            "MAINT_DB": str(self.root / "usage.sqlite"),
            "COACH_ROLES": str(self.root / "roles.json"),
        }

    def schedule(self, days_old):
        (self.root / "sched/schedules.nuon").write_text(schedules(days_old))

    def entry(self, kind, name, text):
        d = self.root / "registry" / kind / name
        d.mkdir(parents=True)
        (d / "info").write_text(text)

    def auditor(self, checks):
        """The Auditor's latest run, with these finding counts per check."""
        (self.root / "auditor").mkdir(exist_ok=True)
        row = {
            "ts": int(time.time()),
            "findings": sum(checks.values()),
            "checks": checks,
        }
        (self.root / "auditor/runs.jsonl").write_text(json.dumps(row) + "\n")

    def runs(self, role, findings):
        (self.root / role).mkdir(exist_ok=True)
        now = int(time.time())
        with open(self.root / role / "runs.jsonl", "w") as f:
            for i, n in enumerate(findings):
                ts = now - (len(findings) - i) * 3600
                f.write(json.dumps({"ts": ts, "findings": n, "checks": {}}) + "\n")

    def coach(self, *args):
        return subprocess.run(
            [str(BIN), *args],
            check=False,
            env=self.env,
            capture_output=True,
            text=True,
        )

    def observations(self):
        r = self.coach("--json")
        self.assertEqual(r.returncode, 0, r.stderr)
        return [json.loads(line) for line in r.stdout.splitlines()]

    def value(self, role, measure):
        found = [
            o["value"]
            for o in self.observations()
            if o["role"] == role and o["measure"] == measure
        ]
        return found[0] if found else "absent"

    def test_runs_findings_and_cadence(self):
        self.runs("mechanic", [0, 0, 2, 4])
        self.assertEqual(self.value("mechanic", "runs_30d"), 4)
        self.assertEqual(self.value("mechanic", "runs_expected"), 20)
        self.assertEqual(self.value("mechanic", "findings_per_run"), 1.5)
        self.assertIsNotNone(self.value("mechanic", "days_since_finding"))
        self.assertIsNone(self.value("mechanic", "time_to_resolve"))

    def test_role_without_history(self):
        self.assertIsNone(self.value("coach", "runs_30d"))
        self.assertEqual(self.value("coach", "findings_per_run"), "absent")

    def test_registry_checkers(self):
        self.assertEqual(self.value("mechanic", "registry_entries_checked"), 1)
        self.assertEqual(self.value("registry", "entries_without_checker"), 1)

    def test_cost_per_run(self):
        con = sqlite3.connect(self.root / "usage.sqlite")
        con.execute("create table agent_runs (session_id, name, started_at)")
        con.execute("create table message_costs (session_id, ts, cost_usd)")
        now = int(time.time())
        con.execute("insert into agent_runs values ('s1', 'mechanic', ?)", (now,))
        con.execute("insert into agent_runs values ('s2', 'mechanic', ?)", (now,))
        con.execute("insert into message_costs values ('s1', ?, 1.0)", (now,))
        con.execute("insert into message_costs values ('s2', ?, 3.0)", (now,))
        con.commit()
        con.close()
        self.assertEqual(self.value("mechanic", "cost_per_run"), 2.0)

    def test_refuses_cost_on_wrong_data(self):
        self.auditor({"panels": 1})
        self.assertEqual(self.value("auditor", "non_registry_findings"), 1)
        self.assertEqual(self.value("mechanic", "cost_per_run"), "absent")
        self.assertIn("Not judging cost", self.coach().stdout)

    def test_registry_findings_do_not_block(self):
        self.auditor({"registry": 3})
        self.assertEqual(self.value("auditor", "non_registry_findings"), "absent")

    def test_suggestions_cite_numbers(self):
        self.runs("mechanic", [0] * 6)
        out = self.coach().stdout
        self.assertIn("mechanic ran 6 times against 20 expected", out)
        self.assertIn("mechanic found nothing in 6 runs", out)
        self.assertIn("1 registry entries have no checker", out)

    def test_new_schedule_is_not_blamed(self):
        self.schedule(1)
        self.runs("mechanic", [1])
        self.assertEqual(self.value("mechanic", "runs_expected"), 1)
        self.assertNotIn("expected", self.coach().stdout.split("Suggested")[1])

    def test_run_is_recorded_and_trimmed(self):
        self.runs("mechanic", [0] * 6)
        self.coach()
        log = self.root / "coach/runs.jsonl"
        row = json.loads(log.read_text().splitlines()[-1])
        self.assertEqual(row["findings"], 3)
        self.assertEqual(row["checks"], {})
        log.write_text('{"ts": 1, "findings": 0, "checks": {}}\n' * 30000)
        self.coach()
        self.assertEqual(len(log.read_text().splitlines()), 2000)

    def test_missing_registry_fails_cleanly(self):
        self.env["REGISTRY_DIR"] = str(self.root / "nope")
        r = self.coach()
        self.assertEqual(r.returncode, 1)
        self.assertIn("registry", r.stderr)


if __name__ == "__main__":
    unittest.main()
