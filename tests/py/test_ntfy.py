"""The ntfy service against a fake ntfy server: publish, accept a valid reply, reject the rest."""

import importlib.util
import json
import tempfile
import threading
import time
import unittest
from http.server import BaseHTTPRequestHandler, HTTPServer
from pathlib import Path

spec = importlib.util.spec_from_file_location("ntfy", Path(__file__).parents[2] / "container/services/ntfy/ntfy.py")
ntfy = importlib.util.module_from_spec(spec)
spec.loader.exec_module(ntfy)

RID = "1795559057942126550-32781"


class Fake(BaseHTTPRequestHandler):
    log = []  # noqa: RUF012

    def handle_one(self):
        n = int(self.headers.get("Content-Length") or 0)
        Fake.log.append((self.command, self.path, dict(self.headers), self.rfile.read(n).decode()))
        self.send_response(200)
        self.end_headers()
        self.wfile.write(b"{}")

    do_POST = do_DELETE = handle_one

    def log_message(self, *a):
        pass


class NtfyTest(unittest.TestCase):
    def setUp(self):
        Fake.log = []
        self.srv = HTTPServer(("127.0.0.1", 0), Fake)
        threading.Thread(target=self.srv.serve_forever, daemon=True).start()
        self.tmp = Path(tempfile.mkdtemp())
        ntfy.APPROVE = self.tmp
        (self.tmp / "requests").mkdir()
        self.n = ntfy.Notifier(
            {"URL": f"http://127.0.0.1:{self.srv.server_port}", "TOPIC": "t"}, "main-tok", "reply-tok"
        )
        self.req(RID)

    def tearDown(self):
        self.srv.shutdown()

    def req(self, rid):
        body = {"id": rid, "tool": "Bash", "summary": "run it", "input": {"command": "ls\nrm x"}, "since": time.time()}
        (self.tmp / "requests" / f"{rid}.json").write_text(json.dumps(body))

    def reply(self, text, t=None):
        return {"event": "message", "id": text + str(len(Fake.log)), "time": t or int(time.time()), "message": text}

    def nonce(self):
        return self.n.sent[RID][0]

    def test_publish_once_with_actions(self):
        self.n.scan()
        self.n.scan()
        posts = [e for e in Fake.log if e[0] == "POST"]
        self.assertEqual(len(posts), 1)
        _, path, headers, body = posts[0]
        self.assertEqual(path, f"/t/{RID}")
        self.assertEqual(body, "ls\nrm x")
        acts = json.loads(headers["Actions"])
        self.assertEqual(acts[0]["url"], f"{self.n.base}/t-reply")
        self.assertEqual(acts[0]["body"], f"{RID} {self.nonce()} allow")
        self.assertEqual(acts[0]["headers"]["Authorization"], "Bearer reply-tok")

    def test_outbox_pushed_then_kept_in_sent(self):
        ntfy.SVC = self.tmp
        (self.tmp / "outbox").mkdir()
        (self.tmp / "outbox" / "a.json").write_text(json.dumps({"id": "a", "title": "x: 🔺", "body": "disk full"}))
        (self.tmp / "outbox" / "b.json").write_text("{")
        self.n.push_outbox()
        posts = [e for e in Fake.log if e[1] == "/t"]
        self.assertEqual([p[3] for p in posts], ["disk full"])
        self.assertTrue((self.tmp / "outbox" / "sent" / "a.json").exists())
        self.n.last_pub = 0
        self.n.push_outbox()
        self.assertTrue((self.tmp / "outbox" / "b.bad").exists())  # kept, not dropped

    def test_valid_reply_answers_once(self):
        self.n.scan()
        self.assertTrue(self.n.handle(self.reply(f"{RID} {self.nonce()} deny")))
        self.assertEqual((self.tmp / "answers" / RID).read_text(), "deny")
        self.assertIn('"via": "ntfy"', (self.tmp / "journal.jsonl").read_text())
        self.assertFalse(self.n.handle(self.reply(f"{RID} anything allow")))

    def test_rejections(self):
        self.n.scan()
        good = self.nonce()
        self.assertFalse(self.n.handle(self.reply(f"{RID} wrong allow")))
        self.assertFalse(self.n.handle(self.reply(f"1-2 {good} allow")))
        self.assertFalse(self.n.handle(self.reply(f"{RID} {good} allow", t=1)))
        self.assertFalse(self.n.handle(self.reply(f"{RID} {good} maybe")))
        self.assertFalse((self.tmp / "answers" / RID).exists())

    def test_answered_elsewhere_is_rejected_and_cleared(self):
        self.n.scan()
        good = self.nonce()
        (self.tmp / "answers").mkdir()
        (self.tmp / "answers" / RID).write_text("allow")
        self.assertFalse(self.n.handle(self.reply(f"{RID} {good} deny")))
        self.n.scan()
        self.assertEqual(Fake.log[-1][:2], ("DELETE", f"/t/{RID}"))


if __name__ == "__main__":
    unittest.main()
