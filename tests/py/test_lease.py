# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

TOOL = Path(__file__).resolve().parents[2] / "bin/homun-lease-legacy"


class LeaseTest(unittest.TestCase):
    def setUp(self):
        self.dir = tempfile.TemporaryDirectory()
        self.file = Path(self.dir.name) / "lease"
        self.addCleanup(self.dir.cleanup)

    def run_tool(self, *args):
        env = {**os.environ, "LEASE_FILE": str(self.file)}
        return subprocess.run([sys.executable, str(TOOL), *args], capture_output=True, text=True, env=env, check=False)

    def write(self, holder, age):
        self.file.write_text(json.dumps({"holder": holder, "since": int(time.time()) - age, "scope": "x"}))

    def test_take_creates(self):
        self.assertEqual(self.run_tool("take", "manager", "edit").returncode, 0)
        lease = json.loads(self.file.read_text())
        self.assertEqual((lease["holder"], lease["scope"]), ("manager", "edit"))

    def test_take_conflict(self):
        self.write("intake", 60)
        r = self.run_tool("take", "manager", "edit")
        self.assertEqual(r.returncode, 1)
        self.assertIn("intake", r.stderr)
        self.assertEqual(json.loads(self.file.read_text())["holder"], "intake")

    def test_wait_times_out(self):
        self.write("intake", 60)
        t = time.time()
        self.assertEqual(self.run_tool("take", "manager", "edit", "wait", "1").returncode, 1)
        self.assertGreaterEqual(time.time() - t, 0.9)

    def test_wait_gets_it_after_release(self):
        self.write("intake", 60)
        p = subprocess.Popen(
            [sys.executable, str(TOOL), "take", "manager", "e", "wait", "10"],
            env={**os.environ, "LEASE_FILE": str(self.file)},
        )
        time.sleep(0.5)
        self.assertEqual(self.run_tool("release", "intake").returncode, 0)
        self.assertEqual(p.wait(15), 0)
        self.assertEqual(json.loads(self.file.read_text())["holder"], "manager")

    def test_release_by_other_refused(self):
        self.write("intake", 60)
        r = self.run_tool("release", "manager")
        self.assertEqual(r.returncode, 1)
        self.assertIn("intake", r.stderr)
        self.assertTrue(self.file.exists())

    def test_release_own(self):
        self.run_tool("take", "manager", "e")
        self.assertEqual(self.run_tool("release", "manager").returncode, 0)
        self.assertFalse(self.file.exists())

    def test_stale_is_void(self):
        self.write("intake", 8000)
        self.assertEqual(self.run_tool("take", "manager", "e").returncode, 0)
        self.assertEqual(json.loads(self.file.read_text())["holder"], "manager")

    def test_old_with_fresh_heartbeat_holds(self):
        self.write("mechanic", 8000)
        (self.file.parent / "heartbeat").write_text("")
        self.assertEqual(self.run_tool("take", "manager", "e").returncode, 1)

    def test_tally_alive_by_manager_heartbeat(self):
        mgr = Path(self.dir.name) / "manager"
        mgr.mkdir()
        (mgr / "heartbeat").write_text("")
        self.write("manager", 8000)
        env = {**os.environ, "LEASE_FILE": str(self.file), "MANAGER_DIR": str(mgr)}
        r = subprocess.run([sys.executable, str(TOOL), "take", "intake", "e"], capture_output=True, text=True, env=env)
        self.assertEqual(r.returncode, 1)

    def test_unknown_holder_refused(self):
        r = self.run_tool("take", "tally", "e")
        self.assertEqual(r.returncode, 2)
        self.assertFalse(self.file.exists())


if __name__ == "__main__":
    unittest.main()
