"""Tests of container/services/scheduler/listen, run with sh in a temp dir."""

import os
import shutil
import signal
import subprocess
import tempfile
import time
import unittest
from pathlib import Path

LISTEN = Path(__file__).resolve().parents[2] / "container/services/scheduler/listen"


class ListenCase(unittest.TestCase):
    def setUp(self):
        self.dir = Path(self.enterContext(tempfile.TemporaryDirectory()))
        shutil.copy(LISTEN, self.dir / "listen")
        # `once` sleeps 5 s between looks; a quicker sleep keeps the tests fast.
        real_sleep = shutil.which("sleep")
        fake = self.dir / "bin"
        fake.mkdir()
        (fake / "sleep").write_text(f"#!/bin/sh\nexec {real_sleep} 0.05\n")
        (fake / "sleep").chmod(0o755)
        self.env = {**os.environ, "PATH": f"{fake}:{os.environ['PATH']}"}
        self.events = self.dir / "events"
        self.cursor = self.dir / "cursor"

    def spawn(self, *args):
        proc = subprocess.Popen(
            ["sh", str(self.dir / "listen"), *args],
            stdout=subprocess.PIPE,
            env=self.env,
            start_new_session=True,
        )
        self.addCleanup(self.kill, proc)
        return proc

    @staticmethod
    def kill(proc):
        if proc.poll() is None:
            os.killpg(proc.pid, signal.SIGKILL)
        proc.wait()
        proc.stdout.close()

    def once(self, **kwargs):
        return subprocess.run(
            ["sh", str(self.dir / "listen"), "once"],
            capture_output=True,
            env=self.env,
            timeout=10,
            check=False,
            **kwargs,
        ).stdout

    def append(self, data):
        with open(self.events, "ab") as f:
            f.write(data)

    def wait_for(self, condition):
        for _ in range(100):
            if condition():
                return True
            time.sleep(0.05)
        return False

    def cursor_value(self):
        return self.cursor.read_text() if self.cursor.exists() else None


class OnceTest(ListenCase):
    def test_prints_every_line_after_the_cursor(self):
        self.events.write_bytes(b"a\nb\n")
        self.cursor.write_text("0")
        self.assertEqual(self.once(), b"a\nb\n")

    def test_prints_only_the_lines_after_the_cursor(self):
        self.events.write_bytes(b"a\nb\nc\n")
        self.cursor.write_text("2")
        self.assertEqual(self.once(), b"b\nc\n")

    def test_moves_the_cursor_to_the_end(self):
        self.events.write_bytes(b"a\nb\n")
        self.cursor.write_text("0")
        self.once()
        self.assertEqual(self.cursor_value(), "4")

    def test_a_second_call_prints_nothing_old(self):
        self.events.write_bytes(b"a\n")
        self.cursor.write_text("0")
        self.once()
        proc = self.spawn("once")
        self.append(b"b\n")
        self.assertEqual(proc.communicate(timeout=10)[0], b"b\n")

    def test_without_a_cursor_starts_at_the_end(self):
        self.events.write_bytes(b"old\n")
        proc = self.spawn("once")
        self.assertTrue(self.wait_for(lambda: self.cursor_value() == "4"))
        self.append(b"new\n")
        self.assertEqual(proc.communicate(timeout=10)[0], b"new\n")

    def test_waits_for_a_line_and_prints_exactly_it(self):
        self.events.write_bytes(b"a\n")
        self.cursor.write_text("2")
        proc = self.spawn("once")
        self.assertTrue(self.wait_for(lambda: (self.dir / "listener").exists()))
        self.append(b"x y\n")
        self.assertEqual(proc.communicate(timeout=10)[0], b"x y\n")

    def test_touches_the_heartbeat_while_waiting(self):
        self.events.write_bytes(b"")
        self.cursor.write_text("0")
        proc = self.spawn("once")
        listener = self.dir / "listener"
        self.assertTrue(self.wait_for(listener.exists))
        os.utime(listener, (1, 1))
        self.assertTrue(self.wait_for(lambda: listener.stat().st_mtime > 1000))
        self.assertIsNone(proc.poll())

    def test_truncated_events_reset_the_cursor(self):
        self.events.write_bytes(b"x\n")
        self.cursor.write_text("100")
        self.assertEqual(self.once(), b"x\n")

    def test_events_emptied_while_waiting_restart_from_zero(self):
        self.events.write_bytes(b"0123456789\n")
        self.cursor.write_text("11")
        proc = self.spawn("once")
        self.assertTrue(self.wait_for(lambda: (self.dir / "listener").exists()))
        self.events.write_bytes(b"new\n")
        self.assertEqual(proc.communicate(timeout=10)[0], b"new\n")


class FollowTest(ListenCase):
    def read_lines(self, proc, count):
        return [proc.stdout.readline() for _ in range(count)]

    def test_replays_lines_missed_since_the_cursor(self):
        self.events.write_bytes(b"a\nb\nc\n")
        self.cursor.write_text("2")
        proc = self.spawn()
        self.assertEqual(self.read_lines(proc, 2), [b"b\n", b"c\n"])

    def test_prints_a_line_appended_later(self):
        self.events.write_bytes(b"a\n")
        self.cursor.write_text("2")
        proc = self.spawn()
        self.assertTrue(self.wait_for(lambda: (self.dir / "listener").exists()))
        self.append(b"later\n")
        self.assertEqual(self.read_lines(proc, 1), [b"later\n"])

    def test_cursor_follows_the_printed_lines_in_bytes(self):
        self.events.write_bytes("é\nab\n".encode())
        self.cursor.write_text("0")
        proc = self.spawn()
        self.read_lines(proc, 2)
        self.assertTrue(self.wait_for(lambda: self.cursor_value() == "6"))

    def test_truncated_events_reset_the_cursor(self):
        self.events.write_bytes(b"x\n")
        self.cursor.write_text("100")
        proc = self.spawn()
        self.assertEqual(self.read_lines(proc, 1), [b"x\n"])

    def test_without_a_cursor_old_lines_are_not_replayed(self):
        self.events.write_bytes(b"old\n")
        proc = self.spawn()
        self.assertTrue(self.wait_for(lambda: self.cursor_value() == "4"))
        self.append(b"new\n")
        self.assertEqual(self.read_lines(proc, 1), [b"new\n"])


if __name__ == "__main__":
    unittest.main()
