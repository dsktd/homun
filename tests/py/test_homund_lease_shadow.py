"""Shadow test of `homund lease` against bin/homun-lease-legacy: the same files, output and exit
codes, and a race of separate processes that leaves exactly one holder."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import re
import subprocess
import sys
import tempfile
import time
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
OLD = [sys.executable, str(ROOT / "bin/homun-lease-legacy")]
HOMUND = os.environ.get("HOMUND") or str(ROOT / "core/homund/target/debug/homund")
NEW = [HOMUND, "lease"]


@unittest.skipUnless(Path(HOMUND).exists(), "homund is not built")
class LeaseShadowTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.file = Path(tmp.name) / "lease"
        self.env = {
            **os.environ,
            "LEASE_FILE": str(self.file),
            "MANAGER_DIR": str(Path(tmp.name) / "manager"),
            "HOMUN_ROLES": str(ROOT / "roles/roles.toml"),
        }

    def run_tool(self, tool, *args):
        r = subprocess.run(
            [*tool, *args], capture_output=True, text=True, env=self.env, check=False
        )
        return r.returncode, r.stdout, r.stderr

    def seen(self, tool, steps):
        self.file.unlink(missing_ok=True)
        out = []
        for step in steps:
            if step[0] == "write":
                self.file.write_text(
                    json.dumps(
                        {
                            "holder": step[1],
                            "since": int(time.time()) - step[2],
                            "scope": "x",
                        }
                    )
                )
                continue
            rc, stdout, stderr = self.run_tool(tool, *step)
            out.append(
                (
                    rc,
                    (
                        stdout.replace('"age": 0', '"age": 1')
                        if step[0] == "show"
                        else stdout
                    ),
                    stderr,
                )
            )
        return out, json.loads(self.file.read_text()) if self.file.exists() else None

    def test_same_behaviour(self):
        cases = [
            [
                ("show",),
                ("take", "manager", "edit"),
                ("show",),
                ("take", "mechanic", "e"),
                ("release", "mechanic"),
            ],
            [
                ("take", "manager", "a"),
                ("take", "manager", "b"),
                ("release", "manager"),
                ("release", "manager"),
            ],
            [("take", "nobody", "x")],
            [("take", "manager")],
            [("write", "mechanic", 60), ("take", "manager", "e", "wait", "1")],
            [("write", "mechanic", 9000), ("take", "manager", "e")],
            [("bogus",), ("help",)],
        ]
        for steps in cases:
            old, new = self.seen(OLD, steps), self.seen(NEW, steps)
            for a, b in zip(old[0], new[0], strict=True):
                self.assertEqual(a[0], b[0], steps)
                self.assertEqual(a[1].split("{")[0], b[1].split("{")[0], steps)
                self.assertEqual(
                    re.sub(r"for \d+s", "for Ns", a[2]),
                    re.sub(r"for \d+s", "for Ns", b[2]),
                    steps,
                )
            self.assertEqual(
                old[1] and (old[1]["holder"], old[1]["scope"]),
                new[1] and (new[1]["holder"], new[1]["scope"]),
                steps,
            )

    def test_process_race_has_one_winner(self):
        holders = ["manager", "mechanic", "auditor", "coach", "digest", "intake"]
        procs = [
            subprocess.Popen(
                [*NEW, "take", h, "r"], env=self.env, stderr=subprocess.DEVNULL
            )
            for h in holders
        ]
        wins = [h for h, p in zip(holders, procs, strict=True) if p.wait(30) == 0]
        self.assertEqual(len(wins), 1)
        self.assertEqual(json.loads(self.file.read_text())["holder"], wins[0])


if __name__ == "__main__":
    unittest.main()
