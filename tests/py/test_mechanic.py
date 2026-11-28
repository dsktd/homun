"""bin/claude-mechanic: each check red and green against temp dirs."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import sqlite3
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

import stubbus

BIN = Path(__file__).resolve().parents[2] / "bin/claude-mechanic"


class Mechanic(unittest.TestCase):
    def setUp(self):
        self.tmp = tempfile.TemporaryDirectory()
        self.addCleanup(self.tmp.cleanup)
        self.svc = Path(self.tmp.name)
        self.env = {
            **os.environ,
            **stubbus.install(self.tmp.name),
            "CLAUDE_SERVICES_DIR": str(self.svc),
            "MECHANIC_SERVICES_CMD": "",
            "MECHANIC_STATUS_URL": "",
            "MECHANIC_ROOT": self.tmp.name,
            "MECHANIC_BARE": str(self.svc / "nobare"),
            "MECHANIC_TOOLS": "",
            "MECHANIC_TRACKER": "",
            "MECHANIC_USAGE_JSONL": str(self.svc / "usage.jsonl"),
        }
        (self.svc / "maint").mkdir()
        (self.svc / "maint/hygiene.jsonl").write_text("")
        (self.svc / "usage-db").mkdir()
        self.sample(time.time())
        self.written(time.time())

    def written(self, ts):
        (self.svc / "usage.jsonl").write_text(f'{{"ts": {int(ts)}}}\n')

    def sample(self, ts, lines=1):
        con = sqlite3.connect(self.svc / "usage-db/usage.sqlite")
        con.execute("create table if not exists samples (ts integer)")
        con.execute("create table if not exists meta (key text, value integer)")
        con.execute("delete from samples")
        con.execute("delete from meta")
        con.execute("insert into samples values (?)", (int(ts),))
        con.execute("insert into meta values ('lines', ?)", (lines,))
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

    def files_mode(self, beat_age=0, run_age=0):
        beat = self.svc / "manager/heartbeat"
        beat.parent.mkdir(exist_ok=True)
        beat.write_text("")
        os.utime(beat, (time.time() - beat_age,) * 2)
        runs = self.svc / "mechanic/runs.jsonl"
        runs.parent.mkdir(exist_ok=True)
        runs.write_text(json.dumps({"ts": int(time.time() - run_age)}) + "\n")
        return {"MECHANIC_LIVENESS": "files", "MECHANIC_SERVICES_CMD": "true"}

    def test_files_mode_trusts_the_pid_file(self):
        self.service("up", pid=1)
        (self.svc / "up/pid").write_text("999999999\n")  # no such process here
        self.service("down")
        self.assertEqual(
            self.run_m(**self.files_mode()), ["services: not running: down"]
        )

    def test_files_mode_heartbeat_and_runs(self):
        self.service("up", pid=1)
        self.assertEqual(self.run_m(**self.files_mode()), [])
        env = self.files_mode(beat_age=700, run_age=27 * 3600)
        self.assertEqual(
            self.run_m(**env),
            ["heartbeat: manager stale 700s", "runs: last scheduled gauge run 27h ago"],
        )
        (self.svc / "manager/heartbeat").unlink()
        (self.svc / "mechanic/runs.jsonl").unlink()
        self.assertEqual(
            self.run_m(**env),
            [
                "heartbeat: manager/heartbeat missing",
                "runs: no scheduled gauge run recorded",
            ],
        )

    def test_files_mode_skips_the_network_checks(self):
        self.service("up", pid=1)
        env = {**self.files_mode(), "MECHANIC_STATUS_URL": (self.svc / "none").as_uri()}
        self.assertEqual(self.run_m(**env), ["status: page unreadable"])
        del env["MECHANIC_STATUS_URL"]
        env["MECHANIC_TRACKER"] = str(self.svc / "no-ghd")
        self.assertEqual(self.run_m(**env), ["context: unavailable"])

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

    def test_registered_logs_ignore_stray_files_and_comments(self):
        (self.svc / "registry/log").mkdir(parents=True)
        (self.svc / "registry/log/README").write_text("notes")
        (self.svc / "registry/README").write_text("notes")
        info = self.svc / "registry/log/big"
        info.mkdir()
        (info / "info").write_text(f"# path: /nope\npath: {self.svc}/big.jsonl\n")
        (self.svc / "big.jsonl").write_bytes(b"x" * 9 * 1024 * 1024)
        self.assertEqual(self.run_m(), ["logs: big.jsonl is 9 MB (over 8)"])

    def schedules(self, enabled, last_fire, cron="0 * * * *", created=None):
        d = self.svc / "sched"
        d.mkdir(exist_ok=True)
        extra = f", created: '{created}'" if created else ""
        (d / "schedules.nuon").write_text(
            f"[{{name: nightly, cron: '{cron}', prompt: p, enabled: {enabled}{extra}}}]"
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

    def test_schedule_period_is_the_longest_gap_of_the_next_fires(self):
        # Mondays and Fridays: gaps of 4 and 3 days, so 6 days of silence is fine
        self.schedules("true", int(time.time()) - 5 * 86400, cron="0 8 * * 1,5")
        self.assertEqual(self.run_m(), [])
        self.schedules("true", int(time.time()) - 7 * 86400, cron="0 8 * * 1,5")
        self.assertEqual(len(self.run_m()), 1)

    def test_schedule_never_fired_counts_from_its_creation(self):
        created = time.strftime(
            "%Y-%m-%dT%H:%M:%S.123456789+00:00", time.gmtime(time.time() - 3 * 3600)
        )
        self.schedules("true", None, created=created)
        out = self.run_m()
        self.assertEqual(len(out), 1)
        self.assertTrue(out[0].startswith("schedules: nightly has not fired since "))

    def test_usage_lag(self):
        # an unimported line an hour old is behind
        self.written(time.time() - 3600)
        self.sample(time.time() - 3600, lines=0)
        self.assertIn("usage-db", self.run_m()[0])
        # imported, however old: an idle night is not a fault
        self.sample(time.time() - 3600, lines=1)
        self.assertEqual(self.run_m(), [])
        # a fresh line after an idle night is not behind either
        self.written(time.time())
        self.sample(time.time() - 8 * 3600, lines=0)
        self.assertEqual(self.run_m(), [])

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
                "bus": True,
            },
        )
        self.assertEqual(
            stubbus.sent(self.tmp.name),
            [
                {
                    "to": "manager",
                    "alarm": "mechanic",
                    "msg": "mechanic: 1 findings; run bin/claude-mechanic",
                }
            ],
        )

    def test_no_notify_when_green(self):
        self.run_m("--notify")
        self.assertFalse((self.svc / "scheduler/events").exists())
        self.assertEqual(stubbus.sent(self.tmp.name), [])

    def test_run_source(self):
        runs = self.svc / "mechanic/runs.jsonl"
        self.run_m("--notify")
        self.run_m("--notify", "--source", "cron")
        rows = [json.loads(x) for x in runs.read_text().splitlines()]
        self.assertEqual([r["source"] for r in rows], ["manual", "cron"])

    def test_runs_history(self):
        runs = self.svc / "mechanic/runs.jsonl"
        self.run_m("--notify")
        self.service("down")
        self.run_m("--notify")
        rows = [json.loads(x) for x in runs.read_text().splitlines()]
        # every check that ran is logged, with its count (zeros included)
        self.assertEqual([r["checks"]["services"] for r in rows], [0, 1])
        self.assertEqual(
            [
                (r["findings"], {k: v for k, v in r["checks"].items() if v})
                for r in rows
            ],
            [(0, {}), (1, {"services": 1})],
        )
        self.assertIsInstance(rows[0]["ts"], int)

    def test_manual_runs_are_not_logged(self):
        self.run_m()
        self.assertFalse((self.svc / "mechanic/runs.jsonl").exists())

    def test_runs_history_capped(self):
        runs = self.svc / "mechanic/runs.jsonl"
        runs.parent.mkdir()
        runs.write_text('{"x": 1}\n' * 200000)
        self.run_m("--notify")
        lines = runs.read_text().splitlines()
        self.assertEqual(len(lines), 2000)
        self.assertEqual(json.loads(lines[-1])["findings"], 0)

    def make_repo(self, name, files):
        repo = self.svc / "bare" / f"{name}.git"
        work = self.svc / "work" / name
        work.mkdir(parents=True)
        for rel, data in files.items():
            (work / rel).write_bytes(data)
        git = ["git", "-C", str(work)]
        subprocess.run([*git, "init", "-q"], check=True)
        subprocess.run([*git, "add", "-A"], check=True)
        subprocess.run(
            [*git, "-c", "user.name=t", "-c", "user.email=t@t", "commit", "-qm", "x"],
            check=True,
        )
        repo.parent.mkdir(exist_ok=True)
        subprocess.run(
            ["git", "clone", "-q", "--bare", str(work), str(repo)], check=True
        )

    def test_secrets(self):
        token = "ghp_" + "a1B2" * 9
        self.make_repo(
            "r",
            {
                "ok.txt": b"nothing here\n",
                "cfg.env": f"x=1\ntoken = {token}\n".encode(),
                "bin.dat": b"\0" + token.encode(),
                "big.txt": token.encode() + b"\n" + b"x" * (2 * 1024 * 1024),
            },
        )
        env = {"MECHANIC_BARE": str(self.svc / "bare")}
        out = self.run_m(**env)
        self.assertEqual(
            sorted(out),
            [
                "secrets: r cfg.env:2 assigned-secret",
                "secrets: r cfg.env:2 github-token",
            ],
        )
        self.assertNotIn(token, "".join(out))

    def test_context(self):
        fake = self.svc / "tracker"
        key = "sk-ant-" + "abc123" * 5
        fake.write_text(
            "#!/bin/sh\n"
            'if [ "$1" = list ]; then echo \'[{"id":7},{"id":8}]\'; exit; fi\n'
            f'if [ "$2" = 7 ]; then echo \'{{"id":7,"title":"t","body":"{key}"}}\'; exit; fi\n'
            'echo \'{"id":8,"title":"t","body":null}\'\n'
        )
        fake.chmod(0o755)
        out = self.run_m(MECHANIC_TRACKER=str(fake))
        self.assertEqual(out, ["context: item #7 anthropic-key"])
        fake.write_text("#!/bin/sh\nexit 1\n")
        self.assertEqual(
            self.run_m(MECHANIC_TRACKER=str(fake)), ["context: unavailable"]
        )

    def test_proxy(self):
        d = self.svc / "proxy"
        d.mkdir()
        self.assertEqual(
            self.run_m(),
            ["proxy: Caddyfile is missing", "proxy: users is missing"],
        )
        (d / "Caddyfile").write_text("a {\n\tbasic_auth {\n\t}\n}\n")
        (d / "users").write_text("")
        (d / "users").chmod(0o644)
        self.assertEqual(self.run_m(), ["proxy: users has mode 644 (want 600)"])
        (d / "users").chmod(0o600)
        self.assertEqual(self.run_m(), [])
        (d / "Caddyfile").write_text('a {\n\trespond "no" 403\n}\n')
        self.assertEqual(self.run_m(), [])
        (d / "Caddyfile").write_text("a {\n\treverse_proxy x\n}\n")
        self.assertEqual(
            self.run_m(), ["proxy: Caddyfile has no basic auth and is not deny-all"]
        )


if __name__ == "__main__":
    unittest.main()
