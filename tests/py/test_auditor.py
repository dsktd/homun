"""bin/claude-auditor: each check red and green against a temp database and dashboards."""

import json
import os
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-auditor"

SCHEMA = """
create table samples (ts integer not null, session_id text, five_hour_used real,
  cost_usd real);
create table messages (id text primary key, uuid text, ts integer not null,
  agent_id text, model text, input_tokens integer, output_tokens integer,
  cache_creation_input_tokens integer, cache_read_input_tokens integer);
create table mode_history (ts integer primary key);
create table maint_runs (ts integer, repo text, task text);
create table events (ts integer);
create table agent_runs (session_id text primary key, last_seen integer);
create table meta (key text primary key, value integer);
create table prices (family text);
create table transcripts (path text primary key);
create view cost_per_day as select date(ts, 'unixepoch') day, 0.0 cost_usd from samples;
create view budget_deltas as select ts, 0.0 delta from samples;
create view message_costs as select *, output_tokens / 1000.0 cost_usd from messages;
"""
COST = (
    "select cast(strftime('%s', date(ts,'unixepoch')) as integer) as time, model, "
    "sum(cost_usd) as cost from message_costs where ts between $__from/1000-86400 "
    "and $__to/1000 group by 1, 2 order by 1"
)
TOKENS = (
    "select ts/3600*3600 as time, model, sum(output_tokens) as tokens from messages "
    "where ts between $__from/1000 and $__to/1000 group by 1, 2 order by 1"
)


HOUR = 3600


