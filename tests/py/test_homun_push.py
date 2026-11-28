"""container/homun-push: one interrupt alarm in the user's bus inbox, with the optional url."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import subprocess
import tempfile
import unittest
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]
PUSH = ROOT / "container/homun-push"


def push(bus, *args):
    # homun-push calls homun-msg by name: a shim directory puts the repo's on PATH
    with tempfile.TemporaryDirectory() as shim:
        Path(shim, "homun-msg").write_text(
            f'#!/bin/sh\nexec env HOMUN_MSG_LEGACY=1 sh {ROOT}/container/homun-msg "$@"\n'
        )
        os.chmod(Path(shim, "homun-msg"), 0o755)
        env = {
            **os.environ,
            "LC_ALL": "C.UTF-8",
            "HOMUN_BUS": bus,
            "PATH": f"{shim}:{os.environ['PATH']}",
        }
        return subprocess.run(
            ["sh", str(PUSH), *args],
            env=env,
            capture_output=True,
            text=True,
            check=False,
        )


class PushTest(unittest.TestCase):
    def test_message_and_url(self):
        with tempfile.TemporaryDirectory() as bus:
            self.assertEqual(
                push(bus, "digest ready", "https://x.test/a").returncode, 0
            )
            m = json.loads((Path(bus) / "user/inbox.jsonl").read_text())
            self.assertEqual(m["alarm"], "push")
            # the legacy shell bus door (used here) blanks non-ASCII; homund keeps the marker
            self.assertTrue(m["msg"].endswith(" digest ready https://x.test/a"))
            self.assertIn('text="🔺 $1"', PUSH.read_text())

    def test_usage(self):
        with tempfile.TemporaryDirectory() as bus:
            self.assertEqual(push(bus).returncode, 2)


if __name__ == "__main__":
    unittest.main()
