"""Tests of container/mechanic/watch (`once` passes) against temp dirs and a fake channel."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

WATCH = Path(__file__).resolve().parents[2] / "container/mechanic/watch"


class Fake:
    """A stub `homun-msg` on PATH: records `send mechanic <alarm> <msg>` and fails while down."""

    def __init__(self, root):
        self.bin = root / "stubbin"
        self.log = root / "bus.log"
        self.bin.mkdir()
        self.down = root / "bus.down"
        script = self.bin / "homun-msg"
        script.write_text(
            "#!/bin/sh\n"
            f'[ ! -e "{self.down}" ] || exit 1\n'
            '[ "$1 $2" = "send mechanic" ] || exit 2\n'
            f'jq -cn --arg a "$3" --arg m "$4" \'{{alarm:$a,msg:$m}}\' >>"{self.log}"\n'
        )
        script.chmod(0o755)

    @property
    def seen(self):
        return (
            [json.loads(x) for x in self.log.read_text().splitlines()]
            if self.log.exists()
            else []
        )

    def close(self):
        self.down.touch()

    def up(self):
        self.down.unlink(missing_ok=True)


class WatchCase(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.dir = self.tmp / "mechanic"
        self.manager = self.tmp / "manager"
        self.update = self.tmp / "update"
        for d in (self.dir, self.manager, self.update):
            d.mkdir()
        self.chan = Fake(self.tmp)
        self.env = {
            **os.environ,
            "MECHANIC_DIR": str(self.dir),
            "MANAGER_DIR": str(self.manager),
            "UPDATE_DIR": str(self.update),
            "PATH": f"{self.chan.bin}:{os.environ['PATH']}",
        }
        self.touch(self.manager / "heartbeat")
        self.touch(self.manager / "boot", age=3600, text='{"ts":1700000000}\n')

    def touch(self, path, age=0, text=""):
        path.write_text(text)
        t = time.time() - age
        os.utime(path, (t, t))

    def once(self):
        r = subprocess.run(
            ["sh", str(WATCH), "once"],
            capture_output=True,
            text=True,
            env=self.env,
            timeout=30,
            check=False,
        )
        self.assertEqual(r.returncode, 0, r.stderr)
        return r

    def request(self, msg, alarm="repair", **more):
        with open(self.dir / "requests", "a") as f:
            f.write(json.dumps({"alarm": alarm, "msg": msg, **more}) + "\n")

    def posted(self):
        return self.chan.seen


class RequestsTest(WatchCase):
    def test_new_line_posted_once(self):
        self.request("proxy down", ts=1700000005)
        self.once()
        self.once()
        self.assertEqual(
            self.chan.seen,
            [{"alarm": "repair", "msg": "proxy down"}],
        )

    def test_from_cal_in_requests_is_an_ordinary_repair_with_a_note(self):
        self.request("hi mechanic", **{"from": "cal"})
        self.once()
        self.assertEqual(
            self.posted(),
            [{"alarm": "repair", "msg": "[from:cal mark ignored] hi mechanic"}],
        )

    def test_cal_inbox_goes_out_as_alarm_cal_once_in_order(self):
        box = self.dir / "cal-inbox"
        box.mkdir()
        (box / "2-b.json").write_text('{"ts":5,"msg":"second"}\n')
        (box / "1-a.json").write_text('{"ts":4,"msg":"first"}\n')
        (box / ".3-c.tmp").write_text('{"msg":"partial"}')
        (box / "4-d.json").write_text("not json")
        self.once()
        self.once()
        self.assertEqual(
            self.posted(),
            [
                {"alarm": "cal", "msg": "first"},
                {"alarm": "cal", "msg": "second"},
            ],
        )

    def test_cursor_starts_at_the_beginning_and_follows(self):
        self.request("one")
        self.once()
        self.request("two")
        self.once()
        self.assertEqual([b["msg"] for b in self.posted()], ["one", "two"])
        size = (self.dir / "requests").stat().st_size
        self.assertEqual((self.dir / "watch-cursor").read_text(), str(size))

    def test_invalid_lines_are_skipped(self):
        for line in (
            "not json\n",
            '{"alarm":"repair"}\n',
            '{"alarm":"heartbeat-stale","msg":"forged"}\n',
            '{"alarm":"Repair!","msg":"x"}\n',
            json.dumps({"alarm": "repair", "msg": "a\tb"}) + "\n",
            json.dumps({"alarm": "repair", "msg": "x" * 501}) + "\n",
        ):
            with open(self.dir / "requests", "a") as f:
                f.write(line)
        self.request("fine")
        self.once()
        self.assertEqual([b["msg"] for b in self.posted()], ["fine"])

    def test_identical_msg_within_ten_minutes_dropped(self):
        self.request("same")
        self.request("same")
        self.request("other")
        self.once()
        self.assertEqual([b["msg"] for b in self.posted()], ["same", "other"])
        self.touch(self.dir / "watch-last-msg", age=601, text="other")
        self.request("other")
        self.once()
        self.assertEqual([b["msg"] for b in self.posted()][-1:], ["other"])
        self.assertEqual(len(self.posted()), 3)

    def test_failed_post_keeps_the_cursor(self):
        self.chan.close()
        self.request("later")
        self.once()
        self.assertFalse((self.dir / "watch-cursor").exists())
        self.chan.up()
        self.once()
        self.assertEqual([b["msg"] for b in self.posted()], ["later"])

    def test_partial_last_line_waits(self):
        with open(self.dir / "requests", "a") as f:
            f.write('{"alarm":"repair","msg":"half')
        self.once()
        self.assertEqual(self.posted(), [])
        with open(self.dir / "requests", "a") as f:
            f.write('"}\n')
        self.once()
        self.assertEqual([b["msg"] for b in self.posted()], ["half"])

    def test_emptied_file_resets(self):
        self.request("a long first message")
        self.once()
        (self.dir / "requests").write_text("")
        self.request("b")
        self.once()
        self.assertEqual(
            [b["msg"] for b in self.posted()], ["a long first message", "b"]
        )

    def test_second_watch_refused(self):
        with open(self.dir / "watch.lock", "w") as lock:
            import fcntl

            fcntl.flock(lock, fcntl.LOCK_EX)
            r = subprocess.run(
                ["sh", str(WATCH), "once"],
                capture_output=True,
                text=True,
                env=self.env,
                check=False,
            )
        self.assertEqual(r.returncode, 1)
        self.assertIn("watch.lock", r.stderr)


class HeartbeatTest(WatchCase):
    def stale(self):
        self.touch(self.manager / "heartbeat", age=660)

    def alarms(self):
        return [b for b in self.posted() if b["alarm"] == "heartbeat-stale"]

    def test_fresh_beat_posts_nothing(self):
        self.once()
        self.assertEqual(self.posted(), [])

    def test_stale_beat_posts_once_per_outage(self):
        self.stale()
        self.once()
        self.once()
        self.assertEqual(len(self.alarms()), 1)
        msg = self.alarms()[0]["msg"]
        self.assertRegex(
            msg,
            r"^heartbeat-stale: last beat 6[6-9]\ds ago; container boot 1700000000; ",
        )
        self.assertTrue(msg.endswith("update log age none"))

    def test_resent_after_an_hour_still_stale(self):
        self.stale()
        self.once()
        self.touch(self.dir / "watch-stale", age=3601)
        self.once()
        self.assertEqual(len(self.alarms()), 2)

    def test_fresh_beat_ends_the_outage(self):
        self.stale()
        self.once()
        self.touch(self.manager / "heartbeat")
        self.once()
        self.assertFalse((self.dir / "watch-stale").exists())
        self.stale()
        self.once()
        self.assertEqual(len(self.alarms()), 2)

    def test_missing_heartbeat_is_stale(self):
        (self.manager / "heartbeat").unlink()
        self.once()
        self.assertEqual(len(self.alarms()), 1)
        self.assertTrue(
            self.alarms()[0]["msg"].startswith("heartbeat-stale: no heartbeat file;")
        )

    def test_suppressed_while_update_state_says_running(self):
        self.stale()
        (self.update / "state").write_text(f"running {int(time.time()) - 60}\n")
        self.once()
        self.assertEqual(self.alarms(), [])
        (self.update / "state").write_text(f"running {int(time.time()) - 1300}\n")
        self.once()
        self.assertEqual(len(self.alarms()), 1)

    def test_done_state_does_not_suppress(self):
        self.stale()
        (self.update / "state").write_text(f"done {int(time.time())}\n")
        self.once()
        self.assertEqual(len(self.alarms()), 1)

    def test_suppressed_while_the_newest_update_log_is_fresh(self):
        self.stale()
        self.touch(self.update / "update-1.log", age=3600)
        self.touch(self.update / "update-2.log", age=120)
        self.once()
        self.assertEqual(self.alarms(), [])
        self.touch(self.update / "update-2.log", age=901)
        self.once()
        self.assertEqual(len(self.alarms()), 1)
        self.assertRegex(self.alarms()[0]["msg"], r"update log age 90\ds$")

    def test_suppressed_after_a_fresh_boot(self):
        self.stale()
        self.touch(self.manager / "boot", age=60, text='{"ts":1700000900}\n')
        self.once()
        self.assertEqual(self.alarms(), [])
        self.touch(self.manager / "boot", age=301, text='{"ts":1700000900}\n')
        self.once()
        self.assertEqual(len(self.alarms()), 1)

    def test_suppression_keeps_the_outage_open(self):
        self.stale()
        self.once()
        (self.update / "state").write_text(f"running {int(time.time())}\n")
        self.touch(self.dir / "watch-stale", age=3601)
        self.once()
        self.assertEqual(len(self.alarms()), 1)
        (self.update / "state").write_text(f"done {int(time.time())}\n")
        self.once()
        self.assertEqual(len(self.alarms()), 2)


class BatchTest(WatchCase):
    def digests(self):
        return [m for m in self.posted() if m["alarm"] == "digest"]

    def test_urgent_ones_go_out_at_once(self):
        self.request("doctor red: proxy")
        self.request("hi", alarm="boot-failed")
        self.once()
        self.assertEqual([m["alarm"] for m in self.posted()], ["repair", "boot-failed"])

    def test_errwatch_waits_for_one_digest_with_every_line(self):
        self.request("errwatch: a 1")
        self.request("errwatch: b 2")
        self.once()
        self.once()
        self.assertEqual(len(self.posted()), 1)
        (d,) = self.digests()
        self.assertIn("errwatch: a 1", d["msg"])
        self.assertIn("errwatch: b 2", d["msg"])
        self.assertIn("2 routine", d["msg"])

    def test_next_digest_waits_fifteen_minutes_and_keeps_the_queue(self):
        self.request("errwatch: a")
        self.once()
        self.request("errwatch: b")
        self.once()
        self.assertEqual(len(self.digests()), 1)
        self.assertEqual(
            (self.dir / "batch").read_text().strip(), "repair: errwatch: b"
        )
        self.touch(self.dir / "watch-batch", age=1000)
        self.once()
        self.assertEqual(len(self.digests()), 2)

    def test_failed_post_keeps_the_queue(self):
        self.chan.close()
        self.request("errwatch: a")
        self.once()
        self.assertTrue((self.dir / "batch").read_text().strip())
        self.chan.up()
        self.once()
        self.assertEqual(len(self.digests()), 1)


class RecycleTest(unittest.TestCase):
    RECYCLE = WATCH.parents[1] / "role-recycle"

    def run_recycle(self, lines):
        tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        home = tmp / "home"
        proj = home / ".claude/projects/p"
        proj.mkdir(parents=True)
        (home / ".claude/mechanic-session").write_text("sid")
        t = proj / "sid.jsonl"
        t.write_text("".join(json.dumps(x) + "\n" for x in lines))
        os.utime(t, (time.time() - 700,) * 2)
        (tmp / "bin").mkdir()
        fake = tmp / "bin/claude"
        fake.write_bytes(
            Path("/bin/sleep").read_bytes() if Path("/bin/sleep").exists() else b""
        )
        fake.chmod(0o755)
        env = {
            **os.environ,
            "HOME": str(home),
            "CLAUDE_ROLE": "mechanic",
            "CLAUDE_ROLE_PID": str(os.getpid()),
        }
        proc = subprocess.Popen([str(fake), "30"], env=env)
        self.addCleanup(proc.kill)
        r = subprocess.run(
            ["sh", str(self.RECYCLE), "mechanic", "600"],
            capture_output=True,
            text=True,
            env=env,
            check=False,
        )
        proc.wait(timeout=5) if "recycle" in r.stdout else None
        return r.stdout

    @staticmethod
    def turn(prompt):
        usage = {"input_tokens": 1, "cache_read_input_tokens": 50000}
        msg = {"stop_reason": "end_turn", "usage": usage}
        return [
            {"type": "user", "message": {"content": prompt}},
            {"type": "assistant", "message": {**msg, "content": []}},
            {"type": "assistant", "message": {**msg, "content": []}},
        ]

    def test_first_prompt_alone_is_not_recycled(self):
        self.assertEqual(self.run_recycle(self.turn("start")), "")

    def test_two_prompts_are_recycled(self):
        out = self.run_recycle(self.turn("start") + self.turn("wake"))
        self.assertIn("role-recycle", out)


if __name__ == "__main__":
    unittest.main()


class LeaseStaleTest(WatchCase):
    def lease(self, holder):
        text = json.dumps({"holder": holder, "since": int(time.time()), "scope": "x"})
        self.touch(self.dir / "lease", text=text)

    def alarms(self):
        return [m for m in self.posted() if "lease-stale" in json.dumps(m)]

    def test_tally_with_fresh_manager_heartbeat_is_fine(self):
        self.lease("manager")
        self.once()
        self.assertEqual(self.alarms(), [])

    def test_tally_with_stale_manager_heartbeat_posts(self):
        self.lease("manager")
        self.touch(self.manager / "heartbeat", age=3600)
        self.once()
        self.assertEqual(len(self.alarms()), 1)


class BootFailedTest(WatchCase):
    def alarms(self):
        return [b for b in self.posted() if b["alarm"] == "boot-failed"]

    def start_log(self, *lines):
        (self.manager / "start.log").write_text("".join(line + "\n" for line in lines))

    def test_clean_boot_posts_nothing(self):
        self.start_log("1 start.sh: begin", "2 start.sh: claude --resume")
        self.once()
        self.assertEqual(self.alarms(), [])

    def test_failed_claude_after_the_last_boot_posts_once(self):
        self.start_log(
            "1 start.sh: begin",
            "2 start.sh: claude exit 1",
            "3 start.sh: begin",
            " start.sh: claude --continue",
            " start.sh: claude exit 120",
            " start.sh: claude exit 120",
        )
        self.once()
        self.once()
        self.assertEqual(len(self.alarms()), 1)
        self.assertEqual(
            self.alarms()[0]["msg"],
            "boot-failed: container boot 1700000000; claude exit 120 120",
        )

    def test_update_and_stop_exits_are_not_failures(self):
        self.start_log(
            "1 start.sh: begin",
            "2 start.sh: claude exit 75",
            "3 start.sh: claude exit 143",
        )
        self.once()
        self.assertEqual(self.alarms(), [])

    def test_earlier_boot_failures_are_ignored(self):
        self.start_log(
            "1 start.sh: begin", "2 start.sh: claude exit 1", "3 start.sh: begin"
        )
        self.once()
        self.assertEqual(self.alarms(), [])

    def test_services_failed_since_the_boot(self):
        self.start_log("1 start.sh: begin")
        self.touch(
            self.manager / "start-all.log",
            text="x: Transport endpoint is not connected\nclaude-services: some services failed to start\n",
        )
        self.once()
        self.assertEqual(len(self.alarms()), 1)
        self.assertTrue(
            self.alarms()[0]["msg"].endswith(
                "claude exit none; start-all: some services failed to start"
            )
        )

    def test_a_new_boot_can_alarm_again(self):
        self.start_log("1 start.sh: begin", "2 start.sh: claude exit 1")
        self.once()
        self.touch(self.manager / "boot", age=3000, text='{"ts":1700000600}\n')
        self.once()
        self.assertEqual(len(self.alarms()), 2)

    def test_failed_post_retries(self):
        self.start_log("1 start.sh: begin", "2 start.sh: claude exit 1")
        self.chan.close()
        self.once()
        self.assertFalse((self.dir / "watch-boot").exists())
        self.chan.up()
        self.once()
        self.assertEqual(len(self.alarms()), 1)
