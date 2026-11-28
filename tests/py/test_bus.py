"""Tests of container/homun-msg: concurrent writers leave no torn lines; rotation at 1 MiB."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

SCRIPT = Path(__file__).resolve().parents[2] / "container/homun-msg"


def run(bus, *args, role="writer"):
    env = {**os.environ, "HOMUN_BUS": bus, "HOMUN_ROLE": role}
    return subprocess.Popen(["sh", str(SCRIPT), *args], env=env, stderr=subprocess.PIPE)


class BusTest(unittest.TestCase):
    def test_concurrent_writers(self):
        with tempfile.TemporaryDirectory() as bus:
            procs = [
                run(bus, "send", "mgr", "worker", f"m{i} " + "x" * 400)
                for i in range(50)
            ]
            for p in procs:
                self.assertEqual(p.wait(), 0)
            lines = (Path(bus) / "mgr/inbox.jsonl").read_text().splitlines()
            self.assertEqual(len(lines), 50)
            got = [json.loads(line) for line in lines]
            self.assertEqual(
                {g["msg"].split()[0] for g in got}, {f"m{i}" for i in range(50)}
            )
            self.assertEqual({g["from"] for g in got}, {"writer"})
            self.assertEqual(len({g["id"] for g in got}), 50)

    def test_clamps_and_usage(self):
        with tempfile.TemporaryDirectory() as bus:
            self.assertEqual(run(bus, "send", "mgr", "a", "y" * 900 + "\n\t").wait(), 0)
            msg = json.loads((Path(bus) / "mgr/inbox.jsonl").read_text())["msg"]
            self.assertEqual(len(msg), 500)
            self.assertEqual(run(bus, "send", "mgr").wait(), 2)
            self.assertEqual(run(bus, "send", "../x", "a", "m").wait(), 2)

    def test_rotation(self):
        with tempfile.TemporaryDirectory() as bus:
            d = Path(bus) / "mgr"
            d.mkdir()
            (d / "inbox.jsonl").write_text("x" * 1048576 + "\n")
            self.assertEqual(run(bus, "send", "mgr", "a", "fresh").wait(), 0)
            self.assertEqual(len((d / "inbox.jsonl").read_text().splitlines()), 1)
            self.assertEqual(len(list(d.glob("inbox.2*.jsonl"))), 1)


if __name__ == "__main__":
    unittest.main()