class Auditor(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        root = Path(self.tmp.name)
        self.svc = root
        self.db = root / "usage.sqlite"
        self.dash = root / "dash"
        self.dash.mkdir()
        self.roles = root / "roles.json"
        self.roles.write_text(json.dumps({"manager": {"status": "active"}}))
        self.env = {
            **os.environ,
            "MAINT_DB": str(self.db),
            "AUDITOR_DASHBOARDS": str(self.dash),
            "AUDITOR_ROLES": str(self.roles),
            "AUDITOR_DIR": str(root / "auditor"),
            "SCHEDULER_DIR": str(root / "sched"),
            "CLAUDE_SERVICES_DIR": str(root),
            "REGISTRY_DIR": str(root / "registry"),
            "CLAUDE_SCHED_DIR": str(root / "schedules"),
        }
        self.con = sqlite3.connect(self.db)
        self.con.executescript(SCHEMA)
        self.now = int(time.time())
        self.fill()
        self.panels(COST, TOKENS)
        for table in (
            "samples",
            "messages",
            "mode_history",
            "maint_runs",
            "events",
            "agent_runs",
            "meta",
            "prices",
            "transcripts",
        ):
            self.register("table", table)
        self.register("dashboard", "d")
        self.register("role", "manager")

    def register(self, kind, name, checked_by="auditor"):
        d = self.svc / "registry" / kind / name
        d.mkdir(parents=True, exist_ok=True)
        lines = [f"checked_by: {checked_by}"] if checked_by else []
        (d / "info").write_text("\n".join([f"kind: {kind}", f"name: {name}", *lines]))

    def fill(self):
        for table in (
            "samples",
            "messages",
            "mode_history",
            "maint_runs",
            "events",
            "agent_runs",
        ):
            self.row(table, self.now - 60)
        self.con.execute("insert into meta values ('lines', 1)")
        self.con.execute("insert into prices values ('x')")
        self.con.execute("insert into transcripts values ('f')")
        self.con.commit()

    def row(self, table, ts, **extra):
        cols = {
            "samples": {"ts": ts, "session_id": "s", "five_hour_used": 1.0},
            "messages": {
                "id": f"m{ts}{len(extra)}",
                "uuid": f"u{ts}",
                "ts": ts,
                "agent_id": None,
                "model": "x",
                "output_tokens": 1000,
            },
            "mode_history": {"ts": ts},
            "maint_runs": {"ts": ts, "repo": "r", "task": "t"},
            "events": {"ts": ts},
            "agent_runs": {"session_id": f"a{ts}", "last_seen": ts},
        }[table]
        cols.update(extra)
        names = ",".join(cols)
        marks = ",".join("?" * len(cols))
        self.con.execute(
            f"insert into {table} ({names}) values ({marks})", list(cols.values())
        )
        self.con.commit()

    def panels(self, *queries):
        panels = [
            {"title": f"p{i}", "targets": [{"queryText": q}]}
            for i, q in enumerate(queries)
        ]
        (self.dash / "d.json").write_text(json.dumps({"panels": panels}))
        # the totals check looks panels up by title
        titles = {
            COST: "API-equivalent cost per day and model (priced from transcripts)",
            TOKENS: "Output tokens per hour",
        }
        for p in panels:
            p["title"] = titles.get(p["targets"][0]["queryText"], p["title"])
        (self.dash / "d.json").write_text(json.dumps({"panels": panels}))

    def run_a(self, *args):
        r = subprocess.run(
            [str(BIN), *args],
            env=self.env,
            capture_output=True,
            text=True,
            check=False,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return r.stdout.splitlines()

    def only(self, prefix):
        return [x for x in self.run_a() if x.startswith(prefix)]

    def test_green(self):
        self.assertEqual(self.run_a(), [])

    def test_query_error(self):
        self.panels("select nope from samples")
        self.assertIn("query fails", self.only("panels")[0])

    def test_empty_panel(self):
        self.panels("select ts as time from samples where ts < 0")
        self.assertIn("empty", self.only("panels")[0])

    def test_negative_value(self):
        self.panels("select ts as time, -1.5 as v from samples")
        self.assertIn("shows -1.5", self.only("panels")[0])

    def test_stale_series_while_fresh(self):
        self.panels("select ts as time, 1.0 as v from samples where session_id = 'old'")
        self.row("samples", self.now - 5 * 3600, session_id="old")
        self.assertIn("5 h old", self.only("panels")[0])

    def test_total_mismatch(self):
        self.panels(COST, TOKENS.replace("sum(output_tokens)", "sum(output_tokens)/2"))
        self.assertIn("Output tokens per hour", self.only("totals")[0])

    def test_duplicate_uuid(self):
        self.row("messages", self.now - 50, id="other", uuid=f"u{self.now - 60}")
        self.assertIn("counted more than once", self.only("totals")[0])

    def test_stale_table(self):
        self.con.execute("update maint_runs set ts = ?", (self.now - 40 * 3600,))
        self.con.commit()
        self.assertEqual(
            self.only("tables"), ["tables: maint_runs newest row is 40 h old"]
        )

    def test_backwards_timestamps(self):
        self.row("maint_runs", self.now - 500)
        self.assertIn(
            "maint_runs has 1 timestamps going backwards", self.only("tables")[0]
        )

    def test_row_count_drop(self):
        self.row("events", self.now - 30)
        self.run_a()
        self.con.execute("delete from events where ts = (select min(ts) from events)")
        self.con.commit()
        self.assertEqual(
            self.only("tables"), ["tables: events dropped from 2 to 1 rows"]
        )

    def test_stale_agent_runs(self):
        self.con.execute("update agent_runs set last_seen = ?", (self.now - 3 * HOUR,))
        self.con.commit()
        self.assertEqual(
            self.only("tables"), ["tables: agent_runs newest row is 3 h old"]
        )

    def test_counted_table_dropping(self):
        self.run_a()
        self.con.execute("delete from transcripts")
        self.con.commit()
        self.assertEqual(
            self.only("tables"), ["tables: transcripts dropped from 1 to 0 rows"]
        )

    def events(self, *rows):
        d = Path(self.env["SCHEDULER_DIR"])
        d.mkdir(exist_ok=True)
        (d / "events").write_text("".join(json.dumps(r) + "\n" for r in rows))

    def test_alarms(self):
        self.register("alarm", "mechanic")
        self.events(
            {"alarm": "mechanic", "msg": "mechanic: 1 findings"},
            {"alarm": "nightly", "msg": "[schedule nightly] go"},
            {"alarm": "bogus", "msg": "x"},
            {"alarm": "other", "msg": "[schedule nightly] go"},
        )
        self.assertEqual(
            self.only("alarms"),
            ["alarms: unknown alarm bogus", "alarms: unknown alarm other"],
        )

    def test_role_run_history(self):
        self.roles.write_text(
            json.dumps(
                {"manager": {"status": "active"}, "mechanic": {"status": "active"}}
            )
        )
        self.assertEqual(self.only("coach"), ["coach: mechanic left no records"])
        log = self.svc / "mechanic/runs.jsonl"
        log.parent.mkdir()
        log.write_text('{"ts": 1, "findings": 0, "checks": {}}\n')
        self.assertEqual(self.only("coach"), [])

    def test_coach_run_history(self):
        self.roles.write_text(json.dumps({"coach": {"status": "active"}}))
        self.assertEqual(self.only("coach"), ["coach: coach left no records"])
        log = self.svc / "coach/runs.jsonl"
        log.parent.mkdir()
        log.write_text('{"ts": 1, "findings": 0, "checks": {}}\n')
        self.assertEqual(self.only("coach"), [])

    def test_role_without_any_record(self):
        self.roles.write_text(json.dumps({"digest": {"status": "active"}}))
        self.assertEqual(
            self.only("coach"), ["coach: digest leaves no findings history"]
        )

    def test_manager_records_older_than_a_week_do_not_count(self):
        self.assertEqual(self.only("coach"), [])
        self.con.execute("update messages set ts = ?", (self.now - 8 * 86400,))
        self.con.commit()
        self.assertEqual(self.only("coach"), ["coach: manager left no records"])

    def test_failure_is_a_finding_and_the_run_is_logged(self):
        Path(self.env["AUDITOR_DIR"]).mkdir()
        (Path(self.env["AUDITOR_DIR"]) / "state.json").write_text("{not json")
        out = self.run_a("--notify")
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith("audit: "))
        rows = (self.svc / "auditor/runs.jsonl").read_text().splitlines()
        self.assertEqual(json.loads(rows[0])["checks"], {"audit": 1})

    def test_sqlite_internal_tables_need_no_registration(self):
        self.con.execute("create table seq (id integer primary key autoincrement)")
        self.con.execute("insert into seq default values")
        self.con.commit()
        self.register("table", "seq")
        self.assertEqual(self.only("registry"), [])

    def test_small_timestamp_inversions_are_tolerated(self):
        self.row("maint_runs", self.now - 63)
        self.assertEqual(self.only("tables"), [])

    def test_alarms_reads_only_the_newest_lines_and_survives_odd_lines(self):
        self.register("alarm", "mechanic")
        good = {"alarm": "mechanic", "msg": "m"}
        d = Path(self.env["SCHEDULER_DIR"])
        d.mkdir()
        (d / "events").write_text(
            json.dumps({"alarm": "retired", "msg": "x"})
            + "\n"
            + (json.dumps(good) + "\n") * 200
            + "[1]\n"
        )
        self.assertEqual(
            self.only("alarms"), ["alarms: unknown alarm (unreadable line)"]
        )

    def test_run_history_is_capped(self):
        log = self.svc / "auditor/runs.jsonl"
        log.parent.mkdir()
        log.write_text('{"x": 1}\n' * 200000)
        self.run_a("--notify")
        self.assertEqual(len(log.read_text().splitlines()), 2000)

    def test_run_is_recorded(self):
        self.run_a()
        self.assertFalse((self.svc / "auditor/runs.jsonl").exists())
        self.run_a("--notify")
        rows = (self.svc / "auditor/runs.jsonl").read_text().splitlines()
        self.assertEqual(len(rows), 1)
        self.assertEqual(json.loads(rows[0])["findings"], 0)

    def test_planned_roles_skipped(self):
        self.roles.write_text(json.dumps({"coach": {"status": "planned"}}))
        self.assertEqual(self.only("coach"), [])

    def test_unpriced_message(self):
        self.con.execute("drop view message_costs")
        self.con.execute(
            "create view message_costs as select *, null cost_usd from messages"
        )
        self.assertEqual(self.only("totals")[:1], ["totals: 1 messages have no price"])

    def test_registry_unregistered_and_missing(self):
        service = self.svc / "newsvc"
        service.mkdir()
        (service / "run").write_text("#!/bin/sh\n")
        (service / "run").chmod(0o755)
        self.con.execute("create table fresh (x)")
        (self.dash / "other.json").write_text("{}")
        self.roles.write_text(
            json.dumps({"manager": {"status": "active"}, "x": {"status": "planned"}})
        )
        self.register("service", "gone")
        self.assertEqual(
            self.only("registry"),
            [
                "registry: service-newsvc exists but is not registered",
                "registry: table-fresh exists but is not registered",
                "registry: dashboard-other exists but is not registered",
                "registry: role-x exists but is not registered",
                "registry: service-gone is registered but missing",
            ],
        )

    def test_registry_schedule(self):
        Path(self.env["CLAUDE_SCHED_DIR"]).mkdir()
        (Path(self.env["CLAUDE_SCHED_DIR"]) / "schedules.nuon").write_text(
            "[[name, cron]; [nightly, '0 1 * * *']]"
        )
        self.assertEqual(
            self.only("registry"),
            ["registry: schedule-nightly exists but is not registered"],
        )
        self.register("schedule", "nightly")
        self.assertEqual(self.only("registry"), [])

    def test_registry_entry_without_checker(self):
        self.register("log", "events", checked_by="")
        self.assertEqual(self.only("registry"), ["registry: log-events has no checker"])

    def test_checker_gap_does_not_alarm(self):
        self.register("log", "events", checked_by="")
        self.run_a("--notify")
        self.assertFalse((Path(self.tmp.name) / "sched/events").exists())

    def test_registry_ignores_stray_files_and_reads_comments(self):
        (self.svc / "registry/README").write_text("notes")
        (self.svc / "registry/log/README").parent.mkdir()
        (self.svc / "registry/log/README").write_text("notes")
        self.register("log", "events", checked_by="")
        info = self.svc / "registry/log/events/info"
        info.write_text(info.read_text() + "\n# checked_by: nobody\nchecked_by: x")
        self.assertEqual(self.only("registry"), [])

    def test_registry_directory_missing(self):
        subprocess.run(["rm", "-r", str(self.svc / "registry")], check=True)
        self.assertEqual(
            self.only("registry"), [f"registry: {self.svc / 'registry'} is missing"]
        )

    def test_missing_database(self):
        self.db.unlink()
        self.assertEqual(self.run_a(), ["tables: usage.sqlite is missing"])

    def test_json_and_notify(self):
        self.panels(COST, TOKENS, "select nope from samples")
        out = self.run_a("--json", "--notify")
        self.assertEqual(json.loads(out[0])["check"], "panels")
        events = (Path(self.tmp.name) / "sched/events").read_text().splitlines()
        self.assertEqual(
            json.loads(events[0]),
            {"alarm": "auditor", "msg": "auditor: 1 findings; run bin/claude-auditor"},
        )

    def test_no_notify_when_green(self):
        self.run_a("--notify")
        self.assertFalse((Path(self.tmp.name) / "sched/events").exists())


if __name__ == "__main__":
    unittest.main()
