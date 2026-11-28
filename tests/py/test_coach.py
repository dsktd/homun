"""bin/claude-coach against temp dirs only."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import importlib.machinery
import importlib.util
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
            "mechanic": {"status": "active", "model": "Opus"},
            "digest": {"status": "active", "model": "None for the report: a script"},
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
            "MECHANIC_DIR": str(self.root / "mechanic"),
            "COACH_REPO": str(self.root / "repo"),
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
            "source": "cron",
        }
        (self.root / "auditor/runs.jsonl").write_text(json.dumps(row) + "\n")

    def runs(self, role, findings, first_days_ago=0):
        """Hourly rows ending now; the first one `first_days_ago` days back when given."""
        (self.root / role).mkdir(exist_ok=True)
        now = int(time.time())
        with open(self.root / role / "runs.jsonl", "w") as f:
            for i, n in enumerate(findings):
                ts = now - (len(findings) - i) * 3600
                if first_days_ago and i == 0:
                    ts = now - first_days_ago * 86400
                row = {"ts": ts, "findings": n, "checks": {}, "source": "cron"}
                f.write(json.dumps(row) + "\n")

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
        self.runs("mechanic", [0, 0, 2, 4], first_days_ago=19)
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

    def test_registry_stray_files_and_comments(self):
        (self.root / "registry/README").write_text("notes")
        (self.root / "registry/service/README").write_text("notes")
        self.entry("service", "c", "# checked_by: mechanic\nchecked_by: mechanic\n")
        self.assertEqual(self.value("mechanic", "registry_entries_checked"), 2)

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

    def test_modelless_role_costs_nothing(self):
        self.assertEqual(self.value("digest", "cost_per_run"), 0)
        self.assertIsNone(self.value("mechanic", "cost_per_run"))

    def test_refuses_cost_on_wrong_data(self):
        self.auditor({"panels": 1})
        self.assertEqual(self.value("auditor", "non_registry_findings"), 1)
        self.assertEqual(self.value("mechanic", "cost_per_run"), "absent")
        self.assertIn("Not judging cost", self.coach().stdout)

    def test_registry_findings_do_not_block(self):
        self.auditor({"registry": 3})
        self.assertEqual(self.value("auditor", "non_registry_findings"), "absent")

    def test_suggestions_cite_numbers(self):
        self.runs("mechanic", [0] * 6, first_days_ago=19)
        out = self.coach().stdout
        self.assertIn("mechanic ran 6 times against 20 expected", out)
        self.assertNotIn("found nothing", out)
        self.assertIn("1 registry entries have no checker", out)

    def test_expected_runs_only_for_simple_crons(self):
        loader = importlib.machinery.SourceFileLoader("coach", str(BIN))
        coach = importlib.util.module_from_spec(
            importlib.util.spec_from_loader("coach", loader)
        )
        loader.exec_module(coach)
        self.assertEqual(coach.expected_runs("0 8 * * *", 20), 20)
        self.assertEqual(coach.expected_runs("0 9 * * 1,3", 21), 6)
        self.assertEqual(coach.expected_runs("0 10 1 * *", 60), 2)
        for cron in ("0 * * * *", "*/5 8 * * *", "0 9 * * 1-5", "0 8 1 * 1", "0 8 *"):
            self.assertIsNone(coach.expected_runs(cron, 20), cron)

    def test_malformed_created_falls_back_to_the_first_run(self):
        (self.root / "sched/schedules.nuon").write_text(
            '[[name, cron, enabled, created]; [mechanic, "0 8 * * *", true, "garbage"]]'
        )
        self.runs("mechanic", [0, 0])
        self.assertEqual(self.value("mechanic", "runs_30d"), 2)

    def test_new_schedule_is_not_blamed(self):
        self.schedule(1)
        self.runs("mechanic", [1])
        self.assertEqual(self.value("mechanic", "runs_expected"), 1)
        self.assertNotIn("expected", self.coach().stdout.split("Suggested")[1])

    def test_non_cron_runs_not_counted(self):
        self.runs("mechanic", [0] * 6)
        log = self.root / "mechanic/runs.jsonl"
        rows = [json.loads(x) for x in log.read_text().splitlines()]
        for row in rows[:2]:
            row["source"] = "test"
        for row in rows[2:3]:
            del row["source"]
        log.write_text("".join(json.dumps(x) + "\n" for x in rows))
        out = [json.loads(x) for x in self.coach("--json").stdout.splitlines()]
        got = [
            o["value"]
            for o in out
            if o["role"] == "mechanic" and o["measure"] == "runs_30d"
        ]
        self.assertEqual(got, [3])

    def test_run_is_recorded_and_trimmed(self):
        self.runs("mechanic", [0] * 6, first_days_ago=19)
        log = self.root / "coach/runs.jsonl"
        self.coach()
        self.assertFalse(log.exists())
        self.coach("--notify")
        row = json.loads(log.read_text().splitlines()[-1])
        self.assertEqual(row["findings"], 2)
        self.assertEqual(row["checks"], {})
        self.assertEqual(row["source"], "manual")
        self.coach("--notify", "--source", "cron")
        row = json.loads(log.read_text().splitlines()[-1])
        self.assertEqual(row["source"], "cron")
        log.write_text('{"ts": 1, "findings": 0, "checks": {}}\n' * 30000)
        self.coach("--notify")
        self.assertEqual(len(log.read_text().splitlines()), 2000)

    def test_missing_registry_fails_cleanly(self):
        self.env["REGISTRY_DIR"] = str(self.root / "nope")
        r = self.coach()
        self.assertEqual(r.returncode, 1)
        self.assertIn("registry", r.stderr)


class Repairs(Coach):
    def setUp(self):
        super().setUp()
        git = ["git", "-C", str(self.root / "repo")]
        subprocess.run(
            ["git", "init", "-q", "-b", "main", str(self.root / "repo")], check=True
        )
        subprocess.run(
            [
                *git,
                "-c",
                "user.name=t",
                "-c",
                "user.email=t@t",
                "commit",
                "-q",
                "--allow-empty",
                "-m",
                "x",
            ],
            check=True,
        )
        self.sha = subprocess.run(
            [*git, "rev-parse", "HEAD"], capture_output=True, text=True, check=True
        ).stdout.strip()
        self.now = int(time.time())

    def repairs(self, *rows):
        d = self.root / "mechanic"
        d.mkdir()
        with open(d / "repairs.jsonl", "w") as f:
            for i, r in enumerate(rows):
                base = {
                    "id": f"r{i}",
                    "trigger": "manager",
                    "broken": "a",
                    "commits": [self.sha],
                    "restart_requested": False,
                    "outcome": "fixed",
                    "reverted": None,
                }
                f.write(json.dumps({**base, **r}) + "\n")

    def test_no_file_no_measures(self):
        self.assertEqual(self.value("mechanic", "repairs_30d"), "absent")

    def test_measures(self):
        n = self.now - 3600
        self.repairs(
            {"woke_at": n, "repaired_at": n + 100},
            {
                "woke_at": n + 1000,
                "repaired_at": n + 1500,
                "broken": "b",
                "restart_requested": True,
                "outcome": "partial",
            },
            {
                "woke_at": n + 2000,
                "repaired_at": n + 2300,
                "trigger": "cal",
                "broken": "b",
            },
        )
        self.assertEqual(self.value("mechanic", "repairs_30d"), 3)
        self.assertEqual(self.value("mechanic", "repairs_time_manager_s"), 300)
        self.assertEqual(self.value("mechanic", "repairs_time_cal_s"), 300)
        self.assertEqual(self.value("mechanic", "repairs_repeat_breakages"), 1)
        self.assertEqual(self.value("mechanic", "repairs_restarts_requested"), 1)
        self.assertEqual(self.value("mechanic", "repairs_reverted_share"), 0.33)
        self.assertIsNone(self.value("mechanic", "repairs_cost_per_repair"))

    def test_cost_per_repair(self):
        n = self.now - 3600
        self.repairs({"woke_at": n, "repaired_at": n + 100})
        con = sqlite3.connect(self.root / "usage.sqlite")
        con.execute("create table agent_runs (session_id, name, started_at)")
        con.execute("create table message_costs (session_id, ts, cost_usd)")
        con.execute("insert into agent_runs values ('s1', 'mechanic', ?)", (n,))
        con.execute("insert into message_costs values ('s1', ?, 1.5)", (n + 50,))
        con.execute("insert into message_costs values ('s1', ?, 9.0)", (n + 500,))
        con.commit()
        con.close()
        self.assertEqual(self.value("mechanic", "repairs_cost_per_repair"), 1.5)

    def test_notify_marks_reverted_once(self):
        n = self.now - 3600
        self.repairs(
            {"woke_at": n, "repaired_at": n + 100},
            {
                "woke_at": n + 1000,
                "repaired_at": n + 1100,
                "commits": ["0" * 40],
                "broken": "c",
            },
            {"woke_at": n + 2000, "repaired_at": n + 2100},
        )
        self.assertEqual(self.coach("--notify", "--source", "test").returncode, 0)
        rows = [
            json.loads(x)
            for x in (self.root / "mechanic/repairs.jsonl").read_text().splitlines()
        ]
        self.assertEqual(rows[0]["reverted"], n + 2000)
        self.assertGreater(rows[1]["reverted"], n)
        self.assertIsNone(rows[2]["reverted"])
        self.coach("--notify", "--source", "test")
        again = [
            json.loads(x)
            for x in (self.root / "mechanic/repairs.jsonl").read_text().splitlines()
        ]
        self.assertEqual(rows, again)


if __name__ == "__main__":
    unittest.main()
