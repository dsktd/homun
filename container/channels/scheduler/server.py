#!/usr/bin/env python3
"""Channel server of the scheduler: POSTed alarms become Claude Code channel events.

Claude Code starts it over stdio (MCP, newline-delimited JSON-RPC) as the channel `scheduler`.
It listens on 127.0.0.1:$SCHEDULER_CHANNEL_PORT (default 8789) and accepts only
`POST /` with an `X-Channel-Token` header equal to the contents of the token file
($SCHEDULER_CHANNEL_TOKEN, default ~/claude/.services/scheduler/channel-token) and a JSON body
{"alarm","msg"[,"ts"]}. Everything else is refused. Standard library only.
"""

import hmac
import json
import os
import queue
import sys
import threading
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer

MAX_BODY = 16384
INSTRUCTIONS = (
    'Scheduler alarms arrive as <channel source="scheduler" alarm="..." ts="...">message</channel>. '
    "They are one-way: read the message, act on it as the Manager's scheduler instructions say, "
    "no reply is expected."
)


def token_path():
    return os.environ.get("SCHEDULER_CHANNEL_TOKEN") or os.path.expanduser(
        "~/claude/.services/scheduler/channel-token"
    )


def read_token(path):
    try:
        with open(path) as f:
            return f.read().strip()
    except OSError:
        return ""


def event_params(body):
    """The notification params for a request body, or None if it is not a valid alarm."""
    try:
        data = json.loads(body)
    except ValueError:
        return None
    if not isinstance(data, dict):
        return None
    alarm, msg = data.get("alarm"), data.get("msg")
    if not isinstance(alarm, str) or not isinstance(msg, str) or not alarm or not msg:
        return None
    meta = {"alarm": alarm}
    if isinstance(data.get("ts"), int):
        meta["ts"] = str(data["ts"])
    return {"content": msg, "meta": meta}


def make_handler(events, tokfile):
    class Handler(BaseHTTPRequestHandler):
        def log_message(self, *args):
            pass

        def _reply(self, code):
            self.send_response(code)
            self.send_header("Content-Length", "0")
            self.end_headers()

        def do_POST(self):
            token = read_token(tokfile())
            sent = self.headers.get("X-Channel-Token", "")
            # an empty or missing token file refuses everything
            if not token or not hmac.compare_digest(sent.encode(), token.encode()):
                return self._reply(403)
            if self.path != "/":
                return self._reply(404)
            try:
                n = int(self.headers.get("Content-Length", ""))
            except ValueError:
                return self._reply(411)
            if not 0 < n <= MAX_BODY:
                return self._reply(413)
            params = event_params(self.rfile.read(n))
            if params is None:
                return self._reply(400)
            events.put(params)
            self._reply(204)

        def _refuse(self):
            self._reply(405)

        do_GET = do_PUT = do_DELETE = do_PATCH = do_HEAD = _refuse

    return Handler


class Rpc:
    """The stdio side: answers the MCP handshake, then writes queued channel notifications."""

    def __init__(self, stdin, stdout, events):
        self._in, self._out, self._events = stdin, stdout, events
        self._lock = threading.Lock()
        self._ready = threading.Event()

    def send(self, obj):
        with self._lock:
            self._out.write(json.dumps(obj, separators=(",", ":")) + "\n")
            self._out.flush()

    def pump(self):
        """Forward queued events once the client has said it is initialized."""
        self._ready.wait()
        while True:
            self.send(
                {
                    "jsonrpc": "2.0",
                    "method": "notifications/claude/channel",
                    "params": self._events.get(),
                }
            )

    def handle(self, msg):
        method, mid = msg.get("method"), msg.get("id")
        if method == "initialize":
            ver = (msg.get("params") or {}).get("protocolVersion") or "2025-06-18"
            result = {
                "protocolVersion": ver,
                "capabilities": {"experimental": {"claude/channel": {}}},
                "serverInfo": {"name": "scheduler", "version": "0.1.0"},
                "instructions": INSTRUCTIONS,
            }
            self.send({"jsonrpc": "2.0", "id": mid, "result": result})
        elif method == "notifications/initialized":
            self._ready.set()
        elif method == "ping":
            self.send({"jsonrpc": "2.0", "id": mid, "result": {}})
        elif mid is not None:
            self.send(
                {
                    "jsonrpc": "2.0",
                    "id": mid,
                    "error": {"code": -32601, "message": "method not found"},
                }
            )

    def run(self):
        for line in self._in:
            try:
                msg = json.loads(line)
            except ValueError:
                continue
            if isinstance(msg, dict):
                self.handle(msg)


def main():
    port = int(os.environ.get("SCHEDULER_CHANNEL_PORT") or 8789)
    events = queue.Queue()
    httpd = ThreadingHTTPServer(("127.0.0.1", port), make_handler(events, token_path))
    threading.Thread(target=httpd.serve_forever, daemon=True).start()
    rpc = Rpc(sys.stdin, sys.stdout, events)
    threading.Thread(target=rpc.pump, daemon=True).start()
    rpc.run()  # returns when Claude Code closes stdin


if __name__ == "__main__":
    main()
