# First: the bus goes to a temp dir (tests/py/isolate.py).
import isolate  # noqa: F401, I001
import http.client
import importlib.machinery
import importlib.util
import json
import os
import sys
import tempfile
import threading
import time
import unittest
from http.server import ThreadingHTTPServer
from pathlib import Path

ROOT = Path(__file__).resolve().parents[2] / "container"
TOKEN = "T" * 32
SIZE = 6 * 1024 * 1024


def load_gateway(shares):
    # The service runs from its own directory (python3 -E -s), where "import progress" resolves
    sys.path.insert(0, str(ROOT / "services/send"))
    os.environ["SHARES_DIR"] = str(shares)
    spec = importlib.util.spec_from_file_location(
        "send_gateway", ROOT / "services/send/gateway.py"
    )
    mod = importlib.util.module_from_spec(spec)
    spec.loader.exec_module(mod)
    return mod


def load_tool():
    loader = importlib.machinery.SourceFileLoader(
        "claude_send", str(ROOT / "claude-send")
    )
    spec = importlib.util.spec_from_loader("claude_send", loader)
    mod = importlib.util.module_from_spec(spec)
    loader.exec_module(mod)
    return mod


class GatewayTest(unittest.TestCase):
    def setUp(self):
        tmp = tempfile.TemporaryDirectory()
        self.addCleanup(tmp.cleanup)
        self.tmp = Path(tmp.name)
        self.gw = load_gateway(self.tmp / "shares")
        self.data = os.urandom(SIZE)
        (self.tmp / "f.bin").write_bytes(self.data)
        self.dir = self.tmp / "shares" / "send-1"
        self.dir.mkdir(parents=True)
        self.meta("confirm")
        self.server = ThreadingHTTPServer(("127.0.0.1", 0), self.gw.Handler)
        self.server.daemon_threads = True
        threading.Thread(target=self.server.serve_forever, daemon=True).start()
        self.addCleanup(self.server.server_close)
        self.addCleanup(self.server.shutdown)

    def meta(self, mode):
        meta = {
            "path": str(self.tmp / "f.bin"),
            "name": "f.bin",
            "size": SIZE,
            "sha256": "0" * 64,
            "token": TOKEN,
            "started": int(time.time()),
            "expires": int(time.time()) + 3600,
            "mode": mode,
        }
        (self.dir / "meta.json").write_text(json.dumps(meta))

    def state(self):
        return json.loads((self.dir / "state.json").read_text())

    def put_state(self, **kw):
        st = {"state": "ready", "sent": 0, "attempts": 0, "completions": 0}
        st.update(kw)
        (self.dir / "state.json").write_text(json.dumps(st))

    def get(self, rng=None, read=None):
        c = http.client.HTTPConnection("127.0.0.1", self.server.server_port, timeout=10)
        headers = {"Host": "file.share.dsktd.net"}
        if rng:
            headers["Range"] = rng
        c.request("GET", f"/{TOKEN}/file", headers=headers)
        r = c.getresponse()
        body = r.read(read) if read is not None else r.read()
        if read is not None:
            c.close()
        return r.status, body

    def wait_idle(self):
        for _ in range(100):
            if self.state()["state"] != "downloading":
                return
            time.sleep(0.1)
        self.fail("request never finished")

    def test_resume_after_drop_keeps_attempts(self):
        status, part = self.get(read=1000)
        self.assertEqual(status, 200)
        self.assertEqual(part, self.data[:1000])
        self.wait_idle()
        st = self.state()
        self.assertEqual(
            (st["state"], st["attempts"], st["completions"]), ("ready", 1, 0)
        )
        status, rest = self.get(rng="bytes=1000-")
        self.assertEqual(status, 206)
        self.assertEqual(rest, self.data[1000:])
        self.wait_idle()
        st = self.state()
        self.assertEqual((st["attempts"], st["completions"], st["sent"]), (1, 1, SIZE))
        self.assertEqual(st["state"], "done")

    def test_fresh_request_counts_attempt(self):
        self.get(read=10)
        self.wait_idle()
        self.get(read=10)
        self.wait_idle()
        self.assertEqual(self.state()["attempts"], 2)

    def test_active_download_blocks_second_request(self):
        self.put_state(state="downloading", attempts=1, progress=time.time())
        self.assertEqual(self.get(rng="bytes=5-")[0], 404)

    def test_stale_download_is_taken_over(self):
        self.put_state(
            state="downloading", attempts=1, sent=500, progress=time.time() - 60
        )
        status, rest = self.get(rng="bytes=500-")
        self.assertEqual(status, 206)
        self.assertEqual(rest, self.data[500:])
        self.wait_idle()
        st = self.state()
        self.assertEqual((st["attempts"], st["completions"]), (1, 1))

    def test_bytes_mode_closes_on_resumed_end(self):
        self.meta("bytes")
        self.get(read=100)
        self.wait_idle()
        self.get(rng="bytes=100-")
        self.wait_idle()
        st = self.state()
        self.assertEqual((st["state"], st["reason"]), ("gone", "all bytes sent"))

    def test_attempts_used_up_refuses_fresh_request(self):
        self.put_state(attempts=3)
        self.assertEqual(self.get()[0], 404)


class ToolTest(unittest.TestCase):
    def setUp(self):
        self.tool = load_tool()

    def test_detach_keyword(self):
        self.assertTrue(self.tool.parse(["a", "detach"], tty=True)[4])

    def test_default_follows_tty(self):
        self.assertFalse(self.tool.parse(["a"], tty=True)[4])
        self.assertTrue(self.tool.parse(["a"], tty=False)[4])

    def test_wait_forces_foreground(self):
        self.assertFalse(self.tool.parse(["a", "wait"], tty=False)[4])

    def test_options_still_parse(self):
        path, dur, mode, force, _ = self.tool.parse(
            ["a", "for", "2h", "close", "bytes", "force", "detach"], tty=True
        )
        self.assertEqual((path, dur, mode, force), ("a", 7200, "bytes", True))

    def test_stop_writes_closed_marker(self):
        with tempfile.TemporaryDirectory() as t:
            self.tool.SHARES = Path(t)
            d = Path(t) / "send-x"
            d.mkdir()
            (d / "meta.json").write_text("{}")
            self.tool.stop("x")
            self.assertEqual((d / "closed").read_text(), "stopped by the sender\n")
            with self.assertRaises(self.tool.SendError):
                self.tool.stop("nope")


if __name__ == "__main__":
    unittest.main()
