"""Tests of the scheduler channel: serve.py's Channel push and container/channels/scheduler/server.py."""

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
chan = load("scheduler_channel_server", "container/channels/scheduler/server.py")


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


class ServerTest(unittest.TestCase):
    def setUp(self):
        self.tmp = Path(self.enterContext(tempfile.TemporaryDirectory()))
        self.tok = self.tmp / "tok"
        self.tok.write_text("good\n")
        self.events = queue.Queue()
        self.httpd = ThreadingHTTPServer(
            ("127.0.0.1", 0), chan.make_handler(self.events, lambda: str(self.tok))
        )
        threading.Thread(target=self.httpd.serve_forever, daemon=True).start()
        self.addCleanup(self.httpd.server_close)
        self.addCleanup(self.httpd.shutdown)

    def call(self, method="POST", token="good", body=None, path="/"):
        data = (
            body
            if body is not None
            else json.dumps({"alarm": "a", "msg": "m", "ts": 3}).encode()
        )
        req = urllib.request.Request(
            f"http://127.0.0.1:{self.httpd.server_port}{path}",
            data=data if method == "POST" else None,
            method=method,
        )
        if token is not None:
            req.add_header("X-Channel-Token", token)
        try:
            with urllib.request.urlopen(req, timeout=3) as r:
                return r.status
        except urllib.error.HTTPError as e:
            return e.code

    def test_valid_post_queues_event(self):
        self.assertEqual(self.call(), 204)
        self.assertEqual(
            self.events.get_nowait(),
            {"content": "m", "meta": {"alarm": "a", "ts": "3"}},
        )

    def test_wrong_or_missing_token_refused(self):
        self.assertEqual(self.call(token="bad"), 403)
        self.assertEqual(self.call(token=None), 403)
        self.assertTrue(self.events.empty())

    def test_missing_token_file_refuses_everything(self):
        self.tok.unlink()
        self.assertEqual(self.call(token=""), 403)

    def test_other_methods_paths_and_bodies_refused(self):
        self.assertEqual(self.call(method="GET"), 405)
        self.assertEqual(self.call(path="/x"), 404)
        self.assertEqual(self.call(body=b"not json"), 400)
        self.assertEqual(self.call(body=b'{"alarm":"a"}'), 400)
        self.assertEqual(self.call(body=b"x" * 20000), 413)
        self.assertTrue(self.events.empty())


class RpcTest(unittest.TestCase):
    def test_handshake_then_notification(self):
        lines = [
            {
                "jsonrpc": "2.0",
                "id": 1,
                "method": "initialize",
                "params": {"protocolVersion": "2025-06-18"},
            },
            {"jsonrpc": "2.0", "method": "notifications/initialized"},
        ]
        out = io.StringIO()
        events = queue.Queue()
        rpc = chan.Rpc(
            io.StringIO("".join(json.dumps(x) + "\n" for x in lines)), out, events
        )
        rpc.run()
        events.put({"content": "m", "meta": {"alarm": "a"}})
        threading.Thread(target=rpc.pump, daemon=True).start()
        for _ in range(100):
            if out.getvalue().count("\n") >= 2:
                break
            threading.Event().wait(0.05)
        first, second = (json.loads(x) for x in out.getvalue().splitlines()[:2])
        self.assertEqual(
            first["result"]["capabilities"], {"experimental": {"claude/channel": {}}}
        )
        self.assertIn("instructions", first["result"])
        self.assertEqual(second["method"], "notifications/claude/channel")
        self.assertEqual(second["params"]["content"], "m")


if __name__ == "__main__":
    unittest.main()
