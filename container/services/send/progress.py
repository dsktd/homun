"""Read-only progress page for file sends, served by the send service for any Host but the file host's
(through the proxy at /send/).

Reads ~/claude/.services/shares/send-*/{meta.json,state.json} and shows name, state, sent/size,
rate, ETA and expiry. It never shows tokens, URLs or paths: only the fields listed here leave
this process. Rate and ETA come from successive state.json samples taken every 2 s. Standard
library only; links are relative.
"""

import html
import json
import os
import sys
import threading
import time
from collections import deque
from pathlib import Path

SHARES = Path(os.environ.get("SHARES_DIR", Path.home() / "claude/.services/shares"))
SAMPLE_EVERY = 2
RATE_WINDOW = 12
RECENT = 24 * 3600

PAGE = """<!doctype html><html lang="en"><head><meta charset="utf-8">
<meta name="viewport" content="width=device-width,initial-scale=1">
<title>Transfers</title>
<style>
:root{color-scheme:light dark;--bg:#fff;--fg:#1d2127;--dim:#6b7280;--card:#f3f4f6;--bar:#d9dde3;--ok:#2563eb;--done:#16a34a}
@media(prefers-color-scheme:dark){:root{--bg:#14171c;--fg:#e5e7eb;--dim:#9aa3af;--card:#1d2229;--bar:#2c333c;--ok:#60a5fa;--done:#4ade80}}
body{margin:0;padding:1rem;background:var(--bg);color:var(--fg);font:16px/1.4 system-ui,sans-serif;max-width:46rem;margin-inline:auto}
h1{font-size:1.2rem;margin:.2rem 0 1rem}
.s{background:var(--card);border-radius:.6rem;padding:.7rem .9rem;margin:0 0 .8rem}
.n{font-weight:600;word-break:break-all}
.m{display:flex;flex-wrap:wrap;gap:.2rem 1rem;color:var(--dim);font-size:.9rem;margin-top:.3rem}
.b{height:.7rem;background:var(--bar);border-radius:.4rem;overflow:hidden;margin:.5rem 0 .2rem}
.b i{display:block;height:100%;background:var(--ok)}
.done .b i{background:var(--done)}
.empty{color:var(--dim)}
</style></head><body><h1>Transfers</h1>
<div id="l">@BODY@
<p class="empty">Updated @TIME@. Live.</p></div>
<script>setInterval(async()=>{try{const r=await fetch(location.href,{cache:"no-store"});const d=new DOMParser().parseFromString(await r.text(),"text/html").getElementById("l");if(d)document.getElementById("l").innerHTML=d.innerHTML}catch(e){}},1000)</script></body></html>
"""


def human(n):
    n = float(n)
    for unit in ("B", "KB", "MB", "GB", "TB"):
        if n < 1024 or unit == "TB":
            return f"{n:.0f} {unit}" if unit == "B" else f"{n:.1f} {unit}"
        n /= 1024


def span(sec):
    sec = int(sec)
    if sec < 60:
        return f"{sec}s"
    if sec < 3600:
        return f"{sec // 60}m {sec % 60:02d}s"
    return f"{sec // 3600}h {sec % 3600 // 60:02d}m"


class Sampler:
    """Keeps recent (time, sent) samples per send directory name; names never leave here."""

    def __init__(self):
        self.lock = threading.Lock()
        self.samples = {}

    def sample(self):
        now = time.time()
        with self.lock:
            for d in SHARES.glob("send-*"):
                st = read(d / "state.json")
                if st is None:
                    continue
                q = self.samples.setdefault(
                    d.name, deque(maxlen=RATE_WINDOW // SAMPLE_EVERY + 2)
                )
                q.append((now, int(st.get("sent", 0))))

    def rate(self, key):
        with self.lock:
            q = list(self.samples.get(key, ()))
        if len(q) < 2 or q[-1][0] - q[0][0] <= 0:
            return 0.0
        return max(0.0, (q[-1][1] - q[0][1]) / (q[-1][0] - q[0][0]))

    def loop(self):
        while True:
            try:
                self.sample()
            except (OSError, ValueError, TypeError) as e:
                print("sample:", e, file=sys.stderr, flush=True)
            time.sleep(SAMPLE_EVERY)


def read(path):
    try:
        return json.loads(path.read_text())
    except (OSError, ValueError):
        return None


def rows(sampler):
    now = time.time()
    out = []
    for d in sorted(SHARES.glob("send-*")):
        meta = read(d / "meta.json")
        if not isinstance(meta, dict):
            continue
        st = read(d / "state.json") or {"state": "ready", "sent": 0}
        try:
            mtime = (d / "state.json").stat().st_mtime
        except OSError:
            mtime = float(meta.get("expires") or 0)
        gone = st.get("state") == "gone" or (d / "closed").exists()
        expires = float(meta.get("expires") or 0)
        state = (
            "expired"
            if gone and st.get("reason") == "expired"
            else st.get("state", "ready")
        )
        if gone and state != "expired":
            state = "closed"
        elif not gone and expires and now >= expires:
            state, gone = "expired", True
        if gone and now - max(mtime, expires) > RECENT:
            continue
        size = int(meta.get("size") or 0)
        sent = min(int(st.get("sent") or 0), size) if size else int(st.get("sent") or 0)
        rate = sampler.rate(d.name) if state == "downloading" else 0.0
        eta = (size - sent) / rate if rate > 0 and size > sent else None
        out.append(
            {
                "name": str(meta.get("name", "?")),
                "state": state,
                "size": size,
                "sent": sent,
                "rate": rate,
                "eta": eta,
                "expires": expires,
                "attempts": int(st.get("attempts") or 0),
                "completions": int(st.get("completions") or 0),
                "active": not gone,
                "mtime": mtime,
            }
        )
    out.sort(key=lambda r: (not r["active"], -r["mtime"]))
    return out


def card(r):
    pct = 100 * r["sent"] / r["size"] if r["size"] else 0
    bits = [f"{human(r['sent'])} / {human(r['size'])} ({pct:.0f}%)"]
    if r["state"] == "downloading":
        bits.append(f"{human(r['rate'])}/s")
        bits.append(f"ETA {span(r['eta'])}" if r["eta"] is not None else "ETA ?")
    if r["attempts"]:
        bits.append(f"{r['attempts']} attempt{'s' * (r['attempts'] != 1)}")
    if r["expires"]:
        left = r["expires"] - time.time()
        bits.append(f"expires in {span(left)}" if left > 0 else "expired")
    cls = "s done" if r["state"] == "done" else "s"
    return (
        f'<div class="{cls}"><div class="n">{html.escape(r["name"])}</div>'
        f'<div class="m"><b>{html.escape(r["state"])}</b></div>'
        f'<div class="b"><i style="width:{pct:.1f}%"></i></div>'
        f'<div class="m">{"".join(f"<span>{html.escape(b)}</span>" for b in bits)}</div></div>'
    )


def render(sampler):
    rs = rows(sampler)
    body = "".join(card(r) for r in rs) or '<p class="empty">No sends right now.</p>'
    return PAGE.replace("@BODY@", body).replace("@TIME@", time.strftime("%H:%M:%S"))


def page(sampler, path):
    """(body, content type) for a progress path, or None."""
    if path in ("/", "/index.html"):
        return render(sampler).encode(), "text/html; charset=utf-8"
    if path == "/transfers.json":
        rs = [{k: v for k, v in r.items() if k != "mtime"} for r in rows(sampler)]
        return json.dumps(rs).encode(), "application/json"
    return None
