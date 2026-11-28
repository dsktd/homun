"""One-time file sends: the gateway behind the file share host (file.share.dsktd.net).

Serves each registered send (a directory ~/claude/.services/shares/send-<id>/ written by
claude-send) at /<token>: a small page, /<token>/file and /<token>/<anything> (the file
streamed from its original path; the last segment is cosmetic so curl -O and wget save under
the right name; one range is honoured so curl -C - and wget -c resume) and POST /<token>/done (the receiver's "I have it"). Everything else is
the same 404. A request for any Host but the file host's name (the LAN proxy at /send/) gets only
the read-only progress page (progress.py). Reachable from the internet through the edge (Caddy) and the relay box's tunnel, so it stays small:
standard library only, bounded connections, short timeouts, no listing, no other methods.
"""

import hmac
import html
import json
import os
import re
import secrets
import sys
import threading
import time
import urllib.parse
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from pathlib import Path

import progress

SHARES = Path(os.environ.get("SHARES_DIR", Path.home() / "claude/.services/shares"))
PORT = int(os.environ.get("PORT", "8433"))
MAX_CONNECTIONS = 16
MAX_ATTEMPTS = 3
STALE = 30  # seconds without a byte before a "downloading" request may be taken over
GRACE = 600
BLOB_LIMIT = 200 * 1024 * 1024
CHUNK = 256 * 1024
TOKEN = re.compile(r"^/([A-Za-z0-9_-]{32})(/file|/done|/[^/]+)?$")
RANGE = re.compile(r"^bytes=(\d*)-(\d*)$")
NAMES_FILE = SHARES.parent / "edge/names"
DEFAULT_HOST = "file.share.dsktd.net"
NOT_FOUND = b"not found\n"
SAMPLER = progress.Sampler()


class Send:
    """One registered send: meta.json from claude-send, state.json owned by the gateway."""

    lock = threading.Lock()

    def __init__(self, d):
        self.dir = d
        self.meta = json.loads((d / "meta.json").read_text())

    def state(self):
        try:
            return json.loads((self.dir / "state.json").read_text())
        except (OSError, ValueError):
            return {"state": "ready", "sent": 0, "attempts": 0, "completions": 0}

    def save(self, st):
        tmp = self.dir / "state.json.new"
        fd = os.open(tmp, os.O_WRONLY | os.O_CREAT | os.O_TRUNC, 0o600)
        with os.fdopen(fd, "w") as f:
            json.dump(st, f)
        tmp.replace(self.dir / "state.json")

    def close(self, st, reason):
        st["state"] = "gone"
        st["closed"] = int(time.time())
        st["reason"] = reason
        self.save(st)
        line = f"{time.strftime('%FT%T%z')} closed: {reason}\n"
        fd = os.open(self.dir / "log", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600)
        with os.fdopen(fd, "a") as f:
            f.write(line)

    def live(self, st):
        if st["state"] == "gone" or (self.dir / "closed").exists():
            return False
        return time.time() < self.meta["expires"]


def sends():
    for d in sorted(SHARES.glob("send-*")):
        try:
            yield Send(d)
        except (OSError, ValueError, KeyError):
            continue


def find(token):
    found = None
    for s in sends():
        if hmac.compare_digest(s.meta.get("token", ""), token):
            found = s
    return found


PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1"><title>File</title>
<style>:root{{color-scheme:light dark;--bg:#fafaf7;--fg:#222;--mut:#666;--acc:#2d6cdf}}
@media (prefers-color-scheme:dark){{:root{{--bg:#16171a;--fg:#e8e8e8;--mut:#9a9a9a;--acc:#7aa7ff}}}}
body{{background:var(--bg);color:var(--fg);font:16px/1.5 system-ui,sans-serif;margin:0;padding:16px}}
main{{max-width:34rem;margin:10vh auto}}h1{{font-size:1.25rem;word-break:break-all}}
.m{{color:var(--mut);font-size:.85rem;word-break:break-all}}
button{{font:inherit;padding:.7rem 1.2rem;border:0;border-radius:.5rem;background:var(--acc);color:#fff;margin:.3rem .3rem 0 0}}
button.s{{background:transparent;color:var(--acc);border:1px solid var(--acc)}}[hidden]{{display:none}}</style>
</head><body><main><h1>{name}</h1><p class="m">{size} &middot; sha256 {sha}</p>
<p id="st">{status}</p><p><button id="dl"{dl}>Download</button>
<button id="ok" class="s"{ok}>I have the file</button></p>
<p class="m">Sent directly from the sender's machine while this page is open; not stored on a server.</p>
</main><script>
const S={js};const st=document.getElementById('st'),dl=document.getElementById('dl'),ok=document.getElementById('ok');
const base=location.pathname.replace(/\\/$/,'');
function done(){{fetch(base+'/done',{{method:'POST'}}).finally(()=>{{st.textContent='Done. This link is closed.';dl.hidden=ok.hidden=true}})}}
ok.onclick=done;
dl.onclick=async()=>{{
 if(S.size>S.blob){{location.href=base+'/file';st.textContent='Downloading in your browser. When it has finished, press "I have the file".';ok.hidden=false;return}}
 dl.disabled=true;st.textContent='Downloading 0%';
 try{{const r=await fetch(base+'/file');if(!r.ok)throw 0;const rd=r.body.getReader();const parts=[];let n=0;
  for(;;){{const {{done:d,value:v}}=await rd.read();if(d)break;parts.push(v);n+=v.length;st.textContent='Downloading '+Math.floor(100*n/S.size)+'%'}}
  if(n!==S.size)throw 0;const a=document.createElement('a');a.href=URL.createObjectURL(new Blob(parts));a.download=S.name;
  document.body.appendChild(a);a.click();
  if(S.mode==='bytes'){{st.textContent='Done. This link is closed.';dl.hidden=true}}
  else if(S.mode==='grace')done();
  else{{st.textContent='Saved. Press "I have the file" to close the link.';ok.hidden=false}}
 }}catch(e){{dl.disabled=false;st.textContent='The download broke off. Try again.'}}
}};
</script></body></html>
"""


def ascii_name(name):
    return re.sub(r"[^A-Za-z0-9._ -]", "_", name)


def n_zero(a, b):
    return not a and int(b) == 0


def human(n):
    for unit in ("B", "KiB", "MiB", "GiB"):
        if n < 1024 or unit == "GiB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


class Handler(BaseHTTPRequestHandler):
    protocol_version = "HTTP/1.0"
    timeout = 30
    server_version = "send"
    sys_version = ""
    slots = threading.BoundedSemaphore(MAX_CONNECTIONS)

    def handle(self):
        if not self.slots.acquire(blocking=False):
            return
        try:
            super().handle()
        finally:
            self.slots.release()

    def log_message(self, fmt, *args):
        pass

    def send_error(self, code, message=None, explain=None):
        self.not_found()

    def not_found(self):
        self.send_response(404)
        self.send_header("Content-Type", "text/plain")
        self.send_header("Content-Length", str(len(NOT_FOUND)))
        self.end_headers()
        if self.command != "HEAD":
            self.wfile.write(NOT_FOUND)

    def host_ok(self):
        want = DEFAULT_HOST
        try:
            for line in NAMES_FILE.read_text().splitlines():
                if line.split()[:1] == ["file"] and len(line.split()) == 2:
                    want = line.split()[1]
        except OSError:
            pass
        got = (self.headers.get("Host") or "").lower()
        return got == want or got.startswith(want + ":")

    def route(self):
        if not self.host_ok():
            return None, None
        m = TOKEN.match(urllib.parse.urlsplit(self.path).path)
        if not m:
            return None, None
        s = find(m.group(1))
        if s is None:
            return None, None
        with Send.lock:
            if not s.live(s.state()):
                return None, None
        return s, m.group(2) or ""

    def progress(self):
        got = progress.page(SAMPLER, urllib.parse.urlsplit(self.path).path)
        if got is None:
            return self.not_found()
        data, kind = got
        self.send_response(200)
        self.send_header("Content-Type", kind)
        self.send_header("Content-Length", str(len(data)))
        self.send_header("Cache-Control", "no-store")
        self.end_headers()
        self.wfile.write(data)

    def do_GET(self):
        if not self.host_ok():
            return self.progress()
        s, sub = self.route()
        if s is None:
            return self.not_found()
        if sub and sub != "/done":
            return self.file(s, direct=sub != "/file")
        if sub:
            return self.not_found()
        self.page(s)

    def do_POST(self):
        s, sub = self.route()
        length = self.headers.get("Content-Length", "0")
        if s is None or sub != "/done" or not length.isdigit() or int(length) > 1024:
            return self.not_found()
        self.rfile.read(int(length))
        with Send.lock:
            st = s.state()
            if not s.live(st) or st.get("completions", 0) < 1:
                return self.not_found()
            s.close(st, "receiver confirmed")
        self.send_response(204)
        self.end_headers()

    def page(self, s):
        st = s.state()
        meta = s.meta
        status = {
            "ready": "Ready.",
            "downloading": "A download is running.",
            "done": "Sent once. Download again if it did not arrive.",
        }[st["state"]]
        js = json.dumps(
            {
                "size": meta["size"],
                "name": meta["name"],
                "mode": meta["mode"],
                "blob": BLOB_LIMIT,
            }
        )
        body = PAGE.format(
            name=html.escape(meta["name"]),
            size=human(meta["size"]),
            sha=meta["sha256"],
            status=status,
            dl="",
            ok="" if st["state"] == "done" and meta["mode"] != "bytes" else " hidden",
            js=js.replace("<", "\\u003c"),
        ).encode()
        self.send_response(200)
        self.send_header("Content-Type", "text/html; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Cache-Control", "no-store")
        self.send_header("Referrer-Policy", "no-referrer")
        self.send_header("X-Content-Type-Options", "nosniff")
        self.send_header(
            "Content-Security-Policy",
            "default-src 'none'; style-src 'unsafe-inline'; script-src 'unsafe-inline'; "
            "connect-src 'self'; img-src 'none'; frame-ancestors 'none'",
        )
        self.end_headers()
        self.wfile.write(body)

    def byte_range(self, size):
        """(start, end) inclusive for the Range header; None when absent; False if unsatisfiable."""
        head = self.headers.get("Range")
        if not head:
            return None
        m = RANGE.match(head.strip())
        if not m or (not m.group(1) and not m.group(2)):
            return None
        a, b = m.groups()
        if not a:
            n = int(b)
            start, end = max(size - n, 0), size - 1
        else:
            start, end = int(a), min(int(b), size - 1) if b else size - 1
        if start >= size or start > end or n_zero(a, b):
            return False
        return start, end

    def file(self, s, direct=False):
        meta = s.meta
        rng = self.byte_range(meta["size"])
        resume = bool(rng) and rng[0] > 0
        me = secrets.token_hex(4)
        with Send.lock:
            st = s.state()
            active = (
                st["state"] == "downloading"
                and time.time() - st.get("progress", 0) < STALE
            )
            if active or (not resume and st["attempts"] >= MAX_ATTEMPTS):
                return self.not_found()
            try:
                f = open(meta["path"], "rb")  # noqa: SIM115 (closed by the with below)
            except OSError:
                return self.not_found()
            st.update(state="downloading", owner=me, progress=time.time())
            if resume:
                st["attempts"] = max(st["attempts"], 1)
            else:
                st.update(sent=0, attempts=st["attempts"] + 1)
            st["who"] = self.headers.get("X-Forwarded-For", "via tunnel")[:64]
            s.save(st)
        sent = 0
        start, length = 0, meta["size"]
        try:
            with f:
                if os.fstat(f.fileno()).st_size != meta["size"]:
                    raise OSError("file changed")
                quoted = urllib.parse.quote(meta["name"])
                if rng is False:
                    self.send_response(416)
                    self.send_header("Content-Range", f"bytes */{meta['size']}")
                    self.send_header("Content-Length", "0")
                    self.end_headers()
                    raise OSError("unsatisfiable range")
                if rng:
                    start, length = rng[0], rng[1] - rng[0] + 1
                    self.send_response(206)
                    self.send_header(
                        "Content-Range", f"bytes {rng[0]}-{rng[1]}/{meta['size']}"
                    )
                else:
                    self.send_response(200)
                self.send_header("Content-Type", "application/octet-stream")
                self.send_header("Accept-Ranges", "bytes")
                self.send_header("Content-Length", str(length))
                self.send_header(
                    "Content-Disposition",
                    f"attachment; filename=\"{ascii_name(meta['name'])}\"; filename*=UTF-8''{quoted}",
                )
                self.send_header("Cache-Control", "no-store")
                self.send_header("X-Content-Type-Options", "nosniff")
                self.end_headers()
                self.wfile.flush()
                self.connection.settimeout(60)
                last = 0.0
                f.seek(start)
                while length - sent > 0 and (
                    chunk := f.read(min(CHUNK, length - sent))
                ):
                    self.connection.sendall(chunk)
                    sent += len(chunk)
                    if time.monotonic() - last > 0.5:
                        last = time.monotonic()
                        with Send.lock:
                            st = s.state()
                            st["sent"] = max(st.get("sent", 0), start + sent)
                            if st.get("owner") == me:
                                st["progress"] = time.time()
                            s.save(st)
        except OSError:
            pass
        with Send.lock:
            st = s.state()
            if sent:
                st["sent"] = max(st.get("sent", 0), start + sent)
            if st.get("owner") != me:
                s.save(st)  # taken over while stale: only the byte count counts
                return
            complete = sent > 0 and st["sent"] >= meta["size"]
            if complete:
                st["completions"] = st.get("completions", 0) + 1
                st["completed_at"] = int(time.time())
                st["state"] = "done"
                st.setdefault("grace_until", int(time.time()) + GRACE)
                line = f"{time.strftime('%FT%T%z')} sent {sent} bytes to {st['who']}\n"
                fd = os.open(
                    s.dir / "log", os.O_WRONLY | os.O_CREAT | os.O_APPEND, 0o600
                )
                with os.fdopen(fd, "a") as lf:
                    lf.write(line)
                if meta["mode"] == "bytes":
                    s.close(st, "all bytes sent")
                    return
                if meta["mode"] == "grace" and direct:
                    s.close(st, "downloaded once by a command-line client")
                    return
            else:
                st["state"] = "done" if st.get("completions") else "ready"
            if (
                st["state"] != "gone"
                and st["attempts"] >= MAX_ATTEMPTS
                and not complete
            ):
                s.close(st, "attempts used up")
                return
            s.save(st)


def housekeeping():
    while True:
        now = time.time()
        for s in sends():
            with Send.lock:
                st = s.state()
                if st["state"] == "gone":
                    continue
                if (s.dir / "closed").exists():
                    s.close(st, (s.dir / "closed").read_text().strip() or "stopped")
                elif now >= s.meta["expires"]:
                    s.close(st, "expired")
                elif (
                    s.meta["mode"] == "grace" and st.get("grace_until", now + 1) <= now
                ):
                    s.close(st, "grace window over")
        time.sleep(1)


def main():
    threading.Thread(target=SAMPLER.loop, daemon=True).start()
    threading.Thread(target=housekeeping, daemon=True).start()
    server = ThreadingHTTPServer(("127.0.0.1", PORT), Handler)
    server.daemon_threads = True
    print(f"send gateway on 127.0.0.1:{PORT}", flush=True)
    server.serve_forever()


if __name__ == "__main__":
    sys.exit(main())
