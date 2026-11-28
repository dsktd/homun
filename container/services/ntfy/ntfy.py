"""Pending approvals to the phone through ntfy, and the taps back as answers.

One notification per pending request in approve/requests, with Allow / Deny actions that POST
"<id> <nonce> allow|deny" to the reply topic. A reply is accepted only for a still pending id, with
that request's nonce, newer than its notification; the answer is then written as the remote
cockpit does (answers/<id> by rename, one journal line). Nothing secret is logged.
"""

import json
import os
import re
import secrets
import sys
import time
import urllib.request
from pathlib import Path

SVC = Path(os.environ.get("NTFY_DIR", Path.home() / "claude/.services/ntfy"))
APPROVE = Path(os.environ.get("APPROVE_DIR", Path.home() / "claude/.services/approve"))
ID = re.compile(r"\A[0-9]+-[0-9]+\Z")
MIN_GAP = 2.0  # seconds between publishes


def log(*a):
    print(time.strftime("%FT%T"), *a, flush=True)


def read_conf(path):
    out = {}
    for line in path.read_text().splitlines():
        k, _, v = line.partition("=")
        if k.strip() and not line.lstrip().startswith("#"):
            out[k.strip()] = v.strip().strip("\"'")
    return out


def ascii_header(s):
    return " ".join(s.split()).encode("ascii", "replace").decode()[:200]


def summary(req):
    """Title and a short body for a request: the action, then the first lines of its content."""
    inp = req.get("input") or {}
    title = ascii_header(f"{req.get('tool', '?')}: {req.get('summary', '')}")[:80]
    text = inp.get("command") or inp.get("content") or inp.get("new_string") or inp.get("file_path")
    if not isinstance(text, str):
        text = json.dumps(inp)
    lines = [ln for ln in text.splitlines() if ln.strip()][:5]
    return title, "\n".join(ln[:120] for ln in lines)[:500]


