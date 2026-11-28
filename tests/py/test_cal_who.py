"""bin/claude-cal who against a fake listener in a temp dir."""

# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import json
import os
import socket
import subprocess
import tempfile
import threading
import unittest
from pathlib import Path

BIN = Path(__file__).resolve().parents[2] / "bin/claude-cal"


class Who(unittest.TestCase):
    def run_who(self, d):
        env = {**os.environ, "CAL_CHANNEL_DIR": d}
        return subprocess.run(
            ["python3", str(BIN), "who"],
            check=False,
            env=env,
            capture_output=True,
            text=True,
        )

    def test_nobody(self):
        with tempfile.TemporaryDirectory() as d:
            r = self.run_who(d)
            self.assertEqual(r.returncode, 1)
            self.assertIn("not listening", r.stderr)

    def test_answer(self):
        with tempfile.TemporaryDirectory() as d:
            Path(d, "who").write_text("1\n")
            srv = socket.socket(socket.AF_UNIX)
            srv.bind(os.path.join(d, "sock"))
            srv.listen(1)

            def serve():
                c, _ = srv.accept()
                got = c.makefile("rb").read()
                c.sendall(
                    json.dumps(
                        {"role": "manager", "name": "Example", "got": got.decode()}
                    ).encode()
                    + b"\n"
                )
                c.close()

            t = threading.Thread(target=serve)
            t.start()
            r = self.run_who(d)
            t.join()
            self.assertEqual(r.returncode, 0)
            j = json.loads(r.stdout)
            self.assertEqual(j["name"], "Example")
            self.assertEqual(j["got"], "WHO\n")


if __name__ == "__main__":
    unittest.main()
