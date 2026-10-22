"""container/services/status/serve.py: the Mechanic section and POST /mechanic/run."""

import importlib.util
import json
import os
import sys
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import ThreadingHTTPServer
from pathlib import Path

SERVE = Path(__file__).resolve().parents[2] / "container/services/status/serve.py"


class StatusMechanicTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.dir = Path(tmp.name)
        (self.dir / "mechanic").mkdir()
        fake = self.dir / "mech"
        fake.write_text(f'#!/bin/sh\necho "$@" >{self.dir}/args\n')
        fake.chmod(0o755)
        old = (dict(os.environ), sys.argv)
        os.environ.update(CLAUDE_SERVICES_DIR=str(self.dir), STATUS_MECHANIC=str(fake))
        sys.argv = ["serve.py"]
        spec = importlib.util.spec_from_file_location("status_serve", SERVE)
        self.mod = importlib.util.module_from_spec(spec)
        spec.loader.exec_module(self.mod)
        os.environ.clear()
        os.environ.update(old[0])
        sys.argv = old[1]
        self.srv = ThreadingHTTPServer(("127.0.0.1", 0), self.mod.Handler)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.addCleanup(self.srv.server_close)
        self.addCleanup(self.srv.shutdown)
        self.base = f"http://127.0.0.1:{self.srv.server_port}"

    def test_no_runs(self):
        self.assertIsNone(self.mod.mechanic())
        self.assertIn("No runs yet", self.mod.r_mechanic(None, 0))

    def test_counts_only(self):
        row = {
            "ts": 1000,
            "findings": 3,
            "checks": {"disk": 1, "logs": 2},
            "msg": "SECRET",
        }
        (self.dir / "mechanic" / "runs.jsonl").write_text(json.dumps(row) + "\n")
        m = self.mod.mechanic()
        self.assertEqual(
            m, {"ts": 1000, "findings": 3, "checks": {"disk": 1, "logs": 2}}
        )
        html = self.mod.r_mechanic(m, 1090)
        self.assertIn("3 findings", html)
        self.assertIn("disk 1, logs 2", html)
        self.assertIn("1m ago", html)
        self.assertNotIn("SECRET", html + json.dumps(m))

    def test_post_needs_header(self):
        req = urllib.request.Request(self.base + "/mechanic/run", method="POST")
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.urlopen(req)
        self.assertEqual(cm.exception.code, 400)
        self.assertFalse((self.dir / "args").exists())

    def test_post_runs_mechanic(self):
        class NoRedirect(urllib.request.HTTPRedirectHandler):
            def redirect_request(self, *a, **k):
                return None

        req = urllib.request.Request(
            self.base + "/mechanic/run", method="POST", headers={"X-Run": "1"}
        )
        with self.assertRaises(urllib.error.HTTPError) as cm:
            urllib.request.build_opener(NoRedirect).open(req)
        self.assertEqual(cm.exception.code, 303)
        self.assertEqual(cm.exception.headers["Location"], "../")
        for _ in range(50):
            if (self.dir / "args").exists() and (self.dir / "args").read_text():
                break
            threading.Event().wait(0.1)
        self.assertEqual((self.dir / "args").read_text().strip(), "--notify")


if __name__ == "__main__":
    unittest.main()