class Notifier:
    def __init__(self, conf, token, reply_token, clock=time.time):
        self.base = conf["URL"].rstrip("/")
        self.topic = conf["TOPIC"]
        self.reply = self.topic + "-reply"
        self.token = token
        self.reply_token = reply_token or token
        self.clock = clock
        self.sent = {}  # id -> (nonce, notified time)
        self.seen = set()  # reply message ids handled
        self.last_pub = 0.0

    def call(self, method, path, body=b"", headers=None, timeout=15):
        h = {"Authorization": "Bearer " + self.token, **(headers or {})}
        req = urllib.request.Request(self.base + path, body, h, method=method)
        return urllib.request.urlopen(req, timeout=timeout)

    def pending(self):
        out = {}
        for f in (APPROVE / "requests").glob("*.json"):
            try:
                req = json.loads(f.read_text())
            except (OSError, ValueError):
                continue
            rid = req.get("id")
            if not isinstance(rid, str) or not ID.match(rid) or f.stem != rid:
                continue
            if (APPROVE / "answers" / rid).exists():
                continue
            if self.clock() > req.get("since", 0) + req.get("timeout", 60) + 15:
                continue
            out[rid] = req
        return out

    def publish(self, rid, req):
        nonce = secrets.token_urlsafe(12)
        title, body = summary(req)
        act = [
            {
                "action": "http",
                "label": label,
                "url": f"{self.base}/{self.reply}",
                "method": "POST",
                "headers": {"Authorization": "Bearer " + self.reply_token},
                "body": f"{rid} {nonce} {verdict}",
                "clear": True,
            }
            for label, verdict in (("Allow", "allow"), ("Deny", "deny"))
        ]
        self.call(
            "POST",
            f"/{self.topic}/{rid}",
            body.encode() or b"-",
            {"Title": title, "Priority": "high", "Actions": json.dumps(act)},
        )
        self.sent[rid] = (nonce, self.clock())
        self.last_pub = time.monotonic()
        log("notified", rid)

    def clear(self, rid):
        self.sent.pop(rid, None)
        try:
            self.call("DELETE", f"/{self.topic}/{rid}")
        except OSError as e:
            log("clear failed", rid, type(e).__name__)
        log("cleared", rid)

    def scan(self):
        """One pass: notify new pending requests (rate limited), clear finished ones."""
        pend = self.pending()
        for rid in [r for r in list(self.sent) if r not in pend]:
            self.clear(rid)
        for rid, req in pend.items():
            if rid in self.sent:
                continue
            if time.monotonic() - self.last_pub < MIN_GAP:
                break
            try:
                self.publish(rid, req)
            except OSError as e:
                log("publish failed", rid, type(e).__name__)
                self.last_pub = time.monotonic()

    def push_outbox(self):
        """Publish each outbox file (an alarm the attention ladder wants pushed); keep a file
        that failed for the next pass, move a sent one to outbox/sent/."""
        for f in sorted((SVC / "outbox").glob("*.json")):
            if time.monotonic() - self.last_pub < MIN_GAP:
                return
            try:
                item = json.loads(f.read_text())
                self.call(
                    "POST",
                    f"/{self.topic}",
                    str(item.get("body") or "-").encode()[:500],
                    {"Title": ascii_header(str(item.get("title", "homun")))[:80], "Priority": "high"},
                )
            except ValueError:
                f.rename(f.with_suffix(".bad"))  # kept, never retried
                log("outbox: unreadable", f.name)
                continue
            except OSError as e:
                log("outbox: publish failed", f.name, type(e).__name__)
                self.last_pub = time.monotonic()
                return
            self.last_pub = time.monotonic()
            (SVC / "outbox" / "sent").mkdir(exist_ok=True)
            f.rename(SVC / "outbox" / "sent" / f.name)
            log("pushed", f.stem)

    def handle(self, msg):
        """One reply-topic message; True when it became an answer."""
        mid = msg.get("id")
        if msg.get("event") != "message" or mid in self.seen:
            return False
        self.seen.add(mid)
        parts = str(msg.get("message", "")).split()
        if len(parts) != 3 or parts[2] not in ("allow", "deny"):
            log("ignored: malformed reply", mid)
            return False
        rid, nonce, verdict = parts
        mine = self.sent.get(rid)
        if not mine or rid not in self.pending():
            log("ignored: not pending", mid)
            return False
        if not secrets.compare_digest(mine[0], nonce) or msg.get("time", 0) < int(mine[1]):
            log("ignored: bad nonce or stale", mid)
            return False
        self.sent.pop(rid)  # the nonce is spent
        self.answer(rid, verdict)
        return True

    def answer(self, rid, verdict):
        d = APPROVE / "answers"
        d.mkdir(parents=True, exist_ok=True)
        tmp = d / (rid + ".tmp")
        tmp.write_text(verdict)
        tmp.rename(d / rid)
        line = {"time": time.strftime("%FT%TZ", time.gmtime()), "id": rid, "answer": verdict, "via": "ntfy"}
        with open(APPROVE / "journal.jsonl", "a") as f:
            f.write(json.dumps(line) + "\n")
        log("answered", rid, verdict)
        try:
            self.call("DELETE", f"/{self.topic}/{rid}")
        except OSError:
            pass

    def listen(self):
        """Follow the reply topic's JSON stream, forever, reconnecting with backoff."""
        delay = 1
        since = int(self.clock())  # replays after a reconnect are deduplicated by id
        while True:
            try:
                with self.call("GET", f"/{self.reply}/json?since={since}", timeout=120) as r:
                    delay = 1
                    for line in r:
                        try:
                            self.handle(json.loads(line))
                        except ValueError:
                            pass
            except OSError as e:
                log("reply stream down", type(e).__name__)
            time.sleep(delay)
            delay = min(delay * 2, 60)


def main():
    import threading

    conf = read_conf(SVC / "conf")
    token = (SVC / "token").read_text().strip()
    rt = SVC / "reply-token"
    n = Notifier(conf, token, rt.read_text().strip() if rt.exists() else None)
    threading.Thread(target=n.listen, daemon=True).start()
    log("started", conf["TOPIC"])
    while True:
        n.scan()
        n.push_outbox()
        time.sleep(1)


if __name__ == "__main__":
    sys.exit(main())
