"""Tests of the scheduler channel: serve.py's Channel push."""

import contextlib
import importlib.util
import io
import json
import queue
import tempfile
import threading
import unittest
import urllib.error
import urllib.request
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2]


def load(name, rel):
    spec = importlib.util.spec_from_file_location(name, ROOT / rel)
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


serve = load("scheduler_serve", "container/services/scheduler/serve.py")


class Fake(ThreadingHTTPServer):
    """Records the requests it gets and answers with `status`."""

    def __init__(self, status=204):
        class H(BaseHTTPRequestHandler):
            def log_message(self, *a):
                pass

            def do_POST(h):
                n = int(h.headers["Content-Length"])
                self.seen.append(
                    (h.headers["X-Channel-Token"], json.loads(h.rfile.read(n)))
                )
                h.send_response(self.status)
                h.send_header("Content-Length", "0")
                h.end_headers()

        super().__init__(("127.0.0.1", 0), H)
        self.status, self.seen = status, []
        threading.Thread(target=self.serve_forever, daemon=True).start()

    def close(self):
        self.shutdown()
        self.server_close()


class PushTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.out = self.enterContext(contextlib.redirect_stdout(io.StringIO()))
        self.tok = self.tmp / "channel-token"

    def fake(self, status=204):
        f = Fake(status)
        self.addCleanup(f.close)
        return f

    def test_pushes_event_with_token(self):
        f = self.fake()
        self.tok.write_text("s3cret\n")
        serve.Channel(str(self.tok), f.server_port).push(5, "daily", "hi")
        self.assertEqual(f.seen, [("s3cret", {"ts": 5, "alarm": "daily", "msg": "hi"})])

    def test_no_token_file_no_request(self):
        f = self.fake()
        serve.Channel(str(self.tok), f.server_port).push(5, "daily", "hi")
        self.assertEqual(f.seen, [])

    def test_failure_is_logged_once_and_never_raises(self):
        self.tok.write_text("t")
        ch = serve.Channel(str(self.tok), 1)  # nothing listens on port 1
        ch.push(1, "a", "m")
        ch.push(2, "a", "m")
        self.assertEqual(self.out.getvalue().count("channel push failed"), 1)

    def test_rejection_status_counts_as_failure(self):
        f = self.fake(403)
        self.tok.write_text("t")
        serve.Channel(str(self.tok), f.server_port).push(1, "a", "m")
        self.assertIn("channel push failed", self.out.getvalue())

    def test_ledger_writes_events_line_and_pushes(self):
        f = self.fake()
        self.tok.write_text("t")
        ledger = serve.Ledger(
            str(self.tmp / "events"),
            str(self.tmp / "h"),
            str(self.tmp / "no.sqlite"),
            serve.Channel(str(self.tok), f.server_port),
        )
        ledger.record(7, "x", "y", False, 1, False)
        self.assertEqual(len((self.tmp / "events").read_text().splitlines()), 1)
        self.assertEqual(f.seen[0][1]["alarm"], "x")

    def test_ledger_survives_dead_channel(self):
        self.tok.write_text("t")
        ledger = serve.Ledger(
            str(self.tmp / "events"),
            str(self.tmp / "h"),
            str(self.tmp / "no.sqlite"),
            serve.Channel(str(self.tok), 1),
        )
        ledger.record(7, "x", "y", False, 1, False)
        self.assertTrue((self.tmp / "h").exists())
